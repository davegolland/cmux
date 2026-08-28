import CMUXAgentLaunch
import CmuxSwiftRenderUI
import Foundation

/// Child-run (subagent) bookkeeping from the parent session's hook events.
///
/// Two shapes exist on the wire. Claude spawns children through the `Task`
/// tool, so a child's life is bracketed by that tool's
/// `PreToolUse`/`PostToolUse` pair (the payload carries `description` and
/// `subagent_type`). Codex emits dedicated `SubagentStart`/`SubagentStop`
/// events. Neither child ever runs hooks of its own, so this bookkeeping is
/// the ONLY view cmux has of nested agents; the state machine in
/// `nextState(previous:event:)` deliberately keeps ignoring these events (a
/// child's lifecycle says nothing about whether the PARENT is working).
///
/// Honest limits: a background Task returns from `PostToolUse` immediately
/// while the child keeps running, so background children read as settled the
/// moment they detach; without per-child ids from the CLI, a `stop`/`Stop`
/// closes every open child (a stopped parent has no running foreground
/// children).
extension AgentChatSessionRegistry {
    nonisolated static func applyChildRunEvent(
        _ record: inout AgentChatSessionRecord,
        event: WorkstreamEvent
    ) {
        switch event.hookEventName {
        case .preToolUse where isTaskSpawn(event):
            openChild(
                &record,
                id: event.requestId ?? UUID().uuidString,
                label: taskLabel(from: event.toolInputJSON),
                at: event.receivedAt
            )
        case .postToolUse where isTaskSpawn(event):
            closeChild(&record, id: event.requestId, at: event.receivedAt)
        case .subagentStart:
            openChild(
                &record,
                id: event.requestId ?? UUID().uuidString,
                label: taskLabel(from: event.toolInputJSON),
                at: event.receivedAt
            )
        case .subagentStop:
            closeChild(&record, id: event.requestId, at: event.receivedAt)
        case .stop, .sessionEnd:
            // The parent finished its turn (or ended); foreground children
            // cannot still be running.
            for index in record.children.indices where record.children[index].endedAt == nil {
                record.children[index].endedAt = event.receivedAt
            }
        default:
            break
        }
        prune(&record, now: event.receivedAt)
    }

    private nonisolated static func isTaskSpawn(_ event: WorkstreamEvent) -> Bool {
        // Claude Code renamed the spawn tool "Task" -> "Agent" (2.x); both
        // names remain on the wire depending on CLI version.
        event.toolName == "Task" || event.toolName == "Agent"
    }

    private nonisolated static func openChild(
        _ record: inout AgentChatSessionRecord,
        id: String,
        label: String?,
        at date: Date
    ) {
        let safeID = boundedText(id, maxBytes: SidebarAgentChildLimits.maxIDBytes)
            ?? UUID().uuidString
        let safeLabel = boundedText(label, maxBytes: SidebarAgentChildLimits.maxLabelBytes)
        // A repeated PreToolUse for the same request (retries) must not fork
        // a duplicate child.
        if record.children.contains(where: { $0.id == safeID && $0.endedAt == nil }) { return }
        record.children.append(AgentChatChildRun(id: safeID, label: safeLabel, startedAt: date))
        prune(&record, now: date)
    }

    private nonisolated static func closeChild(
        _ record: inout AgentChatSessionRecord,
        id: String?,
        at date: Date
    ) {
        if let id, let index = record.children.firstIndex(where: { $0.id == id && $0.endedAt == nil }) {
            record.children[index].endedAt = date
            return
        }
        // No correlation id on the wire: close the OLDEST open child (FIFO -
        // parallel Task fan-outs finish roughly in start order more often
        // than not, and a mismatch only swaps two elapsed labels).
        if let index = record.children.firstIndex(where: { $0.endedAt == nil }) {
            record.children[index].endedAt = date
        }
    }

    private nonisolated static func prune(_ record: inout AgentChatSessionRecord, now: Date) {
        record.children.removeAll { child in
            guard let endedAt = child.endedAt else { return false }
            return now.timeIntervalSince(endedAt) > AgentChatChildRun.settledRetention
        }
        if record.children.count > AgentChatChildRun.capacity {
            // Drop settled children first. If an event stream reports more
            // running children than the bound, drop the oldest running rows
            // too; retaining an unbounded list is a denial-of-service risk.
            while record.children.count > AgentChatChildRun.capacity {
                if let index = record.children.firstIndex(where: { $0.endedAt != nil }) {
                    record.children.remove(at: index)
                } else {
                    record.children.removeFirst()
                }
            }
        }
    }

    /// The Task payload's human-readable label: `description`, falling back
    /// to `subagent_type`.
    private nonisolated static func taskLabel(from toolInputJSON: String?) -> String? {
        guard let toolInputJSON,
              toolInputJSON.utf8.count <= 64 * 1024,
              let data = toolInputJSON.data(using: .utf8),
              SidebarJSONGuard.isBoundedSyntax(data, maximumDepth: 64, maximumTokens: 100_000),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        guard SidebarJSONGuard.isBoundedObject(
            object,
            maximumBytes: 64 * 1024,
            maximumCollectionItems: 2_048
        ) else { return nil }
        let description = boundedText(
            object["description"] as? String,
            maxBytes: SidebarAgentChildLimits.maxLabelBytes
        )
        if let description { return description }
        return boundedText(
            object["subagent_type"] as? String,
            maxBytes: SidebarAgentChildLimits.maxLabelBytes
        )
    }

    private nonisolated static func boundedText(_ value: String?, maxBytes: Int) -> String? {
        guard let value else { return nil }
        let cleaned = String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        guard cleaned.utf8.count > maxBytes else { return cleaned }

        var result = ""
        var used = 0
        for scalar in cleaned.unicodeScalars {
            let width = String(scalar).utf8.count
            guard used + width <= maxBytes else { break }
            result.unicodeScalars.append(scalar)
            used += width
        }
        return result.isEmpty ? nil : result
    }
}

private enum SidebarAgentChildLimits {
    static let maxIDBytes = 128
    static let maxLabelBytes = 512
}
