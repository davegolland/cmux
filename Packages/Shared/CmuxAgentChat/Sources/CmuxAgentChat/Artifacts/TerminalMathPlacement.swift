/// One formula placed on the rendered terminal grid, in viewport rows and
/// cell columns.
///
/// ``TerminalMathGridScanner`` produces placements from the plain rows of a
/// render-grid frame. A placement covers the delimited source exactly as it
/// sits on screen: the first row's cells run from ``startColumn`` to
/// ``endColumn``, and when the source soft-wrapped onto later rows each extra
/// row is a ``Segment`` in ``continuationRows``. An overlay paints an opaque
/// patch over every segment and draws the rendered formula on the first row.
public struct TerminalMathPlacement: Sendable, Equatable, Hashable {
    /// A run of cells on one row.
    public struct Segment: Sendable, Equatable, Hashable {
        /// Viewport row, 0-based.
        public let row: Int
        /// First column of the run, inclusive.
        public let startColumn: Int
        /// Column after the run, exclusive.
        public let endColumn: Int

        /// Creates a segment.
        ///
        /// - Parameters:
        ///   - row: Viewport row, 0-based.
        ///   - startColumn: First column of the run, inclusive.
        ///   - endColumn: Column after the run, exclusive.
        public init(row: Int, startColumn: Int, endColumn: Int) {
            self.row = row
            self.startColumn = startColumn
            self.endColumn = endColumn
        }

        /// Returns whether the segment covers the cell at `row`, `column`.
        public func contains(row: Int, column: Int) -> Bool {
            self.row == row && column >= startColumn && column < endColumn
        }
    }

    /// First viewport row of the source, 0-based.
    public let row: Int
    /// First column of the source on ``row``, inclusive.
    public let startColumn: Int
    /// Column after the source on ``row``, exclusive.
    public let endColumn: Int
    /// Extra rows the source occupies when it soft-wrapped; empty otherwise.
    public let continuationRows: [Segment]
    /// The delimited source exactly as on screen, joined across wrapped rows
    /// with no separator.
    public let source: String
    /// The LaTeX between the delimiters, untrimmed.
    public let body: String
    /// Whether the delimiters request display math.
    public let isDisplay: Bool

    /// Creates a placement.
    ///
    /// - Parameters:
    ///   - row: First viewport row of the source, 0-based.
    ///   - startColumn: First column of the source on `row`, inclusive.
    ///   - endColumn: Column after the source on `row`, exclusive.
    ///   - continuationRows: Extra rows when the source soft-wrapped.
    ///   - source: The delimited source exactly as on screen.
    ///   - body: The LaTeX between the delimiters.
    ///   - isDisplay: Whether the delimiters request display math.
    public init(
        row: Int,
        startColumn: Int,
        endColumn: Int,
        continuationRows: [Segment] = [],
        source: String,
        body: String,
        isDisplay: Bool
    ) {
        self.row = row
        self.startColumn = startColumn
        self.endColumn = endColumn
        self.continuationRows = continuationRows
        self.source = source
        self.body = body
        self.isDisplay = isDisplay
    }

    /// All segments including the first row, in row order.
    public var segments: [Segment] {
        var result = [Segment(row: row, startColumn: startColumn, endColumn: endColumn)]
        result.append(contentsOf: continuationRows)
        return result
    }

    /// Returns whether any segment covers the cell at `row`, `column`.
    public func contains(row: Int, column: Int) -> Bool {
        if self.row == row, column >= startColumn, column < endColumn { return true }
        return continuationRows.contains { $0.contains(row: row, column: column) }
    }
}
