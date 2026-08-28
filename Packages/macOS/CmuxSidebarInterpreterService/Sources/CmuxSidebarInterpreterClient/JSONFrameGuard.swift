import Foundation

/// A non-recursive preflight for JSON received over a worker pipe.
/// `JSONDecoder` validates syntax, but it may recurse while decoding a deeply
/// nested value. Check string escapes and nesting first so malformed peer data
/// cannot use the decoder's native stack as a denial-of-service vector.
public enum JSONFrameGuard {
    /// A frame larger than the channel contract is never worth parsing. Keep
    /// this check here as well as in the channel so direct callers cannot
    /// bypass the allocation boundary.
    public static let maximumFrameBytes = LengthPrefixedMessageChannel.maximumFrameLength
    /// A peer that sends this many malformed frames without a valid response
    /// is not making progress. Callers should close the generation.
    public static let maximumConsecutiveInvalidFrames = 16

    /// Maximum amount of parser work represented by one frame. This is a
    /// syntax preflight, not a schema validator. Counting non-string bytes
    /// keeps a flat array of millions of tiny values from reaching
    /// `JSONDecoder` even when the byte frame cap is still technically valid.
    public static let defaultMaximumTokens = 200_000

    public static func isBounded(
        _ data: Data,
        maximumDepth: Int = 64,
        maximumTokens: Int = defaultMaximumTokens
    ) -> Bool {
        guard !data.isEmpty,
              data.count <= maximumFrameBytes,
              maximumDepth > 0,
              maximumTokens > 0 else { return false }
        var stack: [UInt8] = []
        stack.reserveCapacity(min(maximumDepth, 64))
        var inString = false
        var escaped = false
        var unicodeDigits = 0
        var tokenCount = 0

        for byte in data {
            if inString {
                if unicodeDigits > 0 {
                    guard isHex(byte) else { return false }
                    unicodeDigits -= 1
                    continue
                }
                if escaped {
                    if byte == 0x75 { // `u`
                        unicodeDigits = 4
                    } else {
                        guard byte == 0x22 || byte == 0x5C || byte == 0x2F
                            || byte == 0x62 || byte == 0x66 || byte == 0x6E
                            || byte == 0x72 || byte == 0x74 else { return false }
                    }
                    escaped = false
                } else if byte == 0x5C { // backslash
                    escaped = true
                } else if byte == 0x22 { // quote
                    inString = false
                } else {
                    guard byte >= 0x20 else { return false }
                }
                continue
            }

            switch byte {
            case 0x22: // quote
                inString = true
                tokenCount += 1
                guard tokenCount <= maximumTokens else { return false }
            case 0x7B, 0x5B: // `{`, `[`
                stack.append(byte)
                tokenCount += 1
                guard stack.count <= maximumDepth, tokenCount <= maximumTokens else { return false }
            case 0x7D, 0x5D: // `}`, `]`
                guard let opener = stack.popLast(),
                      (opener == 0x7B && byte == 0x7D) || (opener == 0x5B && byte == 0x5D) else {
                    return false
                }
                tokenCount += 1
                guard tokenCount <= maximumTokens else { return false }
            case 0x20, 0x09, 0x0A, 0x0D:
                continue
            default:
                tokenCount += 1
                guard tokenCount <= maximumTokens else { return false }
            }
        }
        return !inString && !escaped && unicodeDigits == 0 && stack.isEmpty
    }

    private static func isHex(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39)
            || (byte >= 0x41 && byte <= 0x46)
            || (byte >= 0x61 && byte <= 0x66)
    }
}
