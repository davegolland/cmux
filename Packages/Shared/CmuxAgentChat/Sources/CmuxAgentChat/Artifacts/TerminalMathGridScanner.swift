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
/// The scanner is pure. A grid that contains none of `$`, `\(`, or `\[`
/// costs one scalar pass over the rows and no stitching, allocation, or
/// grapheme counting.
public struct TerminalMathGridScanner: Sendable {
    /// Sources longer than this many characters are dropped: they cannot fit
    /// a sensible overlay and are almost certainly not one formula.
    public static let maxSourceLength = 1024

    /// Soft upper bound on the rows stitched into one logical line.
    ///
    /// Bounds the detector's work on grids whose every row fills the width
    /// (a TUI drawing box borders stitches its whole viewport otherwise).
    /// The cut is delayed past this bound while the next row holds a
    /// delimiter, up to ``hardMaxStitchedRows``, so a closer is not orphaned
    /// into the next line where it would read as an opener. Formulas longer
    /// than this many rows are not expected on a terminal.
    public static let maxStitchedRows = 16
    /// Hard upper bound on the rows stitched into one logical line.
    public static let hardMaxStitchedRows = 32

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

        // Cheap reject before any stitching or allocation: no row can open a
        // span. On a math-free grid this pass is the entire cost of a scan.
        let scanRows = Self.rowsWithCandidateOpener(rows)
        let openerRows = scanRows.hasOpener
        guard openerRows.contains(true) else { return [] }

        var result: [TerminalMathPlacement] = []
        var lineStart = 0
        while lineStart < rows.count {
            let lineEnd = Self.logicalLineEnd(
                startingAt: lineStart, rows: rows, columns: columns, openerRows: openerRows
            )
            defer { lineStart = lineEnd }

            guard openerRows[lineStart..<lineEnd].contains(true) else { continue }

            // Grid rows carry no escape sequences, so the detector's stripped
            // text equals its input and the span ranges index the line
            // directly. `spans(in:)` is called without a `hasMath` probe,
            // which would strip and scan the same line a second time. A row
            // that does hold a control scalar (never seen from Ghostty, but
            // cheap to honour) is stripped first so the ranges stay aligned.
            let needsStrip = scanRows.hasControl[lineStart..<lineEnd].contains(true)
            if lineEnd - lineStart == 1 {
                let row = needsStrip ? detector.strippedText(rows[lineStart]) : rows[lineStart]
                Self.appendPlacements(
                    from: detector.spans(in: row),
                    in: row,
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
                    let row = needsStrip ? detector.strippedText(rows[index]) : rows[index]
                    rowStarts.append(offset)
                    joined += row
                    offset += row.count
                }
                Self.appendPlacements(
                    from: detector.spans(in: joined),
                    in: joined,
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
    ///
    /// The soft cap ``maxStitchedRows`` is exceeded only while the next row
    /// holds a delimiter, so the cut never turns a formula's closer into the
    /// opener of the next line; ``hardMaxStitchedRows`` bounds that too.
    private static func logicalLineEnd(
        startingAt start: Int,
        rows: [String],
        columns: Int,
        openerRows: [Bool]
    ) -> Int {
        var end = start + 1
        while end < rows.count,
              end - start < hardMaxStitchedRows,
              end - start < maxStitchedRows || openerRows[end],
              continues(row: rows[end - 1], onto: rows[end], columns: columns) {
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
    ///
    /// A character is at least one UTF-8 byte, so a row shorter than
    /// `columns` bytes cannot fill the width; that O(1) check rejects every
    /// partial row before any grapheme counting.
    private static func fills(_ row: String, columns: Int) -> Bool {
        guard row.utf8.count >= columns else { return false }
        var seen = 0
        var index = row.startIndex
        while index < row.endIndex {
            seen += 1
            if seen >= columns { return true }
            index = row.index(after: index)
        }
        return false
    }

    /// One flag per row: `true` when the row contains a `$`, `\(`, or `\[`.
    ///
    /// Backslash state carries across rows, so a `\` that ends one row and
    /// a `(` that starts the next flags the second row; the rows join with
    /// no separator when they stitch, so that is a real opener there, and
    /// elsewhere the false positive only costs a detector pass.
    /// Per-row flags from one scalar pass: whether the row can open a span,
    /// and whether it holds a scalar the escape stripper would remove.
    private struct RowScan {
        var hasOpener: [Bool]
        var hasControl: [Bool]
    }

    private static func rowsWithCandidateOpener(_ rows: [String]) -> RowScan {
        var scan = RowScan(
            hasOpener: [Bool](repeating: false, count: rows.count),
            hasControl: [Bool](repeating: false, count: rows.count)
        )
        var previousWasBackslash = false
        for (index, row) in rows.enumerated() {
            for scalar in row.unicodeScalars {
                if isStrippableControl(scalar) {
                    scan.hasControl[index] = true
                }
                if !scan.hasOpener[index],
                   scalar == "$" || (previousWasBackslash && (scalar == "(" || scalar == "[")) {
                    scan.hasOpener[index] = true
                }
                previousWasBackslash = scalar == "\\"
            }
        }
        return scan
    }

    /// ESC and the C1 introducers ``TerminalEscapeSequenceStripper`` removes.
    private static func isStrippableControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1B, 0x90, 0x98, 0x9B...0x9F: return true
        default: return false
        }
    }

    // MARK: - Mapping

    /// Converts detector spans on one logical line into placements.
    ///
    /// - Parameters:
    ///   - spans: The spans found in the logical line.
    ///   - stripped: The text the span ranges index; for grid rows this is
    ///     the logical line itself.
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
