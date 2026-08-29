import Foundation
import Testing
@testable import CmuxTerminalCore

@Suite("Terminal math byte gate")
struct TerminalMathByteGateTests {
    @Test("A dollar sign in plain text bumps the revision")
    func dollarInPlainText() {
        var gate = TerminalMathByteGate()
        consume("The answer is $x^2$ today.", into: &gate)
        #expect(gate.candidateRevision == 1)
    }

    @Test("Plain text without an opener never bumps the revision")
    func plainTextWithoutOpener() {
        var gate = TerminalMathByteGate()
        consume("ls -la\r\ntotal 12 (three files) [ok]\r\n", into: &gate)
        #expect(gate.candidateRevision == 0)
    }

    @Test("Inline delimiter split across two chunks still fires")
    func backslashParenthesisAcrossChunks() {
        var gate = TerminalMathByteGate()
        consume("see \\", into: &gate)
        #expect(gate.candidateRevision == 0)
        consume("(a+b\\)", into: &gate)
        #expect(gate.candidateRevision == 1)
    }

    @Test("Display delimiter fires")
    func backslashBracket() {
        var gate = TerminalMathByteGate()
        consume("\\[ \\int_0^1 x\\,dx \\]", into: &gate)
        #expect(gate.candidateRevision == 1)
    }

    @Test("Bare parenthesis or bracket without a backslash does not fire")
    func bareBracketsDoNotFire() {
        var gate = TerminalMathByteGate()
        consume("f(x) = a[0] + \\n(", into: &gate)
        #expect(gate.candidateRevision == 0)
    }

    @Test("Dollar inside an OSC title does not fire")
    func oscTitleWithDollar() {
        var gate = TerminalMathByteGate()
        consume("\u{1B}]0;cost $100\u{07}done", into: &gate)
        #expect(gate.candidateRevision == 0)
        consume("\u{1B}]8;;https://example.com/?q=$1\u{1B}\\link\u{1B}]8;;\u{1B}\\", into: &gate)
        #expect(gate.candidateRevision == 0)
    }

    @Test("An OSC opened in one chunk swallows a dollar in the next")
    func oscStatePersistsAcrossChunks() {
        var gate = TerminalMathByteGate()
        consume("\u{1B}]0;cost ", into: &gate)
        #expect(gate.candidateRevision == 0)
        consume("$100\u{07}", into: &gate)
        #expect(gate.candidateRevision == 0)
        consume("$x$", into: &gate)
        #expect(gate.candidateRevision == 1)
    }

    @Test("A dollar as a CSI intermediate byte does not fire")
    func csiIntermediateDollarDoesNotFire() {
        // DECRQM: `ESC [ ? 2026 $ p`, emitted by tmux and neovim on startup.
        var gate = TerminalMathByteGate()
        consume("\u{1B}[?2026$p", into: &gate)
        #expect(gate.candidateRevision == 0)
        consume("after", into: &gate)
        #expect(gate.candidateRevision == 0)
    }

    @Test("A CSI split across chunks mid-parameters keeps swallowing a dollar")
    func csiStatePersistsAcrossChunks() {
        var gate = TerminalMathByteGate()
        consume("\u{1B}[?20", into: &gate)
        #expect(gate.candidateRevision == 0)
        consume("26$p", into: &gate)
        #expect(gate.candidateRevision == 0)
        consume("$y$", into: &gate)
        #expect(gate.candidateRevision == 1)
    }

    @Test("Bytes inside a CSI sequence do not fire")
    func csiParametersDoNotFire() {
        var gate = TerminalMathByteGate()
        consume("\u{1B}[1;31mplain\u{1B}[0m", into: &gate)
        #expect(gate.candidateRevision == 0)
    }

    @Test("An SGR sequence between backslash and parenthesis is transparent")
    func escapeSequenceBetweenBackslashAndParenthesis() {
        var gate = TerminalMathByteGate()
        consume("\\\u{1B}[0m(x)", into: &gate)
        #expect(gate.candidateRevision == 1)
    }

    @Test("A line break between backslash and parenthesis clears the candidate")
    func lineBreakClearsBackslash() {
        var gate = TerminalMathByteGate()
        consume("\\\r\n(x)", into: &gate)
        #expect(gate.candidateRevision == 0)
    }

    @Test("An escaped backslash followed by a parenthesis still fires")
    func doubleBackslashParenthesisFires() {
        // Documented choice: `\\(` treats the second backslash as the opener
        // candidate. A false positive costs one grid scan; a false negative
        // would hide real math.
        var gate = TerminalMathByteGate()
        consume("path \\\\(x)", into: &gate)
        #expect(gate.candidateRevision == 1)
    }

    @Test("The revision bumps at most once per chunk")
    func revisionBumpsOncePerChunk() {
        var gate = TerminalMathByteGate()
        consume("$a$ and $b$ and \\(c\\) and \\[d\\]", into: &gate)
        #expect(gate.candidateRevision == 1)
        consume("$e$", into: &gate)
        #expect(gate.candidateRevision == 2)
        consume("nothing here", into: &gate)
        #expect(gate.candidateRevision == 2)
    }

    @Test("An empty chunk leaves the revision unchanged")
    func emptyChunk() {
        var gate = TerminalMathByteGate()
        Data().withUnsafeBytes { raw in
            gate.consume(raw.bindMemory(to: UInt8.self))
        }
        #expect(gate.candidateRevision == 0)
    }

    private func consume(_ text: String, into gate: inout TerminalMathByteGate) {
        Data(text.utf8).withUnsafeBytes { raw in
            gate.consume(raw.bindMemory(to: UInt8.self))
        }
    }
}
