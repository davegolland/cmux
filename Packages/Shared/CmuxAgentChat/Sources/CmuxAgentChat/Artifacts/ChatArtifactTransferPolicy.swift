/// Transfer limits shared by Mac artifact RPC handlers and iOS preview code.
public struct ChatArtifactTransferPolicy: Sendable, Equatable {
    /// Hard protocol and memory ceilings. The initializer is public because
    /// tests and alternate transports can provide a policy, so these limits
    /// must also be enforced at that boundary.
    public static let maximumRawChunkBytes = 3 * 1024 * 1024
    public static let maximumMobileSyncFrameLimitBytes = 64 * 1024 * 1024
    public static let maximumPreviewBytes: Int64 = 64 * 1024 * 1024
    public static let maximumMediaPreviewBytes: Int64 = 512 * 1024 * 1024

    /// Default artifact transfer policy.
    public static let defaultPolicy = ChatArtifactTransferPolicy()

    /// Maximum raw bytes returned by one fetch RPC chunk.
    public let maxRawChunkBytes: Int
    /// Maximum mobile-sync frame size the chunk envelope must remain below.
    public let mobileSyncFrameLimitBytes: Int
    /// Maximum file size the iOS viewer previews inline.
    public let maxPreviewBytes: Int64
    /// Maximum movie or audio size streamed to an iOS temporary file.
    public let maxMediaPreviewBytes: Int64

    /// Creates an artifact transfer policy.
    ///
    /// - Parameters:
    ///   - maxRawChunkBytes: Maximum raw bytes returned by one fetch chunk.
    ///   - mobileSyncFrameLimitBytes: Maximum mobile-sync frame size.
    ///   - maxPreviewBytes: Maximum inline preview file size.
    ///   - maxMediaPreviewBytes: Maximum temporary-file media preview size.
    public init(
        maxRawChunkBytes: Int = 3 * 1024 * 1024,
        mobileSyncFrameLimitBytes: Int = 8 * 1024 * 1024,
        maxPreviewBytes: Int64 = 64 * 1024 * 1024,
        maxMediaPreviewBytes: Int64 = 512 * 1024 * 1024
    ) {
        self.maxRawChunkBytes = min(
            max(maxRawChunkBytes, 1),
            Self.maximumRawChunkBytes
        )
        self.mobileSyncFrameLimitBytes = min(
            max(mobileSyncFrameLimitBytes, 1_024),
            Self.maximumMobileSyncFrameLimitBytes
        )
        self.maxPreviewBytes = min(
            max(maxPreviewBytes, 1),
            Self.maximumPreviewBytes
        )
        self.maxMediaPreviewBytes = min(
            max(maxMediaPreviewBytes, 1),
            Self.maximumMediaPreviewBytes
        )
    }

    /// Clamps a requested chunk length to the policy's raw-byte maximum.
    ///
    /// - Parameter requestedLength: Optional client-requested byte count.
    /// - Returns: A positive chunk length no larger than ``maxRawChunkBytes``.
    public func clampedChunkLength(_ requestedLength: Int?) -> Int {
        guard let requestedLength, requestedLength > 0 else {
            return maxRawChunkBytes
        }
        return min(requestedLength, maxRawChunkBytes)
    }

    /// Estimates base64-plus-envelope bytes for a raw chunk.
    ///
    /// - Parameter rawByteCount: Raw chunk byte count.
    /// - Returns: Conservative encoded payload size including JSON overhead.
    public func estimatedEnvelopeByteCount(rawByteCount: Int) -> Int {
        let bounded = min(max(rawByteCount, 0), maxRawChunkBytes)
        let (rounded, roundedOverflow) = bounded.addingReportingOverflow(2)
        guard !roundedOverflow else { return Int.max }
        let (groups, _) = rounded.dividedReportingOverflow(by: 3)
        let (base64Bytes, base64Overflow) = groups.multipliedReportingOverflow(by: 4)
        guard !base64Overflow else { return Int.max }
        let (total, totalOverflow) = base64Bytes.addingReportingOverflow(1_024)
        return totalOverflow ? Int.max : total
    }
}
