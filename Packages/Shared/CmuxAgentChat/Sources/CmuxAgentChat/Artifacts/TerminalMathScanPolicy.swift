/// Decides when a terminal surface's math overlay scans the rendered grid.
///
/// The policy is a pure state machine: the surface controller feeds it
/// ``Event`` values (the byte tee saw a delimiter, Ghostty rendered a frame,
/// the viewport moved, a raster finished) and executes the ``Action`` values
/// it returns. Nothing here touches AppKit or time; the caller passes a
/// monotonic clock reading in seconds with every time-sensitive event.
///
/// Rules:
/// - A candidate never scans by itself. It retains the view-local
///   rendered-frame demand, asks for a Ghostty tick, and waits for the next
///   frame so the scan always reads a grid that already contains the bytes
///   that raised the candidate (the tee fires before the VT parser).
/// - A frame scans while a candidate or placements are pending. With a
///   candidate pending the scan is never throttled beyond one per frame;
///   otherwise scans are limited to one per ``scanCooldown`` and a frame that
///   lands inside the cooldown schedules a single trailing scan at its end so
///   the final state is always re-validated.
/// - Only frame-driven scans (and trailing scans, which stand in for the
///   frame that was throttled) clear the candidate and re-arm the tee.
///   Viewport and raster scans re-validate placement geometry only.
/// - After ``idleScansBeforeRelease`` consecutive frame-driven scans that
///   found nothing while no candidate was pending, the demand is released so
///   an idle terminal costs nothing. A later candidate retains it again.
/// - A viewport change with nothing on screen only probes: one scan at most
///   every ``idleProbeCooldown`` without retaining demand, so scrollback
///   growth during bulk output stays cheap while scrolling back to a formula
///   still finds it. A probe that finds placements retains demand again.
/// - Enabling the feature rescans at once (no tick is needed: nothing is
///   being parsed) and re-arms nothing.
/// - The alternate screen never shows overlays: a scan there clears the
///   overlay and counts as "found nothing".
public struct TerminalMathScanPolicy: Sendable, Equatable {
    /// Why a scan was requested; decides what its completion may change.
    public enum ScanReason: Sendable, Equatable {
        /// A rendered frame (or the trailing scan standing in for one).
        case frame
        /// Scroll, resize, theme, or cell-size change.
        case viewportChanged
        /// A raster finished and can now be painted.
        case rasterReady
    }

    /// Inputs to the policy. Times are seconds on any monotonic clock.
    public enum Event: Sendable, Equatable {
        /// The PTY tee saw a math delimiter since the last scan.
        case candidate
        /// Ghostty rendered a frame for this surface.
        case frame(now: Double)
        /// The trailing scan scheduled by ``Action/scheduleTrailingScan(after:)`` is due.
        case trailingScanDue(now: Double)
        /// Scroll, resize, theme, config, or cell-size change.
        case viewportChanged(now: Double)
        /// `terminal.renderMath` toggled.
        case enabled(Bool)
        /// The scan started by the last ``Action/scanNow(_:)`` finished.
        case scanCompleted(found: Bool, isAlternateScreen: Bool, now: Double)
        /// An asynchronous raster produced an image.
        case rasterReady(now: Double)
    }

    /// Outputs the caller executes in order.
    public enum Action: Sendable, Equatable {
        /// Read the grid and report back with ``Event/scanCompleted(found:isAlternateScreen:now:)``.
        case scanNow(ScanReason)
        /// Feed ``Event/trailingScanDue(now:)`` after this many seconds.
        case scheduleTrailingScan(after: Double)
        /// Retain the view-local rendered-frame demand.
        case retainDemand
        /// Release the view-local rendered-frame demand.
        case releaseDemand
        /// Tell the router the grid was scanned so the tee can raise the next candidate.
        case rearmTee
        /// Drop placements and hide the overlay.
        case clearOverlay
        /// Ask Ghostty for a fresh frame so a post-parse frame arrives.
        case requestTick
    }

    /// Minimum spacing between scans while no candidate is pending, in seconds.
    public static let scanCooldown: Double = 0.1
    /// Minimum spacing between viewport probes while nothing is on screen.
    public static let idleProbeCooldown: Double = 0.5
    /// Empty frame-driven scans (no candidate pending) before demand is released.
    public static let idleScansBeforeRelease = 2

    /// Whether the feature is on for this surface.
    public private(set) var isEnabled = true
    /// A delimiter arrived and the grid has not been scanned since.
    public private(set) var hasCandidate = false
    /// The most recent scan found at least one placement.
    public private(set) var hasPlacements = false
    /// The rendered-frame demand is currently retained.
    public private(set) var demandRetained = false
    /// Consecutive empty frame-driven scans with no candidate pending.
    public private(set) var idleFrameScans = 0
    /// When the last scan completed, or nil before the first scan.
    public private(set) var lastScanAt: Double?
    /// Reason of the scheduled trailing scan, or nil when none is pending.
    public private(set) var trailingScanReason: ScanReason?
    /// A trailing scan is scheduled and not yet due.
    public var trailingScanPending: Bool { trailingScanReason != nil }
    /// Reason of the scan whose completion is awaited.
    public private(set) var activeScanReason: ScanReason?

    /// Creates a policy in its initial, enabled state.
    public init() {}

    /// Applies `event` and returns the actions to execute, in order.
    public mutating func handle(_ event: Event) -> [Action] {
        switch event {
        case .candidate:
            return noteCandidate()
        case .frame(let now):
            guard isEnabled, hasCandidate || hasPlacements || demandRetained else { return [] }
            if hasCandidate {
                return startScan(.frame)
            }
            return throttledScan(.frame, now: now)
        case .trailingScanDue:
            let reason = trailingScanReason ?? .frame
            trailingScanReason = nil
            guard isEnabled else { return [] }
            // A candidate that arrived meanwhile owns the next frame-driven
            // scan; a trailing scan now would read the grid before that frame.
            guard !hasCandidate else { return [] }
            guard hasPlacements || demandRetained || reason == .viewportChanged else { return [] }
            return startScan(reason)
        case .viewportChanged(let now):
            guard isEnabled else { return [] }
            // A pending candidate already guarantees a frame-driven scan.
            guard !hasCandidate else { return [] }
            if hasPlacements {
                var actions = retainDemandIfNeeded()
                actions += throttledScan(.viewportChanged, now: now, cooldown: Self.scanCooldown)
                return actions
            }
            // Nothing on screen: probe without demand so scrollback growth
            // during bulk output costs at most one export per cooldown.
            return throttledScan(.viewportChanged, now: now, cooldown: Self.idleProbeCooldown)
        case .enabled(let enabled):
            return setEnabled(enabled)
        case .scanCompleted(let found, let isAlternateScreen, let now):
            return completeScan(found: found, isAlternateScreen: isAlternateScreen, now: now)
        case .rasterReady(let now):
            guard isEnabled, hasPlacements, !hasCandidate else { return [] }
            return throttledScan(.rasterReady, now: now)
        }
    }

    // MARK: - Transitions

    private mutating func noteCandidate() -> [Action] {
        guard isEnabled else { return [] }
        hasCandidate = true
        idleFrameScans = 0
        var actions = retainDemandIfNeeded()
        actions.append(.requestTick)
        return actions
    }

    private mutating func setEnabled(_ enabled: Bool) -> [Action] {
        if enabled {
            // Always one rescan, even when already enabled: a controller
            // created while the setting was off starts enabled and may be
            // looking at math that arrived under the closed gate. The scan
            // runs at once: a tick does not wake Ghostty's renderer, so an
            // idle surface would never deliver the frame a candidate waits for.
            isEnabled = true
            var actions = retainDemandIfNeeded()
            actions += startScan(.viewportChanged)
            return actions
        }
        var actions: [Action] = [.clearOverlay]
        if demandRetained {
            actions.append(.releaseDemand)
        }
        self = TerminalMathScanPolicy()
        isEnabled = false
        return actions
    }

    private mutating func completeScan(found: Bool, isAlternateScreen: Bool, now: Double) -> [Action] {
        let reason = activeScanReason ?? .frame
        activeScanReason = nil
        lastScanAt = now
        let effectiveFound = found && !isAlternateScreen
        hasPlacements = effectiveFound
        var actions: [Action] = []
        if isAlternateScreen {
            actions.append(.clearOverlay)
        }
        if effectiveFound {
            // A probe or an enable found math: frames must now re-validate it.
            actions += retainDemandIfNeeded()
        }
        guard reason == .frame else { return actions }

        let hadCandidate = hasCandidate
        hasCandidate = false
        actions.append(.rearmTee)
        if effectiveFound || hadCandidate {
            idleFrameScans = 0
        } else {
            idleFrameScans += 1
            if idleFrameScans >= Self.idleScansBeforeRelease {
                idleFrameScans = 0
                if demandRetained {
                    demandRetained = false
                    actions.append(.releaseDemand)
                }
            }
        }
        return actions
    }

    private mutating func retainDemandIfNeeded() -> [Action] {
        guard !demandRetained else { return [] }
        demandRetained = true
        return [.retainDemand]
    }

    private mutating func startScan(_ reason: ScanReason) -> [Action] {
        activeScanReason = reason
        return [.scanNow(reason)]
    }

    /// Scans now unless a scan completed inside `cooldown`, in which case a
    /// single trailing scan is scheduled for the end of the cooldown.
    private mutating func throttledScan(
        _ reason: ScanReason,
        now: Double,
        cooldown: Double = TerminalMathScanPolicy.scanCooldown
    ) -> [Action] {
        if let lastScanAt {
            let elapsed = now - lastScanAt
            if elapsed < cooldown {
                guard !trailingScanPending else { return [] }
                trailingScanReason = reason
                return [.scheduleTrailingScan(after: cooldown - max(0, elapsed))]
            }
        }
        return startScan(reason)
    }
}
