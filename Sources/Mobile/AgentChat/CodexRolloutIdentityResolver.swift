import Foundation
import CmuxSwiftRenderUI

/// Collapses open Codex rollout files into one logical parent session.
struct CodexRolloutIdentityResolver: Sendable {
    private let maximumSessionMetaBytes = 4 * 1_024 * 1_024
    private let sessionMetaReadChunkBytes = 4 * 1_024
    private static let maximumSessionIdentifierBytes = 256

    func resolve(
        openRolloutPaths: [String],
        preferredSessionIDs: Set<String> = [],
        sessionIDFromPath: (String) -> String?
    ) -> CodexRolloutIdentity? {
        var orderedSessionIDs: [String] = []
        var pathBySessionID: [String: String] = [:]
        var parentBySessionID: [String: String] = [:]
        var canonicalSessionIDBySessionID: [String: String] = [:]
        var seenPaths: Set<String> = []

        for path in openRolloutPaths.prefix(20_000) where seenPaths.insert(path).inserted {
            guard !Task.isCancelled else { return nil }
            let fallbackSessionID = sessionIDFromPath((path as NSString).lastPathComponent)
            let metadata = sessionMetadata(atPath: path)
            guard let sessionID = metadata.sessionID ?? fallbackSessionID else { continue }
            if pathBySessionID[sessionID] == nil {
                orderedSessionIDs.append(sessionID)
                pathBySessionID[sessionID] = path
            }
            if let parentSessionID = metadata.parentSessionID,
               parentSessionID != sessionID {
                parentBySessionID[sessionID] = parentSessionID
            }
            if let canonicalSessionID = metadata.canonicalSessionID {
                canonicalSessionIDBySessionID[sessionID] = canonicalSessionID
            }
        }

        guard !orderedSessionIDs.isEmpty else { return nil }
        let openSessionIDs = Set(orderedSessionIDs)
        let canonicalSessionIDs = orderedSessionIDs.compactMap {
            canonicalSessionIDBySessionID[$0]
        }
        if let canonicalSessionID = Set(canonicalSessionIDs).onlyElement,
           orderedSessionIDs.allSatisfy({ sessionID in
               sessionID == canonicalSessionID
                   || canonicalSessionIDBySessionID[sessionID] == canonicalSessionID
           }),
           let path = pathBySessionID[canonicalSessionID] {
            return CodexRolloutIdentity(
                sessionID: canonicalSessionID,
                transcriptPath: path
            )
        }

        let roots = orderedSessionIDs.compactMap {
            rootSessionID(
                for: $0,
                parentBySessionID: parentBySessionID,
                openSessionIDs: openSessionIDs
            )
        }
        if roots.count == orderedSessionIDs.count,
           let root = Set(roots).onlyElement,
           let path = pathBySessionID[root] {
            return CodexRolloutIdentity(sessionID: root, transcriptPath: path)
        }

        if let preferred = orderedSessionIDs.first(where: preferredSessionIDs.contains),
           let path = pathBySessionID[preferred] {
            return CodexRolloutIdentity(sessionID: preferred, transcriptPath: path)
        }

        return nil
    }

    private func rootSessionID(
        for sessionID: String,
        parentBySessionID: [String: String],
        openSessionIDs: Set<String>
    ) -> String? {
        var current = sessionID
        var visited: Set<String> = []
        while let parent = parentBySessionID[current], openSessionIDs.contains(parent) {
            guard visited.insert(current).inserted else { return nil }
            current = parent
        }
        return current
    }

    private func sessionMetadata(
        atPath path: String
    ) -> (sessionID: String?, canonicalSessionID: String?, parentSessionID: String?) {
        guard let data = sessionMetaLine(atPath: path),
              SidebarJSONGuard.isBoundedSyntax(data, maximumDepth: 64, maximumTokens: 100_000),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              SidebarJSONGuard.isBoundedObject(
                  object,
                  maximumBytes: maximumSessionMetaBytes,
                  maximumCollectionItems: 2_048
              ),
              object["type"] as? String == "session_meta",
              let payload = object["payload"] as? [String: Any] else {
            return (nil, nil, nil)
        }
        return (
            normalized(payload["id"] as? String),
            normalized(payload["session_id"] as? String),
            normalized(payload["parent_thread_id"] as? String)
        )
    }

    private func sessionMetaLine(atPath path: String) -> Data? {
        guard path.utf8.count <= 4 * 1024,
              path.hasPrefix("/"),
              path.hasSuffix(".jsonl"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
#if canImport(Darwin)
        // Rollout paths come from a process table, but the process can be
        // compromised and the file can be replaced between enumeration and
        // reading. Open with a no-follow descriptor and read only the bounded
        // first line. A large rollout may be valid; only its metadata line is
        // needed here, so do not impose a full-file size limit.
        let descriptor = Darwin.open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0 else { return nil }
        var line = Data()
        var buffer = [UInt8](repeating: 0, count: sessionMetaReadChunkBytes)
        while line.count <= maximumSessionMetaBytes {
            guard !Task.isCancelled else { return nil }
            let readCount = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(descriptor, raw.baseAddress, raw.count)
            }
            if readCount > 0 {
                let bytes = buffer.prefix(readCount)
                if let newline = bytes.firstIndex(of: 0x0A) {
                    let prefix = bytes[..<newline]
                    guard line.count + prefix.count <= maximumSessionMetaBytes else { return nil }
                    line.append(contentsOf: prefix)
                    return line
                }
                guard line.count + bytes.count <= maximumSessionMetaBytes else { return nil }
                line.append(contentsOf: bytes)
            } else if readCount == 0 {
                return nil
            } else if errno == EINTR {
                continue
            } else {
                return nil
            }
        }
        return nil
#else
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var line = Data()
        while line.count <= maximumSessionMetaBytes {
            guard !Task.isCancelled,
                  let chunk = try? handle.read(
                      upToCount: min(
                          sessionMetaReadChunkBytes,
                          maximumSessionMetaBytes + 1 - line.count
                      )
                  ),
                  !chunk.isEmpty else {
                return nil
            }
            if let newline = chunk.firstIndex(of: 0x0A) {
                let prefix = chunk[..<newline]
                guard line.count + prefix.count <= maximumSessionMetaBytes else { return nil }
                line.append(contentsOf: prefix)
                return line
            }
            line.append(chunk)
        }
        return nil
#endif
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed.utf8.count <= Self.maximumSessionIdentifierBytes,
              !trimmed.unicodeScalars.contains(where: {
                  $0 == "/"
                      || $0 == "\\"
                      || CharacterSet.controlCharacters.contains($0)
              }) else { return nil }
        return trimmed
    }
}

private extension Set {
    var onlyElement: Element? {
        count == 1 ? first : nil
    }
}
