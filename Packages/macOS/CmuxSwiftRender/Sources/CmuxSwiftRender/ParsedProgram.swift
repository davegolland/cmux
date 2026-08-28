import SwiftSyntax

/// A parsed and operator-folded sidebar program, ready to interpret against a
/// data context without re-parsing.
///
/// Produced by ``SwiftViewInterpreter/parse(_:)`` and consumed by
/// ``SwiftViewInterpreter/evaluate(_:state:)``. Parsing and operator folding
/// are the source-only, expensive steps; caching a ``ParsedProgram`` lets a
/// host re-render against changing live data (for example a per-second clock
/// tick) without paying the parse cost on every frame.
///
/// ```swift
/// let interpreter = SwiftViewInterpreter()
/// let program = interpreter.parse(source)        // parse once
/// let node = interpreter.evaluate(program, state: liveData)  // cheap re-eval
/// ```
public struct ParsedProgram: Sendable {
    /// The folded syntax tree the interpreter walks.
    let file: SourceFileSyntax
    /// False when parsing was refused by the source-size guard. Keeping the
    /// marker in the value type lets the public parse API fail closed without
    /// changing it to a throwing API.
    let isValid: Bool

    init(file: SourceFileSyntax, isValid: Bool = true) {
        self.file = file
        self.isValid = isValid
    }
}
