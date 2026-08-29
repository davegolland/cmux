import Testing

@testable import CmuxAgentChat

@Suite("TerminalMathScanPolicy")
struct TerminalMathScanPolicyTests {
    private typealias Policy = TerminalMathScanPolicy
    private typealias Action = TerminalMathScanPolicy.Action

    private let cooldown = Policy.scanCooldown

    /// The trailing delay of a single `scheduleTrailingScan`, or nil.
    private func trailingDelay(_ actions: [Action]) -> Double? {
        guard actions.count == 1, case .scheduleTrailingScan(let after) = actions[0] else { return nil }
        return after
    }

    /// A policy that has seen a candidate and is waiting for its frame.
    private func armed() -> Policy {
        var policy = Policy()
        _ = policy.handle(.candidate)
        return policy
    }

    /// A policy whose candidate scan found placements at `now`.
    private func withPlacements(now: Double = 1) -> Policy {
        var policy = armed()
        _ = policy.handle(.frame(now: now))
        _ = policy.handle(.scanCompleted(found: true, isAlternateScreen: false, now: now))
        return policy
    }

    @Test("a candidate retains demand and asks for a tick but never scans")
    func candidateDoesNotScan() {
        var policy = Policy()
        let actions = policy.handle(.candidate)
        #expect(actions == [.retainDemand, .requestTick])
        #expect(policy.hasCandidate)
        #expect(policy.demandRetained)
        #expect(!actions.contains { if case .scanNow = $0 { return true } else { return false } })
    }

    @Test("a second candidate does not retain demand twice")
    func repeatedCandidateRetainsOnce() {
        var policy = armed()
        #expect(policy.handle(.candidate) == [.requestTick])
    }

    @Test("the frame after a candidate scans, and completion clears the candidate and re-arms the tee")
    func candidateScanClearsCandidateAndRearms() {
        var policy = armed()
        #expect(policy.handle(.frame(now: 1)) == [.scanNow(.frame)])
        #expect(policy.activeScanReason == .frame)
        let done = policy.handle(.scanCompleted(found: true, isAlternateScreen: false, now: 1))
        #expect(done == [.rearmTee])
        #expect(!policy.hasCandidate)
        #expect(policy.hasPlacements)
        #expect(policy.idleFrameScans == 0)
        #expect(policy.lastScanAt == 1)
    }

    @Test("a frame with no candidate, no placements, and no demand is ignored")
    func idleFrameIsIgnored() {
        var policy = Policy()
        #expect(policy.handle(.frame(now: 1)).isEmpty)
        #expect(policy.handle(.scanCompleted(found: false, isAlternateScreen: false, now: 1)) == [.rearmTee])
    }

    @Test("a candidate scan is never throttled even inside the cooldown")
    func candidateScanIsNotThrottled() {
        var policy = withPlacements(now: 1)
        _ = policy.handle(.candidate)
        #expect(policy.handle(.frame(now: 1 + cooldown / 4)) == [.scanNow(.frame)])
    }

    @Test("a later frame with placements re-scans once the cooldown has passed")
    func frameWithPlacementsScansAfterCooldown() {
        var policy = withPlacements(now: 1)
        #expect(policy.handle(.frame(now: 1 + cooldown)) == [.scanNow(.frame)])
        #expect(policy.handle(.scanCompleted(found: true, isAlternateScreen: false, now: 1 + cooldown)) == [.rearmTee])
        #expect(policy.hasPlacements)
    }

    @Test("frames inside the cooldown schedule exactly one trailing scan")
    func throttleProducesOneTrailingScan() {
        var policy = withPlacements(now: 1)
        let first = trailingDelay(policy.handle(.frame(now: 1.02)))
        #expect(abs((first ?? -1) - (cooldown - 0.02)) < 1e-9)
        #expect(policy.trailingScanPending)
        #expect(policy.handle(.frame(now: 1.05)).isEmpty)
        #expect(policy.handle(.frame(now: 1.09)).isEmpty)

        let due = policy.handle(.trailingScanDue(now: 1.1))
        #expect(due == [.scanNow(.frame)])
        #expect(!policy.trailingScanPending)
        #expect(policy.handle(.scanCompleted(found: false, isAlternateScreen: false, now: 1.1)) == [.rearmTee])
        #expect(!policy.hasPlacements)
    }

    @Test("the trailing scan is skipped when nothing is left to validate")
    func trailingScanSkippedWhenDisabled() {
        var policy = withPlacements(now: 1)
        _ = policy.handle(.frame(now: 1.02))
        _ = policy.handle(.enabled(false))
        #expect(policy.handle(.trailingScanDue(now: 1.1)).isEmpty)
    }

    @Test("two empty frame scans with no candidate release demand")
    func twoIdleFramesReleaseDemand() {
        var policy = armed()
        // Candidate scan finds nothing: not idle, the candidate was pending.
        _ = policy.handle(.frame(now: 1))
        #expect(policy.handle(.scanCompleted(found: false, isAlternateScreen: false, now: 1)) == [.rearmTee])
        #expect(policy.idleFrameScans == 0)
        #expect(policy.demandRetained)

        // Demand is still retained, so frames keep scanning (throttled).
        #expect(policy.handle(.frame(now: 2)) == [.scanNow(.frame)])
        #expect(policy.handle(.scanCompleted(found: false, isAlternateScreen: false, now: 2)) == [.rearmTee])
        #expect(policy.idleFrameScans == 1)
        #expect(policy.demandRetained)

        #expect(policy.handle(.frame(now: 3)) == [.scanNow(.frame)])
        let released = policy.handle(.scanCompleted(found: false, isAlternateScreen: false, now: 3))
        #expect(released == [.rearmTee, .releaseDemand])
        #expect(!policy.demandRetained)
        #expect(policy.idleFrameScans == 0)

        // With demand released, frames are ignored until the next candidate.
        #expect(policy.handle(.frame(now: 4)).isEmpty)
        #expect(policy.handle(.candidate) == [.retainDemand, .requestTick])
    }

    @Test("a placement found between idle scans resets the idle count")
    func placementsResetIdleCount() {
        var policy = withPlacements(now: 1)
        _ = policy.handle(.frame(now: 2))
        _ = policy.handle(.scanCompleted(found: false, isAlternateScreen: false, now: 2))
        #expect(policy.idleFrameScans == 1)
        _ = policy.handle(.frame(now: 3))
        _ = policy.handle(.scanCompleted(found: true, isAlternateScreen: false, now: 3))
        #expect(policy.idleFrameScans == 0)
        _ = policy.handle(.frame(now: 4))
        #expect(policy.handle(.scanCompleted(found: false, isAlternateScreen: false, now: 4)) == [.rearmTee])
        #expect(policy.demandRetained)
    }

    @Test("a viewport change scans without clearing the candidate or re-arming")
    func viewportChangedScansWithoutRearm() {
        var policy = withPlacements(now: 1)
        #expect(policy.handle(.viewportChanged(now: 2)) == [.scanNow(.viewportChanged)])
        #expect(policy.activeScanReason == .viewportChanged)
        let done = policy.handle(.scanCompleted(found: true, isAlternateScreen: false, now: 2))
        #expect(done.isEmpty)
        #expect(!done.contains(.rearmTee))
        #expect(policy.hasPlacements)
    }

    @Test("a viewport change while a candidate is pending defers to the frame scan")
    func viewportChangedWithCandidateDefers() {
        var policy = armed()
        #expect(policy.handle(.viewportChanged(now: 2)).isEmpty)
        #expect(policy.hasCandidate)
        #expect(policy.handle(.frame(now: 3)) == [.scanNow(.frame)])
    }

    @Test("a viewport change with nothing on screen probes without demand")
    func viewportChangedProbesWithoutDemand() {
        var policy = Policy()
        #expect(policy.handle(.viewportChanged(now: 5)) == [.scanNow(.viewportChanged)])
        #expect(!policy.demandRetained)
        #expect(policy.handle(.scanCompleted(found: false, isAlternateScreen: false, now: 5)).isEmpty)
        #expect(!policy.hasPlacements)
        #expect(!policy.demandRetained)
        #expect(policy.idleFrameScans == 0)
    }

    @Test("idle probes are spaced by the idle probe cooldown, not the scan cooldown")
    func idleProbesAreSpacedOut() {
        var policy = Policy()
        _ = policy.handle(.viewportChanged(now: 5))
        _ = policy.handle(.scanCompleted(found: false, isAlternateScreen: false, now: 5))
        // Inside the scan cooldown and the idle cooldown: one trailing probe.
        let delay = trailingDelay(policy.handle(.viewportChanged(now: 5.2)))
        #expect(abs((delay ?? -1) - (Policy.idleProbeCooldown - 0.2)) < 1e-9)
        #expect(policy.trailingScanReason == .viewportChanged)
        #expect(policy.handle(.viewportChanged(now: 5.3)).isEmpty)
        // The trailing probe runs as a viewport scan: no candidate clear, no re-arm.
        #expect(policy.handle(.trailingScanDue(now: 5.5)) == [.scanNow(.viewportChanged)])
        #expect(policy.handle(.scanCompleted(found: false, isAlternateScreen: false, now: 5.5)).isEmpty)
        #expect(!policy.demandRetained)
    }

    @Test("a probe that finds math retains demand so frames re-validate it")
    func probeThatFindsMathRetainsDemand() {
        var policy = Policy()
        _ = policy.handle(.viewportChanged(now: 5))
        #expect(policy.handle(.scanCompleted(found: true, isAlternateScreen: false, now: 5)) == [.retainDemand])
        #expect(policy.demandRetained)
        #expect(policy.hasPlacements)
        #expect(policy.handle(.frame(now: 6)) == [.scanNow(.frame)])
    }

    @Test("a trailing scan yields to a candidate that arrived meanwhile")
    func trailingScanYieldsToCandidate() {
        var policy = withPlacements(now: 1)
        #expect(trailingDelay(policy.handle(.frame(now: 1.05))) != nil)
        #expect(policy.handle(.candidate) == [.requestTick])
        #expect(policy.handle(.trailingScanDue(now: 1.1)).isEmpty)
        #expect(!policy.trailingScanPending)
        #expect(policy.hasCandidate)
        #expect(policy.handle(.frame(now: 1.2)) == [.scanNow(.frame)])
    }

    @Test("a viewport change inside the cooldown is coalesced into the trailing scan")
    func viewportChangedIsThrottled() {
        var policy = withPlacements(now: 1)
        let delay = trailingDelay(policy.handle(.viewportChanged(now: 1.01)))
        #expect(abs((delay ?? -1) - (cooldown - 0.01)) < 1e-9)
        #expect(policy.handle(.viewportChanged(now: 1.02)).isEmpty)
    }

    @Test("a raster completion re-syncs placements without re-arming")
    func rasterReadyScansWhenPlacementsExist() {
        var policy = withPlacements(now: 1)
        #expect(policy.handle(.rasterReady(now: 2)) == [.scanNow(.rasterReady)])
        #expect(policy.handle(.scanCompleted(found: true, isAlternateScreen: false, now: 2)).isEmpty)
    }

    @Test("a raster completion with no placements is ignored")
    func rasterReadyIgnoredWithoutPlacements() {
        var policy = Policy()
        #expect(policy.handle(.rasterReady(now: 2)).isEmpty)
        var pending = armed()
        #expect(pending.handle(.rasterReady(now: 2)).isEmpty)
    }

    @Test("disabling clears the overlay, releases demand, and resets state")
    func disableClearsEverything() {
        var policy = withPlacements(now: 1)
        _ = policy.handle(.candidate)
        #expect(policy.handle(.enabled(false)) == [.clearOverlay, .releaseDemand])
        #expect(!policy.isEnabled)
        #expect(!policy.hasCandidate)
        #expect(!policy.hasPlacements)
        #expect(!policy.demandRetained)
        #expect(policy.handle(.candidate).isEmpty)
        #expect(policy.handle(.frame(now: 2)).isEmpty)
        #expect(policy.handle(.viewportChanged(now: 2)).isEmpty)
        #expect(policy.handle(.rasterReady(now: 2)).isEmpty)
    }

    @Test("disabling without demand only clears the overlay")
    func disableWithoutDemand() {
        var policy = Policy()
        #expect(policy.handle(.enabled(false)) == [.clearOverlay])
    }

    @Test("enabling rescans at once so math already on screen comes back without a frame")
    func enableRescansOnce() {
        var policy = Policy()
        _ = policy.handle(.enabled(false))
        #expect(policy.handle(.enabled(true)) == [.retainDemand, .scanNow(.viewportChanged)])
        #expect(policy.isEnabled)
        #expect(!policy.hasCandidate)
        // The rescan re-arms nothing and keeps the frame path alive.
        #expect(policy.handle(.scanCompleted(found: true, isAlternateScreen: false, now: 1)).isEmpty)
        #expect(policy.hasPlacements)
        #expect(policy.handle(.frame(now: 2)) == [.scanNow(.frame)])

        // Enabling an already-enabled policy still rescans once.
        var fresh = Policy()
        #expect(fresh.handle(.enabled(true)) == [.retainDemand, .scanNow(.viewportChanged)])
    }

    @Test("the alternate screen clears the overlay and counts as found nothing")
    func alternateScreenClears() {
        var policy = withPlacements(now: 1)
        _ = policy.handle(.frame(now: 2))
        let done = policy.handle(.scanCompleted(found: true, isAlternateScreen: true, now: 2))
        #expect(done == [.clearOverlay, .rearmTee])
        #expect(!policy.hasPlacements)
        #expect(policy.idleFrameScans == 1)

        _ = policy.handle(.frame(now: 3))
        let released = policy.handle(.scanCompleted(found: true, isAlternateScreen: true, now: 3))
        #expect(released == [.clearOverlay, .rearmTee, .releaseDemand])
        #expect(!policy.demandRetained)
    }

    @Test("an alternate-screen viewport scan clears without re-arming")
    func alternateScreenViewportScan() {
        var policy = withPlacements(now: 1)
        _ = policy.handle(.viewportChanged(now: 2))
        #expect(policy.handle(.scanCompleted(found: false, isAlternateScreen: true, now: 2)) == [.clearOverlay])
        #expect(!policy.hasPlacements)
    }

    @Test("a fresh policy is enabled, idle, and equatable")
    func initialState() {
        let policy = Policy()
        #expect(policy.isEnabled)
        #expect(!policy.hasCandidate)
        #expect(!policy.hasPlacements)
        #expect(!policy.demandRetained)
        #expect(policy.lastScanAt == nil)
        #expect(policy == Policy())
    }
}
