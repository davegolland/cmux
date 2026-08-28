import Foundation

extension RenderNode {
    private struct StringBudget {
        var total = 0

        mutating func add(_ value: String?) -> Bool {
            guard let value else { return true }
            let bytes = value.utf8.count
            guard bytes <= RenderSecurityLimits.maxRenderStringBytesTotal,
                  total <= RenderSecurityLimits.maxRenderStringBytesTotal - bytes else {
                return false
            }
            total += bytes
            return true
        }

        mutating func add(contentsOf values: [String]) -> Bool {
            for value in values where !add(value) {
                return false
            }
            return true
        }
    }

    /// Validates the complete render IR before a host turns it into SwiftUI.
    ///
    /// `RenderNode` is Codable and crosses a process boundary in the
    /// interpreter service. Do not rely on the producer's interpreter budget:
    /// a malformed worker, a future producer, or a package caller can provide
    /// a tree directly. The walk is iterative so hostile nesting cannot use
    /// the host's native stack, and every retained string, collection, number,
    /// action, and modifier is bounded.
    public func isWithinSecurityLimits() -> Bool {
        var stack: [(node: RenderNode, depth: Int)] = [(self, 0)]
        var nodeCount = 0
        var edgeCount = 0
        var stringBudget = StringBudget()

        while let entry = stack.popLast() {
            nodeCount += 1
            guard nodeCount <= RenderSecurityLimits.maxRenderNodes,
                  entry.depth <= RenderSecurityLimits.maxValueDepth,
                  validText(entry.node.text),
                  validText(entry.node.systemName),
                  validNumber(entry.node.spacing),
                  validNumber(entry.node.cornerRadius),
                  validNumber(entry.node.value),
                  entry.node.children.count <= RenderSecurityLimits.maxRenderChildren,
                  entry.node.modifiers.count <= RenderSecurityLimits.maxModifiersPerNode,
                  entry.node.colors.count <= RenderSecurityLimits.maxGradientStops,
                  entry.node.points.count <= RenderSecurityLimits.maxGradientStops,
                  entry.node.colors.allSatisfy(validToken),
                  entry.node.points.allSatisfy(validToken),
                  validAction(entry.node.action),
                  validReorder(entry.node.reorder),
                  consumeStrings(
                      in: entry.node,
                      budget: &stringBudget
                  ) else {
                return false
            }

            edgeCount += entry.node.children.count
            guard edgeCount <= RenderSecurityLimits.maxRenderEdges else { return false }

            for modifier in entry.node.modifiers {
                guard validModifier(modifier),
                      modifier.children.count <= RenderSecurityLimits.maxRenderChildren else {
                    return false
                }
                edgeCount += modifier.children.count
                guard edgeCount <= RenderSecurityLimits.maxRenderEdges else { return false }
                for child in modifier.children.reversed() {
                    stack.append((child, entry.depth + 1))
                }
            }
            for child in entry.node.children.reversed() {
                stack.append((child, entry.depth + 1))
            }
        }
        return true
    }

    /// Counts every string that will be retained by the decoded IR. This is
    /// deliberately separate from validation so the aggregate budget also
    /// covers modifier arguments, reorder ids, and action payloads.
    private func consumeStrings(in node: RenderNode, budget: inout StringBudget) -> Bool {
        guard budget.add(node.kind.rawValue),
              budget.add(node.text),
              budget.add(node.systemName),
              budget.add(contentsOf: node.colors),
              budget.add(contentsOf: node.points) else {
            return false
        }
        for modifier in node.modifiers {
            guard budget.add(modifier.name) else { return false }
            for argument in modifier.args {
                guard budget.add(argument.label), budget.add(argument.value) else { return false }
            }
        }
        if let action = node.action {
            for command in action.commands {
                switch command {
                case let .cmux(method, params):
                    guard budget.add(method) else { return false }
                    for (key, value) in params {
                        guard budget.add(key), budget.add(value) else { return false }
                    }
                case let .log(message), let .openURL(message):
                    guard budget.add(message) else { return false }
                }
            }
        }
        if let reorder = node.reorder {
            guard budget.add(reorder.method),
                  budget.add(reorder.idParam),
                  budget.add(reorder.indexParam),
                  budget.add(contentsOf: reorder.itemIds) else {
                return false
            }
        }
        return true
    }

    private func validModifier(_ modifier: RenderModifier) -> Bool {
        guard validIdentifier(modifier.name),
              modifier.args.count <= RenderSecurityLimits.maxModifierArguments else {
            return false
        }
        return modifier.args.allSatisfy { arg in
            (arg.label == nil || validToken(arg.label!)) && validToken(arg.value)
        }
    }

    private func validReorder(_ reorder: ReorderSpec?) -> Bool {
        guard let reorder else { return true }
        return validIdentifier(reorder.method)
            && validIdentifier(reorder.idParam)
            && validIdentifier(reorder.indexParam)
            && reorder.itemIds.count <= RenderSecurityLimits.maxRenderChildren
            && reorder.itemIds.allSatisfy(validIdentifier)
    }

    private func validAction(_ action: ButtonAction?) -> Bool {
        guard let action else { return true }
        guard action.commands.count <= RenderSecurityLimits.maxActionCommands else { return false }
        return action.commands.allSatisfy { command in
            switch command {
            case let .cmux(method, params):
                guard validIdentifier(method), params.count <= RenderSecurityLimits.maxActionParameters else {
                    return false
                }
                return params.allSatisfy { key, value in
                    validIdentifier(key) && validActionValue(value)
                }
            case let .log(message):
                return message.utf8.count <= RenderSecurityLimits.maxActionValueBytes && noNUL(message)
            case let .openURL(url):
                return url.utf8.count <= 2 * 1024 && noNUL(url)
            }
        }
    }

    private func validActionValue(_ value: String) -> Bool {
        value.utf8.count <= RenderSecurityLimits.maxActionValueBytes && noNUL(value)
    }

    private func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= RenderSecurityLimits.maxIdentifierBytes && noControls(value)
    }

    private func validToken(_ value: String?) -> Bool {
        guard let value else { return true }
        // An empty token is valid for no-argument modifiers and for optional
        // gradient points. Call sites that require a name use
        // `validIdentifier`, which still rejects empty strings.
        return value.utf8.count <= RenderSecurityLimits.maxTokenBytes && noUnsafeTokenControls(value)
    }

    private func validText(_ value: String?) -> Bool {
        guard let value else { return true }
        return value.utf8.count <= RenderSecurityLimits.maxValueStringBytes && noNUL(value)
    }

    private func validNumber(_ value: Double?) -> Bool {
        guard let value else { return true }
        return value.isFinite && abs(value) <= 1_000_000
    }

    private func noNUL(_ value: String) -> Bool {
        !value.unicodeScalars.contains { $0.value == 0 }
    }

    private func noControls(_ value: String) -> Bool {
        !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private func noUnsafeTokenControls(_ value: String) -> Bool {
        !value.unicodeScalars.contains { scalar in
            CharacterSet.controlCharacters.contains(scalar)
                && scalar.value != 0x09
                && scalar.value != 0x0A
                && scalar.value != 0x0D
        }
    }
}
