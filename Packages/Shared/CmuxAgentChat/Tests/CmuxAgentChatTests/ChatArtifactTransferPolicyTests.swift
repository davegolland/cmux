import Testing

@testable import CmuxAgentChat

@Suite("ChatArtifactTransferPolicy")
struct ChatArtifactTransferPolicyTests {
    @Test("default chunk fits mobile sync frame")
    func defaultChunkFitsFrame() {
        let policy = ChatArtifactTransferPolicy.defaultPolicy
        #expect(policy.maxRawChunkBytes == 3 * 1024 * 1024)
        #expect(policy.maxPreviewBytes == 64 * 1024 * 1024)
        #expect(policy.maxMediaPreviewBytes == 512 * 1024 * 1024)
        #expect(policy.estimatedEnvelopeByteCount(rawByteCount: policy.maxRawChunkBytes) < policy.mobileSyncFrameLimitBytes)
        #expect(policy.clampedChunkLength(10 * 1024 * 1024) == policy.maxRawChunkBytes)
    }

    @Test("custom policies cannot bypass hard transfer ceilings")
    func hostilePolicyValuesAreClamped() {
        let policy = ChatArtifactTransferPolicy(
            maxRawChunkBytes: .max,
            mobileSyncFrameLimitBytes: .max,
            maxPreviewBytes: .max,
            maxMediaPreviewBytes: .max
        )

        #expect(policy.maxRawChunkBytes == ChatArtifactTransferPolicy.maximumRawChunkBytes)
        #expect(policy.mobileSyncFrameLimitBytes == ChatArtifactTransferPolicy.maximumMobileSyncFrameLimitBytes)
        #expect(policy.maxPreviewBytes == ChatArtifactTransferPolicy.maximumPreviewBytes)
        #expect(policy.maxMediaPreviewBytes == ChatArtifactTransferPolicy.maximumMediaPreviewBytes)
        #expect(policy.estimatedEnvelopeByteCount(rawByteCount: .max) < Int.max)
    }
}
