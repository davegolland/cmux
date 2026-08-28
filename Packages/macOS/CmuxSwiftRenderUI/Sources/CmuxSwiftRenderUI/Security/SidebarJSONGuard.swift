import CoreFoundation
import Foundation

/// Non-recursive checks used immediately before Foundation JSON parsing.
/// Foundation's parser is correct, but it can do recursive work for hostile
/// nesting and it accepts arbitrary Foundation object graphs when callers
/// pass `Any`. These checks keep both paths bounded and fail closed.
public enum SidebarJSONGuard {
    public static func isBoundedSyntax(
        _ data: Data,
        maximumDepth: Int = SidebarSecurityLimits.maxDSLDepth,
        maximumTokens: Int = 200_000,
        maximumBytes: Int = 8 * 1024 * 1024
    ) -> Bool {
        guard !data.isEmpty,
              maximumDepth > 0,
              maximumTokens > 0,
              maximumBytes > 0,
              data.count <= maximumBytes else { return false }

        var stack: [UInt8] = []
        stack.reserveCapacity(min(maximumDepth, 64))
        var inString = false
        var escaped = false
        var unicodeDigits = 0
        var tokenCount = 0
        var sawValue = false

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
                } else if byte == 0x5C {
                    escaped = true
                } else if byte == 0x22 {
                    inString = false
                } else {
                    // JSON strings cannot contain raw C0 controls.
                    guard byte >= 0x20 else { return false }
                }
                continue
            }

            switch byte {
            case 0x22: // `"`
                inString = true
                sawValue = true
            case 0x7B, 0x5B: // `{`, `[`
                stack.append(byte)
                tokenCount += 1
                sawValue = true
                guard stack.count <= maximumDepth, tokenCount <= maximumTokens else { return false }
            case 0x7D, 0x5D: // `}`, `]`
                guard let opener = stack.popLast(),
                      (opener == 0x7B && byte == 0x7D) || (opener == 0x5B && byte == 0x5D) else {
                    return false
                }
                tokenCount += 1
                guard tokenCount <= maximumTokens else { return false }
            case 0x2C, 0x3A: // `,`, `:`
                tokenCount += 1
                guard tokenCount <= maximumTokens else { return false }
            case 0x20, 0x09, 0x0A, 0x0D:
                continue
            default:
                // Foundation performs the full literal/number validation.
                // We only need to know that the frame contains some value.
                sawValue = true
            }
        }

        return sawValue && !inString && !escaped && unicodeDigits == 0 && stack.isEmpty
    }

    /// Checks a Foundation object graph without recursion. `value` must be a
    /// JSON-compatible graph. The byte budget is an estimate; callers still
    /// check the exact encoded length after `JSONSerialization`.
    public static func isBoundedObject(
        _ value: Any,
        maximumBytes: Int,
        maximumDepth: Int = SidebarSecurityLimits.maxDSLDepth,
        maximumNodes: Int = 100_000,
        maximumCollectionItems: Int = SidebarSecurityLimits.maxSceneChildren,
        maximumStringBytes: Int = SidebarSecurityLimits.maxSceneStringBytes,
        maximumNumberMagnitude: Double? = nil,
        rejectUnsafeControls: Bool = true
    ) -> Bool {
        guard maximumBytes > 0, maximumDepth > 0, maximumNodes > 0,
              maximumCollectionItems > 0, maximumStringBytes > 0,
              maximumNumberMagnitude.map({ $0.isFinite && $0 >= 0 }) ?? true else { return false }

        var stack: [(value: Any, depth: Int)] = [(value, 0)]
        var nodes = 0
        var estimatedBytes = 0

        while let entry = stack.popLast() {
            nodes += 1
            guard nodes <= maximumNodes, entry.depth <= maximumDepth else { return false }

            if entry.value is NSNull {
                continue
            }
            if let string = entry.value as? String {
                let count = string.utf8.count
                guard count <= maximumStringBytes,
                      !rejectUnsafeControls || string.unicodeScalars.allSatisfy({
                          !CharacterSet.controlCharacters.contains($0)
                              || $0 == "\n" || $0 == "\r" || $0 == "\t"
                      }),
                      estimatedBytes <= maximumBytes - count else {
                    return false
                }
                estimatedBytes += count
                continue
            }
            if let number = entry.value as? NSNumber {
                if CFGetTypeID(number) != CFBooleanGetTypeID() {
                    let value = number.doubleValue
                    guard value.isFinite,
                          maximumNumberMagnitude.map({ abs(value) <= $0 }) ?? true else {
                        return false
                    }
                }
                estimatedBytes += 8
                guard estimatedBytes <= maximumBytes else { return false }
                continue
            }
            if let array = entry.value as? [Any] {
                guard array.count <= maximumCollectionItems else { return false }
                estimatedBytes += 2
                guard estimatedBytes <= maximumBytes else { return false }
                for child in array.reversed() {
                    stack.append((child, entry.depth + 1))
                }
                continue
            }
            if let object = entry.value as? [String: Any] {
                guard object.count <= maximumCollectionItems else { return false }
                estimatedBytes += 2
                guard estimatedBytes <= maximumBytes else { return false }
                for (key, child) in object {
                    let keyBytes = key.utf8.count
                    guard !key.isEmpty,
                          keyBytes <= SidebarSecurityLimits.maxIdentifierBytes,
                          !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                          estimatedBytes <= maximumBytes - keyBytes else {
                        return false
                    }
                    estimatedBytes += keyBytes
                    stack.append((child, entry.depth + 1))
                }
                continue
            }

            // Dates, URLs, custom objects, and non-string dictionary keys do
            // not belong on a JSON bridge.
            return false
        }
        return true
    }

    private static func isHex(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39)
            || (byte >= 0x41 && byte <= 0x46)
            || (byte >= 0x61 && byte <= 0x66)
    }
}
