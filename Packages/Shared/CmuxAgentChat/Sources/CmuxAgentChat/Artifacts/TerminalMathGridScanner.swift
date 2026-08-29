/// Finds LaTeX math on a rendered terminal grid and maps each span to cells.
///
/// The input is the plain text of every viewport row, one string per row,
/// where `Character` offset equals cell column (as
/// `MobileTerminalRenderGridFrame.plainRows()` produces: wide cells already
/// carry a trailing pad space, and rows are not padded to the grid width).
///
/// Rows are stitched into logical lines before detection so a formula that
/// soft-wrapped still renders. The frame carries no wrap flag, so wrapping is
/// inferred: row `r` continues onto `r + 1` only when row `r` is at least
/// `columns` characters long (it fills the width), row `r + 1` is non-empty,
/// and row `r + 1` does not start with a space. Rows are joined with no
/// separator, and a span that crosses a row boundary yields a placement with
/// ``TerminalMathPlacement/continuationRows``.
///
/// The scanner is pure and allocation-free for rows that contain none of
/// `$`, `\(`, or `\[`.
public struct TerminalMathGridScanner: Sendable {
    /// Sources longer than this many characters are dropped: they cannot fit
    /// a sensible overlay and are almost certainly not one formula.
    public static let maxSourceLength = 2048

    private let detector: TerminalMathSpanDetector

    /// Creates a scanner.
    ///
    /// - Parameter detector: The span detector to run on each logical line.
    public init(detector: TerminalMathSpanDetector = TerminalMathSpanDetector()) {
        self.detector = detector
    }

    /// Returns every formula on the grid, sorted by row then start column.
    ///
    /// - Parameters:
    ///   - rows: One string per viewport row; may be shorter than `columns`
    ///     (no trailing pad).
    ///   - columns: Grid width in cells.
    ///   - cursor: Row and column of a visible cursor, or `nil`. A placement
    ///     whose cells include the cursor is dropped so the text the user is
    ///     editing stays raw.
    /// - Returns: The placements, sorted by `(row, startColumn)`.
    public func placements(
        rows: [String],
        columns: Int,
        cursor: (row: Int, column: Int)?
    ) -> [TerminalMathPlacement] {
        guard !rows.isEmpty, columns > 0 else { return [] }

        var result: [TerminalMathPlacement] = []
        var lineStart = 0
        while lineStart < rows.count {
            let lineEnd = Self.logicalLineEnd(startingAt: lineStart, rows: rows, columns: columns)
            defer { lineStart = lineEnd }

            // Cheap reject before any allocation: none of the rows in this
            // logical line can open a span.
            guard Self.anyRowHasCandidateOpener(rows[lineStart..<lineEnd]) else { continue }

            if lineEnd - lineStart == 1 {
                let row = rows[lineStart]
                guard detector.hasMath(in: row) else { continue }
                Self.appendPlacements(
                    from: detector.spans(in: row),
                    in: detector.strippedText(row),
                    rowStarts: [0],
                    firstRow: lineStart,
                    cursor: cursor,
                    into: &result
                )
            } else {
                var joined = ""
                var rowStarts: [Int] = []
                rowStarts.reserveCapacity(lineEnd - lineStart)
                var offset = 0
                for index in lineStart..<lineEnd {
                    rowStarts.append(offset)
                    joined += rows[index]
                    offset += rows[index].count
                }
                guard detector.hasMath(in: joined) else { continue }
                Self.appendPlacements(
                    from: detector.spans(in: joined),
                    in: detector.strippedText(joined),
                    rowStarts: rowStarts,
                    firstRow: lineStart,
                    cursor: cursor,
                    into: &result
                )
            }
        }

        result.sort { lhs, rhs in
            if lhs.row != rhs.row { return lhs.row < rhs.row }
            return lhs.startColumn < rhs.startColumn
        }
        return result
    }

    // MARK: - Stitching

    /// Returns the exclusive end row of the logical line starting at `start`.
    private static func logicalLineEnd(startingAt start: Int, rows: [String], columns: Int) -> Int {
        var end = start + 1
        while end < rows.count, continues(row: rows[end - 1], onto: rows[end], columns: columns) {
            end += 1
        }
        return end
    }

    /// The soft-wrap heuristic: `row` fills the width, and `next` begins
    /// with a non-space character.
    private static func continues(row: String, onto next: String, columns: Int) -> Bool {
        guard let first = next.first, first != " " else { return false }
        return fills(row, columns: columns)
    }

    /// `true` when `row` holds at least `columns` characters, without
    /// counting past that many.
    private static func fills(_ row: String, columns: Int) -> Bool {
        var seen = 0
        var index = row.startIndex
        while index < row.endIndex {
            seen += 1
            if seen >= columns { return true }
            index = row.index(after: index)
        }
        return false
    }

    /// `true` when any row contains a `$`, `\(`, or `\[`. Backslash state
    /// does not carry across rows, so a `\` that ends one row and a `(` that
    /// starts the next is also accepted: false positives here only cost a
    /// detector pass.
    private static func anyRowHasCandidateOpener(_ rows: ArraySlice<String>) -> Bool {
        var previousWasBackslash = false
        for row in rows {
            for scalar in row.unicodeScalars {
                if scalar == "$" { return true }
                if previousWasBackslash, scalar == "(" || scalar == "[" { return true }
                previousWasBackslash = scalar == "\\"
            }
        }
        return false
    }

    // MARK: - Mapping

    /// Converts detector spans on one logical line into placements.
    ///
    /// - Parameters:
    ///   - spans: The spans found in the logical line.
    ///   - stripped: The text the span ranges index.
    ///   - rowStarts: Character offset of each row's first cell within the
    ///     logical line, ascending, starting at 0.
    ///   - firstRow: Viewport row of `rowStarts[0]`.
    ///   - cursor: The visible cursor cell, if any.
    ///   - result: Receives the placements that survive the drop rules.
    private static func appendPlacements(
        from spans: [TerminalMathSpan],
        in stripped: String,
        rowStarts: [Int],
        firstRow: Int,
        cursor: (row: Int, column: Int)?,
        into result: inout [TerminalMathPlacement]
    ) {
        guard !spans.isEmpty else { return }
        var cursorIndex = stripped.startIndex
        var cursorOffset = 0
        for span in spans {
            guard span.source.count <= maxSourceLength else { continue }
            // Spans arrive in display order, so each offset walk resumes
            // from the previous one.
            cursorOffset += stripped.distance(from: cursorIndex, to: span.range.lowerBound)
            cursorIndex = span.range.lowerBound
            let startOffset = cursorOffset
            let length = stripped.distance(from: span.range.lowerBound, to: span.range.upperBound)
            guard length > 0 else { continue }
            let endOffset = startOffset + length

            let segments = segments(
                from: startOffset,
                to: endOffset,
                rowStarts: rowStarts,
                firstRow: firstRow
            )
            guard let first = segments.first else { continue }
            if let cursor, segments.contains(where: { $0.contains(row: cursor.row, column: cursor.column) }) {
                continue
            }
            result.append(TerminalMathPlacement(
                row: first.row,
                startColumn: first.startColumn,
                endColumn: first.endColumn,
                continuationRows: Array(segments.dropFirst()),
                source: span.source,
                body: span.body,
                isDisplay: span.isDisplay
            ))
        }
    }

    /// Splits the character range `[start, end)` of a logical line into one
    /// segment per row it touches.
    private static func segments(
        from start: Int,
        to end: Int,
        rowStarts: [Int],
        firstRow: Int
    ) -> [TerminalMathPlacement.Segment] {
        var segments: [TerminalMathPlacement.Segment] = []
        var rowIndex = rowIndex(containing: start, rowStarts: rowStarts)
        var segmentStart = start
        while segmentStart < end {
            let rowStart = rowStarts[rowIndex]
            let nextRowStart = rowIndex + 1 < rowStarts.count ? rowStarts[rowIndex + 1] : Int.max
            let segmentEnd = min(end, nextRowStart)
            if segmentEnd > segmentStart {
                segments.append(TerminalMathPlacement.Segment(
                    row: firstRow + rowIndex,
                    startColumn: segmentStart - rowStart,
                    endColumn: segmentEnd - rowStart
                ))
            }
            segmentStart = segmentEnd
            rowIndex += 1
            if rowIndex >= rowStarts.count { break }
        }
        return segments
    }

    /// Index into `rowStarts` of the row holding character `offset`.
    private static func rowIndex(containing offset: Int, rowStarts: [Int]) -> Int {
        var index = 0
        while index + 1 < rowStarts.count, rowStarts[index + 1] <= offset {
            index += 1
        }
        return index
    }
}
