public import CmuxSwiftRender
public import Foundation

/// Builds the interpreter data context for a custom sidebar from a
/// ``CustomSidebarContextSnapshot``.
///
/// This is the pure, value-typed projection that used to live inline in the
/// sidebar view (`customSidebarDataContext` / `customSidebarWorkspaceValue` /
/// `customSidebarSurfaceValues`). It owns the exact field set, default values,
/// and optional-field omission rules of the interpreter data keys documented
/// in `docs/custom-sidebars.md`; the app feeds it value snapshots projected
/// from live workspace state and renders the resulting `SwiftValue` tree. The
/// builder performs no I/O and reads no live objects, so its output is a pure
/// function of the snapshot plus the injected calendar.
public struct CustomSidebarDataContextBuilder {
    private let calendar: Calendar

    private static let maxCollectionItems = 2_048
    private static let maxStringBytes = 16 * 1024
    private static let maxObjectFields = 128
    private static let maxValueDepth = 64
    private static let maxIdentifierBytes = 128
    private static let maxAgentEntries = 64

    /// Creates a builder.
    ///
    /// - Parameter calendar: the calendar used to derive the `clock` object's
    ///   hour/minute/second/weekday components. Defaults to `Calendar.current`,
    ///   matching the original inline projection.
    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    /// Projects the snapshot into the top-level interpreter data dictionary.
    ///
    /// Mirrors the original `customSidebarDataContext(now:)` output exactly:
    /// `workspaces`, `workspaceCount`, `selectedTitle`, `selectedId`,
    /// `unreadTotal`, and `clock`.
    public func dataContext(for snapshot: CustomSidebarContextSnapshot) -> [String: SwiftValue] {
        let workspaces: [SwiftValue] = snapshot.workspaces
            .prefix(Self.maxCollectionItems)
            .map { boundedValue(workspaceValue($0), depth: 0) }
        let components = calendar.dateComponents(
            [.hour, .minute, .second, .weekday],
            from: snapshot.now
        )
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0
        let second = components.second ?? 0
        let epoch = safeEpoch(snapshot.now) ?? 0
        let clock: SwiftValue = .object([
            "time": .string(String(format: "%02d:%02d:%02d", hour, minute, second)),
            "hour": .int(hour),
            "minute": .int(minute),
            "second": .int(second),
            "weekday": .int(components.weekday ?? 0),
            "epoch": .int(epoch),
        ])
        return [
            "workspaces": .array(workspaces),
            "groups": .array(snapshot.groups.prefix(Self.maxCollectionItems).map { boundedValue(groupValue($0), depth: 0) }),
            "workspaceCount": .int(snapshot.workspaces.count),
            "selectedTitle": .string(boundedText(snapshot.selectedWorkspaceTitle)),
            "selectedId": .string(snapshot.selectedWorkspaceId?.uuidString ?? ""),
            "unreadTotal": .int(snapshot.totalUnreadCount),
            "clock": boundedValue(clock, depth: 0),
        ]
    }

    /// Projects one group's snapshot into the interpreter value tree.
    public func groupValue(_ group: CustomSidebarGroupSnapshot) -> SwiftValue {
        var fields: [String: SwiftValue] = [
            "id": .string(group.id.uuidString),
            "name": .string(boundedText(group.name)),
            "collapsed": .bool(group.isCollapsed),
            "pinned": .bool(group.isPinned),
            "anchorId": .string(group.anchorWorkspaceId.uuidString),
        ]
        if let color = group.customColor, !color.isEmpty {
            fields["color"] = .string(boundedText(color))
        }
        if let icon = group.iconSymbol, !icon.isEmpty {
            fields["icon"] = .string(boundedText(icon))
        }
        return .object(fields)
    }

    /// Projects one workspace's snapshot into the interpreter value tree.
    ///
    /// Optional fields are omitted when absent so interpreted `if let` /
    /// ternary truthiness behaves; always-present fields default sensibly.
    public func workspaceValue(_ workspace: CustomSidebarWorkspaceSnapshot) -> SwiftValue {
        var fields: [String: SwiftValue] = [
            "id": .string(workspace.id.uuidString),
            "title": .string(boundedText(workspace.title)),
            "selected": .bool(workspace.isSelected),
            "pinned": .bool(workspace.isPinned),
            "index": .int(workspace.index),
            "directory": .string(boundedText(workspace.directory)),
            "ports": .array(workspace.listeningPorts.prefix(Self.maxCollectionItems).map { .int($0) }),
            "portCount": .int(workspace.listeningPorts.count),
            "unread": .int(workspace.unreadCount),
            "tabs": .array(workspace.surfaces.prefix(Self.maxCollectionItems).map { boundedValue(surfaceValue($0), depth: 0) }),
            "tabCount": .int(workspace.surfaceCount),
        ]
        if let groupId = workspace.groupId {
            fields["group"] = .string(groupId.uuidString)
        }
        if let description = workspace.customDescription, !description.isEmpty {
            fields["description"] = .string(boundedText(description))
        }
        if let color = workspace.customColor, !color.isEmpty {
            fields["color"] = .string(boundedText(color))
        }
        if let branch = workspace.gitBranch {
            fields["branch"] = .string(boundedText(branch))
            fields["dirty"] = .bool(workspace.gitIsDirty)
        }
        if let firstPullRequest = workspace.pullRequestValues.first {
            fields["pr"] = boundedValue(firstPullRequest, depth: 0)
            fields["prs"] = .array(workspace.pullRequestValues.prefix(Self.maxCollectionItems).map { boundedValue($0, depth: 0) })
        }
        if let progress = workspace.progress,
           progress.value.isFinite,
           abs(progress.value) <= 1_000_000 {
            var progressFields: [String: SwiftValue] = ["value": .double(progress.value)]
            if let label = progress.label {
                progressFields["label"] = .string(boundedText(label))
            }
            fields["progress"] = .object(progressFields)
        }
        if let message = workspace.latestConversationMessage, !message.isEmpty {
            fields["latestMessage"] = .string(boundedText(message))
        }
        if let prompt = workspace.latestSubmittedMessage, !prompt.isEmpty {
            fields["latestPrompt"] = .string(boundedText(prompt))
        }
        if let at = workspace.latestSubmittedAt {
            if let epoch = safeEpoch(at) { fields["latestAt"] = .int(epoch) }
        }
        if let remote = workspace.remote {
            fields["remote"] = .object([
                "target": .string(boundedText(remote.target)),
                "state": .string(boundedText(remote.stateRawValue)),
                "connected": .bool(remote.isConnected),
            ])
        }
        if !workspace.agents.isEmpty {
            let agents = workspace.agents
                .filter { validIdentifier($0.sessionId) }
                .prefix(Self.maxAgentEntries)
                .map { boundedValue(agentValue($0), depth: 0) }
            if !agents.isEmpty { fields["agents"] = .array(agents) }
        }
        return .object(fields)
    }

    /// Projects one agent-session snapshot into the interpreter value tree
    /// (`workspaces[i].agents[j]`). Optional fields are omitted when absent.
    public func agentValue(_ agent: CustomSidebarAgentSnapshot) -> SwiftValue {
        var fields: [String: SwiftValue] = [
            "id": .string(boundedIdentifier(agent.sessionId)),
            "kind": .string(boundedIdentifier(agent.kind)),
            "name": .string(boundedText(agent.name)),
            "status": .string(boundedIdentifier(agent.status)),
            "lastActivityAt": .int(safeEpoch(agent.lastActivityAt) ?? 0),
        ]
        if let since = agent.stateSince {
            fields["sinceEpoch"] = .int(safeEpoch(since) ?? 0)
        }
        if let title = agent.title, !title.isEmpty {
            fields["title"] = .string(boundedText(title))
        }
        if let panelId = agent.panelId {
            fields["panelId"] = .string(panelId.uuidString)
        }
        if let surfaceId = agent.surfaceId {
            // The id surface.* verbs accept (surface.focus etc.); panelId
            // above is the panel behind the tab.
            fields["surfaceId"] = .string(surfaceId.uuidString)
        }
        if let directory = agent.workingDirectory, !directory.isEmpty {
            fields["directory"] = .string(boundedText(directory))
        }
        if !agent.children.isEmpty {
            let children = agent.children
                .filter { validIdentifier($0.id) }
                .prefix(Self.maxAgentEntries)
                .map { boundedValue(agentChildValue($0), depth: 0) }
            if !children.isEmpty { fields["children"] = .array(children) }
        }
        // Transcript paths and process ids stay in the native session record.
        // They are not needed to render a panel and would disclose local
        // filesystem/process details to authored JavaScript. A future drag
        // capability can issue a narrowly scoped transfer token instead of
        // exposing either value in the general data context.
        return .object(fields)
    }

    /// Projects one child agent run into the interpreter value tree
    /// (`agents[j].children[k]`). Optional fields are omitted when absent.
    public func agentChildValue(_ child: CustomSidebarAgentChildSnapshot) -> SwiftValue {
        var fields: [String: SwiftValue] = [
            "id": .string(boundedIdentifier(child.id)),
            "running": .bool(child.isRunning),
            "startedEpoch": .int(safeEpoch(child.startedAt) ?? 0),
        ]
        if let label = child.label, !label.isEmpty {
            fields["label"] = .string(boundedText(label))
        }
        if let endedAt = child.endedAt {
            fields["endedEpoch"] = .int(safeEpoch(endedAt) ?? 0)
        }
        return .object(fields)
    }

    /// Projects one surface snapshot into the interpreter value tree, enriched
    /// with per-surface directory, pin, git, and ports where available.
    public func surfaceValue(_ surface: CustomSidebarSurfaceSnapshot) -> SwiftValue {
        var surfaceFields: [String: SwiftValue] = [
            "id": .string(surface.panelId.uuidString),
            "title": .string(boundedText(surface.title)),
            "focused": .bool(surface.isFocused),
            "pinned": .bool(surface.isPinned),
        ]
        if let surfaceId = surface.surfaceId {
            // The id surface.* verbs accept (surface.focus etc.); `id` above
            // is the panel behind the tab.
            surfaceFields["surfaceId"] = .string(surfaceId.uuidString)
        }
        if let directory = surface.directory, !directory.isEmpty {
            surfaceFields["directory"] = .string(boundedText(directory))
        }
        if let branch = surface.gitBranch {
            surfaceFields["branch"] = .string(boundedText(branch))
            surfaceFields["dirty"] = .bool(surface.gitIsDirty)
        }
        if !surface.listeningPorts.isEmpty {
            surfaceFields["ports"] = .array(surface.listeningPorts.prefix(Self.maxCollectionItems).map { .int($0) })
        }
        return .object(surfaceFields)
    }

    /// Copies host data into a bounded value tree before it crosses into an
    /// interpreter. Hook text, branch names, and extension metadata are all
    /// external input; truncating here prevents one hostile record from
    /// inflating every sidebar update and keeps the JSON bridge fail-closed.
    private func boundedValue(_ value: SwiftValue, depth: Int) -> SwiftValue {
        guard depth <= Self.maxValueDepth else { return .string("…") }
        switch value {
        case let .string(text):
            return .string(boundedText(text))
        case let .array(values):
            return .array(values.prefix(Self.maxCollectionItems).map { boundedValue($0, depth: depth + 1) })
        case let .object(fields):
            let limited = fields.keys.sorted().prefix(Self.maxObjectFields)
            var result: [String: SwiftValue] = [:]
            result.reserveCapacity(limited.count)
            for key in limited where key.utf8.count <= Self.maxIdentifierBytes
                && !key.isEmpty
                && !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
                if let child = fields[key] {
                    result[key] = boundedValue(child, depth: depth + 1)
                }
            }
            return .object(result)
        case let .double(number):
            return number.isFinite && abs(number) <= 1_000_000 ? value : .string("…")
        default:
            return value
        }
    }

    private func boundedText(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(Self.maxStringBytes)
        var used = 0
        for scalar in value.unicodeScalars {
            let fragment: String
            if CharacterSet.controlCharacters.contains(scalar), scalar != "\n", scalar != "\r", scalar != "\t" {
                fragment = "�"
            } else {
                fragment = String(scalar)
            }
            let width = fragment.utf8.count
            guard used + width <= Self.maxStringBytes else { break }
            // Append the sanitized fragment, not the original scalar. The
            // latter would preserve terminal/control characters even though
            // the byte budget was calculated for the replacement glyph.
            result.append(contentsOf: fragment)
            used += width
        }
        return result
    }

    private func boundedIdentifier(_ value: String) -> String {
        let text = boundedText(value)
        guard !text.isEmpty,
              text.utf8.count <= Self.maxIdentifierBytes,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return "unknown"
        }
        return text
    }

    private func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= Self.maxIdentifierBytes
            && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    private func safeEpoch(_ date: Date) -> Int? {
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite else { return nil }

        // `Double(Int.max)` rounds up to 2^63 on 64-bit platforms. A plain
        // `Int(seconds)` at that boundary therefore traps even though the
        // comparison appears to have passed. Truncate first, then require a
        // strict upper bound that is representable as an Int.
        let truncated = seconds.rounded(.towardZero)
        guard truncated >= Double(Int.min), truncated < Double(Int.max) else {
            return nil
        }
        return Int(truncated)
    }
}
