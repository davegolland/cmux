/// Detects LaTeX math spans in raw terminal text.
///
/// Agents such as Claude Code print LaTeX straight into the terminal grid.
/// This detector finds the delimited spans so the terminal can render them,
/// using the same delimiter rules as the markdown viewer's `cmux-math.js`
/// (`findEndOfMath`, `matchPairAt`, `matchInlineDollarAt`, `matchParenAt`,
/// `matchBracketAt`, `matchBlockAt`, `looksLikeTeX`, and `splitText`), so a
/// formula reads the same in both surfaces:
///
/// | Delimiters   | Kind                                                     |
/// |--------------|----------------------------------------------------------|
/// | `$$ ... $$`  | display: on its own line(s), or inline with no space just inside the delimiters |
/// | `\[ ... \]`  | display: only on its own line(s)                         |
/// | `\( ... \)`  | inline, when the body has the shape of TeX               |
/// | `$ ... $`    | inline, Pandoc rules plus an identifier rule (see below) |
///
/// The rules for `$ ... $`: the opening `$` has a non-space character
/// immediately to its right that is not another `$`; the closing `$` has a
/// non-space character immediately to its left; the closing `$` is not
/// immediately followed by a digit, another `$`, an ASCII letter, `_`, `(`,
/// or `{` (so a second variable never closes a first one); the opening `$`
/// is not immediately preceded by another `$` (so a streamed `$$x$`, one
/// character short of its closer, stays literal); and the body spans no
/// blank line.
///
/// A `$$ ... $$` that starts a line (after at most three spaces of
/// indentation) and whose closer ends its line is one display block and may
/// contain newlines and padding. Anywhere else `$$`
/// is "tight": the body must touch both delimiters, so two literal `$$`
/// tokens in a sentence never pair up. A `\[ ... \]` is math only as such a
/// block; mid-sentence it is a literal bracket. A `\( ... \)` is math only
/// when the trimmed body has no whitespace or the body contains one of
/// `\ ^ _ = + - * / < > { } |`, so prose like `\(see above\)` stays prose.
///
/// In every form a backslash escapes the next character, braces nest so a
/// `$` inside `{ ... }` never closes, an empty or blank body is not math, an
/// unterminated delimiter is not math (a half-received `$$` stays literal
/// until its closing pair streams in), and `\$` never opens math. Every
/// search is bounded: a `$` or `\(` closer is sought within 2048 scalars, a
/// `$$` or `\[` closer within 8192, and an open brace with no closing brace
/// ahead in that window ends the search.
///
/// A false positive is worse than no rendering, so `echo $PATH`, `$1`,
/// `${FOO}`, `$?`, `$HOME/$USER`, `PATH=$HOME/bin:$PATH`, `echo $$`, and
/// "it costs $5 to $10" all stay literal.
///
/// Input may include VT escape sequences, such as those emitted by a terminal
/// screen export. They are removed by ``TerminalEscapeSequenceStripper``
/// before scanning, and every ``TerminalMathSpan/range`` indexes the stripped
/// text returned by ``strippedText(_:)``, never the raw input.
///
/// ```swift
/// let detector = TerminalMathSpanDetector()
/// let text = "draw each entry from $\\mathcal{N}(0, 1/m)$."
/// guard detector.hasMath(in: text) else { return }
/// let spans = detector.spans(in: text)
/// spans[0].body      // "\\mathcal{N}(0, 1/m)"
/// spans[0].isDisplay // false
/// ```
public struct TerminalMathSpanDetector: Sendable {
    /// A match expressed as scalar offsets into the stripped text.
    private struct Candidate {
        let start: Int
        let bodyStart: Int
        let bodyEnd: Int
        let end: Int
        let isDisplay: Bool
    }

    /// Converts ascending scalar offsets to `String.Index` in one forward pass.
    private struct ScalarOffsetCursor {
        private let view: String.UnicodeScalarView
        private var index: String.Index
        private var offset = 0

        init(view: String.UnicodeScalarView) {
            self.view = view
            self.index = view.startIndex
        }

        mutating func index(at target: Int) -> String.Index {
            if target < offset {
                index = view.startIndex
                offset = 0
            }
            index = view.index(index, offsetBy: target - offset)
            offset = target
            return index
        }
    }

    /// Answers "is there a `}` in `[index, limit)`" for the ascending brace
    /// positions one scan visits, re-searching only past the last `}` found
    /// so a scan window costs one pass however many braces it holds.
    private struct CloseBraceLookahead {
        private var searchedFrom = -1
        private var found: Int?

        mutating func exists(from index: Int, before limit: Int, in scalars: [Unicode.Scalar]) -> Bool {
            if searchedFrom >= 0, index >= searchedFrom {
                guard let found else { return false }
                if found >= index { return found < limit }
            }
            searchedFrom = index
            found = scalars[index..<limit].firstIndex(of: TerminalMathSpanDetector.closeBrace)
            return found != nil
        }
    }

    /// Scalars a `$ ... $` or `\( ... \)` body may span.
    private static let maxInlineScan = 2048
    /// Scalars a `$$ ... $$` or `\[ ... \]` body may span.
    private static let maxDisplayScan = 8192
    /// Scalars after a block closer that may hold trailing spaces before the
    /// line ending.
    private static let maxBlockTailWindow = 64

    private static let dollar: Unicode.Scalar = "$"
    private static let backslash: Unicode.Scalar = "\\"
    private static let openBrace: Unicode.Scalar = "{"
    private static let closeBrace: Unicode.Scalar = "}"
    private static let lineFeed: Unicode.Scalar = "\n"
    private static let carriageReturn: Unicode.Scalar = "\r"
    private static let space: Unicode.Scalar = " "
    private static let tab: Unicode.Scalar = "\t"

    private static let displayDollar: [Unicode.Scalar] = ["$", "$"]
    private static let bracketOpen: [Unicode.Scalar] = ["\\", "["]
    private static let bracketClose: [Unicode.Scalar] = ["\\", "]"]
    private static let parenOpen: [Unicode.Scalar] = ["\\", "("]
    private static let parenClose: [Unicode.Scalar] = ["\\", ")"]

    /// The characters that give a `\( ... \)` body the shape of TeX.
    private static let texShapeScalars: Set<Unicode.Scalar> = [
        "\\", "^", "_", "=", "+", "-", "*", "/", "<", ">", "{", "}", "|",
    ]

    /// Creates a detector.
    public init() {}

    /// Returns whether `text` contains at least one math span.
    ///
    /// Text with no `$`, `\(`, or `\[` returns `false` without stripping or
    /// scanning, so callers can run this on every screen update. Otherwise the
    /// result matches `!spans(in: text).isEmpty`, but the scan stops at the
    /// first span.
    ///
    /// - Parameter text: Plain or VT-escaped terminal text.
    /// - Returns: `true` when ``spans(in:)`` would return at least one span.
    public func hasMath(in text: String) -> Bool {
        guard Self.containsCandidateOpener(text) else { return false }
        let scalars = Array(strippedText(text).unicodeScalars)
        return !Self.candidates(in: scalars, stopAfterFirst: true).isEmpty
    }

    /// Returns `text` with VT escape sequences removed.
    ///
    /// This is the string that every ``TerminalMathSpan/range`` from
    /// ``spans(in:)`` indexes. Plain text comes back unchanged.
    ///
    /// - Parameter text: Plain or VT-escaped terminal text.
    /// - Returns: The visible text without escape sequences.
    public func strippedText(_ text: String) -> String {
        TerminalEscapeSequenceStripper().strip(text)
    }

    /// Returns every math span in `text`, in display order.
    ///
    /// Spans never overlap: scanning resumes after each match, exactly as
    /// `cmux-math.js`'s `splitText` does, so `a $x$ b $y$ c` yields `$x$`
    /// then `$y$`. A block span's ``TerminalMathSpan/source`` is the delimited
    /// text only; the trailing spaces and line ending that `splitText` folds
    /// into its `raw` are left in place.
    ///
    /// - Parameter text: Plain or VT-escaped terminal text.
    /// - Returns: The detected spans, with ranges into ``strippedText(_:)``.
    public func spans(in text: String) -> [TerminalMathSpan] {
        let stripped = strippedText(text)
        let scalars = Array(stripped.unicodeScalars)
        let candidates = Self.candidates(in: scalars, stopAfterFirst: false)
        guard !candidates.isEmpty else { return [] }

        var cursor = ScalarOffsetCursor(view: stripped.unicodeScalars)
        return candidates.map { candidate in
            let start = cursor.index(at: candidate.start)
            let end = cursor.index(at: candidate.end)
            return TerminalMathSpan(
                source: Self.string(scalars[candidate.start..<candidate.end]),
                body: Self.string(scalars[candidate.bodyStart..<candidate.bodyEnd]),
                isDisplay: candidate.isDisplay,
                range: start..<end
            )
        }
    }

    // MARK: - Scanning

    /// Port of `splitText`: walks the text and collects every match, skipping
    /// `\$` so an escaped dollar never opens math. A `$$` or `\[` that starts
    /// a line (see ``startsLine(_:at:)``) is tried as a block first; the
    /// indentation stays outside the span. `\[` is never inline math.
    private static func candidates(in scalars: [Unicode.Scalar], stopAfterFirst: Bool) -> [Candidate] {
        var result: [Candidate] = []
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            let next: Unicode.Scalar? = index + 1 < scalars.count ? scalars[index + 1] : nil
            if scalar == backslash, next == dollar {
                index += 2
                continue
            }
            guard scalar == dollar || scalar == backslash else {
                index += 1
                continue
            }
            let isBracket = scalar == backslash && next == "["
            var candidate: Candidate?
            if isBracket || (scalar == dollar && next == dollar), startsLine(scalars, at: index) {
                candidate = matchBlock(scalars, at: index)
            }
            if candidate == nil, !isBracket {
                candidate = matchInline(scalars, at: index)
            }
            guard let candidate else {
                index += 1
                continue
            }
            result.append(candidate)
            if stopAfterFirst { return result }
            index = candidate.end
        }
        return result
    }

    /// The own-line test from `splitText`: the delimiter at `index` follows
    /// the start of the text or a `\n`, with at most three spaces of
    /// indentation between (Claude Code indents terminal output by two).
    /// Four or more spaces, or a tab, do not count.
    private static func startsLine(_ scalars: [Unicode.Scalar], at index: Int) -> Bool {
        var back = index
        while back > 0, back > index - 3, scalars[back - 1] == space {
            back -= 1
        }
        return back == 0 || scalars[back - 1] == lineFeed
    }

    /// Port of `matchBlockAt` for a delimiter that starts its line: the whole
    /// block is one display equation, and the closer must be followed by
    /// optional spaces and a line ending or the end of the text, so
    /// `$$x$$ then prose` stays on the inline path.
    private static func matchBlock(_ scalars: [Unicode.Scalar], at index: Int) -> Candidate? {
        let candidate: Candidate?
        if hasPrefix(displayDollar, in: scalars, at: index) {
            candidate = matchPair(
                scalars, at: index, open: displayDollar, close: displayDollar,
                isDisplay: true, maxScan: maxDisplayScan, tight: false
            )
        } else if hasPrefix(bracketOpen, in: scalars, at: index) {
            candidate = matchPair(
                scalars, at: index, open: bracketOpen, close: bracketClose,
                isDisplay: true, maxScan: maxDisplayScan, tight: false
            )
        } else {
            candidate = nil
        }
        guard let candidate, hasBlockTail(scalars, after: candidate.end) else { return nil }
        return candidate
    }

    /// The block tail rule: spaces or tabs, then `\n`, `\r\n`, or the end of
    /// the text, all within a 64-scalar window after the closer.
    private static func hasBlockTail(_ scalars: [Unicode.Scalar], after: Int) -> Bool {
        let windowEnd = min(scalars.count, after + maxBlockTailWindow)
        var cursor = after
        while cursor < windowEnd, scalars[cursor] == space || scalars[cursor] == tab {
            cursor += 1
        }
        if cursor == scalars.count { return true }
        if cursor == windowEnd { return false }
        if scalars[cursor] == lineFeed { return true }
        return scalars[cursor] == carriageReturn
            && cursor + 1 < windowEnd
            && scalars[cursor + 1] == lineFeed
    }

    /// Port of `matchInlineAt`: tries tight `$$` before `$` so `$$` is never
    /// read as an empty `$ $`; a backslash can only open `\(`.
    private static func matchInline(_ scalars: [Unicode.Scalar], at index: Int) -> Candidate? {
        let scalar = scalars[index]
        if scalar == dollar {
            return matchPair(
                scalars, at: index, open: displayDollar, close: displayDollar,
                isDisplay: true, maxScan: maxDisplayScan, tight: true
            ) ?? matchInlineDollar(scalars, at: index)
        }
        if scalar == backslash {
            return matchParen(scalars, at: index)
        }
        return nil
    }

    /// Port of `matchParenAt`: `\( ... \)` whose body looks like TeX.
    private static func matchParen(_ scalars: [Unicode.Scalar], at index: Int) -> Candidate? {
        guard let candidate = matchPair(
            scalars, at: index, open: parenOpen, close: parenClose,
            isDisplay: false, maxScan: maxInlineScan, tight: false
        ), looksLikeTeX(scalars[candidate.bodyStart..<candidate.bodyEnd]) else { return nil }
        return candidate
    }

    /// Port of `matchPairAt`: a generic two-character delimiter pair. With
    /// `tight`, the body must touch both delimiters.
    private static func matchPair(
        _ scalars: [Unicode.Scalar],
        at index: Int,
        open: [Unicode.Scalar],
        close: [Unicode.Scalar],
        isDisplay: Bool,
        maxScan: Int,
        tight: Bool
    ) -> Candidate? {
        guard hasPrefix(open, in: scalars, at: index) else { return nil }
        let bodyStart = index + open.count
        guard let bodyEnd = findEndOfMath(close, in: scalars, from: bodyStart, maxScan: maxScan) else { return nil }
        let body = scalars[bodyStart..<bodyEnd]
        guard isMathBody(body) else { return nil }
        if tight, let first = body.first, let last = body.last, isSpace(first) || isSpace(last) {
            return nil
        }
        return Candidate(
            start: index,
            bodyStart: bodyStart,
            bodyEnd: bodyEnd,
            end: bodyEnd + close.count,
            isDisplay: isDisplay
        )
    }

    /// Port of `matchInlineDollarAt`: `$ ... $` with the Pandoc rules plus
    /// the identifier rule for the character after the closer, and the rule
    /// that the second `$` of an unclosed `$$` never opens inline math, so a
    /// streamed `$$x$` (one character short of its closer) stays literal.
    private static func matchInlineDollar(_ scalars: [Unicode.Scalar], at start: Int) -> Candidate? {
        guard scalars[start] == dollar, start + 1 < scalars.count else { return nil }
        if start > 0, scalars[start - 1] == dollar { return nil }
        let first = scalars[start + 1]
        guard first != dollar, !isSpace(first) else { return nil }

        let limit = min(scalars.count, start + maxInlineScan)
        var index = start + 1
        var braceLevel = 0
        var lookahead = CloseBraceLookahead()
        while index < limit {
            let scalar = scalars[index]
            if scalar == backslash {
                index += 2
                continue
            }
            if scalar == openBrace {
                braceLevel += 1
                guard lookahead.exists(from: index, before: limit, in: scalars) else { return nil }
            } else if scalar == closeBrace {
                braceLevel -= 1
            } else if scalar == dollar, braceLevel <= 0 {
                let before = scalars[index - 1]
                guard !isSpace(before) else { return nil }
                if index + 1 < scalars.count {
                    let after = scalars[index + 1]
                    guard !isDigit(after), after != dollar, !startsIdentifier(after) else { return nil }
                }
                let bodyStart = start + 1
                guard isMathBody(scalars[bodyStart..<index]) else { return nil }
                return Candidate(
                    start: start,
                    bodyStart: bodyStart,
                    bodyEnd: index,
                    end: index + 1,
                    isDisplay: false
                )
            }
            index += 1
        }
        return nil
    }

    /// Port of `findEndOfMath`: the offset of `delimiter` at or after `from`,
    /// skipping backslash-escaped characters and anything inside braces,
    /// looking no further than `maxScan` scalars. An open brace with no
    /// closing brace ahead in the window can never balance, so it ends the
    /// search. Adapted from KaTeX auto-render (MIT).
    private static func findEndOfMath(
        _ delimiter: [Unicode.Scalar],
        in scalars: [Unicode.Scalar],
        from: Int,
        maxScan: Int
    ) -> Int? {
        let limit = min(scalars.count, from + maxScan)
        var index = from
        var braceLevel = 0
        var lookahead = CloseBraceLookahead()
        while index < limit {
            let scalar = scalars[index]
            if braceLevel <= 0, hasPrefix(delimiter, in: scalars, at: index) {
                return index
            } else if scalar == backslash {
                index += 1
            } else if scalar == openBrace {
                braceLevel += 1
                guard lookahead.exists(from: index, before: limit, in: scalars) else { return nil }
            } else if scalar == closeBrace {
                braceLevel -= 1
            }
            index += 1
        }
        return nil
    }

    // MARK: - Character classes

    /// A body is math when it is not blank and, like a markdown paragraph,
    /// spans no blank line. A blank line is `\n`, any number of spaces, an
    /// optional `\r`, then `\n` (the JavaScript `/\n *\r?\n/`).
    private static func isMathBody(_ body: ArraySlice<Unicode.Scalar>) -> Bool {
        guard body.contains(where: { !isWhitespace($0) }) else { return false }
        var index = body.startIndex
        while let lineStart = body[index...].firstIndex(of: lineFeed) {
            var cursor = body.index(after: lineStart)
            while cursor < body.endIndex, body[cursor] == space {
                cursor = body.index(after: cursor)
            }
            if cursor < body.endIndex, body[cursor] == carriageReturn {
                cursor = body.index(after: cursor)
            }
            if cursor < body.endIndex, body[cursor] == lineFeed {
                return false
            }
            index = body.index(after: lineStart)
        }
        return true
    }

    /// Port of `looksLikeTeX`: the trimmed body is a single token, or the
    /// body holds an operator, backslash, brace, bar, or script character.
    private static func looksLikeTeX(_ body: ArraySlice<Unicode.Scalar>) -> Bool {
        let trimmed = body.drop(while: isWhitespace).reversed().drop(while: isWhitespace)
        if !trimmed.contains(where: isWhitespace) { return true }
        return body.contains(where: texShapeScalars.contains)
    }

    private static func hasPrefix(_ prefix: [Unicode.Scalar], in scalars: [Unicode.Scalar], at index: Int) -> Bool {
        guard index + prefix.count <= scalars.count else { return false }
        for (offset, scalar) in prefix.enumerated() where scalars[index + offset] != scalar {
            return false
        }
        return true
    }

    /// `true` when the raw text contains a `$` or a `\(` / `\[`, the only
    /// characters that can open a span. A stripped text can never contain one
    /// the raw text lacks, so this is a safe fast reject on the raw input.
    private static func containsCandidateOpener(_ text: String) -> Bool {
        var previousWasBackslash = false
        for scalar in text.unicodeScalars {
            if scalar == dollar { return true }
            if previousWasBackslash, scalar == "(" || scalar == "[" { return true }
            previousWasBackslash = scalar == backslash
        }
        return false
    }

    /// The JavaScript `isSpace`: the ASCII whitespace that matters for
    /// delimiter adjacency.
    private static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x20, 0x09, 0x0A, 0x0D, 0x0C, 0x0B: return true
        default: return false
        }
    }

    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        (0x30...0x39).contains(scalar.value)
    }

    /// The JavaScript `startsIdentifier`: a character that would begin an
    /// identifier or a shell, PHP, or JavaScript expansion after a `$`.
    private static func startsIdentifier(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x41...0x5A, 0x61...0x7A, 0x5F, 0x28, 0x7B: return true
        default: return false
        }
    }

    /// What JavaScript `\s` matches and `String.prototype.trim` removes.
    private static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A,
             0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
            return true
        default:
            return false
        }
    }

    private static func string(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }
}
