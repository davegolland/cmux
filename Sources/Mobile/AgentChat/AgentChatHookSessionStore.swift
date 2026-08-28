import CmuxAgentChat
import CmuxSwiftRenderUI
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Reads the per-agent hook session stores (`~/.cmuxterm/<agent>-hook-sessions.json`)
/// the `cmux hooks` CLI maintains, yielding terminal bindings and transcript
/// paths for agent sessions.
///
/// Mirrors `FeedJumpResolver.lookup`'s tolerant parsing (nested `sessions`
/// dict with a flat-layout fallback) but surfaces the additional fields the
/// chat service needs (`cwd`, `transcriptPath`, `pid`).
struct AgentChatHookSessionStore: Sendable {
    /// One hook-store entry's chat-relevant fields.
    struct Entry: Sendable {
        /// The agent's session identifier (the store key).
        let sessionID: String
        /// Owning cmux workspace UUID string.
        let workspaceID: String?
        /// Hosting cmux terminal surface UUID string.
        let surfaceID: String?
        /// The session's working directory.
        let workingDirectory: String?
        /// Absolute transcript JSONL path, when the hook recorded one.
        let transcriptPath: String?
        /// The agent process id, for liveness checks.
        let pid: Int?
        /// When the hook store last updated the record.
        let updatedAt: Date?
    }

    private let homeDirectory: URL

    /// Creates a store reader.
    ///
    /// - Parameter homeDirectory: The home directory containing
    ///   `.cmuxterm/`; injectable for tests.
    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
    }

    /// Reads one agent's hook session store.
    ///
    /// - Parameter agentSource: The agent's `_source` name (`claude`,
    ///   `codex`, ...), which names the store file.
    /// - Returns: All entries, or empty when the store is absent/malformed.
    func entries(agentSource: String) -> [Entry] {
        guard Self.isSafeAgentSource(agentSource) else { return [] }
        let file = homeDirectory
            .appendingPathComponent(".cmuxterm", isDirectory: true)
            .appendingPathComponent("\(agentSource)-hook-sessions.json", isDirectory: false)
        guard let data = Self.readBounded(file),
              SidebarJSONGuard.isBoundedSyntax(data, maximumTokens: 100_000),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              SidebarJSONGuard.isBoundedObject(
                  root,
                  maximumBytes: SidebarSecurityLimits.maxDataJSONBytes,
                  maximumCollectionItems: Self.maxEntries
              ) else {
            return []
        }
        let sessions = (root["sessions"] as? [String: Any]) ?? root
        // Sort before applying the cap. Dictionary iteration order is not
        // stable, and a writer must not be able to hide arbitrary sessions by
        // changing hash order.
        return sessions.compactMap { key, value -> Entry? in
            guard Self.isSafeField(key, maxBytes: SidebarSecurityLimits.maxIdentifierBytes) else {
                return nil
            }
            guard let entry = value as? [String: Any] else { return nil }
            let updatedAt = (entry["updatedAt"] as? TimeInterval).flatMap {
                $0.isFinite ? Date(timeIntervalSince1970: $0) : nil
            }
            return Entry(
                sessionID: key,
                workspaceID: Self.nonEmpty(entry["workspaceId"] as? String),
                surfaceID: Self.nonEmpty(entry["surfaceId"] as? String),
                workingDirectory: Self.nonEmpty(entry["cwd"] as? String),
                transcriptPath: Self.nonEmpty(entry["transcriptPath"] as? String),
                pid: AgentChatPIDValidation.sanitized(entry["pid"] as? Int),
                updatedAt: updatedAt
            )
        }
        .sorted { $0.sessionID < $1.sessionID }
        .prefix(Self.maxEntries)
        .map { $0 }
    }

    /// Reads one session's entry from one agent's store.
    ///
    /// - Parameters:
    ///   - agentSource: The agent's `_source` name.
    ///   - sessionID: The session to look up.
    /// - Returns: The entry, or `nil` when absent.
    func entry(agentSource: String, sessionID: String) -> Entry? {
        entries(agentSource: agentSource).first { $0.sessionID == sessionID }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value,
              isSafeField(value, maxBytes: SidebarSecurityLimits.maxSceneStringBytes),
              !value.isEmpty else { return nil }
        return value
    }

    private static let maxEntries = 2_048
    private static let maxStoreBytes = SidebarSecurityLimits.maxDataJSONBytes

    /// The source becomes part of a filename. Restrict it to a portable
    /// identifier so a hook event cannot turn a lookup into path traversal.
    private static func isSafeAgentSource(_ source: String) -> Bool {
        guard !source.isEmpty, source.utf8.count <= 64 else { return false }
        return source.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 0x30 && scalar.value <= 0x39)
                || (scalar.value >= 0x41 && scalar.value <= 0x5A)
                || (scalar.value >= 0x61 && scalar.value <= 0x7A)
                || scalar == "-" || scalar == "_" || scalar == "."
        }
    }

    private static func isSafeField(_ value: String, maxBytes: Int) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maxBytes
            && value.unicodeScalars.allSatisfy { scalar in
                !CharacterSet.controlCharacters.contains(scalar)
            }
    }

    /// Reads a bounded snapshot. The store is written by another process, so
    /// both the initial metadata and the extra-byte read are required to keep
    /// a growth race from allocating unbounded memory.
    private static func readBounded(_ url: URL) -> Data? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType,
              type == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              size.int64Value >= 0,
              size.uint64Value <= UInt64(maxStoreBytes) else { return nil }
#if canImport(Darwin)
        // Do not follow a swapped final symlink between the metadata check and
        // the read. Hook files are mutable IPC input, not trusted app data.
        // O_NONBLOCK prevents a hostile replacement with a FIFO from stalling
        // the actor while it reads hook state.
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size <= off_t(maxStoreBytes) else { return nil }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while result.count <= maxStoreBytes {
            let amount = min(buffer.count, maxStoreBytes + 1 - result.count)
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
                return nil
            }
        }
        guard result.count <= maxStoreBytes else { return nil }
        // The writer can replace or grow the store while it is being read.
        // Reject a snapshot whose descriptor size no longer matches the
        // initial contract instead of parsing a partial, attacker-shaped JSON
        // document as if it were stable.
        var finalInfo = stat()
        guard Darwin.fstat(descriptor, &finalInfo) == 0,
              (finalInfo.st_mode & S_IFMT) == S_IFREG,
              finalInfo.st_size >= 0,
              finalInfo.st_size <= off_t(maxStoreBytes),
              finalInfo.st_size == info.st_size else { return nil }
        return result
#else
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var result = Data()
        while result.count <= maxStoreBytes {
            let amount = min(64 * 1024, maxStoreBytes + 1 - result.count)
            guard let chunk = try? handle.read(upToCount: amount), !chunk.isEmpty else { break }
            result.append(chunk)
        }
        return result.count <= maxStoreBytes ? result : nil
#endif
    }
}
