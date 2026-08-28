/// Cheap, non-recursive lexical limits applied before SwiftSyntax parses
/// authored sidebar source. SwiftSyntax is resilient to malformed syntax, but
/// extremely deep delimiter nesting can still consume the parser's native
/// stack before it reports an error. This guard rejects only excessive
/// nesting; ordinary syntax validation remains SwiftSyntax's job.
enum SwiftSourceSecurityGuard {
    /// A legitimate sidebar rarely nests more than a few dozen expressions.
    /// Keep a generous ceiling while staying well below a stack-exhaustion
    /// shape for the 4 MB parser worker stack.
    static let maximumDelimiterDepth = 1_024

    /// Delimiters in a string interpolation are normally skipped with the
    /// string body. A long contiguous run is still a cheap signal for a
    /// hostile interpolation payload, so cap it independently.
    static let maximumOpeningRun = 4_096

    static func isWithinLimits(_ source: String) -> Bool {
        let bytes = Array(source.utf8)
        var delimiters: [Delimiter] = []
        delimiters.reserveCapacity(64)
        var lineComment = false
        var blockCommentDepth = 0
        var stringState: StringState?
        // String literals can contain interpolated Swift expressions. Keep
        // the paused string states so delimiters inside those expressions are
        // counted by the same depth guard as ordinary source.
        var interpolationStrings: [StringState] = []
        var openingRun = 0
        var index = 0

        while index < bytes.count {
            let byte = bytes[index]

            if lineComment {
                if byte == 0x0A || byte == 0x0D { lineComment = false }
                openingRun = 0
                index += 1
                continue
            }

            if blockCommentDepth > 0 {
                if byte == 0x2F, peek(bytes, index + 1) == 0x2A {
                    blockCommentDepth += 1
                    index += 2
                } else if byte == 0x2A, peek(bytes, index + 1) == 0x2F {
                    blockCommentDepth -= 1
                    index += 2
                } else {
                    index += 1
                }
                openingRun = 0
                continue
            }

            if let state = stringState {
                if let interpolationLength = interpolationStartLength(bytes, at: index, state: state) {
                    interpolationStrings.append(state)
                    stringState = nil
                    delimiters.append(.interpolation)
                    guard delimiters.count <= maximumDelimiterDepth else { return false }
                    openingRun += 1
                    guard openingRun <= maximumOpeningRun else { return false }
                    index += interpolationLength
                    continue
                }
                if byte == 0x5C { // backslash escape
                    // Skip the escaped scalar. Raw strings may include hash
                    // markers after the slash; skipping one byte is safe for
                    // the depth check and keeps this scanner deliberately
                    // conservative.
                    index += min(2, bytes.count - index)
                    openingRun = 0
                    continue
                }
                if byte == 0x22,
                   let consumed = closingQuoteLength(bytes, at: index, state: state) {
                    stringState = nil
                    index += consumed
                    openingRun = 0
                    continue
                }
                if isOpeningDelimiter(byte) {
                    openingRun += 1
                    if openingRun > maximumOpeningRun { return false }
                } else {
                    openingRun = 0
                }
                index += 1
                continue
            }

            if byte == 0x2F, peek(bytes, index + 1) == 0x2F {
                lineComment = true
                openingRun = 0
                index += 2
                continue
            }
            if byte == 0x2F, peek(bytes, index + 1) == 0x2A {
                blockCommentDepth = 1
                openingRun = 0
                index += 2
                continue
            }
            if let (hashes, multiline, consumed) = openingQuote(bytes, at: index) {
                stringState = StringState(hashes: hashes, multiline: multiline)
                openingRun = 0
                index += consumed
                continue
            }

            if isOpeningDelimiter(byte) {
                delimiters.append(.normal(byte))
                openingRun += 1
                guard delimiters.count <= maximumDelimiterDepth,
                      openingRun <= maximumOpeningRun else { return false }
            } else {
                openingRun = 0
                if let top = delimiters.last {
                    switch top {
                    case .normal(let opener):
                        if let matching = matchingOpening(for: byte), opener == matching {
                            delimiters.removeLast()
                        }
                    case .interpolation where byte == 0x29: // `)`
                        delimiters.removeLast()
                        stringState = interpolationStrings.popLast()
                    case .interpolation:
                        break
                    }
                }
            }
            index += 1
        }
        return true
    }

    private struct StringState {
        let hashes: Int
        let multiline: Bool
    }

    private enum Delimiter {
        case normal(UInt8)
        case interpolation
    }

    private static func peek(_ bytes: [UInt8], _ index: Int) -> UInt8? {
        guard index < bytes.count else { return nil }
        return bytes[index]
    }

    private static func isOpeningDelimiter(_ byte: UInt8) -> Bool {
        byte == 0x28 || byte == 0x5B || byte == 0x7B // ( [ {
    }

    private static func matchingOpening(for closing: UInt8) -> UInt8? {
        switch closing {
        case 0x29: return 0x28 // )
        case 0x5D: return 0x5B // ]
        case 0x7D: return 0x7B // }
        default: return nil
        }
    }

    /// Returns the byte length of a Swift string-interpolation opener (`\\(`,
    /// or `\\#(` for an extended string), if one begins at `index`.
    private static func interpolationStartLength(
        _ bytes: [UInt8],
        at index: Int,
        state: StringState
    ) -> Int? {
        guard peek(bytes, index) == 0x5C else { return nil } // `\\`
        var cursor = index + 1
        for _ in 0..<state.hashes {
            guard peek(bytes, cursor) == 0x23 else { return nil }
            cursor += 1
        }
        guard peek(bytes, cursor) == 0x28 else { return nil } // `(`
        return cursor - index + 1
    }

    private static func openingQuote(
        _ bytes: [UInt8],
        at index: Int
    ) -> (hashes: Int, multiline: Bool, consumed: Int)? {
        var cursor = index
        var hashes = 0
        while peek(bytes, cursor) == 0x23 { // #
            hashes += 1
            cursor += 1
            // Swift extended string delimiters are short in practice. This
            // cap also prevents a run of hashes from becoming scanner work.
            if hashes > 16 { return nil }
        }
        guard peek(bytes, cursor) == 0x22 else { return nil } // "
        let multiline = peek(bytes, cursor + 1) == 0x22
            && peek(bytes, cursor + 2) == 0x22
        let quoteBytes = multiline ? 3 : 1
        return (hashes, multiline, cursor - index + quoteBytes)
    }

    private static func closingQuoteLength(
        _ bytes: [UInt8],
        at index: Int,
        state: StringState
    ) -> Int? {
        let quoteBytes = state.multiline ? 3 : 1
        guard (0..<quoteBytes).allSatisfy({ peek(bytes, index + $0) == 0x22 }) else {
            return nil
        }
        let hashStart = index + quoteBytes
        guard (0..<state.hashes).allSatisfy({ peek(bytes, hashStart + $0) == 0x23 }) else {
            return nil
        }
        return quoteBytes + state.hashes
    }
}
