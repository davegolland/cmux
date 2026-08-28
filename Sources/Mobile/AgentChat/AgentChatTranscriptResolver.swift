import CmuxAgentChat
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Resolves the transcript JSONL path for an agent session.
///
/// Preference order: the hook store's recorded `transcriptPath`, then the
/// agent-specific conventional location (claude: encoded-cwd project dir;
/// codex: rollout filename containing the session id).
struct AgentChatTranscriptResolver: Sendable {
    private static let maximumCodexFallbackEntries = 20_000
    private static let maximumSessionFileComponentBytes = 256
    private let homeDirectory: URL
    /// Config-dir root for Claude (`$CLAUDE_CONFIG_DIR` or `~/.claude`).
    private let claudeConfigRoot: URL
    /// Config-dir root for Codex (`$CODEX_HOME` or `~/.codex`).
    private let codexConfigRoot: URL

    /// Creates a resolver.
    ///
    /// The derived-path fallbacks honor the agents' own config-dir env
    /// overrides so a user who relocates their config (e.g. `CLAUDE_CONFIG_DIR`
    /// or `CODEX_HOME`, including via a launcher/subrouter) still has transcripts
    /// resolved. The PRIMARY source remains the hook-recorded absolute
    /// `transcriptPath`, which already encodes any custom dir; this only fixes
    /// the fallback used when no path was recorded (e.g. a codex session resumed
    /// out-of-band, resolved by scanning the sessions dir).
    ///
    /// - Parameters:
    ///   - homeDirectory: Injectable home directory for tests.
    ///   - environment: Injectable environment for tests; defaults to the
    ///     process environment. Empty/whitespace override values are ignored.
    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.homeDirectory = homeDirectory
        self.claudeConfigRoot = Self.configRoot(
            override: environment["CLAUDE_CONFIG_DIR"],
            default: homeDirectory.appendingPathComponent(".claude", isDirectory: true)
        )
        self.codexConfigRoot = Self.configRoot(
            override: environment["CODEX_HOME"],
            default: homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        )
    }

    /// Resolves a config-dir root from an env override, expanding a leading `~`,
    /// falling back to `defaultRoot` when the override is absent or blank.
    private static func configRoot(override: String?, default defaultRoot: URL) -> URL {
        guard let trimmed = override?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return defaultRoot
        }
        return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Resolves the transcript path for a session.
    ///
    /// - Parameters:
    ///   - record: The session's registry record.
    ///   - deadline: Optional deadline for recursive fallback enumeration.
    /// - Returns: An existing transcript path, or `nil` when none is found.
    func transcriptPath(
        for record: AgentChatSessionRecord,
        deadline: ContinuousClock.Instant? = nil
    ) -> String? {
        if let recorded = recordedTranscriptPath(for: record) {
            return recorded
        }
        switch record.agentKind {
        case .claude:
            return claudeFallbackPath(record: record)
        case .codex:
            return codexFallbackPath(sessionID: record.sessionID, deadline: deadline)
        case .other:
            return nil
        }
    }

    /// Resolves only paths that are cheap to check from the main-actor mobile
    /// session list path. Codex's fallback scans the full sessions tree, so it is
    /// intentionally excluded here and remains available only when opening a
    /// transcript.
    func boundedTranscriptPath(for record: AgentChatSessionRecord) -> String? {
        if let recorded = recordedTranscriptPath(for: record) {
            return recorded
        }
        switch record.agentKind {
        case .claude:
            return claudeFallbackPath(record: record)
        case .codex, .other:
            return nil
        }
    }

    private func recordedTranscriptPath(for record: AgentChatSessionRecord) -> String? {
        guard let recorded = record.transcriptPath,
              recorded.utf8.count <= AgentChatBoundedFileReader.maxPathBytes,
              !recorded.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        let expanded = (recorded as NSString).expandingTildeInPath
        let normalized = URL(fileURLWithPath: expanded).standardizedFileURL
        // Hook payloads are mutable input. Only accept the transcript format,
        // an absolute normalized path, and a regular bounded file opened with
        // O_NOFOLLOW. This prevents a bad hook entry from turning the history
        // reader into a general arbitrary-file reader.
        guard normalized.path.hasPrefix("/"),
              normalized.pathExtension.caseInsensitiveCompare("jsonl") == .orderedSame,
              let metadata = try? AgentChatBoundedFileReader.metadata(atPath: normalized.path),
              metadata.size <= AgentChatBoundedFileReader.maxTranscriptBytes else {
            return nil
        }
        return normalized.path
    }

    private func claudeFallbackPath(record: AgentChatSessionRecord) -> String? {
        let fileManager = FileManager.default
        guard let cwd = record.workingDirectory,
              Self.isSafeSessionFileComponent(record.hookStoreLookupSessionID) else {
            return nil
        }
        let projectDir = RestorableAgentSessionIndex.encodeClaudeProjectDir(cwd)
        guard !projectDir.isEmpty,
              projectDir.utf8.count <= AgentChatBoundedFileReader.maxPathBytes,
              !projectDir.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            return nil
        }
        let path = claudeConfigRoot
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(projectDir, isDirectory: true)
            .appendingPathComponent("\(record.hookStoreLookupSessionID).jsonl", isDirectory: false)
            .path
        return fileManager.fileExists(atPath: path) ? path : nil
    }

    /// Codex rollout files are named `rollout-<timestamp>-<session-uuid>.jsonl`
    /// under `~/.codex/sessions/YYYY/MM/DD/`; scan recent day directories for
    /// the session id.
    private func codexFallbackPath(
        sessionID: String,
        deadline: ContinuousClock.Instant?
    ) -> String? {
        guard Self.isSafeSessionFileComponent(sessionID) else { return nil }
        guard !Task.isCancelled else { return nil }
        if let deadline, ContinuousClock.now >= deadline {
            return nil
        }
        let fileManager = FileManager.default
        let root = codexConfigRoot
            .appendingPathComponent("sessions", isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let needle = sessionID.lowercased()
        var visitedEntries = 0
        for case let url as URL in enumerator {
            guard !Task.isCancelled else { return nil }
            if let deadline, ContinuousClock.now >= deadline {
                return nil
            }
            visitedEntries += 1
            guard visitedEntries <= Self.maximumCodexFallbackEntries else { return nil }
            guard url.pathExtension == "jsonl" else { continue }
            if url.lastPathComponent.lowercased().contains(needle) {
                return url.path
            }
        }
        return nil
    }

    /// Session identifiers become file-name components and search needles.
    /// Keep the accepted alphabet broad enough for agent versions that use
    /// prefixed IDs, while rejecting separators, controls, and pathological
    /// allocation sizes.
    private static func isSafeSessionFileComponent(_ value: String) -> Bool {
        guard !value.isEmpty,
              value != ".",
              value != "..",
              value.utf8.count <= maximumSessionFileComponentBytes else {
            return false
        }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar != "/"
                && scalar != "\\"
                && !CharacterSet.controlCharacters.contains(scalar)
        }
    }
}

/// Errors returned by the transcript reader. Transcript paths come from agent
/// hooks and can point at a file that changes while cmux is reading it, so the
/// reader must keep both the path and allocation bounded.
enum AgentChatBoundedFileReadError: Error, Sendable {
    case invalidPath
    case notRegularFile
    case tooLarge
    case offsetOutOfRange
    case readFailed
}

/// Opens agent transcript files with a bounded, no-follow read. This is shared
/// by the history tailer and artifact index so neither path can map an
/// attacker-controlled multi-gigabyte file into the cmux process.
enum AgentChatBoundedFileReader {
    struct Metadata: Sendable {
        let size: UInt64
        let inode: UInt64?
        let modifiedAt: Date?
    }

    static let maxTranscriptBytes = 32 * 1024 * 1024
    static let maxIncrementalBytes = 4 * 1024 * 1024
    static let maxLineBytes = 1 * 1024 * 1024
    static let maxTranscriptLines = 200_000
    private static let chunkSize = 64 * 1024
    static let maxPathBytes = 4 * 1024

    static func metadata(atPath path: String) throws -> Metadata {
        try validate(path)
#if canImport(Darwin)
        let descriptor = Darwin.open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw AgentChatBoundedFileReadError.notRegularFile }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0 else {
            throw AgentChatBoundedFileReadError.notRegularFile
        }
        return Metadata(
            size: UInt64(info.st_size),
            inode: UInt64(info.st_ino),
            modifiedAt: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
        )
#else
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let type = attributes[.type] as? FileAttributeType,
              type == .typeRegular,
              let size = attributes[.size] as? NSNumber else {
            throw AgentChatBoundedFileReadError.notRegularFile
        }
        return Metadata(
            size: size.uint64Value,
            inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
            modifiedAt: attributes[.modificationDate] as? Date
        )
#endif
    }

    static func data(atPath path: String, maximumBytes: Int = maxTranscriptBytes) throws -> Data {
        guard maximumBytes > 0, maximumBytes <= maxTranscriptBytes else {
            throw AgentChatBoundedFileReadError.tooLarge
        }
        try validate(path)
#if canImport(Darwin)
        let descriptor = try openRegular(path)
        defer { Darwin.close(descriptor) }
        var info = try regularStat(descriptor)
        guard info.st_size <= off_t(maximumBytes) else {
            throw AgentChatBoundedFileReadError.tooLarge
        }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while result.count <= maximumBytes {
            let amount = min(buffer.count, maximumBytes + 1 - result.count)
            let readCount = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(descriptor, raw.baseAddress, amount)
            }
            if readCount > 0 {
                buffer.withUnsafeBytes { raw in
                    result.append(contentsOf: raw.bindMemory(to: UInt8.self).prefix(readCount))
                }
            } else if readCount == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                throw AgentChatBoundedFileReadError.readFailed
            }
        }
        guard result.count <= maximumBytes else {
            throw AgentChatBoundedFileReadError.tooLarge
        }
        // Detect a growth race after the bounded read. A caller that needs a
        // chunk may still read a growing file, but a full snapshot must not be
        // silently accepted after it crossed its size contract.
        info = try regularStat(descriptor)
        guard info.st_size <= off_t(maximumBytes) else {
            throw AgentChatBoundedFileReadError.tooLarge
        }
        return result
#else
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        let attributes = try metadata(atPath: path)
        guard attributes.size <= UInt64(maximumBytes) else {
            throw AgentChatBoundedFileReadError.tooLarge
        }
        var result = Data()
        while result.count <= maximumBytes {
            let amount = min(chunkSize, maximumBytes + 1 - result.count)
            guard let chunk = try handle.read(upToCount: amount), !chunk.isEmpty else { break }
            result.append(chunk)
        }
        guard result.count <= maximumBytes else { throw AgentChatBoundedFileReadError.tooLarge }
        return result
#endif
    }

    /// Reads at most `maximumBytes` from `offset`. The complete transcript is
    /// still capped by `maxTranscriptBytes`, while the per-event cap prevents
    /// one append from monopolising the actor.
    static func data(
        atPath path: String,
        offset: UInt64,
        maximumBytes: Int = maxIncrementalBytes
    ) throws -> Data {
        guard maximumBytes > 0, maximumBytes <= maxIncrementalBytes else {
            throw AgentChatBoundedFileReadError.tooLarge
        }
        try validate(path)
#if canImport(Darwin)
        let descriptor = try openRegular(path)
        defer { Darwin.close(descriptor) }
        let info = try regularStat(descriptor)
        guard info.st_size <= off_t(maxTranscriptBytes) else {
            throw AgentChatBoundedFileReadError.tooLarge
        }
        guard offset <= UInt64(info.st_size) else {
            throw AgentChatBoundedFileReadError.offsetOutOfRange
        }
        // The incremental read is a slice of the same 32 MiB transcript
        // contract as a full read.  A file can grow after the initial stat,
        // so never let a requested chunk cross that contract while reading
        // from an old offset.
        guard offset <= UInt64(Int.max) else {
            throw AgentChatBoundedFileReadError.offsetOutOfRange
        }
        let remainingTranscriptBytes = AgentChatBoundedFileReader.maxTranscriptBytes - Int(offset)
        let readLimit = min(maximumBytes, max(0, remainingTranscriptBytes))
        if readLimit == 0 {
            return Data()
        }
        guard offset <= UInt64(Int64.max),
              Darwin.lseek(descriptor, off_t(offset), SEEK_SET) >= 0 else {
            throw AgentChatBoundedFileReadError.offsetOutOfRange
        }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while result.count < readLimit {
            let amount = min(buffer.count, readLimit - result.count)
            let readCount = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(descriptor, raw.baseAddress, amount)
            }
            if readCount > 0 {
                buffer.withUnsafeBytes { raw in
                    result.append(contentsOf: raw.bindMemory(to: UInt8.self).prefix(readCount))
                }
            } else if readCount == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                throw AgentChatBoundedFileReadError.readFailed
            }
        }
        // Detect a growth race after the read.  The descriptor remains the
        // same file, so this check cannot be bypassed by replacing the path.
        let finalInfo = try regularStat(descriptor)
        guard finalInfo.st_size <= off_t(maxTranscriptBytes) else {
            throw AgentChatBoundedFileReadError.tooLarge
        }
        return result
#else
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        let info = try metadata(atPath: path)
        guard info.size <= UInt64(maxTranscriptBytes), offset <= info.size else {
            throw AgentChatBoundedFileReadError.offsetOutOfRange
        }
        let remainingTranscriptBytes = UInt64(maxTranscriptBytes) - offset
        let readLimit = min(UInt64(maximumBytes), remainingTranscriptBytes)
        if readLimit == 0 {
            return Data()
        }
        try handle.seek(toOffset: offset)
        let result = try handle.read(upToCount: Int(readLimit)) ?? Data()
        let finalInfo = try metadata(atPath: path)
        guard finalInfo.size <= UInt64(maxTranscriptBytes) else {
            throw AgentChatBoundedFileReadError.tooLarge
        }
        return result
#endif
    }

    private static func validate(_ path: String) throws {
        guard !path.isEmpty,
              path.hasPrefix("/"),
              path.utf8.count <= maxPathBytes,
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw AgentChatBoundedFileReadError.invalidPath
        }
    }

#if canImport(Darwin)
    private static func openRegular(_ path: String) throws -> Int32 {
        let descriptor = Darwin.open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw AgentChatBoundedFileReadError.notRegularFile }
        do {
            _ = try regularStat(descriptor)
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func regularStat(_ descriptor: Int32) throws -> stat {
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0 else {
            throw AgentChatBoundedFileReadError.notRegularFile
        }
        return info
    }
#endif
}
