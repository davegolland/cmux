import Testing

@testable import CmuxAgentChat

@Suite("TerminalMathGridScanner")
struct TerminalMathGridScannerTests {
    private let scanner = TerminalMathGridScanner()

    private func placements(
        _ rows: [String],
        columns: Int = 80,
        cursor: (row: Int, column: Int)? = nil
    ) -> [TerminalMathPlacement] {
        scanner.placements(rows: rows, columns: columns, cursor: cursor)
    }

    @Test("places an inline and a display span on one row")
    func inlineAndDisplayOnOneRow() throws {
        let row = #"Given $x^2$ then $$y=1$$ done"#
        let found = placements([row])

        #expect(found.count == 2)
        let inline = try #require(found.first)
        #expect(inline.row == 0)
        #expect(inline.startColumn == 6)
        #expect(inline.endColumn == 11)
        #expect(inline.source == "$x^2$")
        #expect(inline.body == "x^2")
        #expect(!inline.isDisplay)
        #expect(inline.continuationRows.isEmpty)
        #expect(inline.segments == [.init(row: 0, startColumn: 6, endColumn: 11)])

        let display = try #require(found.last)
        #expect(display.startColumn == 17)
        #expect(display.endColumn == 24)
        #expect(display.source == "$$y=1$$")
        #expect(display.isDisplay)
    }

    @Test("stitches a span split across a soft-wrapped row pair")
    func softWrappedPair() throws {
        // 20 columns: the opener is on row 0, the closer on row 1.
        let columns = 20
        let rows = [
            #"values is $\frac{a}{"#,  // exactly 20 characters
            #"b}$ and more"#,
        ]
        #expect(rows[0].count == columns)

        let found = placements(rows, columns: columns)
        let placement = try #require(found.first)
        #expect(found.count == 1)
        #expect(placement.source == #"$\frac{a}{b}$"#)
        #expect(placement.body == #"\frac{a}{b}"#)
        #expect(placement.row == 0)
        #expect(placement.startColumn == 10)
        #expect(placement.endColumn == 20)
        #expect(placement.continuationRows == [.init(row: 1, startColumn: 0, endColumn: 3)])
        #expect(placement.segments.count == 2)
    }

    @Test("stitches a display span across three wrapped rows")
    func threeSegmentDisplaySpan() throws {
        let columns = 10
        let rows = [
            "ab $$x+y+z",  // opener on row 0
            "+a+b+c+d+e",  // full middle row
            "+f$$ tail",   // closer on row 2
        ]
        #expect(rows[0].count == columns)
        #expect(rows[1].count == columns)

        let found = placements(rows, columns: columns)
        let placement = try #require(found.first)
        #expect(found.count == 1)
        #expect(placement.isDisplay)
        #expect(placement.source == "$$x+y+z+a+b+c+d+e+f$$")
        #expect(placement.body == "x+y+z+a+b+c+d+e+f")
        #expect(placement.segments == [
            .init(row: 0, startColumn: 3, endColumn: 10),
            .init(row: 1, startColumn: 0, endColumn: 10),
            .init(row: 2, startColumn: 0, endColumn: 4),
        ])
    }

    @Test("stitches a closing $$ that wraps between its two characters")
    func closingDelimiterSplitAtWrapPoint() throws {
        let columns = 10
        let rows = [
            "abcde $$x$",  // first `$` of the closer ends row 0
            "$ trailing",  // second `$` starts row 1
        ]
        #expect(rows[0].count == columns)

        let found = placements(rows, columns: columns)
        let placement = try #require(found.first)
        #expect(found.count == 1)
        #expect(placement.isDisplay)
        #expect(placement.source == "$$x$$")
        #expect(placement.body == "x")
        #expect(placement.segments == [
            .init(row: 0, startColumn: 6, endColumn: 10),
            .init(row: 1, startColumn: 0, endColumn: 1),
        ])
    }

    @Test("stitches an opening \\( that wraps between its two characters")
    func openingDelimiterSplitAtWrapPoint() throws {
        // The opener pre-pass carries the backslash across the row boundary;
        // without the carry neither row would look like it opens a span.
        let columns = 10
        let rows = [
            #"see this \"#,  // 10 characters, ends in a backslash
            #"(a+b\) ok"#,
        ]
        #expect(rows[0].count == columns)

        let found = placements(rows, columns: columns)
        let placement = try #require(found.first)
        #expect(found.count == 1)
        #expect(!placement.isDisplay)
        #expect(placement.source == #"\(a+b\)"#)
        #expect(placement.segments == [
            .init(row: 0, startColumn: 9, endColumn: 10),
            .init(row: 1, startColumn: 0, endColumn: 6),
        ])
    }

    @Test("rejects a full box-drawing grid without walking it")
    func fullBoxGridWithoutOpenersYieldsNothing() {
        // Every row fills the width with a multi-byte character and the next
        // row starts with a non-space, so all rows would stitch; the opener
        // pre-pass must reject the grid before any of that happens.
        let columns = 40
        let rows = Array(repeating: String(repeating: "\u{2502}", count: columns), count: 30)

        #expect(placements(rows, columns: columns).isEmpty)
    }

    @Test("still finds math on a stitched line whose opener row is not the first row")
    func openerOnLaterRowOfStitchedLine() throws {
        let columns = 10
        let rows = [
            "abcdefghij",  // full, no opener
            "kl $x+1$ m",
        ]

        let placement = try #require(placements(rows, columns: columns).first)
        #expect(placement.row == 1)
        #expect(placement.startColumn == 3)
        #expect(placement.endColumn == 8)
        #expect(placement.source == "$x+1$")
    }

    @Test("does not stitch when the next row starts with a space")
    func fullRowFollowedBySpaceDoesNotStitch() {
        let columns = 12
        let rows = [
            "abcdef $x + ",  // 12 characters, unterminated opener
            " y$ trailing",
        ]
        #expect(rows[0].count == columns)

        // Row 0 alone has no terminated span; row 1's `$` would only pair up
        // if the rows were joined.
        #expect(placements(rows, columns: columns).isEmpty)
    }

    @Test("drops a span that contains the cursor")
    func cursorInsideSpanDropsIt() {
        let rows = ["$a$ and $b$"]

        #expect(placements(rows, cursor: (row: 0, column: 1)).map(\.source) == ["$b$"])
        #expect(placements(rows, cursor: (row: 0, column: 9)).map(\.source) == ["$a$"])
        #expect(placements(rows, cursor: (row: 0, column: 4)).map(\.source) == ["$a$", "$b$"])
        #expect(placements(rows, cursor: (row: 1, column: 1)).map(\.source) == ["$a$", "$b$"])
    }

    @Test("drops a wrapped span when the cursor sits on its continuation row")
    func cursorOnContinuationRowDropsIt() {
        let columns = 20
        let rows = [
            #"values is $\frac{a}{"#,
            #"b}$ and more"#,
        ]

        #expect(placements(rows, columns: columns, cursor: (row: 1, column: 2)).isEmpty)
        #expect(placements(rows, columns: columns, cursor: (row: 1, column: 3)).count == 1)
    }

    @Test("counts wide-cell pad spaces as columns")
    func wideCellPadKeepsColumnsExact() throws {
        // A CJK cell occupies two columns; plainRows() pads it with a space.
        let row = "日 $x$"
        let placement = try #require(placements([row]).first)

        #expect(placement.startColumn == 2)
        #expect(placement.endColumn == 5)
    }

    @Test("returns nothing for rows without delimiters")
    func rowsWithoutDelimitersYieldNothing() {
        let rows = ["plain text", "", "more text with \\ backslash", "(parens) [brackets]"]

        #expect(placements(rows).isEmpty)
        #expect(placements([]).isEmpty)
        #expect(placements(rows, columns: 0).isEmpty)
    }

    @Test("drops a source longer than 1024 characters")
    func overlongSourceIsDropped() {
        let columns = 100
        // Build a $$ ... $$ display span whose source is 1025 characters and
        // spread it across full-width rows so it stitches into one line.
        let body = String(repeating: "a", count: 1025 - 4)
        let source = "$$" + body + "$$"
        #expect(source.count == 1025)
        var rows: [String] = []
        var remaining = Substring(source)
        while !remaining.isEmpty {
            rows.append(String(remaining.prefix(columns)))
            remaining = remaining.dropFirst(columns)
        }

        #expect(placements(rows, columns: columns).isEmpty)

        // The same construction one character shorter is kept.
        let shorter = "$$" + String(repeating: "a", count: 1024 - 4) + "$$"
        var shorterRows: [String] = []
        var rest = Substring(shorter)
        while !rest.isEmpty {
            shorterRows.append(String(rest.prefix(columns)))
            rest = rest.dropFirst(columns)
        }
        #expect(placements(shorterRows, columns: columns).count == 1)
    }

    @Test("sorts output by row then start column")
    func outputIsSorted() {
        let rows = [
            "$c$ $d$",
            "",
            "x $e$",
            "$a$",
        ]
        let found = placements(rows)

        #expect(found.map(\.source) == ["$c$", "$d$", "$e$", "$a$"])
        #expect(found.map(\.row) == [0, 0, 2, 3])
        #expect(found.map(\.startColumn) == [0, 4, 2, 0])
    }

    @Test("maps a display block on its own row")
    func displayBlockOnOwnRow() throws {
        let rows = ["  \\[ a = b \\]  "]
        let placement = try #require(placements(rows).first)

        #expect(placement.isDisplay)
        #expect(placement.startColumn == 2)
        #expect(placement.endColumn == 13)
        #expect(placement.source == "\\[ a = b \\]")
    }

    @Test("stitching stops after maxStitchedRows so a full-width grid stays bounded")
    func stitchingIsBounded() {
        let columns = 10
        let filler = String(repeating: "x", count: columns)
        var rows = Array(repeating: filler, count: 40)
        // The formula sits on rows 16 and 17, right after the first cut, and
        // row 17 ends the wrapped source.
        rows[16] = "ab $x^2 + "
        rows[17] = "y^2$ done"
        let placements = TerminalMathGridScanner().placements(rows: rows, columns: columns, cursor: nil)
        #expect(placements.count == 1)
        #expect(placements.first?.source == "$x^2 + y^2$")
        #expect(placements.first?.row == 16)
        #expect(placements.first?.continuationRows.count == 1)
        #expect(TerminalMathGridScanner.maxStitchedRows == 16)
    }
}
