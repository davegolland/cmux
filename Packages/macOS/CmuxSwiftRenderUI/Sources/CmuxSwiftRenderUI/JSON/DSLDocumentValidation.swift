import CmuxSwiftRender
import Foundation

/// Errors raised after JSON decoding when a declarative sidebar exceeds the
/// bounds that the SwiftUI renderer can safely retain.
enum DSLDocumentValidationError: Error {
    case resourceLimit
    case invalidValue
}

extension DSLDocument {
    /// Decodes a JSON document only after a shallow byte scan has rejected
    /// pathological nesting. This keeps `JSONDecoder` from recursively
    /// walking attacker-controlled depth before the typed validation runs.
    static func decodeValidated(from data: Data) throws -> DSLDocument {
        guard data.count <= SidebarSecurityLimits.maxSourceBytes else {
            throw DSLDocumentValidationError.resourceLimit
        }
        guard SidebarJSONGuard.isBoundedSyntax(
            data,
            maximumDepth: SidebarSecurityLimits.maxDSLDepth,
            maximumTokens: 100_000
        ) else {
            throw DSLDocumentValidationError.resourceLimit
        }
        let document = try JSONDecoder().decode(DSLDocument.self, from: data)
        try document.validate()
        return document
    }

    /// Validates the typed tree with an explicit worklist. The renderer uses
    /// recursive SwiftUI view composition, so depth, width, strings, numeric
    /// values, and actions are all bounded before the tree reaches it.
    func validate() throws {
        guard version == 1 else { throw DSLDocumentValidationError.invalidValue }

        var stack: [(node: DSLNode, depth: Int)] = [(root, 1)]
        var nodeCount = 0
        var edgeCount = 0
        var stringBytes = 0

        while let entry = stack.popLast() {
            nodeCount += 1
            guard nodeCount <= SidebarSecurityLimits.maxSceneNodes,
                  entry.depth <= SidebarSecurityLimits.maxDSLDepth else {
                throw DSLDocumentValidationError.resourceLimit
            }

            let node = entry.node
            for value in [node.text, node.title, node.font, node.weight, node.color,
                          node.background, node.systemName, node.alignment] {
                try validateString(value, bytes: &stringBytes)
            }
            try validateNumber(node.spacing, nonnegative: true)
            try validateNumber(node.padding, nonnegative: true)
            try validateNumber(node.size, nonnegative: true)

            if let action = node.action {
                try validateAction(action, bytes: &stringBytes)
            }

            let children = node.children ?? []
            guard children.count <= SidebarSecurityLimits.maxSceneChildren,
                  edgeCount <= SidebarSecurityLimits.maxSceneEdges - children.count else {
                throw DSLDocumentValidationError.resourceLimit
            }
            edgeCount += children.count
            for child in children.reversed() {
                stack.append((child, entry.depth + 1))
            }
        }
    }

    private func validateString(_ value: String?, bytes: inout Int) throws {
        guard let value else { return }
        let count = value.utf8.count
        guard count <= SidebarSecurityLimits.maxSceneStringBytes,
              bytes <= SidebarSecurityLimits.maxDataJSONBytes - count,
              value.unicodeScalars.allSatisfy({ scalar in
                  !CharacterSet.controlCharacters.contains(scalar)
                      || scalar == "\n" || scalar == "\r" || scalar == "\t"
              }) else {
            throw DSLDocumentValidationError.resourceLimit
        }
        bytes += count
    }

    private func validateNumber(_ value: Double?, nonnegative: Bool) throws {
        guard let value else { return }
        guard value.isFinite,
              abs(value) <= SidebarSecurityLimits.maxSceneNumberMagnitude,
              !nonnegative || value >= 0 else {
            throw DSLDocumentValidationError.invalidValue
        }
    }

    private func validateAction(_ action: DSLAction, bytes: inout Int) throws {
        try validateString(action.type, bytes: &bytes)
        try validateString(action.message, bytes: &bytes)
        guard SidebarActionPolicy.default.validated(action.buttonAction) != nil else {
            throw DSLDocumentValidationError.invalidValue
        }
    }
}
