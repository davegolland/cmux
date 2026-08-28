/// A shared evaluation budget that bounds interpreter nesting *and* total
/// produced view nodes, so pathological or malicious authored source degrades
/// to a contained failure instead of overflowing the stack or handing SwiftUI
/// a multi-thousand-node tree that freezes the host.
///
/// One instance is created at the root ``EvalEnvironment`` and shared with every
/// child scope. Recursive evaluation entry points call ``enter()`` on the way
/// in (always paired with ``leave()`` via `defer`) and bail when ``exceeded``.
/// Node-producing entry points call ``recordNode()`` and bail when
/// ``nodesExceeded``; the top-level evaluate returns `nil` for a tripped
/// render so the host's last-good-sticky publish keeps the previous output.
final class RecursionBudget {
    private(set) var depth = 0
    private(set) var nodesProduced = 0
    private(set) var workUnits = 0
    private let limit: Int
    private let nodeLimit: Int
    private let workLimit: Int

    /// - Parameters:
    ///   - limit: Maximum interpreter nesting depth. The default (400) is far
    ///     beyond any legitimate sidebar yet well under the native stack
    ///     limit, so deep-but-finite trees still render while infinite
    ///     recursion is cut off.
    ///   - nodeLimit: Maximum total ``RenderNode``s one evaluation may
    ///     produce. The default (3000) is an order of magnitude above a rich
    ///     real sidebar (a few hundred nodes) yet small enough that a
    ///     pathological `ForEach(0..<100_000)` trips in milliseconds instead
    ///     of building a tree SwiftUI cannot lay out.
    ///   - workLimit: Maximum interpreter operations one evaluation may spend.
    ///     Collection methods can execute many value-only operations without
    ///     producing a view node, so the node limit alone is not a CPU bound.
    init(limit: Int = 400, nodeLimit: Int = 3000, workLimit: Int = 1_000_000) {
        self.limit = limit
        self.nodeLimit = nodeLimit
        self.workLimit = workLimit
    }

    /// Records entry into one more nesting level.
    func enter() {
        depth += 1
    }

    /// Records exit from a nesting level.
    func leave() {
        if depth > 0 { depth -= 1 }
    }

    /// Charges interpreter work and returns whether the budget remains valid.
    /// Saturating arithmetic prevents a hostile caller from overflowing the
    /// counter while reporting a failure.
    @discardableResult
    func consume(_ units: Int = 1) -> Bool {
        guard units >= 0 else { return false }
        let (next, overflow) = workUnits.addingReportingOverflow(units)
        if overflow {
            workUnits = workLimit &+ 1
            return false
        }
        workUnits = next
        return workUnits <= workLimit
    }

    /// Marks the evaluation as failed without spending time materializing an
    /// oversized collection. This is used when a bounded source value has
    /// already proved that rendering cannot be safe.
    func trip() {
        workUnits = workLimit == Int.max ? Int.max : workLimit + 1
    }

    /// Whether nesting has passed the limit; callers should bail when true.
    var exceeded: Bool {
        depth > limit || workUnits > workLimit
    }

    /// Records one produced view node.
    func recordNode() {
        nodesProduced += 1
        _ = consume()
    }

    /// Whether the evaluation has produced more nodes than the budget allows;
    /// node-producing callers should bail when true and the top-level
    /// evaluate should discard the truncated result.
    var nodesExceeded: Bool {
        nodesProduced > nodeLimit
    }
}
