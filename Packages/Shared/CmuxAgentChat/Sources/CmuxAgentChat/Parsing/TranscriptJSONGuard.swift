import Foundation

/// Cheap, iterative limits for one untrusted transcript JSONL line. The
/// typed decoder remains the grammar authority, but it must not be the first
/// code to walk attacker-controlled nesting.
enum TranscriptJSONGuard {
    static let maximumLineBytes = 1 * 1024 * 1024
    static let maximumDepth = 64
    static let maximumTokens = 100_000

    static func isBounded(
        _ data: Data,
        maximumDepth: Int = Self.maximumDepth,
        maximumTokens: Int = Self.maximumTokens
    ) -> Bool {
        guard !data.isEmpty,
              data.count <= Self.maximumLineBytes,
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
                } else if escaped {
                    if byte == 0x75 {
                        unicodeDigits = 4
                    } else {
                        guard byte == 0x22 || byte == 0x5C || byte == 0x2F
                            || byte == 0x62 || byte == 0x66 || byte == 0x6E
                            || byte == 0x72 || byte == 0x74 else { return false }
                    }
                    escaped = false
                } else if byte == 0x5C {
                    escaped = true
                } else if byte == 0x22 {
                    inString = false
                } else {
                    guard byte >= 0x20 else { return false }
                }
                continue
            }

            switch byte {
            case 0x22:
                inString = true
                tokenCount += 1
            case 0x7B, 0x5B:
                stack.append(byte)
                tokenCount += 1
                guard stack.count <= maximumDepth else { return false }
            case 0x7D, 0x5D:
                guard let opener = stack.popLast(),
                      (opener == 0x7B && byte == 0x7D) || (opener == 0x5B && byte == 0x5D) else {
                    return false
                }
                tokenCount += 1
            case 0x20, 0x09, 0x0A, 0x0D:
                continue
            default:
                tokenCount += 1
            }
            guard tokenCount <= maximumTokens else { return false }
        }
        return !inString && !escaped && unicodeDigits == 0 && stack.isEmpty
    }

    private static func isHex(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39)
            || (byte >= 0x41 && byte <= 0x46)
            || (byte >= 0x61 && byte <= 0x66)
    }
}
