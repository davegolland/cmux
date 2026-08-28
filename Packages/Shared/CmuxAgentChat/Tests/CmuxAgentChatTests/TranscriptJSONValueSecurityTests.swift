import Foundation
import Testing

@testable import CmuxAgentChat

@Suite("Transcript JSON limits")
struct TranscriptJSONValueSecurityTests {
    @Test("deep JSON is rejected before decoding")
    func rejectsDeepJSON() {
        let line = String(repeating: "[", count: TranscriptJSONGuard.maximumDepth + 1)
            + String(repeating: "]", count: TranscriptJSONGuard.maximumDepth + 1)
        #expect(TranscriptJSONValue(jsonLine: line) == nil)
    }

    @Test("oversized JSONL line is rejected")
    func rejectsOversizedLine() {
        let line = "\"" + String(repeating: "x", count: TranscriptJSONGuard.maximumLineBytes) + "\""
        #expect(TranscriptJSONValue(jsonLine: line) == nil)
    }

    @Test("out of range numbers do not trap integer extraction")
    func rejectsOutOfRangeIntegerExtraction() {
        let huge = TranscriptJSONValue(jsonLine: "1e1000")
        #expect(huge?.int == nil)
        let fractional = TranscriptJSONValue(jsonLine: "1.5")
        #expect(fractional?.int == nil)
        let valid = TranscriptJSONValue(jsonLine: "42")
        #expect(valid?.int == 42)
    }
}
