import Foundation

/// Iterative limits applied before Foundation parses a control-socket JSON
/// line. Socket clients are local, but a client can still be a compromised
/// process owned by the same user. Keeping hostile nesting and token counts
/// out of `JSONSerialization` prevents parser stack and allocation abuse.
enum ControlJSONGuard {
    /// The largest v2 request line accepted after UTF-8 encoding.
    static let maximumBytes = 8 * 1024 * 1024
    /// Envelope fields are deliberately much smaller than the full line. A
    /// long method or parameter key cannot select a valid command and only
    /// adds dictionary/hash work before dispatch.
    static let maximumMethodBytes = 128
    static let maximumParameterKeyBytes = 128
    static let maximumParameterCount = 256
    /// Maximum container nesting accepted by the wire protocol.
    static let maximumDepth = 64
    /// Maximum lexical tokens passed to Foundation. String contents are
    /// counted as one token, so a large but bounded text parameter remains
    /// possible without allowing millions of tiny values.
    static let maximumTokens = 200_000

    /// Checks a typed value before it is bridged through the recursive
    /// `JSONValue.foundationObject` property. Values can be assembled by
    /// trusted Swift call sites, but a compromised local client can still make
    /// those call sites carry very large response data. Keep this walk
    /// iterative so a malformed value cannot exhaust the native stack before
    /// `JSONSerialization` gets a chance to reject it.
    static func isBounded(_ value: JSONValue) -> Bool {
        var pending: [(value: JSONValue, depth: Int)] = [(value, 0)]
        pending.reserveCapacity(64)
        var bytes = 0
        var tokens = 0

        while let entry = pending.popLast() {
            guard entry.depth <= maximumDepth else { return false }
            tokens += 1
            guard tokens <= maximumTokens else { return false }

            switch entry.value {
            case .null, .bool, .int:
                break
            case .double(let number):
                guard number.isFinite else { return false }
            case .decimal(let text):
                guard !text.isEmpty,
                      text.utf8.count <= 4 * 1024,
                      !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                      NSDecimalNumber(string: text, locale: Locale(identifier: "en_US_POSIX")) != .notANumber else {
                    return false
                }
                guard add(text.utf8.count, to: &bytes) else { return false }
            case .string(let text):
                guard add(text.utf8.count, to: &bytes) else { return false }
            case .array(let values):
                guard values.count <= maximumTokens else { return false }
                pending.append(contentsOf: values.map { ($0, entry.depth + 1) })
            case .object(let fields):
                guard fields.count <= maximumTokens else { return false }
                for (key, value) in fields {
                    guard !key.isEmpty,
                          key.utf8.count <= 64 * 1024,
                          !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                        return false
                    }
                    guard add(key.utf8.count, to: &bytes) else { return false }
                    pending.append((value, entry.depth + 1))
                }
            }
            guard bytes <= maximumBytes else { return false }
        }
        return true
    }

    private static func add(_ amount: Int, to total: inout Int) -> Bool {
        let (sum, overflow) = total.addingReportingOverflow(amount)
        guard !overflow, sum <= maximumBytes else { return false }
        total = sum
        return true
    }

    static func isBounded(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count <= maximumBytes else { return false }

        var stack: [UInt8] = []
        stack.reserveCapacity(maximumDepth)
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
                    if byte == 0x75 { // `u`
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
                    // JSON strings cannot contain raw C0 control bytes.
                    guard byte >= 0x20 else { return false }
                }
                continue
            }

            switch byte {
            case 0x22: // `"`
                inString = true
                tokenCount += 1
            case 0x7B, 0x5B: // `{`, `[`
                stack.append(byte)
                tokenCount += 1
                guard stack.count <= maximumDepth else { return false }
            case 0x7D, 0x5D: // `}`, `]`
                guard let opener = stack.popLast(),
                      (opener == 0x7B && byte == 0x7D)
                          || (opener == 0x5B && byte == 0x5D) else {
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
