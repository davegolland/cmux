import XCTest
import Darwin
import Foundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class TerminalControllerTerminalTextTests: XCTestCase {
    func testTailTerminalLinesPreservesSplitSuffixSemanticsWithoutFullSplit() {
        XCTAssertEqual(TerminalController.tailTerminalLines("a\nb\nc", maxLines: 2), "b\nc")
        XCTAssertEqual(TerminalController.tailTerminalLines("a\nb\n", maxLines: 2), "b\n")
        XCTAssertEqual(TerminalController.tailTerminalLines("a", maxLines: 2), "a")
        XCTAssertEqual(TerminalController.tailTerminalLines("a\nb", maxLines: 0), "")
    }

    func testTerminalTextPayloadTailsScrollbackBeforeEncoding() throws {
        let result = TerminalController.terminalTextPayload(
            from: TerminalController.TerminalTextRawSnapshot(
                viewport: nil,
                screen: "old\nscreen",
                history: "one\ntwo\nthree",
                active: "four\nfive"
            ),
            includeScrollback: true,
            lineLimit: 3
        )
        let payload = try result.get()

        XCTAssertEqual(payload.text, "three\nfour\nfive")
        XCTAssertEqual(payload.base64, Data("three\nfour\nfive".utf8).base64EncodedString())
    }

    func testTerminalTextPayloadRejectsOversizedNativeResult() {
        let oversized = String(repeating: "x", count: 4 * 1024 * 1024 + 1)
        let result = TerminalController.terminalTextPayload(
            from: TerminalController.TerminalTextRawSnapshot(
                viewport: oversized,
                screen: nil,
                history: nil,
                active: nil
            ),
            includeScrollback: false,
            lineLimit: nil
        )

        guard case .failure(let error) = result else {
            XCTFail("oversized terminal text must be rejected")
            return
        }
        XCTAssertEqual(error.message, "Terminal text exceeds the safe limit")
    }

}
