import Foundation

/// A runtime value produced while interpreting a Swift expression.
///
/// Phase 1 covers the value kinds needed for view logic: numbers, strings,
/// booleans, and ranges (the result of `0..<n`). The interpreter resolves
/// identifiers, string interpolations, loop sequences, and `if` conditions
/// to these.
public enum SwiftValue: Codable, Sendable, Equatable {
    case int(Int)
    case double(Double)
    case string(String)
    case bool(Bool)
    case range(lower: Int, upper: Int, inclusive: Bool)
    indirect case array([SwiftValue])
    indirect case object([String: SwiftValue])

    /// How the value renders inside a string interpolation.
    public var displayString: String {
        var budget = RenderSecurityLimits.maxDisplayStringBytes
        return displayString(depth: 0, budget: &budget)
    }

    /// Validates a host-provided value tree without recursive calls. Codable
    /// values can be constructed by a worker or another package without
    /// passing through the sidebar data-context builder, so the interpreter
    /// checks the complete tree at its boundary.
    public func isWithinSecurityLimits() -> Bool {
        var stack: [(value: SwiftValue, depth: Int)] = [(self, 0)]
        var nodes = 0
        var stringBytes = 0

        while let entry = stack.popLast() {
            nodes += 1
            guard nodes <= RenderSecurityLimits.maxValueNodes,
                  entry.depth <= RenderSecurityLimits.maxValueDepth else {
                return false
            }

            switch entry.value {
            case .int, .bool:
                continue
            case let .double(value):
                guard value.isFinite, abs(value) <= 1_000_000 else { return false }
            case let .string(value):
                let count = value.utf8.count
                guard count <= RenderSecurityLimits.maxValueStringBytes,
                      count <= RenderSecurityLimits.maxValueStringTotalBytes,
                      stringBytes <= RenderSecurityLimits.maxValueStringTotalBytes - count else {
                    return false
                }
                stringBytes += count
            case .range:
                continue
            case let .array(values):
                guard values.count <= RenderSecurityLimits.maxCollectionItems else { return false }
                for value in values.reversed() {
                    stack.append((value, entry.depth + 1))
                }
            case let .object(fields):
                guard fields.count <= RenderSecurityLimits.maxValueObjectFields else { return false }
                for (key, value) in fields {
                    guard !key.isEmpty,
                          key.utf8.count <= RenderSecurityLimits.maxIdentifierBytes,
                          !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                        return false
                    }
                    stack.append((value, entry.depth + 1))
                }
            }
        }
        return true
    }

    private func displayString(depth: Int, budget: inout Int) -> String {
        guard depth <= 64 else { return "…" }
        switch self {
        case let .int(value): return Self.boundedFragment(String(value), budget: &budget)
        case let .double(value): return Self.boundedFragment(String(value), budget: &budget)
        case let .string(value): return Self.boundedFragment(value, budget: &budget)
        case let .bool(value): return Self.boundedFragment(String(value), budget: &budget)
        case let .range(lower, upper, inclusive):
            return Self.boundedFragment("\(lower)\(inclusive ? "..." : "..<")\(upper)", budget: &budget)
        case let .array(values):
            guard values.count <= RenderSecurityLimits.maxCollectionItems else { return "[…]" }
            var result = "["
            for (index, value) in values.enumerated() {
                if index > 0 { Self.appendFragment(", ", to: &result, budget: &budget) }
                result.append(contentsOf: value.displayString(depth: depth + 1, budget: &budget))
                if budget == 0 { break }
            }
            Self.appendFragment("]", to: &result, budget: &budget)
            return result
        case let .object(fields):
            guard fields.count <= RenderSecurityLimits.maxCollectionItems else { return "{…}" }
            var result = "{"
            for (index, key) in fields.keys.sorted().enumerated() {
                if index > 0 { Self.appendFragment(", ", to: &result, budget: &budget) }
                Self.appendFragment(key, to: &result, budget: &budget)
                Self.appendFragment(": ", to: &result, budget: &budget)
                if let value = fields[key] {
                    result.append(contentsOf: value.displayString(depth: depth + 1, budget: &budget))
                }
                if budget == 0 { break }
            }
            Self.appendFragment("}", to: &result, budget: &budget)
            return result
        }
    }

    private static func boundedFragment(_ value: String, budget: inout Int) -> String {
        guard budget > 0 else { return "" }
        guard value.utf8.count > budget else {
            budget -= value.utf8.count
            return value
        }
        var result = ""
        var used = 0
        for scalar in value.unicodeScalars {
            let width = String(scalar).utf8.count
            guard used + width <= budget else { break }
            result.unicodeScalars.append(scalar)
            used += width
        }
        budget = 0
        return result
    }

    private static func appendFragment(_ fragment: String, to result: inout String, budget: inout Int) {
        result.append(contentsOf: boundedFragment(fragment, budget: &budget))
    }

    /// Resolves a member (`value.name`): object fields, plus `count`/`isEmpty`
    /// on arrays and strings. Returns `nil` for unsupported members.
    public func member(_ name: String) -> SwiftValue? {
        switch self {
        case let .object(fields):
            return fields[name]
        case let .array(values):
            if name == "count" { return .int(values.count) }
            if name == "isEmpty" { return .bool(values.isEmpty) }
            if name == "indices", values.count <= RenderSecurityLimits.maxCollectionItems {
                return .array(values.indices.map { .int($0) })
            }
            if name == "first" { return values.first }
            if name == "last" { return values.last }
            return nil
        case let .string(value):
            if name == "count" { return .int(value.count) }
            if name == "isEmpty" { return .bool(value.isEmpty) }
            if name == "capitalized" { return boundedTransformedString(value.capitalized) }
            if name == "uppercased" { return boundedTransformedString(value.uppercased()) }
            if name == "lowercased" { return boundedTransformedString(value.lowercased()) }
            return nil
        default:
            return nil
        }
    }

    /// The boolean reading of the value for `if` conditions.
    public var isTruthy: Bool {
        if case let .bool(value) = self { return value }
        return false
    }

    /// Unicode case transforms can expand a string. Bound the transformed
    /// value before it enters another expression or a rendered node.
    private func boundedTransformedString(_ value: String) -> SwiftValue {
        .string(RenderSecurityLimits.boundedString(value, maxBytes: RenderSecurityLimits.maxValueStringBytes))
    }

    /// The values a `for` loop or `ForEach` iterates, for ranges and arrays.
    public var iterationValues: [SwiftValue]? {
        switch self {
        case let .range(lower, upper, inclusive):
            // Overflow-safe end + a materialization cap so a pathological range
            // (e.g. `0...Int.max`) can't overflow or exhaust memory.
            let (end, addOverflow) = inclusive ? upper.addingReportingOverflow(1) : (upper, false)
            guard !addOverflow, end >= lower else { return [] }
            let (count, subOverflow) = end.subtractingReportingOverflow(lower)
            guard !subOverflow, count <= RenderSecurityLimits.maxCollectionItems else { return nil }
            return (lower..<end).map(SwiftValue.int)
        case let .array(values):
            return values.count <= RenderSecurityLimits.maxCollectionItems ? values : nil
        default:
            return nil
        }
    }
}
