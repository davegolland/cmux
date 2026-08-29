/// Removes VT escape sequences from raw terminal text.
///
/// Terminal screen exports carry CSI, OSC, DCS, SOS, PM, and APC sequences in
/// both their 7-bit (`ESC`-introduced) and C1 forms. Detectors that read the
/// visible text, such as ``TerminalArtifactPathDetector`` and
/// ``TerminalMathSpanDetector``, share this one bounded scalar pass so escape
/// terminators never contaminate what they detect.
///
/// The pass removes only the sequences themselves. Printable text, whitespace,
/// and line endings survive unchanged, so offsets into the stripped text line
/// up with what the user sees on screen.
struct TerminalEscapeSequenceStripper: Sendable {
    private enum ScanState {
        case text
        case escape
        case escapeIntermediate
        case csi
        case stringControl(allowsBEL: Bool)
        case stringControlEscape(allowsBEL: Bool)
    }

    /// Creates a stripper.
    init() {}

    /// Returns `text` with every VT escape sequence removed.
    ///
    /// An unterminated sequence at the end of the input (a half-received CSI or
    /// string control) is dropped along with everything after its introducer.
    func strip(_ text: String) -> String {
        let scalars = text.unicodeScalars
        var result = String.UnicodeScalarView()
        var index = scalars.startIndex
        var state = ScanState.text

        while index < scalars.endIndex {
            let scalar = scalars[index]
            index = scalars.index(after: index)
            let value = scalar.value

            switch state {
            case .text:
                switch value {
                case 0x1B:
                    state = .escape
                case 0x9D:
                    // C1 OSC may end with BEL or ST.
                    state = .stringControl(allowsBEL: true)
                case 0x90, 0x98, 0x9E, 0x9F:
                    // C1 DCS, SOS, PM, and APC end only with ST.
                    state = .stringControl(allowsBEL: false)
                case 0x9B:
                    state = .csi
                case 0x9C:
                    // Strip a stray C1 ST just like a stray ESC \ terminator.
                    break
                default:
                    result.append(scalar)
                }

            case .escape:
                switch value {
                case 0x5B: // CSI: ESC [ parameters/intermediates final-byte
                    state = .csi
                case 0x5D:
                    // OSC: payload terminated by BEL or ST.
                    state = .stringControl(allowsBEL: true)
                case 0x50, 0x58, 0x5E, 0x5F:
                    // DCS, SOS, PM, and APC: payload terminated only by ST.
                    state = .stringControl(allowsBEL: false)
                case 0x20...0x2F:
                    state = .escapeIntermediate
                case 0x30...0x7E:
                    // Other two-character ESC sequences, including stray ST.
                    state = .text
                default:
                    // The scalar after ESC is not part of a recognized sequence.
                    // Keep it so ordinary printable text and whitespace survive.
                    result.append(scalar)
                    state = .text
                }

            case .escapeIntermediate:
                if (0x20...0x2F).contains(value) {
                    continue
                }
                state = .text
                if !(0x30...0x7E).contains(value) {
                    result.append(scalar)
                }

            case .csi:
                if (0x40...0x7E).contains(value) {
                    state = .text
                }

            case .stringControl(let allowsBEL):
                if value == 0x9C || (allowsBEL && value == 0x07) {
                    state = .text
                } else if value == 0x1B {
                    state = .stringControlEscape(allowsBEL: allowsBEL)
                }

            case .stringControlEscape(let allowsBEL):
                if value == 0x5C || value == 0x9C || (allowsBEL && value == 0x07) {
                    state = .text
                } else if value != 0x1B {
                    state = .stringControl(allowsBEL: allowsBEL)
                }
            }
        }

        return String(result)
    }
}
