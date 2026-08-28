import CmuxAgentChat
import Foundation

/// Builds and caches the transcript-derived artifact scope for chat sessions.
actor AgentChatArtifactIndex {
    private static let maxTranscriptLines = AgentChatBoundedFileReader.maxTranscriptLines
    private static let maxTranscriptLineBytes = AgentChatBoundedFileReader.maxLineBytes

    struct Snapshot: Sendable {
        let referencedPaths: Set<String>
        let artifacts: [ChatArtifactIndexedReference]
        let generation: String
    }

    enum Operation: Sendable {
        case file
        case list
    }

    enum CanonicalPathResult: Sendable {
        case success(String)
        case canonicalizationFailed
        case notInSet
    }

    private struct CacheKey: Sendable, Equatable {
        let transcriptPath: String
        let workingDirectory: String?
        let fileSize: UInt64
        let modifiedAt: Date

        var generation: String {
            "\(fileSize)-\(Int64(modifiedAt.timeIntervalSince1970 * 1_000_000))"
        }
    }

    private struct CacheEntry: Sendable {
        let key: CacheKey
        let snapshot: Snapshot
    }

    private var cacheBySessionID = ChatArtifactLRUCache<String, CacheEntry>(capacity: 8)

    func snapshot(
        sessionID: String,
        agentKind: ChatAgentKind,
        transcriptPath: String,
        workingDirectory: String?
    ) async throws -> Snapshot {
        let key = try Self.cacheKey(transcriptPath: transcriptPath, workingDirectory: workingDirectory)
        if let cached = cacheBySessionID.value(forKey: sessionID), cached.key == key {
            return cached.snapshot
        }
        let snapshot = try Self.buildSnapshot(
            agentKind: agentKind,
            transcriptPath: transcriptPath,
            workingDirectory: workingDirectory,
            generation: key.generation
        )
        cacheBySessionID.insert(CacheEntry(key: key, snapshot: snapshot), forKey: sessionID)
        return snapshot
    }

    func canonicalPath(
        sessionID: String,
        agentKind: ChatAgentKind,
        transcriptPath: String,
        workingDirectory: String?,
        requestedPath: String,
        operation: Operation,
        directoryAccessMode: ChatArtifactScope.DirectoryAccessMode
    ) async throws -> CanonicalPathResult {
        let snapshot = try await snapshot(
            sessionID: sessionID,
            agentKind: agentKind,
            transcriptPath: transcriptPath,
            workingDirectory: workingDirectory
        )
        let resolver = ChatArtifactScope.FoundationResolver()
        guard ChatArtifactScope.canonicalizedPath(requestedPath, resolver: resolver) != nil else {
            return .canonicalizationFailed
        }
        let canonicalPath: String?
        let scope = ChatArtifactScope(
            referencedPaths: snapshot.referencedPaths,
            directoryAccessMode: directoryAccessMode,
            resolver: resolver
        )
        switch operation {
        case .file:
            canonicalPath = scope.canonicalFilePath(for: requestedPath)
        case .list:
            canonicalPath = scope.canonicalDirectoryListPath(for: requestedPath)
        }
        return canonicalPath.map(CanonicalPathResult.success) ?? .notInSet
    }

    private static func cacheKey(transcriptPath: String, workingDirectory: String?) throws -> CacheKey {
        let metadata = try AgentChatBoundedFileReader.metadata(atPath: transcriptPath)
        guard metadata.size <= UInt64(AgentChatBoundedFileReader.maxTranscriptBytes) else {
            throw AgentChatBoundedFileReadError.tooLarge
        }
        return CacheKey(
            transcriptPath: transcriptPath,
            workingDirectory: workingDirectory,
            fileSize: metadata.size,
            modifiedAt: metadata.modifiedAt ?? Date(timeIntervalSince1970: 0)
        )
    }

    private static func buildSnapshot(
        agentKind: ChatAgentKind,
        transcriptPath: String,
        workingDirectory: String?,
        generation: String
    ) throws -> Snapshot {
        let data = try AgentChatBoundedFileReader.data(atPath: transcriptPath)
        // Validate line count and line length before materializing a String
        // and an array of Substrings. A 32 MB file containing millions of
        // newline bytes could otherwise create a very large temporary object
        // graph before the post-split bounds check runs.
        guard isBoundedTranscriptLines(data) else {
            throw AgentChatBoundedFileReadError.tooLarge
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw AgentChatBoundedFileReadError.readFailed
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let parseResult: ChatTranscriptParseResult
        switch agentKind {
        case .codex:
            parseResult = CodexTranscriptParser().parse(lines: lines, startingSeq: 0)
        case .claude, .other:
            parseResult = ClaudeTranscriptParser().parse(lines: lines, startingSeq: 0)
        }
        let artifacts = ChatArtifactIndexedReference.derive(
            from: parseResult.messages,
            supplementalReferences: parseResult.artifactReferences,
            workingDirectory: workingDirectory
        )
        let referencedPaths = Set(artifacts.map(\.path))
        return Snapshot(
            referencedPaths: referencedPaths,
            artifacts: artifacts,
            generation: generation
        )
    }

    private static func isBoundedTranscriptLines(_ data: Data) -> Bool {
        var lineCount = 1
        var lineBytes = 0
        for byte in data {
            if byte == 0x0A {
                guard lineBytes <= maxTranscriptLineBytes else { return false }
                lineCount += 1
                guard lineCount <= maxTranscriptLines else { return false }
                lineBytes = 0
            } else {
                lineBytes += 1
                guard lineBytes <= maxTranscriptLineBytes else { return false }
            }
        }
        return lineBytes <= maxTranscriptLineBytes
    }
}
