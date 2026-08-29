/// Cheap byte-level pre-check for math delimiters in raw PTY output.
///
/// The gate answers one question per chunk: did this chunk contain a byte
/// that could open a math span (`$`, `\(`, or `\[`)? It exists so the PTY tee
/// can skip the main-actor grid scan for the overwhelming majority of output
/// without building a `String` on Ghostty's IO read thread. False positives
/// are acceptable (the grid scanner rejects them); false negatives are not.
///
/// Bytes inside ESC/CSI/OSC sequences are ignored with the same five-state
/// machine ``PromptLineTurnDetector`` uses, so an OSC window title or a
/// hyperlink URL containing `$` never fires the gate. The trailing-backslash
/// bit carries across chunks, so `\(` split at a chunk boundary still fires.
/// Escape sequences are transparent to that bit (`\` ESC[0m `(` fires, since
/// styled output can interleave SGR between the two bytes); line breaks clear
/// it. A backslash-escaped backslash followed by `(` (`\\(`) fires too: the
/// second backslash is treated as the opener candidate, which is the cheap
/// choice that can only cause a false positive.
///
/// The alternate screen (`CSI ? 47 / 1047 / 1049 h`) never shows overlays,
/// so delimiters printed there do not fire; leaving it (`... l`) fires once so
/// the restored primary screen is scanned again.
///
/// The gate never allocates and bumps ``candidateRevision`` at most once per
/// consumed chunk.
public struct TerminalMathByteGate: Sendable {
    private enum ControlSequence: Sendable {
        case none
        case escape
        case csi
        case osc
        case oscEscape
    }

    private static let dollar = UInt8(ascii: "$")
    private static let backslash = UInt8(ascii: "\\")
    private static let openParenthesis = UInt8(ascii: "(")
    private static let openBracket = UInt8(ascii: "[")
    private static let escape: UInt8 = 0x1B

    private var controlSequence: ControlSequence = .none
    /// The last printable byte outside an escape sequence was a backslash.
    private var sawBackslash = false
    /// CSI parse state: `?` prefix seen, current numeric parameter, an
    /// alternate-screen parameter seen, an intermediate byte seen.
    private var csiIsPrivate = false
    private var csiParameter = 0
    private var csiSawAlternateScreenParameter = false
    private var csiSawIntermediate = false

    /// Whether the terminal is on the alternate screen, as far as the DEC
    /// private mode sequences in the output say.
    public private(set) var isAlternateScreen = false

    /// Increments once per consumed chunk that contained a math opener.
    ///
    /// Compare this value after each chunk and only schedule the grid scan
    /// when it changed.
    public private(set) var candidateRevision: UInt64 = 0

    /// Creates a gate with no pending backslash and no open escape sequence.
    public init() {}

    /// Consumes one borrowed PTY output chunk.
    ///
    /// - Parameter bytes: Raw bytes read from the PTY.
    public mutating func consume(_ bytes: UnsafeBufferPointer<UInt8>) {
        var found = false
        for byte in bytes {
            if consume(byte) { found = true }
        }
        if found {
            candidateRevision &+= 1
        }
    }

    /// Advances the state machine by one byte.
    ///
    /// - Returns: `true` when the byte completes a math opener candidate.
    private mutating func consume(_ byte: UInt8) -> Bool {
        switch controlSequence {
        case .escape:
            switch byte {
            case Self.openBracket:
                controlSequence = .csi
                csiIsPrivate = false
                csiParameter = 0
                csiSawAlternateScreenParameter = false
                csiSawIntermediate = false
            case UInt8(ascii: "]"): controlSequence = .osc
            default: controlSequence = .none
            }
            return false
        case .csi:
            return consumeCSI(byte)
        case .osc:
            if byte == 0x07 {
                controlSequence = .none
            } else if byte == Self.escape {
                controlSequence = .oscEscape
            }
            return false
        case .oscEscape:
            controlSequence = byte == Self.backslash ? .none : .osc
            return false
        case .none:
            break
        }

        switch byte {
        case Self.escape:
            controlSequence = .escape
            return false
        case Self.dollar:
            sawBackslash = false
            return !isAlternateScreen
        case Self.backslash:
            sawBackslash = true
            return false
        case Self.openParenthesis, Self.openBracket:
            let opened = sawBackslash
            sawBackslash = false
            return opened && !isAlternateScreen
        case 0x0A, 0x0D:
            sawBackslash = false
            return false
        default:
            if byte >= 0x20, byte != 0x7F {
                sawBackslash = false
            }
            return false
        }
    }

    /// Advances a CSI sequence by one byte, tracking only what the
    /// alternate-screen modes need.
    ///
    /// - Returns: `true` when the byte ends a sequence that left the
    ///   alternate screen.
    private mutating func consumeCSI(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "?") where csiParameter == 0 && !csiSawAlternateScreenParameter:
            csiIsPrivate = true
            return false
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            csiParameter = min(csiParameter * 10 + Int(byte - UInt8(ascii: "0")), 100_000)
            return false
        case UInt8(ascii: ";"):
            if Self.isAlternateScreenMode(csiParameter) { csiSawAlternateScreenParameter = true }
            csiParameter = 0
            return false
        case 0x20...0x2F:
            csiSawIntermediate = true
            return false
        case 0x40...0x7E:
            controlSequence = .none
            if Self.isAlternateScreenMode(csiParameter) { csiSawAlternateScreenParameter = true }
            guard csiIsPrivate, csiSawAlternateScreenParameter, !csiSawIntermediate else { return false }
            switch byte {
            case UInt8(ascii: "h"):
                isAlternateScreen = true
                return false
            case UInt8(ascii: "l"):
                let left = isAlternateScreen
                isAlternateScreen = false
                return left
            default:
                return false
            }
        default:
            return false
        }
    }

    private static func isAlternateScreenMode(_ parameter: Int) -> Bool {
        parameter == 47 || parameter == 1047 || parameter == 1049
    }
}
