import Testing

@testable import CmuxAgentChat

@Suite("TerminalMathSpanDetector")
struct TerminalMathSpanDetectorTests {
    private let detector = TerminalMathSpanDetector()

    private func bodies(_ text: String) -> [String] {
        detector.spans(in: text).map(\.body)
    }

    private func sources(_ text: String) -> [String] {
        detector.spans(in: text).map(\.source)
    }

    // MARK: - Acceptance cases from Claude Code output

    @Test("detects a single-letter inline span")
    func singleLetterInline() throws {
        let span = try #require(detector.spans(in: "$A$").first)

        #expect(span.source == "$A$")
        #expect(span.body == "A")
        #expect(!span.isDisplay)
        #expect(detector.spans(in: "$A$").count == 1)
    }

    @Test("detects a macro with braces and parentheses inside prose")
    func macroInsideProse() {
        let text = #"draw each entry from $\mathcal{N}(0, 1/m)$."#

        #expect(bodies(text) == [#"\mathcal{N}(0, 1/m)"#])
    }

    @Test("detects a span ending in a parenthesis before a period")
    func spanBeforePeriod() {
        let text = #"The theory says $m \approx C \cdot k \log(n/k)$."#

        #expect(bodies(text) == [#"m \approx C \cdot k \log(n/k)"#])
    }

    @Test("detects two inline spans on one line")
    func twoInlineSpans() {
        let text = "With $n = 100{,}000$ tags and $k = 10$ per document:"

        #expect(bodies(text) == ["n = 100{,}000", "k = 10"])
        #expect(detector.spans(in: text).allSatisfy { !$0.isDisplay })
    }

    @Test("detects a display span with double dollars")
    func displayDollar() throws {
        let text = #"$$k \log(n/k) = 10 \times \ln(10{,}000) \approx 92$$"#
        let spans = detector.spans(in: text)
        let span = try #require(spans.first)

        #expect(spans.count == 1)
        #expect(span.isDisplay)
        #expect(span.source == text)
        #expect(span.body == #"k \log(n/k) = 10 \times \ln(10{,}000) \approx 92"#)
    }

    @Test(
        "leaves shell variables and prices literal",
        arguments: [
            "echo $PATH",
            "It costs $5 to $10.",
            "$1 $2 $HOME $$ $? ${FOO}",
            "between $5-$10 each",
        ]
    )
    func shellAndPricesAreNotMath(_ text: String) {
        #expect(detector.spans(in: text).isEmpty)
        #expect(!detector.hasMath(in: text))
    }

    @Test(
        "does not let a second variable close a first one",
        arguments: [
            "cd $HOME/$USER",
            "export PATH=$HOME/bin:$PATH",
            "$this->foo($bar)",
            "${a}${b}",
            "$(el).val($x)",
        ]
    )
    func identifierAfterCloserIsNotMath(_ text: String) {
        #expect(detector.spans(in: text).isEmpty)
    }

    @Test("allows punctuation and a closing parenthesis after the closer")
    func punctuationAfterCloser() {
        #expect(sources("the $x$-axis, then $y$. Also ($z$)") == ["$x$", "$y$", "$z$"])
    }

    @Test(
        "detects macros without validating them",
        arguments: [
            #"$\frac{1}{\sigma\sqrt{2\pi}}$"#,
            #"$\notarealmacro{x}$"#,
        ]
    )
    func detectsWithoutValidatingMacros(_ text: String) throws {
        let spans = detector.spans(in: text)
        let span = try #require(spans.first)

        #expect(spans.count == 1)
        #expect(span.source == text)
        #expect(span.body == String(text.dropFirst().dropLast()))
    }

    // MARK: - Backslash delimiters

    @Test(
        "detects backslash-paren bodies that look like TeX",
        arguments: [
            (#"so \(x^2\) done"#, "x^2"),
            (#"as \(n \to \infty\)"#, #"n \to \infty"#),
            (#"sum \(a + b\)"#, "a + b"),
            (#"Padded \( x \) renders"#, " x "),
            (#"a \(void\) cast"#, "void"),
        ]
    )
    func backslashParenLooksLikeTeX(_ text: String, _ body: String) throws {
        let spans = detector.spans(in: text)
        let span = try #require(spans.first)

        #expect(spans.count == 1)
        #expect(span.body == body)
        #expect(!span.isDisplay)
    }

    @Test(
        "leaves backslash-paren prose and mid-sentence brackets literal",
        arguments: [
            #"call \(see above\) for details"#,
            #"Use \[Enter\] to confirm"#,
            #"so \(x^2\) and \[\int_0^1 f\]"#,
        ]
    )
    func backslashDelimitersInProse(_ text: String) {
        let spans = detector.spans(in: text)

        #expect(spans.allSatisfy { !$0.isDisplay })
        #expect(!spans.contains { $0.source.hasPrefix(#"\["#) })
    }

    @Test("detects a backslash-bracket block on its own line")
    func backslashBracketBlock() throws {
        let text = "intro\n\\[\\int_0^1 f\\]\nafter"
        let spans = detector.spans(in: text)
        let span = try #require(spans.first)

        #expect(spans.count == 1)
        #expect(span.isDisplay)
        #expect(span.source == #"\[\int_0^1 f\]"#)
        #expect(span.body == #"\int_0^1 f"#)
        #expect(String(text[span.range]) == span.source)
    }

    @Test("never opens math on an escaped dollar")
    func escapedDollarNeverOpens() {
        #expect(detector.spans(in: #"cost \$5 and \$x\$"#).isEmpty)
    }

    @Test("keeps an escaped dollar inside a span body")
    func escapedDollarInsideBody() throws {
        let spans = detector.spans(in: #"$a \$ b$"#)
        let span = try #require(spans.first)

        #expect(spans.count == 1)
        #expect(span.body == #"a \$ b"#)
    }

    @Test("does not close on a dollar nested in braces")
    func dollarInsideBracesDoesNotClose() throws {
        let spans = detector.spans(in: #"$\text{costs $5}$"#)
        let span = try #require(spans.first)

        #expect(spans.count == 1)
        #expect(span.body == #"\text{costs $5}"#)
    }

    @Test("ends the search at an open brace with no closing brace ahead")
    func unbalancedOpenBrace() {
        #expect(detector.spans(in: "$a{b$ c$").isEmpty)
        #expect(bodies("$a{b}$") == ["a{b}"])
    }

    // MARK: - Double dollars

    @Test("pairs inline double dollars only when the body is tight")
    func tightInlineDoubleDollar() throws {
        #expect(detector.spans(in: "the PID is $$ and the parent is $$ too").isEmpty)
        #expect(detector.spans(in: "text $$ x $$ more").isEmpty)

        let span = try #require(detector.spans(in: "so $$E=mc^2$$ holds").first)
        #expect(span.isDisplay)
        #expect(span.source == "$$E=mc^2$$")
        #expect(span.body == "E=mc^2")
    }

    @Test(
        "never opens inline math on the second dollar of an unclosed double dollar",
        arguments: [
            #"$$\frac{x}{y}$"#,
            "$$x$",
            "Price is $$5$ each.",
            "$a$$b$",
        ]
    )
    func secondDollarOfUnclosedPairNeverOpens(_ text: String) {
        #expect(detector.spans(in: text).isEmpty)
        #expect(!detector.hasMath(in: text))
    }

    @Test("still pairs a closed double dollar after the unclosed-pair rule")
    func closedDoubleDollarStillPairs() {
        #expect(bodies("$$x$$") == ["x"])
        #expect(detector.spans(in: "$$x$$").allSatisfy { $0.isDisplay })
    }

    @Test("allows padding inside a double-dollar block on its own line")
    func ownLineDoubleDollarBlock() throws {
        let span = try #require(detector.spans(in: "$$ x $$").first)

        #expect(span.isDisplay)
        #expect(span.body == " x ")
        #expect(detector.spans(in: "$$ x $$ then prose").isEmpty)
        #expect(sources("$$x$$ then prose") == ["$$x$$"])
    }

    @Test("treats up to three spaces of indentation as line start")
    func indentedBlocks() throws {
        let text = "  Result:\n  $$\n  k \\log(n/k) \\approx 92\n  $$\n  Done."
        let stripped = detector.strippedText(text)
        let spans = detector.spans(in: text)
        let span = try #require(spans.first)

        #expect(spans.count == 1)
        #expect(span.isDisplay)
        #expect(span.source == "$$\n  k \\log(n/k) \\approx 92\n  $$")
        #expect(String(stripped[..<span.range.lowerBound]) == "  Result:\n  ")
        #expect(String(stripped[span.range.upperBound...]) == "\n  Done.")

        let bracket = try #require(detector.spans(in: "  \\[ a = b \\]\nnext").first)
        #expect(bracket.isDisplay)
        #expect(bracket.source == #"\[ a = b \]"#)
        #expect(bracket.body == " a = b ")

        #expect(detector.spans(in: "    $$ a $$").isEmpty)
        #expect(detector.spans(in: "\t$$ a $$").isEmpty)
        #expect(detector.spans(in: "x\n   $$ a $$").count == 1)
    }

    @Test("detects a multi-line display block with an untrimmed body")
    func multiLineDisplayBlock() throws {
        let text = "$$\na = b\n$$"
        let spans = detector.spans(in: text)
        let span = try #require(spans.first)

        #expect(spans.count == 1)
        #expect(span.isDisplay)
        #expect(span.source == text)
        #expect(span.body == "\na = b\n")
    }

    @Test("keeps a block's trailing line ending out of the source")
    func blockSourceExcludesLineEnding() throws {
        let text = "before\n$$\na = b\n$$  \nafter"
        let span = try #require(detector.spans(in: text).first)

        #expect(span.source == "$$\na = b\n$$")
        #expect(String(text[span.range]) == span.source)
    }

    // MARK: - Pandoc adjacency, termination, blank lines

    @Test(
        "applies the Pandoc adjacency rules to single dollars",
        arguments: ["$ x$", "$x $", "$x$1"]
    )
    func pandocAdjacencyRules(_ text: String) {
        #expect(detector.spans(in: text).isEmpty)
    }

    @Test(
        "leaves an unterminated delimiter literal while streaming",
        arguments: ["$x + y", "$$x + y", #"\(x + y"#, #"\[x + y"#]
    )
    func unterminatedDelimitersAreNotMath(_ text: String) {
        #expect(detector.spans(in: text).isEmpty)
        #expect(!detector.hasMath(in: text))
    }

    @Test(
        "rejects empty bodies",
        arguments: ["$$$$", #"\(\)"#, #"\[\]"#, "$$ $$"]
    )
    func emptyBodiesAreNotMath(_ text: String) {
        #expect(detector.spans(in: text).isEmpty)
    }

    @Test(
        "rejects a body that spans a blank line",
        arguments: ["$a\n\nb$", "$a\n  \nb$", "$$a\n\nb$$", "$a\r\n\r\nb$"]
    )
    func blankLineInsideBodyIsNotMath(_ text: String) {
        #expect(detector.spans(in: text).isEmpty)
    }

    @Test("bounds every closer search to its scan window")
    func scanWindows() {
        let long = String(repeating: "x", count: 3000)
        let veryLong = String(repeating: "x", count: 9000)

        #expect(detector.spans(in: "$\(long)$").isEmpty)
        #expect(detector.spans(in: #"\("# + long + #"\)"#).isEmpty)
        #expect(detector.spans(in: "$$\(long)$$").count == 1)
        #expect(detector.spans(in: "$$\(veryLong)$$").isEmpty)
    }

    @Test("returns spans in order with ranges into the stripped text")
    func orderedSpansWithRanges() throws {
        let text = "a $x$ b $y$ c"
        let spans = detector.spans(in: text)
        let stripped = detector.strippedText(text)

        #expect(spans.map(\.source) == ["$x$", "$y$"])
        #expect(stripped == text)
        for span in spans {
            #expect(String(stripped[span.range]) == span.source)
        }
        let first = try #require(spans.first)
        let second = try #require(spans.last)
        #expect(first.range.upperBound <= second.range.lowerBound)
        #expect(stripped.distance(from: stripped.startIndex, to: first.range.lowerBound) == 2)
        #expect(stripped.distance(from: stripped.startIndex, to: second.range.lowerBound) == 8)
    }

    @Test("does not treat underscores or asterisks as markdown")
    func underscoresAndAsterisks() {
        #expect(bodies("$a_1 b_2 * c$") == ["a_1 b_2 * c"])
    }

    // MARK: - Escape sequence stripping

    @Test("finds math wrapped in SGR sequences")
    func sgrWrappedMath() throws {
        let text = "\u{1B}[1m$x$\u{1B}[0m"
        let span = try #require(detector.spans(in: text).first)

        #expect(span.source == "$x$")
        #expect(span.body == "x")
        #expect(!span.source.unicodeScalars.contains("\u{1B}"))
    }

    @Test("finds math whose delimiters are colored separately from the body")
    func sgrSplitDelimiters() {
        let text = "\u{1B}[32m$\u{1B}[0mx\u{1B}[32m$\u{1B}[0m"

        #expect(sources(text) == ["$x$"])
    }

    @Test("finds math inside an OSC 8 hyperlink")
    func osc8Hyperlink() {
        let text = "\u{1B}]8;;https://example.com\u{1B}\\$x$\u{1B}]8;;\u{1B}\\"

        #expect(sources(text) == ["$x$"])
    }

    @Test("finds math wrapped in C1 CSI sequences")
    func c1CSIWrappedMath() {
        #expect(sources("\u{9B}1m$x$\u{9B}0m") == ["$x$"])
    }

    @Test("drops math inside an ST-terminated string control")
    func stringControlPayloadIsNotDetectable() {
        let text = "\u{1B}P$hidden$\u{1B}\\ $x$"

        #expect(sources(text) == ["$x$"])
    }

    @Test("keeps math before an unterminated trailing CSI sequence")
    func unterminatedTrailingCSI() {
        #expect(sources("$x$\u{1B}[38;2") == ["$x$"])
    }

    @Test("finds math on both sides of CRLF line endings")
    func crlfLineEndings() {
        #expect(sources("$x$\r\n$y$") == ["$x$", "$y$"])
        #expect(sources("$$\r\na = b\r\n$$\r\n") == ["$$\r\na = b\r\n$$"])
    }

    @Test("ranges index the stripped text, not the raw input")
    func rangesIndexStrippedText() {
        let text = "\u{1B}[1mSee \u{1B}[0m$x$ and \u{1B}]0;title\u{07}$$y$$"
        let stripped = detector.strippedText(text)
        let spans = detector.spans(in: text)

        #expect(stripped == "See $x$ and $$y$$")
        #expect(spans.map(\.source) == ["$x$", "$$y$$"])
        for span in spans {
            #expect(String(stripped.unicodeScalars[span.range]) == span.source)
        }
    }

    @Test("returns plain text unchanged from strippedText")
    func strippedTextPassesPlainTextThrough() {
        let text = "plain $x$ text\n"

        #expect(detector.strippedText(text) == text)
    }

    // MARK: - hasMath

    @Test(
        "hasMath is false without a candidate opener",
        arguments: ["", "no math here", "backslash \\ alone", "paren (x) bracket [y]"]
    )
    func hasMathFastReject(_ text: String) {
        #expect(!detector.hasMath(in: text))
    }

    @Test(
        "hasMath agrees with spans",
        arguments: [
            "$x$",
            #"\(x\)"#,
            #"\(see above\)"#,
            #"\[x\]"#,
            #"Use \[Enter\] to confirm"#,
            "$$x$$",
            "the PID is $$ and the parent is $$ too",
            "\u{1B}[1m$x$\u{1B}[0m",
            "echo $PATH",
            "cd $HOME/$USER",
            "$x + y",
            "\u{1B}P$hidden$\u{1B}\\",
        ]
    )
    func hasMathAgreesWithSpans(_ text: String) {
        #expect(detector.hasMath(in: text) == !detector.spans(in: text).isEmpty)
    }
}
