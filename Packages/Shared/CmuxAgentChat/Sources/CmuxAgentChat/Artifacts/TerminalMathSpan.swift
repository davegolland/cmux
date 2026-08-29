/// One LaTeX math span found by ``TerminalMathSpanDetector``.
///
/// A span records the delimited source exactly as it appeared on screen, the
/// LaTeX between the delimiters, whether the delimiters ask for display or
/// inline layout, and where the source sits in the escape-stripped text so a
/// renderer can replace it in place.
public struct TerminalMathSpan: Sendable, Equatable {
    /// The delimited source exactly as written, such as `$x$` or `$$x$$`.
    ///
    /// Never contains VT escape bytes: the detector strips them before it
    /// scans, so this is what a copy of the formula hands back to the user.
    public let source: String

    /// The text between the delimiters, untrimmed.
    ///
    /// For `$$\na = b\n$$` this is `\na = b\n`. Trimming is left to the
    /// renderer so the span stays a faithful slice of ``source``.
    public let body: String

    /// Whether the delimiters request display math.
    ///
    /// `true` for `$$ ... $$` and `\[ ... \]`, `false` for `$ ... $` and
    /// `\( ... \)`. The flag follows the delimiter, not the position in the
    /// text, so a tight `$$ ... $$` in the middle of a sentence is still
    /// display. (A `\[ ... \]` is only ever detected on its own line.)
    public let isDisplay: Bool

    /// Location of ``source`` in the escape-stripped text.
    ///
    /// The range indexes the string returned by
    /// ``TerminalMathSpanDetector/strippedText(_:)`` for the same input, not
    /// the raw text handed to the detector. Both bounds sit on Unicode scalar
    /// boundaries (the delimiter characters are ASCII), so
    /// `stripped.unicodeScalars[range]` always reproduces ``source``.
    public let range: Range<String.Index>

    /// Creates a span.
    ///
    /// - Parameters:
    ///   - source: The delimited source exactly as written.
    ///   - body: The text between the delimiters, untrimmed.
    ///   - isDisplay: Whether the delimiters request display math.
    ///   - range: Location of `source` in the escape-stripped text.
    public init(source: String, body: String, isDisplay: Bool, range: Range<String.Index>) {
        self.source = source
        self.body = body
        self.isDisplay = isDisplay
        self.range = range
    }
}
