import Foundation
import Observation

/// One property value on a scene node. Props arrive from the JS runtime as
/// scalars only; reactive props are resolved to scalars JS-side before they
/// cross the bridge.
public enum ScenePropValue: Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)

    var stringValue: String? {
        if case let .string(v) = self { return v }
        return nil
    }

    var doubleValue: Double? {
        switch self {
        case let .number(v):
            guard v.isFinite,
                  abs(v) <= SidebarSecurityLimits.maxSceneNumberMagnitude else { return nil }
            return v
        case let .string(s):
            guard let value = Double(s), value.isFinite,
                  abs(value) <= SidebarSecurityLimits.maxSceneNumberMagnitude else { return nil }
            return value
        case .bool: return nil
        }
    }

    var boolValue: Bool? {
        if case let .bool(v) = self { return v }
        return nil
    }

    init?(json: Any) {
        // `as? Bool` is NOT a safe discriminator: NSNumber(0)/NSNumber(1)
        // bridge to Bool successfully, which silently turned numeric props
        // like lineLimit(1) and opacity(1) into booleans. JSONSerialization
        // produces CFBoolean for JSON true/false and CFNumber for numbers,
        // so the type id is the reliable test.
        if let n = json as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else {
                let value = n.doubleValue
                guard value.isFinite,
                      abs(value) <= SidebarSecurityLimits.maxSceneNumberMagnitude else { return nil }
                self = .number(value)
            }
        } else if let s = json as? String {
            guard s.utf8.count <= SidebarSecurityLimits.maxSceneStringBytes else { return nil }
            self = .string(Self.sanitizedString(s))
        } else {
            return nil
        }
    }

    private static func sanitizedString(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.utf8.count)
        for scalar in value.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar),
               scalar != "\n", scalar != "\r", scalar != "\t" {
                result.append("�")
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}

/// One retained scene node. `@Observable` so a SwiftUI view that reads this
/// node's `props`/`children` re-renders when — and only when — this node
/// changes. That is the fine-grained update path: a JS effect that changes one
/// text prop touches one node, which invalidates one view.
@MainActor
@Observable
public final class SceneNode: Identifiable {
    public let id: String
    public let type: String
    public internal(set) var props: [String: ScenePropValue] = [:]
    public internal(set) var children: [String] = []

    init(id: String, type: String) {
        self.id = id
        self.type = type
    }

    func string(_ key: String) -> String? { props[key]?.stringValue }
    func double(_ key: String) -> Double? { props[key]?.doubleValue }
    func bool(_ key: String) -> Bool { props[key]?.boolValue ?? false }
}

/// The retained scene graph the JS runtime mutates through ops. Nodes are
/// looked up by id; the node dictionary itself is intentionally not observed
/// (`@ObservationIgnored`) so structural edits invalidate only the parents
/// whose `children` arrays changed, not every mounted view.
@MainActor
@Observable
public final class SceneStore {
    public private(set) var rootId: String?
    @ObservationIgnored private var nodes: [String: SceneNode] = [:]

    public init() {}

    /// Removes the current scene before a source revision is evaluated.
    func reset() {
        rootId = nil
        // Do not retain attacker-sized dictionaries and backing buffers across
        // source revisions. The graph is bounded, but a sidebar can be
        // reloaded repeatedly during development.
        nodes.removeAll(keepingCapacity: false)
    }

    public func node(_ id: String) -> SceneNode? {
        nodes[id]
    }

    /// Applies one JSON-decoded op batch from the runtime, in order.
    @discardableResult
    func apply(opsJSON: String) -> Bool {
        guard opsJSON.utf8.count <= SidebarSecurityLimits.maxSceneBatchJSONBytes else { return false }
        guard let data = opsJSON.data(using: .utf8),
              SidebarJSONGuard.isBoundedSyntax(data),
              let raw = try? JSONSerialization.jsonObject(with: data),
              SidebarJSONGuard.isBoundedObject(
                  raw,
                  maximumBytes: SidebarSecurityLimits.maxSceneBatchJSONBytes,
                  maximumCollectionItems: SidebarSecurityLimits.maxSceneOperationsPerBatch,
                  maximumNumberMagnitude: SidebarSecurityLimits.maxSceneNumberMagnitude
              ),
              let ops = raw as? [[String: Any]],
              ops.count <= SidebarSecurityLimits.maxSceneOperationsPerBatch else { return false }

        // Apply as a transaction. A malformed batch must not leave a partial
        // graph behind: a later render could otherwise observe a node whose
        // parent or properties came from a different revision. References are
        // retained so rollback restores existing SceneNode identities too.
        let originalNodes = nodes
        let originalRoot = rootId
        let originalState = nodes.mapValues { ($0.props, $0.children) }
        for op in ops {
            guard apply(op) else {
                restore(nodes: originalNodes, rootId: originalRoot, state: originalState)
                return false
            }
        }
        guard validateGraph() else {
            restore(nodes: originalNodes, rootId: originalRoot, state: originalState)
            return false
        }
        return true
    }

    private func restore(
        nodes originalNodes: [String: SceneNode],
        rootId originalRoot: String?,
        state originalState: [String: ([String: ScenePropValue], [String])]
    ) {
        nodes = originalNodes
        rootId = originalRoot
        for (id, state) in originalState {
            guard let node = originalNodes[id] else { continue }
            node.props = state.0
            node.children = state.1
        }
    }

    /// Verifies the retained graph before it reaches recursive SwiftUI view
    /// traversal. Authored JavaScript can forge a child id or a cycle even
    /// when each individual operation has valid JSON types.
    private func validateGraph() -> Bool {
        guard rootId == nil || (rootId.flatMap { nodes[$0] } != nil) else { return false }

        var edgeCount = 0
        var propertyCount = 0
        var retainedStringBytes = 0
        for node in nodes.values {
            guard node.children.count <= SidebarSecurityLimits.maxSceneChildren else { return false }
            propertyCount += node.props.count
            guard propertyCount <= SidebarSecurityLimits.maxScenePropertyCountTotal else { return false }
            retainedStringBytes += node.id.utf8.count + node.type.utf8.count
            guard retainedStringBytes <= SidebarSecurityLimits.maxSceneStringBytesTotal else { return false }
            for (key, value) in node.props {
                retainedStringBytes += key.utf8.count
                if case let .string(text) = value {
                    retainedStringBytes += text.utf8.count
                }
                guard retainedStringBytes <= SidebarSecurityLimits.maxSceneStringBytesTotal else { return false }
            }
            var seen = Set<String>()
            for child in node.children {
                guard nodes[child] != nil, seen.insert(child).inserted else { return false }
                edgeCount += 1
                guard edgeCount <= SidebarSecurityLimits.maxSceneEdges else { return false }
            }
        }

        // Iterative three-colour DFS avoids using the native stack for an
        // authored graph. A gray node is on the current path, so reaching it
        // proves a cycle.
        var colors: [String: UInt8] = [:]
        for start in nodes.keys where colors[start] == nil {
            colors[start] = 1
            var stack: [(id: String, nextChild: Int, depth: Int)] = [(start, 0, 1)]
            while let last = stack.last {
                guard last.depth <= SidebarSecurityLimits.maxDSLDepth else { return false }
                guard let node = nodes[last.id] else { return false }
                if last.nextChild >= node.children.count {
                    colors[last.id] = 2
                    stack.removeLast()
                    continue
                }

                let childID = node.children[last.nextChild]
                stack[stack.count - 1].nextChild += 1
                switch colors[childID] {
                case 1:
                    return false
                case 2:
                    continue
                default:
                    colors[childID] = 1
                    stack.append((childID, 0, last.depth + 1))
                }
            }
        }
        return true
    }

    private func apply(_ op: [String: Any]) -> Bool {
        guard let kind = op["op"] as? String,
              let id = op["id"] as? String,
              validIdentifier(kind),
              validIdentifier(id) else { return false }
        switch kind {
        case "create":
            guard let type = op["type"] as? String,
                  validIdentifier(type),
                  nodes[id] == nil,
                  nodes.count < SidebarSecurityLimits.maxSceneNodes else { return false }
            nodes[id] = SceneNode(id: id, type: type)
        case "update":
            guard let node = nodes[id],
                  let key = op["key"] as? String,
                  validIdentifier(key) else { return false }
            let value: ScenePropValue?
            // `null` is the wire representation for removing a property.
            // Treat Foundation's `NSNull` as the absent optional instead of
            // rejecting an otherwise bounded update batch.
            if let rawValue = op["value"], !(rawValue is NSNull) {
                guard let parsed = ScenePropValue(json: rawValue) else { return false }
                value = parsed
            } else {
                value = nil
            }
            if value != nil,
               node.props[key] == nil,
               node.props.count >= SidebarSecurityLimits.maxSceneProperties {
                return false
            }
            if node.props[key] != value {
                if let value {
                    node.props[key] = value
                } else {
                    node.props.removeValue(forKey: key)
                }
            }
        case "children":
            guard let node = nodes[id],
                  let children = op["children"] as? [String],
                  children.count <= SidebarSecurityLimits.maxSceneChildren,
                  children.allSatisfy(validIdentifier) else { return false }
            if node.children != children {
                node.children = children
            }
        case "append":
            guard let node = nodes[id],
                  let child = op["child"] as? String,
                  validIdentifier(child),
                  node.children.count < SidebarSecurityLimits.maxSceneChildren else { return false }
            if !node.children.contains(child) {
                node.children.append(child)
            }
        case "remove":
            guard nodes.removeValue(forKey: id) != nil else { return true }
            for node in nodes.values {
                node.children.removeAll { $0 == id }
            }
            if rootId == id { rootId = nil }
        case "root":
            guard nodes[id] != nil else { return false }
            rootId = id
        default:
            return false
        }
        return true
    }

    private func validIdentifier(_ value: String) -> Bool {
        value.utf8.count <= SidebarSecurityLimits.maxIdentifierBytes
            && !value.isEmpty
            && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
}
