import AppKit
import CmuxAgentChat
import CmuxFoundation
import CmuxTerminalCore
import CMUXMobileCore

/// Drives one terminal view's math overlay: scans the rendered grid for
/// delimited LaTeX, rasterizes it, and paints ``TerminalMathOverlayView``.
///
/// The controller is a thin adapter around `TerminalMathScanPolicy`: every
/// input (a candidate from the byte tee, a rendered frame, a scroll, resize,
/// theme, or config change, a raster completion, the enable toggle) is fed to
/// the policy as an event and the returned actions are executed here. The
/// policy owns the demand, throttling, tee re-arm, and idle-release rules; the
/// controller owns the grid export, the raster cache lookups, and the overlay
/// model.
@MainActor
final class TerminalMathSurfaceController {
    /// Owning view; the view retains the controller and calls ``invalidate()`` in `deinit`.
    unowned let view: GhosttyNSView

    /// Scan scheduling state machine (pure, tested in CmuxAgentChat).
    private(set) var policy = TerminalMathScanPolicy()
    /// Whether the feature is enabled for this surface.
    var isEnabled: Bool { policy.isEnabled }
    /// Placements from the most recent scan.
    private(set) var lastPlacements: [TerminalMathPlacement] = []
    /// Placements dropped by the fit rule in the most recent sync (debug aid).
    private(set) var lastRejectedByFit: [TerminalMathPlacement] = []
    /// Placements whose raster the rasterizer rejected (KaTeX or pre-check),
    /// in the most recent sync; never re-requested.
    private(set) var lastRejectedByRaster: [TerminalMathPlacement] = []
    /// Whether the overlay is hidden because a selection or copy mode is
    /// active over the grid; placements are kept so it returns afterwards.
    private(set) var isHiddenForSelection = false

    private var releaseDemand: (() -> Void)?
    private var frameObserver: (any NSObjectProtocol)?
    private var viewportObservers: [any NSObjectProtocol] = []
    private var trailingScanTask: Task<Void, Never>?
    private var inFlightRasterKeys: Set<RasterKey> = []
    /// Keys whose raster failed transiently (nil without a cached rejection),
    /// with the earliest time they may be requested again and the delay to
    /// apply on the next failure.
    private var failedKeys: [RasterKey: (retryNotBefore: TimeInterval, delay: TimeInterval)] = [:]
    private var isInvalidated = false

    /// Upper bound on concurrent raster jobs for one surface.
    private static let maxInFlightRasters = 4
    /// First retry delay after a transient raster failure.
    private static let initialRetryDelay: TimeInterval = 1
    /// Longest retry delay after repeated transient raster failures.
    private static let maxRetryDelay: TimeInterval = 30

    /// Identity of one raster request, for in-flight deduplication and backoff.
    private struct RasterKey: Hashable {
        let source: String
        let isDisplay: Bool
        let fontSizePt: CGFloat
        let colorHex: String
        let scale: CGFloat
    }

    /// Creates a controller for `view`.
    init(view: GhosttyNSView) {
        self.view = view
    }

    // MARK: - Entry points

    /// Marks that the tee saw a math delimiter; the next rendered frame scans.
    func noteCandidate() {
        guard !isInvalidated else { return }
        apply(.candidate)
    }

    /// Called from `GhosttyNSView.layout()`; keeps the overlay sized to the view.
    func viewDidLayout() {
        guard !isInvalidated else { return }
        let overlay = view.terminalMathOverlayView
        if overlay.frame != view.bounds {
            overlay.frame = view.bounds
        }
        guard !lastPlacements.isEmpty else { return }
        apply(.viewportChanged(now: Self.now()))
    }

    /// Enables or disables the overlay. Disabling clears everything and
    /// releases demand; enabling rescans the visible grid once so math that
    /// is already on screen is picked up.
    func setEnabled(_ enabled: Bool) {
        guard !isInvalidated else { return }
        apply(.enabled(enabled))
        if !enabled {
            removeObservers()
        }
    }

    /// Releases demand and observers; safe to call more than once and from `deinit`.
    func invalidate() {
        isInvalidated = true
        trailingScanTask?.cancel()
        trailingScanTask = nil
        releaseDemandIfNeeded()
        removeObservers()
        lastPlacements = []
        lastRejectedByFit = []
        lastRejectedByRaster = []
        failedKeys = [:]
    }

    // MARK: - Policy adapter

    private static func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    private func apply(_ event: TerminalMathScanPolicy.Event) {
        guard !isInvalidated else { return }
        execute(policy.handle(event))
    }

    private func execute(_ actions: [TerminalMathScanPolicy.Action]) {
        for action in actions {
            guard !isInvalidated else { return }
            switch action {
            case .scanNow(let reason):
                scan(reason: reason)
            case .scheduleTrailingScan(let after):
                scheduleTrailingScan(after: after)
            case .retainDemand:
                retainDemandIfNeeded()
                installFrameObserverIfNeeded()
                installViewportObserversIfNeeded()
            case .releaseDemand:
                releaseDemandIfNeeded()
            case .rearmTee:
                if let surfaceID = view.terminalSurface?.id {
                    TerminalMathCandidateRouter.shared.markScanned(surfaceID: surfaceID)
                }
            case .clearOverlay:
                clearPlacements()
            case .requestTick:
                GhosttyApp.shared.scheduleTick()
            }
        }
    }

    private func scheduleTrailingScan(after delay: TimeInterval) {
        trailingScanTask?.cancel()
        trailingScanTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.trailingScanTask = nil
            self.apply(.trailingScanDue(now: Self.now()))
        }
    }

    // MARK: - Demand and observers

    private func retainDemandIfNeeded() {
        guard releaseDemand == nil else { return }
        releaseDemand = view.retainLocalRenderedFrameNotifications()
    }

    private func releaseDemandIfNeeded() {
        releaseDemand?()
        releaseDemand = nil
    }

    private func installFrameObserverIfNeeded() {
        guard frameObserver == nil else { return }
        frameObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyDidRenderFrame,
            object: view,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.apply(.frame(now: Self.now()))
            }
        }
    }

    private func installViewportObserversIfNeeded() {
        guard viewportObservers.isEmpty else { return }
        let center = NotificationCenter.default
        let viewportChanged: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                self?.apply(.viewportChanged(now: Self.now()))
            }
        }
        viewportObservers.append(center.addObserver(
            forName: .ghosttyDefaultBackgroundDidChange, object: nil, queue: .main, using: viewportChanged
        ))
        viewportObservers.append(center.addObserver(
            forName: .ghosttyConfigDidReload, object: nil, queue: .main, using: viewportChanged
        ))
        viewportObservers.append(center.addObserver(
            forName: .ghosttyDidUpdateCellSize, object: view, queue: .main, using: viewportChanged
        ))
        viewportObservers.append(center.addObserver(
            forName: .ghosttyDidUpdateScrollbar, object: view, queue: .main, using: viewportChanged
        ))
        viewportObservers.append(center.addObserver(
            forName: .ghosttySurfaceThemeDidChange, object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self,
                      let changed = notification.object as? UUID,
                      changed == self.view.terminalSurface?.id else { return }
                self.apply(.viewportChanged(now: Self.now()))
            }
        })
    }

    private func removeObservers() {
        let center = NotificationCenter.default
        if let frameObserver {
            center.removeObserver(frameObserver)
            self.frameObserver = nil
        }
        for observer in viewportObservers {
            center.removeObserver(observer)
        }
        viewportObservers.removeAll()
    }

    // MARK: - Scanning

    /// Reads the grid, scans it, syncs the overlay, and reports the result to
    /// the policy (which decides about the candidate, the tee, and demand).
    private func scan(reason: TerminalMathScanPolicy.ScanReason) {
        guard let surface = view.terminalSurface,
              let snapshot = surface.mobileRenderGridFrame(
                stateSeq: 0,
                full: true,
                scrollbackLines: 0,
                includeTheme: false,
                anchor: .viewport
              ) else {
            clearPlacements()
            apply(.scanCompleted(found: false, isAlternateScreen: false, now: Self.now()))
            return
        }
        let frame = snapshot.frame
        guard frame.activeScreen != .alternate else {
            clearPlacements()
            apply(.scanCompleted(found: false, isAlternateScreen: true, now: Self.now()))
            return
        }

        let cursor: (row: Int, column: Int)? = frame.cursor.flatMap {
            $0.visible ? (row: $0.row, column: $0.column) : nil
        }
        let placements = TerminalMathGridScanner().placements(
            rows: snapshot.rows,
            columns: frame.columns,
            cursor: cursor
        )
        lastPlacements = placements
        syncOverlay(frame: frame, rows: snapshot.rows)
        apply(.scanCompleted(found: !placements.isEmpty, isAlternateScreen: false, now: Self.now()))
    }

    private func clearPlacements() {
        lastPlacements = []
        lastRejectedByFit = []
        lastRejectedByRaster = []
        isHiddenForSelection = false
        let overlay = view.terminalMathOverlayView
        if !overlay.model.items.isEmpty {
            overlay.model = TerminalMathOverlayModel()
        }
        overlay.isHidden = true
    }

    // MARK: - Overlay sync

    /// Whether Ghostty is drawing a mouse selection or the keyboard copy mode
    /// is active; the opaque patches would hide that highlight, so the
    /// overlay steps aside until the selection ends.
    private var selectionIsActive: Bool {
        view.isKeyboardCopyModeActive || view.terminalMathSurfaceHasSelection()
    }

    /// Whether display math on `placement` may overhang its neighbour rows:
    /// both the row above and the row below the first segment are blank (or
    /// off the grid), so the overhang cannot paint over unpatched text.
    private static func allowsOverhang(for placement: TerminalMathPlacement, rows: [String]) -> Bool {
        func isBlank(_ row: Int) -> Bool {
            guard rows.indices.contains(row) else { return true }
            return rows[row].allSatisfy(\.isWhitespace)
        }
        return isBlank(placement.row - 1) && isBlank(placement.row + 1)
    }

    /// Rebuilds the overlay model from `lastPlacements` and the raster cache,
    /// kicking off bounded async rasters for anything not yet cached and not
    /// known to be rejected or in backoff.
    private func syncOverlay(frame: MobileTerminalRenderGridFrame, rows: [String]) {
        let overlay = view.terminalMathOverlayView
        guard !lastPlacements.isEmpty,
              let metrics = view.terminalMathGridMetrics(),
              let fontSizePt = rasterFontSizePoints(cellHeight: metrics.cellHeight) else {
            clearPlacements()
            return
        }

        let backgroundColor = view.backgroundColor ?? GhosttyApp.shared.defaultBackgroundColor
        let foregroundColor = frame.terminalForeground.flatMap { NSColor(hex: $0) }
            ?? GhosttyApp.shared.defaultForegroundColor
        let scale = view.window?.backingScaleFactor ?? 2
        let colorHex = foregroundColor.hexString()
        let now = Self.now()
        let rasterizer = TerminalMathRasterizer.shared

        var items: [TerminalMathOverlayModel.Item] = []
        var rejectedByFit: [TerminalMathPlacement] = []
        var rejectedByRaster: [TerminalMathPlacement] = []
        var liveKeys: Set<RasterKey> = []
        for placement in lastPlacements {
            let key = RasterKey(
                source: placement.source,
                isDisplay: placement.isDisplay,
                fontSizePt: fontSizePt,
                colorHex: colorHex,
                scale: scale
            )
            liveKeys.insert(key)
            if rasterizer.isCachedRejection(
                source: placement.source,
                isDisplay: placement.isDisplay,
                fontSizePt: fontSizePt,
                color: foregroundColor,
                scale: scale
            ) {
                rejectedByRaster.append(placement)
                continue
            }
            guard let raster = rasterizer.cachedRaster(
                source: placement.source,
                isDisplay: placement.isDisplay,
                fontSizePt: fontSizePt,
                color: foregroundColor,
                scale: scale
            ) else {
                if let failed = failedKeys[key], now < failed.retryNotBefore {
                    continue
                }
                requestRaster(key: key, color: foregroundColor)
                continue
            }
            let size = TerminalMathOverlayLayout.RasterSize(
                widthPt: raster.widthPt,
                heightPt: raster.heightPt,
                baselinePt: raster.baselinePt
            )
            guard let layout = TerminalMathOverlayLayout.frame(
                for: placement,
                raster: size,
                metrics: metrics,
                isDisplay: placement.isDisplay,
                allowsOverhang: placement.isDisplay && Self.allowsOverhang(for: placement, rows: rows)
            ) else {
                rejectedByFit.append(placement)
                continue
            }
            items.append(TerminalMathOverlayModel.Item(
                patchRects: layout.patchRects,
                imageRect: layout.imageRect,
                image: raster.image
            ))
        }
        lastRejectedByFit = rejectedByFit
        lastRejectedByRaster = rejectedByRaster
        // Backoff entries only matter while their placement is on screen.
        failedKeys = failedKeys.filter { liveKeys.contains($0.key) }

        if overlay.frame != view.bounds {
            overlay.frame = view.bounds
        }
        overlay.model = TerminalMathOverlayModel(items: items, backgroundColor: backgroundColor)
        isHiddenForSelection = !items.isEmpty && selectionIsActive
        overlay.isHidden = items.isEmpty || isHiddenForSelection
    }

    private func requestRaster(key: RasterKey, color: NSColor) {
        guard !inFlightRasterKeys.contains(key),
              inFlightRasterKeys.count < Self.maxInFlightRasters else { return }
        inFlightRasterKeys.insert(key)
        Task { @MainActor [weak self] in
            let raster = await TerminalMathRasterizer.shared.raster(
                source: key.source,
                isDisplay: key.isDisplay,
                fontSizePt: key.fontSizePt,
                color: color,
                scale: key.scale
            )
            guard let self else { return }
            self.inFlightRasterKeys.remove(key)
            guard raster != nil else {
                // A cached rejection is skipped by the next sync; anything
                // else is transient, so back off before asking again.
                let delay = self.failedKeys[key].map { min($0.delay * 2, Self.maxRetryDelay) }
                    ?? Self.initialRetryDelay
                self.failedKeys[key] = (retryNotBefore: Self.now() + delay, delay: delay)
                return
            }
            self.failedKeys.removeValue(forKey: key)
            // A completion only triggers another scan; that scan re-reads the
            // grid so a placement that has since scrolled away is not painted.
            self.apply(.rasterReady(now: Self.now()))
        }
    }

    // MARK: - Font size

    /// Ratio of a typical monospace terminal font's x-height to its em size
    /// (Menlo, SF Mono, JetBrains Mono sit between 0.52 and 0.55).
    private static let terminalXHeightEm: CGFloat = 0.52
    /// KaTeX_Main x-height in em.
    private static let katexXHeightEm: CGFloat = 0.431
    /// Cell height / point size Ghostty produces for typical monospace fonts,
    /// where cell height = ascent + descent + line gap. Only used when the
    /// runtime font size cannot be read.
    private static let cellHeightPerPoint: CGFloat = 1.2

    /// KaTeX font size in points for the surface's current zoom.
    ///
    /// The terminal's live point size comes straight from Ghostty via
    /// `GhosttySurfaceRuntimeProbe.currentSurfaceFontSizePoints`, which reads
    /// `ghostty_surface_font_size` (post global magnification, post per-surface
    /// zoom); this is the same source `fontSizeLineageSnapshot` trusts. When
    /// the surface is not live the size is derived from the cell height with
    /// the ``cellHeightPerPoint`` approximation. Either way the value is
    /// multiplied by ``terminalXHeightEm`` / ``katexXHeightEm`` so KaTeX's
    /// lowercase letters match the height of the terminal's.
    private func rasterFontSizePoints(cellHeight: CGFloat) -> CGFloat? {
        let terminalPoints: CGFloat
        if let live = view.terminalSurface?.liveSurfaceForGhosttyAccess(reason: "terminalMathFontSize"),
           let points = GhosttySurfaceRuntimeProbe.currentSurfaceFontSizePoints(live) {
            terminalPoints = CGFloat(points)
        } else if cellHeight > 0 {
            terminalPoints = cellHeight / Self.cellHeightPerPoint
        } else {
            return nil
        }
        let scaled = terminalPoints * (Self.terminalXHeightEm / Self.katexXHeightEm)
        guard scaled.isFinite, scaled > 0 else { return nil }
        // Round to a tenth so the raster cache is not fragmented by float noise.
        return (scaled * 10).rounded() / 10
    }

#if DEBUG
    /// Multi-line description of the controller state for the Debug menu.
    func debugDump() -> String {
        var lines: [String] = []
        lines.append(
            "terminalMath enabled=\(isEnabled) demand=\(releaseDemand != nil) " +
            "inFlight=\(inFlightRasterKeys.count) backoff=\(failedKeys.count) " +
            "overlayHidden=\(view.terminalMathOverlayView.isHidden) hiddenForSelection=\(isHiddenForSelection) " +
            "items=\(view.terminalMathOverlayView.model.items.count)"
        )
        lines.append(
            "policy candidate=\(policy.hasCandidate) placements=\(policy.hasPlacements) " +
            "demandRetained=\(policy.demandRetained) idleFrameScans=\(policy.idleFrameScans) " +
            "trailingPending=\(policy.trailingScanPending) " +
            "activeScan=\(policy.activeScanReason.map { "\($0)" } ?? "none") " +
            "lastScanAt=\(policy.lastScanAt.map { "\($0)" } ?? "never")"
        )
        if let metrics = view.terminalMathGridMetrics() {
            lines.append(
                "metrics cell=\(metrics.cellWidth)x\(metrics.cellHeight) inset=\(metrics.xInset),\(metrics.yInset) " +
                "fontPt=\(rasterFontSizePoints(cellHeight: metrics.cellHeight).map { "\($0)" } ?? "nil")"
            )
        }
        for placement in lastPlacements {
            lines.append(
                "placement row=\(placement.row) cols=\(placement.startColumn)..<\(placement.endColumn) " +
                "wrapped=\(placement.continuationRows.count) display=\(placement.isDisplay) " +
                "fitRejected=\(lastRejectedByFit.contains(placement)) " +
                "rasterRejected=\(lastRejectedByRaster.contains(placement)) source=\(placement.source)"
            )
        }
        if let reason = TerminalMathRasterizer.shared.lastRejectionReason {
            lines.append("rasterizer lastRejectionReason=\(reason)")
        }
        return lines.joined(separator: "\n")
    }
#endif
}
