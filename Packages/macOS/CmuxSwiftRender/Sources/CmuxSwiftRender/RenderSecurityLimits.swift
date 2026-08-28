import Foundation

/// Bounds for the interpreted Swift sidebar value engine.
///
/// The Swift renderer runs in-process in a few hosts, so malformed authored
/// source must fail as a value rather than trap or materialise an unbounded
/// collection. These limits are separate from the SwiftUI layout limits in
/// `CmuxSwiftRenderUI` because this package has no UI dependency.
enum RenderSecurityLimits {
    /// Maximum UTF-8 bytes accepted by the interpreted Swift subset.
    static let maxSourceBytes = 1 * 1024 * 1024

    /// Maximum top-level state bindings accepted by one evaluation.
    static let maxStateEntries = 2_048

    /// Maximum nested value depth and total value nodes accepted from a host.
    static let maxValueDepth = 64
    static let maxValueNodes = 100_000

    /// Maximum UTF-8 bytes for one value string or dictionary key.
    static let maxValueStringBytes = 16 * 1024
    static let maxValueStringTotalBytes = 4 * 1024 * 1024
    static let maxValueObjectFields = 128

    /// Maximum collection elements an interpreted operation may materialise.
    static let maxCollectionItems = 10_000

    /// Insertion sorting calls an interpreted comparator repeatedly. Keep its
    /// quadratic path bounded even when the input is otherwise valid.
    static let maxSortItems = 4_096

    /// Maximum commands and parameters captured from one interpreted action.
    static let maxActionCommands = 16
    static let maxActionParameters = 32

    /// Maximum display text produced while interpolating a value. This avoids
    /// copying a very large data value into every rendered row or command.
    static let maxDisplayStringBytes = 64 * 1024

    /// Maximum source-derived array/dictionary entries evaluated in one
    /// literal. Larger literals are rejected before their values are built.
    static let maxLiteralItems = 10_000

    /// Maximum user-defined functions retained in one evaluation scope. A
    /// source file can contain many unsupported declarations that would not
    /// produce nodes, so keep declaration-table growth bounded as well.
    static let maxFunctionDeclarations = 2_048

    /// Maximum modifier calls and arguments retained on one render node.
    static let maxModifiersPerNode = 64
    static let maxModifierArguments = 64

    /// Maximum gradient stops retained by one render node.
    static let maxGradientStops = 64

    /// Maximum source token retained as a modifier or color/point argument.
    static let maxTokenBytes = 16 * 1024

    /// Action argument text is passed through the host command boundary and
    /// therefore uses the same small bound as the command policy.
    static let maxActionValueBytes = 4 * 1024

    /// Maximum size of the render tree accepted at an IPC or renderer
    /// boundary. The interpreter has its own production budget, but decoded
    /// responses and package callers must validate independently.
    static let maxRenderNodes = 4_096
    static let maxRenderChildren = 2_048
    static let maxRenderEdges = 16_384

    /// Maximum aggregate UTF-8 bytes for strings retained by one render tree.
    /// Per-field caps alone would still allow every node to carry a large
    /// independent text, modifier, or action value.
    static let maxRenderStringBytesTotal = 8 * 1024 * 1024

    /// Maximum UTF-8 bytes for render identifiers and ordinary text fields.
    static let maxIdentifierBytes = 128

    /// Maximum source/data path and surface dimensions used by the worker
    /// protocol. These are deliberately smaller than the frame cap.
    static let maxFilePathBytes = 4 * 1024
    static let maxSurfaceDimension = 10_000.0
    static let maxBackingScale = 8.0
    static let maxPointerCoordinate = 100_000.0

    /// Truncates UTF-8 text without splitting a Unicode scalar.
    static func boundedString(_ value: String, maxBytes: Int) -> String {
        guard maxBytes > 0, value.utf8.count > maxBytes else {
            return maxBytes > 0 ? value : ""
        }
        var result = ""
        result.reserveCapacity(maxBytes)
        var used = 0
        for scalar in value.unicodeScalars {
            let width = String(scalar).utf8.count
            guard used + width <= maxBytes else { break }
            result.unicodeScalars.append(scalar)
            used += width
        }
        return result
    }
}
