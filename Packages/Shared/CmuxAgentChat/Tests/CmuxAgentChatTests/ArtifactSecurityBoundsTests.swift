import Foundation
import Testing

@testable import CmuxAgentChat

@Suite("Artifact security bounds")
struct ArtifactSecurityBoundsTests {
    @Test("structured path extraction caps unique paths")
    func structuredExtractionIsBounded() {
        let values = (0..<(ChatArtifactSecurityLimits.maxPathsPerValue + 100)).map { index in
            TranscriptJSONValue.string("/tmp/transcript-\(index).txt")
        }
        let value = TranscriptJSONValue.object(["path": .array(values)])

        let paths = ChatToolReferencedPathExtractor().referencedPaths(in: value)

        #expect(paths?.count == ChatArtifactSecurityLimits.maxPathsPerValue)
    }

    @Test("batch artifact occurrences are capped without a temporary mapped array")
    func batchReferencesAreBounded() {
        var assembler = TranscriptBatchAssembler(
            state: ChatTranscriptParseState(),
            budget: TranscriptTextBudget()
        )
        let paths = (0..<(ChatArtifactSecurityLimits.maxReferencesPerBatch + 100)).map { index in
            "/tmp/batch-\(index).txt"
        }

        assembler.appendArtifactReferences(paths: paths, seq: 1)

        #expect(assembler.result(lastTimestamp: nil).artifactReferences.count
            == ChatArtifactSecurityLimits.maxReferencesPerBatch)
    }

    @Test("derived gallery rows cap canonicalization of new paths")
    func indexedReferencesAreBounded() {
        let timestamp = Date(timeIntervalSince1970: 0)
        let messages = (0..<(ChatArtifactSecurityLimits.maxIndexedReferences + 100)).map { index in
            ChatMessage(
                id: "message-\(index)",
                seq: index,
                role: .agent,
                timestamp: timestamp,
                kind: .toolUse(ChatToolUse(
                    toolName: "Read",
                    summary: "read",
                    referencedPaths: ["/tmp/index-\(index).txt"]
                ))
            )
        }

        let rows = ChatArtifactIndexedReference.derive(from: messages)

        #expect(rows.count == ChatArtifactSecurityLimits.maxIndexedReferences)
    }

    @Test("path normalization rejects control characters and oversized tokens")
    func unsafePathTokensAreDropped() {
        let timestamp = Date(timeIntervalSince1970: 0)
        let oversized = "/tmp/" + String(
            repeating: "x",
            count: ChatArtifactSecurityLimits.maxPathBytes
        )
        let messages = [
            ChatMessage(
                id: "control",
                seq: 1,
                role: .agent,
                timestamp: timestamp,
                kind: .toolUse(ChatToolUse(
                    toolName: "Read",
                    summary: "read",
                    referencedPaths: ["/tmp/unsafe\u{0}.txt"]
                ))
            ),
            ChatMessage(
                id: "oversized",
                seq: 2,
                role: .agent,
                timestamp: timestamp,
                kind: .toolUse(ChatToolUse(
                    toolName: "Read",
                    summary: "read",
                    referencedPaths: [oversized]
                ))
            ),
        ]

        #expect(ChatArtifactIndexedReference.derive(from: messages).isEmpty)
    }
}
