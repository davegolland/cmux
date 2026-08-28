import Foundation
import SwiftSyntax

/// Evaluates a (operator-folded) Swift expression to a ``SwiftValue``.
///
/// Supports literals, identifier lookup against an ``EvalEnvironment``, string
/// interpolation, unary minus/not, and binary arithmetic, comparison,
/// logical, and range operators. Expressions it does not understand return
/// `nil` so the caller can skip them.
public struct ExpressionEvaluator: Sendable {
    public init() {}

    public func eval(_ expr: ExprSyntax, _ env: EvalEnvironment) -> SwiftValue? {
        env.budget.enter()
        defer { env.budget.leave() }
        guard env.budget.consume(), !env.budget.exceeded else { return nil }
        if let literal = expr.as(IntegerLiteralExprSyntax.self) {
            return Int(literal.literal.text.replacingOccurrences(of: "_", with: "")).map(SwiftValue.int)
        }
        if let literal = expr.as(FloatLiteralExprSyntax.self) {
            guard let value = Double(literal.literal.text.replacingOccurrences(of: "_", with: "")), value.isFinite else {
                return nil
            }
            return .double(value)
        }
        if let literal = expr.as(BooleanLiteralExprSyntax.self) {
            return .bool(literal.literal.text == "true")
        }
        if let literal = expr.as(StringLiteralExprSyntax.self) {
            return .string(evalString(literal, env))
        }
        if let ref = expr.as(DeclReferenceExprSyntax.self) {
            return env.lookup(ref.baseName.text)
        }
        if let member = expr.as(MemberAccessExprSyntax.self), let base = member.base {
            return eval(base, env)?.member(member.declName.baseName.text)
        }
        if let subscriptCall = expr.as(SubscriptCallExprSyntax.self),
           let indexExpr = subscriptCall.arguments.first?.expression {
            guard let base = eval(subscriptCall.calledExpression, env),
                  let index = eval(indexExpr, env) else { return nil }
            switch (base, index) {
            case let (.array(values), .int(i)):
                return (i >= 0 && i < values.count) ? values[i] : nil
            case let (.object(fields), .string(key)):
                return fields[key]
            default:
                return nil
            }
        }
        if let tuple = expr.as(TupleExprSyntax.self), tuple.elements.count == 1,
           let inner = tuple.elements.first?.expression {
            return eval(inner, env)
        }
        if let array = expr.as(ArrayExprSyntax.self) {
            guard array.elements.count <= RenderSecurityLimits.maxLiteralItems else { return nil }
            var values: [SwiftValue] = []
            values.reserveCapacity(array.elements.count)
            for element in array.elements {
                guard env.budget.consume() else { return nil }
                if let value = eval(element.expression, env) { values.append(value) }
            }
            return .array(values)
        }
        if let dictionary = expr.as(DictionaryExprSyntax.self) {
            // `[:]` or `["k": v, …]` with string-displayable keys -> `.object`.
            guard case let .elements(elements) = dictionary.content else { return .object([:]) }
            guard elements.count <= RenderSecurityLimits.maxValueObjectFields else { return nil }
            var fields: [String: SwiftValue] = [:]
            for element in elements {
                guard env.budget.consume() else { return nil }
                guard let key = eval(element.key, env)?.displayString,
                      !key.isEmpty,
                      key.utf8.count <= RenderSecurityLimits.maxTokenBytes,
                      let value = eval(element.value, env) else { continue }
                fields[key] = value
            }
            return .object(fields)
        }
        if let ternary = expr.as(TernaryExprSyntax.self) {
            let taken = eval(ternary.condition, env)?.isTruthy ?? false
            return eval(taken ? ternary.thenExpression : ternary.elseExpression, env)
        }
        if let call = expr.as(FunctionCallExprSyntax.self),
           let ref = call.calledExpression.as(DeclReferenceExprSyntax.self),
           ref.baseName.text == "Color" {
            return colorValue(call, env)
        }
        if let call = expr.as(FunctionCallExprSyntax.self),
           let ref = call.calledExpression.as(DeclReferenceExprSyntax.self),
           ["Array", "Int", "Double", "String"].contains(ref.baseName.text),
           env.lookupFunction(ref.baseName.text) == nil,
           let firstArg = call.arguments.first(where: { $0.label == nil })?.expression {
            let inner = eval(firstArg, env)
            switch ref.baseName.text {
            case "Array": return inner // `Array(seq)` / `Array(x.enumerated())`: identity.
            case "Int":
                switch inner {
                case let .int(i): return .int(i)
                // Int(_: Double) traps on NaN/infinity/overflow; authored
                // source can produce all three (e.g. `Int(1.0 / 0.0)`).
                case let .double(d):
                    guard d.isFinite else { return nil }
                    return Int(exactly: d.rounded(.towardZero)).map { .int($0) }
                case let .string(s): return Int(s).map { .int($0) }
                default: return nil
                }
            case "Double":
                switch inner {
                case let .double(d) where d.isFinite: return .double(d)
                case let .int(i): return .double(Double(i))
                case let .string(s):
                    guard let d = Double(s), d.isFinite else { return nil }
                    return .double(d)
                default: return nil
                }
            case "String":
                return inner.map { .string($0.displayString) }
            default: return nil
            }
        }
        if let call = expr.as(FunctionCallExprSyntax.self),
           let ref = call.calledExpression.as(DeclReferenceExprSyntax.self),
           ["min", "max", "abs"].contains(ref.baseName.text),
           env.lookupFunction(ref.baseName.text) == nil {
            guard call.arguments.count <= RenderSecurityLimits.maxLiteralItems else { return nil }
            let nums = call.arguments.compactMap { numericValue(eval($0.expression, env)) }
            switch ref.baseName.text {
            case "min" where nums.count >= 2: return numberResult(nums.min()!, intIf: allInt(call, env))
            case "max" where nums.count >= 2: return numberResult(nums.max()!, intIf: allInt(call, env))
            case "abs" where nums.count == 1: return numberResult(Swift.abs(nums[0]), intIf: allInt(call, env))
            default: return nil
            }
        }
        if let call = expr.as(FunctionCallExprSyntax.self),
           let ref = call.calledExpression.as(DeclReferenceExprSyntax.self),
           let decl = env.lookupFunction(ref.baseName.text) {
            return callValueFunction(decl, call, env)
        }
        if let call = expr.as(FunctionCallExprSyntax.self),
           let member = call.calledExpression.as(MemberAccessExprSyntax.self),
           let baseExpr = member.base,
           let base = eval(baseExpr, env) {
            return evalMethod(base, member.declName.baseName.text, call, env)
        }
        if let prefix = expr.as(PrefixOperatorExprSyntax.self) {
            return evalPrefix(prefix.operator.text, eval(prefix.expression, env))
        }
        if let infix = expr.as(InfixOperatorExprSyntax.self) {
            return evalInfix(infix, env)
        }
        return nil
    }

    /// Evaluates a string literal, concatenating plain segments and
    /// interpolations evaluated against `env`.
    public func evalString(_ literal: StringLiteralExprSyntax, _ env: EvalEnvironment) -> String {
        var result = ""
        for segment in literal.segments {
            if let text = segment.as(StringSegmentSyntax.self) {
                appendBounded(text.content.text, to: &result)
            } else if let interp = segment.as(ExpressionSegmentSyntax.self),
                      let expr = interp.expressions.first?.expression {
                appendBounded(eval(expr, env)?.displayString ?? "", to: &result)
            }
            if result.utf8.count >= RenderSecurityLimits.maxDisplayStringBytes { break }
        }
        return result
    }

    /// Appends at most the display budget, preserving Unicode scalar
    /// boundaries. Interpolated data is user-controlled and can be much larger
    /// than the source file that references it.
    // MARK: - Operators

    private func evalPrefix(_ op: String, _ value: SwiftValue?) -> SwiftValue? {
        switch (op, value) {
        case let ("-", .int(v)):
            guard v != Int.min else { return nil }
            return .int(-v)
        case let ("-", .double(v)):
            let result = -v
            return result.isFinite ? .double(result) : nil
        case let ("!", .bool(v)): return .bool(!v)
        default: return nil
        }
    }

    private func evalInfix(_ node: InfixOperatorExprSyntax, _ env: EvalEnvironment) -> SwiftValue? {
        guard let op = node.operator.as(BinaryOperatorExprSyntax.self)?.operator.text else { return nil }
        guard let lhs = eval(node.leftOperand, env) else { return nil }

        // Short-circuit logical operators on the left operand before forcing the
        // right one, so guard idioms like `i < items.count && items[i] == x`
        // don't evaluate (and fail on) the right side when the left is decisive.
        switch op {
        case "&&":
            guard lhs.isTruthy else { return .bool(false) }
            return .bool(eval(node.rightOperand, env)?.isTruthy ?? false)
        case "||":
            guard !lhs.isTruthy else { return .bool(true) }
            return .bool(eval(node.rightOperand, env)?.isTruthy ?? false)
        default:
            break
        }

        guard let rhs = eval(node.rightOperand, env) else { return nil }

        switch op {
        case "..<", "...":
            guard case let .int(l) = lhs, case let .int(r) = rhs else { return nil }
            return .range(lower: l, upper: r, inclusive: op == "...")
        case "==": return .bool(lhs == rhs)
        case "!=": return .bool(lhs != rhs)
        default: break
        }

        // String concatenation
        if op == "+", case let .string(l) = lhs, case let .string(r) = rhs {
            return .string(boundedConcatenation(l, r))
        }

        // Keep integer arithmetic in Int so overflow can be detected without
        // converting through a rounded Double. A malformed sidebar must return
        // no value, never trap the host process.
        if case let .int(l) = lhs, case let .int(r) = rhs {
            switch op {
            case "+":
                let (value, overflow) = l.addingReportingOverflow(r)
                return overflow ? nil : .int(value)
            case "-":
                let (value, overflow) = l.subtractingReportingOverflow(r)
                return overflow ? nil : .int(value)
            case "*":
                let (value, overflow) = l.multipliedReportingOverflow(by: r)
                return overflow ? nil : .int(value)
            case "/":
                guard r != 0 else { return nil }
                let (value, overflow) = l.dividedReportingOverflow(by: r)
                return overflow ? nil : .int(value)
            case "%":
                guard r != 0 else { return nil }
                let (value, overflow) = l.remainderReportingOverflow(dividingBy: r)
                return overflow ? nil : .int(value)
            case "<": return .bool(l < r)
            case ">": return .bool(l > r)
            case "<=": return .bool(l <= r)
            case ">=": return .bool(l >= r)
            default: return nil
            }
        }

        // Numeric arithmetic and comparison for mixed integer/double values.
        let (l, r, _) = numericPair(lhs, rhs)
        guard let l, let r else { return nil }
        switch op {
        case "+": return finiteDoubleResult(l + r)
        case "-": return finiteDoubleResult(l - r)
        case "*": return finiteDoubleResult(l * r)
        case "/":
            guard r != 0 else { return nil }
            return finiteDoubleResult(l / r)
        case "%":
            guard r != 0 else { return nil }
            return finiteDoubleResult(l.truncatingRemainder(dividingBy: r))
        case "<": return .bool(l < r)
        case ">": return .bool(l > r)
        case "<=": return .bool(l <= r)
        case ">=": return .bool(l >= r)
        default: return nil
        }
    }

    private func numericPair(_ lhs: SwiftValue, _ rhs: SwiftValue) -> (Double?, Double?, Bool) {
        func num(_ v: SwiftValue) -> (Double?, Bool) {
            switch v {
            case let .int(i): return (Double(i), true)
            case let .double(d): return (d.isFinite ? d : nil, false)
            default: return (nil, false)
            }
        }
        let (l, lInt) = num(lhs)
        let (r, rInt) = num(rhs)
        return (l, r, lInt && rInt)
    }

    /// Converts a floating-point result to a value only when it is finite.
    /// SwiftUI and Foundation APIs have several trapping integer conversions;
    /// keeping non-finite values out at this boundary makes later consumers
    /// safe by construction.
    private func finiteDoubleResult(_ value: Double) -> SwiftValue? {
        guard value.isFinite else { return nil }
        return .double(value)
    }

    // MARK: - Value methods

    /// Evaluates a method call on a value: array higher-order methods and
    /// common string methods. Closures are single-expression and bound to
    /// `$0` (and any named parameter).
    private func evalMethod(_ base: SwiftValue, _ name: String, _ call: FunctionCallExprSyntax, _ env: EvalEnvironment) -> SwiftValue? {
        let closure = call.trailingClosure
            ?? call.arguments.first(where: { ["where", "by"].contains($0.label?.text) })?.expression.as(ClosureExprSyntax.self)
        let firstArg = call.arguments.first(where: { $0.label == nil })?.expression
            ?? call.arguments.first?.expression

        switch base {
        case let .int(value):
            return numberMethod(Double(value), name, call)
        case let .double(value):
            return numberMethod(value, name, call)
        case let .array(values):
            switch name {
            case "filter":
                guard let closure else { return nil }
                guard values.count <= RenderSecurityLimits.maxCollectionItems else { return nil }
                return .array(values.filter { evalClosure(closure, $0, env)?.isTruthy ?? false })
            case "map":
                guard let closure else { return nil }
                guard values.count <= RenderSecurityLimits.maxCollectionItems else { return nil }
                return .array(values.compactMap { evalClosure(closure, $0, env) })
            case "flatMap":
                guard let closure else { return nil }
                guard values.count <= RenderSecurityLimits.maxCollectionItems else { return nil }
                var out: [SwiftValue] = []
                for v in values {
                    guard env.budget.consume() else { return nil }
                    switch evalClosure(closure, v, env) {
                    case let .array(inner):
                        guard out.count + inner.count <= RenderSecurityLimits.maxCollectionItems else { return nil }
                        out += inner
                    case let other?:
                        guard out.count < RenderSecurityLimits.maxCollectionItems else { return nil }
                        out.append(other)
                    case nil: break
                    }
                }
                return .array(out)
            case "reduce":
                guard let closure, let initialExpr = call.arguments.first(where: { $0.label == nil })?.expression,
                      var acc = eval(initialExpr, env) else { return nil }
                guard values.count <= RenderSecurityLimits.maxCollectionItems else { return nil }
                for v in values {
                    guard env.budget.consume() else { return nil }
                    if let next = evalClosure2(closure, acc, v, env) { acc = next }
                }
                return acc
            case "first":
                guard let closure else { return values.first }
                guard values.count <= RenderSecurityLimits.maxCollectionItems else { return nil }
                return values.first { evalClosure(closure, $0, env)?.isTruthy ?? false }
            case "contains":
                if let closure {
                    guard values.count <= RenderSecurityLimits.maxCollectionItems else { return nil }
                    return .bool(values.contains { evalClosure(closure, $0, env)?.isTruthy ?? false })
                }
                guard let firstArg, let needle = eval(firstArg, env) else { return nil }
                guard values.count <= RenderSecurityLimits.maxCollectionItems else { return nil }
                return .bool(values.contains(needle))
            case "count":
                guard let closure else { return .int(values.count) }
                guard values.count <= RenderSecurityLimits.maxCollectionItems else { return nil }
                return .int(values.filter { evalClosure(closure, $0, env)?.isTruthy ?? false }.count)
            case "reversed":
                guard values.count <= RenderSecurityLimits.maxCollectionItems else { return nil }
                return .array(values.reversed())
            case "indices":
                guard values.count <= RenderSecurityLimits.maxCollectionItems else { return nil }
                return .array(values.indices.map { .int($0) })
            case "enumerated":
                // Each element is an index/value pair, addressable as
                // `.offset`/`.element` or destructured by a 2-arg closure
                // (`$0`/`$1`, stored under "0"/"1").
                guard values.count <= RenderSecurityLimits.maxCollectionItems else { return nil }
                return .array(values.enumerated().map { pair in
                    .object([
                        "offset": .int(pair.offset),
                        "element": pair.element,
                        "0": .int(pair.offset),
                        "1": pair.element,
                    ])
                })
            case "prefix":
                guard let firstArg, case let .int(n)? = eval(firstArg, env) else { return nil }
                guard values.count <= RenderSecurityLimits.maxCollectionItems else { return nil }
                return .array(Array(values.prefix(max(0, n))))
            case "dropFirst":
                let n = firstArg.flatMap { if case let .int(k)? = eval($0, env) { return k } else { return nil } } ?? 1
                guard values.count <= RenderSecurityLimits.maxCollectionItems else { return nil }
                return .array(Array(values.dropFirst(max(0, n))))
            case "dropLast":
                let n = firstArg.flatMap { if case let .int(k)? = eval($0, env) { return k } else { return nil } } ?? 1
                guard values.count <= RenderSecurityLimits.maxCollectionItems else { return nil }
                return .array(Array(values.dropLast(max(0, n))))
            case "suffix":
                guard let firstArg, case let .int(n)? = eval(firstArg, env) else { return nil }
                guard values.count <= RenderSecurityLimits.maxCollectionItems else { return nil }
                return .array(Array(values.suffix(max(0, n))))
            case "sorted":
                guard values.count <= RenderSecurityLimits.maxSortItems else { return nil }
                guard let closure else { return .array(sortedScalars(values)) }
                guard values.count <= RenderSecurityLimits.maxSortItems else { return nil }
                // Honor a 2-arg comparator like `sorted { $0.rank < $1.rank }`.
                // Use a stable insertion sort, not `Array.sorted(by:)`, because
                // an interpreted predicate isn't guaranteed to form a strict
                // weak ordering and `sorted(by:)` traps on those in debug.
                var result: [SwiftValue] = []
                for value in values {
                    guard env.budget.consume() else { return nil }
                    var insertAt = result.count
                    // Consume for every comparison, including comparisons that
                    // do not move the value. A `where` clause on a large list
                    // otherwise gets a quadratic path outside the interpreter
                    // budget because Swift's `where` clause is evaluated by the
                    // host loop itself.
                    for index in result.indices {
                        guard env.budget.consume() else { return nil }
                        if evalClosure2(closure, value, result[index], env)?.isTruthy ?? false {
                            insertAt = index
                            break
                        }
                    }
                    result.insert(value, at: insertAt)
                }
                return .array(result)
            case "isEmpty":
                return .bool(values.isEmpty)
            case "joined":
                guard values.count <= RenderSecurityLimits.maxCollectionItems else { return nil }
                let separator: String = {
                    if let firstArg, case let .string(v)? = eval(firstArg, env) { return v }
                    return ""
                }()
                return .string(boundedJoin(values, separator: separator))
            default:
                return nil
            }
        case let .string(s):
            func argString() -> String? {
                guard let firstArg else { return nil }
                if case let .string(v)? = eval(firstArg, env) { return v }
                return nil
            }
            switch name {
            case "hasPrefix": return argString().map { .bool(s.hasPrefix($0)) }
            case "hasSuffix": return argString().map { .bool(s.hasSuffix($0)) }
            case "contains": return argString().map { .bool(s.contains($0)) }
            case "uppercased": return .string(boundedString(s.uppercased()))
            case "lowercased": return .string(boundedString(s.lowercased()))
            case "capitalized": return .string(boundedString(s.capitalized))
            case "isEmpty": return .bool(s.isEmpty)
            case "replacingOccurrences":
                func labeled(_ label: String) -> String? {
                    guard let e = call.arguments.first(where: { $0.label?.text == label })?.expression else { return nil }
                    if case let .string(v)? = eval(e, env) { return v }
                    return nil
                }
                guard let target = labeled("of"), let replacement = labeled("with") else { return nil }
                return .string(boundedReplacement(in: s, target: target, replacement: replacement))
            case "split":
                guard let sep = argString(), let first = sep.first else { return nil }
                // `String.split` returns `maxSplits + 1` pieces when every
                // separator is present. Reserve one slot for that final piece
                // so the result stays within the collection contract.
                let pieces = s.split(
                    separator: first,
                    maxSplits: max(0, RenderSecurityLimits.maxCollectionItems - 1),
                    omittingEmptySubsequences: false
                )
                return .array(pieces.map { .string(boundedString(String($0))) })
            case "trimmingCharacters":
                // `.trimmingCharacters(in: .whitespaces / .whitespacesAndNewlines / .newlines)`
                let token = call.arguments.first(where: { $0.label?.text == "in" })?.expression.trimmedDescription ?? ""
                let set: CharacterSet = token.contains("newlines") && !token.contains("whitespacesAndNewlines")
                    ? .newlines
                    : (token.contains("whitespaces") ? (token.contains("AndNewlines") ? .whitespacesAndNewlines : .whitespaces) : .whitespacesAndNewlines)
                return .string(boundedString(s.trimmingCharacters(in: set)))
            default:
                return nil
            }
        default:
            return nil
        }
    }

    /// The numeric reading of a value (int or double), else nil.
    private func numericValue(_ value: SwiftValue?) -> Double? {
        switch value {
        case let .int(i): return Double(i)
        case let .double(d) where d.isFinite: return d
        default: return nil
        }
    }

    private func boundedString(_ value: String) -> String {
        guard value.utf8.count > RenderSecurityLimits.maxDisplayStringBytes else { return value }
        var result = ""
        var used = 0
        for scalar in value.unicodeScalars {
            let width = String(scalar).utf8.count
            guard used + width <= RenderSecurityLimits.maxDisplayStringBytes else { break }
            result.unicodeScalars.append(scalar)
            used += width
        }
        return result
    }

    /// Concatenates strings without creating an unbounded intermediate. Both
    /// operands can be authored values, so applying the display cap only after
    /// `+` would allow repeated map/reduce expressions to amplify memory.
    private func boundedConcatenation(_ lhs: String, _ rhs: String) -> String {
        var result = ""
        appendBounded(lhs, to: &result)
        appendBounded(rhs, to: &result)
        return result
    }

    /// Joins values incrementally so a large collection cannot materialise a
    /// many-hundred-megabyte intermediate string before the display cap is
    /// applied.
    private func boundedJoin(_ values: [SwiftValue], separator: String) -> String {
        var result = ""
        for (index, value) in values.enumerated() {
            if index > 0 { appendBounded(separator, to: &result) }
            appendBounded(value.displayString, to: &result)
            if result.utf8.count >= RenderSecurityLimits.maxDisplayStringBytes { break }
        }
        return result
    }

    /// Performs replacement while appending into the bounded output buffer.
    /// Foundation's `replacingOccurrences` creates the complete expanded
    /// string first, which lets a short input and a large replacement produce
    /// an avoidable memory spike.
    private func boundedReplacement(in source: String, target: String, replacement: String) -> String {
        guard !target.isEmpty else { return boundedString(source) }
        var result = ""
        var cursor = source.startIndex
        while cursor < source.endIndex {
            guard let match = source.range(of: target, range: cursor..<source.endIndex) else {
                appendBounded(String(source[cursor...]), to: &result)
                break
            }
            appendBounded(String(source[cursor..<match.lowerBound]), to: &result)
            appendBounded(replacement, to: &result)
            if result.utf8.count >= RenderSecurityLimits.maxDisplayStringBytes { break }
            cursor = match.upperBound
        }
        return result
    }

    private func appendBounded(_ fragment: String, to result: inout String) {
        let remaining = RenderSecurityLimits.maxDisplayStringBytes - result.utf8.count
        guard remaining > 0 else { return }
        guard fragment.utf8.count <= remaining else {
            var used = 0
            for scalar in fragment.unicodeScalars {
                let width = String(scalar).utf8.count
                guard used + width <= remaining else { break }
                result.unicodeScalars.append(scalar)
                used += width
            }
            return
        }
        result.append(contentsOf: fragment)
    }

    /// Whether every argument of `call` evaluates to an integer (so a numeric
    /// builtin like `min` returns `.int`, not `.double`).
    private func allInt(_ call: FunctionCallExprSyntax, _ env: EvalEnvironment) -> Bool {
        call.arguments.allSatisfy {
            if case .int? = eval($0.expression, env) { return true }
            return false
        }
    }

    /// Wraps a numeric result as `.int` when `intIf` is true, else `.double`.
    private func numberResult(_ value: Double, intIf: Bool) -> SwiftValue? {
        guard value.isFinite else { return nil }
        guard intIf else { return .double(value) }
        // `Int(value)` traps for a finite value outside the platform integer
        // range. The failable initializer keeps malformed data in the
        // interpreter's nil/error path instead.
        guard let integer = Int(exactly: value.rounded(.towardZero)) else { return nil }
        return .int(integer)
    }

    /// Returns the contents of the first double-quoted literal in `source`,
    /// e.g. the currency code in `.currency(code: "EUR")`.
    private func firstQuoted(in source: String) -> String? {
        guard let open = source.firstIndex(of: "\"") else { return nil }
        let afterOpen = source.index(after: open)
        guard let close = source[afterOpen...].firstIndex(of: "\"") else { return nil }
        let value = String(source[afterOpen..<close])
        guard value.utf8.count <= 32,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return value
    }

    /// Number methods, chiefly `.formatted(...)`, honoring currency and
    /// compact-notation hints from the call's argument source.
    private func numberMethod(_ value: Double, _ name: String, _ call: FunctionCallExprSyntax) -> SwiftValue? {
        guard name == "formatted" else { return nil }
        guard value.isFinite else { return nil }
        let argSource = call.arguments.map { $0.expression.trimmedDescription }.joined(separator: " ")
        if argSource.contains("currency") {
            // Honor the `code:` argument (`.currency(code: "EUR")` -> "€…"),
            // not a hardcoded "$". Foundation resolves the symbol per code.
            let code = firstQuoted(in: argSource) ?? "USD"
            return .string(value.formatted(.currency(code: code)))
        }
        if argSource.contains("compact") || argSource.contains("notation") {
            let a = abs(value)
            if a >= 1_000_000 { return .string(String(format: "%.1fM", value / 1_000_000)) }
            if a >= 1_000 { return .string(String(format: "%.1fK", value / 1_000)) }
        }
        if argSource.contains("percent") {
            let percent = value * 100
            guard percent.isFinite else { return nil }
            return .string(String(format: "%.0f%%", percent))
        }
        if value == value.rounded(), let integer = Int(exactly: value) {
            return .string(String(integer))
        }
        return .string(String(value))
    }

    /// Resolves `Color(...)` to a hex/token string usable by color modifiers:
    /// `Color("#hex")`, `Color(red:green:blue:)`, else nil.
    private func colorValue(_ call: FunctionCallExprSyntax, _ env: EvalEnvironment) -> SwiftValue? {
        if let first = call.arguments.first(where: { $0.label == nil })?.expression,
           case let .string(token)? = eval(first, env) {
            return .string(token)
        }
        func channel(_ label: String) -> Int? {
            guard let e = call.arguments.first(where: { $0.label?.text == label })?.expression else { return nil }
            switch eval(e, env) {
            case let .double(d):
                // Clamp to [0,1] BEFORE converting — `Int(Double.infinity)` traps.
                guard d.isFinite else { return 0 }
                return max(0, min(255, Int((max(0, min(1, d)) * 255).rounded())))
            case let .int(i): return max(0, min(255, i))
            default: return nil
            }
        }
        if let r = channel("red"), let g = channel("green"), let b = channel("blue") {
            return .string(String(format: "#%02X%02X%02X", r, g, b))
        }
        return nil
    }

    /// Evaluates a two-parameter closure body with `a` bound to `$0` (and the
    /// first named param) and `b` bound to `$1` (and the second), for `reduce`.
    private func evalClosure2(_ closure: ClosureExprSyntax, _ a: SwiftValue, _ b: SwiftValue, _ env: EvalEnvironment) -> SwiftValue? {
        let scope = env.makeChild()
        scope.define("$0", a)
        scope.define("$1", b)
        if case let .simpleInput(list)? = closure.signature?.parameterClause {
            let names = Array(list)
            if names.count > 0 { scope.define(names[0].name.text, a) }
            if names.count > 1 { scope.define(names[1].name.text, b) }
        }
        // Multi-statement bodies (local `let`, `if`/`switch`, trailing expr) are
        // evaluated like a value-func block, so `{ a, b in let s = a + b; s }`
        // works, not just single-expression closures.
        return evalBlockValue(closure.statements, scope)
    }

    /// Evaluates a closure body with `element` bound to the closure parameter
    /// (and `$0`), honoring local `let` bindings and a trailing expression.
    private func evalClosure(_ closure: ClosureExprSyntax, _ element: SwiftValue, _ env: EvalEnvironment) -> SwiftValue? {
        let scope = env.makeChild()
        scope.define("$0", element)
        if let name = closureParameterName(closure) { scope.define(name, element) }
        return evalBlockValue(closure.statements, scope)
    }

    private func closureParameterName(_ closure: ClosureExprSyntax) -> String? {
        guard let parameterClause = closure.signature?.parameterClause else { return nil }
        if case let .simpleInput(list) = parameterClause { return list.first?.name.text }
        if case let .parameterClause(clause) = parameterClause { return clause.parameters.first?.firstName.text }
        return nil
    }

    /// Sorts an array of scalar values (int/double/string) ascending; returns
    /// the input unchanged for non-scalar or mixed element types.
    private func sortedScalars(_ values: [SwiftValue]) -> [SwiftValue] {
        guard values.count <= RenderSecurityLimits.maxSortItems else { return [] }
        if values.allSatisfy({ if case .int = $0 { return true }; return false }) {
            return values.sorted { a, b in
                if case let .int(x) = a, case let .int(y) = b { return x < y }
                return false
            }
        }
        if values.allSatisfy({ if case .double = $0 { return true }; if case .int = $0 { return true }; return false }) {
            func d(_ v: SwiftValue) -> Double {
                if case let .int(i) = v { return Double(i) }
                if case let .double(x) = v, x.isFinite { return x }
                return 0
            }
            return values.sorted { d($0) < d($1) }
        }
        if values.allSatisfy({ if case .string = $0 { return true }; return false }) {
            return values.sorted { a, b in
                if case let .string(x) = a, case let .string(y) = b { return x < y }
                return false
            }
        }
        return values
    }
}
