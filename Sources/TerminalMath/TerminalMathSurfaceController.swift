import AppKit
import CmuxAgentChat
import CmuxFoundation
import CmuxTerminalCore
import CMUXMobileCore

/// Drives one terminal view's math overlay: scans the rendered grid for
/// delimited LaTeX, rasterizes it, and paints ``TerminalMathOverlayView``.
///
/// Demand is pull-based. The byte tee marks a candidate through
/// `TerminalMathCandidateRouter`, which calls ``noteCandidate()``; the
/// controller then retains the view-local rendered-frame demand and scans on
/// every frame while there is a candidate or a visible placement. Two idle
/// scans with nothing found release the demand again so an idle terminal
/// costs nothing.
@MainActor
final class TerminalMathSurfaceController {
    /// Owning view; the view retains the controller and calls ``invalidate()`` in `deinit`.
    unowned let view: GhosttyNSView

    /// Whether the feature is enabled for this surface.
    private(set) var isEnabled = true
    /// Set by the router when the PTY tee saw a delimiter since the last scan.
    private var hasCandidate = false
    /// Consecutive scans that found nothing while no candidate was pending.
    private var idleScanCount = 0
    /// Placements from the most recent scan.
    private(set) var lastPlacements: [TerminalMathPlacement] = []
    /// Placements dropped by the fit rule in the most recent sync (debug aid).
    private(set) var lastRejectedByFit: [TerminalMathPlacement] = []

    private var releaseDemand: (() -> Void)?
    private var frameObserver: (any NSObjectProtocol)?
    private var appearanceObservers: [any NSObjectProtocol] = []
    private var isScanScheduled = false
    private var inFlightRasterKeys: Set<RasterKey> = []
    private var isInvalidated = false

    /// Upper bound on concurrent raster jobs for one surface.
    private static let maxInFlightRasters = 4
    /// Idle scans before the local rendered-frame demand is released.
    private static let idleScansBeforeRelease = 2

    /// Identity of one raster request, for in-flight deduplication.
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

    /// Marks that the tee saw a math delimiter; arms frame tracking.
    func noteCandidate() {
        guard isEnabled, !isInvalidated else { return }
        hasCandidate = true
        idleScanCount = 0
        retainDemandIfNeeded()
        installFrameObserverIfNeeded()
        installAppearanceObserversIfNeeded()
        scheduleScan()
    }

    /// Called from `GhosttyNSView.layout()`; keeps the overlay sized to the view.
    func viewDidLayout() {
        guard !isInvalidated else { return }
        let overlay = view.terminalMathOverlayView
        if overlay.frame != view.bounds {
            overlay.frame = view.bounds
        }
        guard !lastPlacements.isEmpty else { return }
        scheduleScan()
    }

    /// Enables or disables the overlay. Disabling clears everything and
    /// releases demand; enabling is a no-op until the next candidate.
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        guard !enabled else { return }
        clearPlacements()
        releaseDemandIfNeeded()
        removeObservers()
        hasCandidate = false
    }

    /// Releases demand and observers; safe to call more than once and from `deinit`.
    func invalidate() {
        isInvalidated = true
        releaseDemandIfNeeded()
        removeObservers()
        lastPlacements = []
        lastRejectedByFit = []
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
                guard let self else { return }
                guard self.hasCandidate || !self.lastPlacements.isEmpty else { return }
                self.scheduleScan()
            }
        }
    }

    private func installAppearanceObserversIfNeeded() {
        guard appearanceObservers.isEmpty else { return }
        let center = NotificationCenter.default
        let rescan: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleScan()
            }
        }
        appearanceObservers.append(center.addObserver(
            forName: .ghosttyDefaultBackgroundDidChange, object: nil, queue: .main, using: rescan
        ))
        appearanceObservers.append(center.addObserver(
            forName: .ghosttyConfigDidReload, object: nil, queue: .main, using: rescan
        ))
        appearanceObservers.append(center.addObserver(
            forName: .ghosttyDidUpdateCellSize, object: view, queue: .main, using: rescan
        ))
        appearanceObservers.append(center.addObserver(
            forName: .ghosttyDidUpdateScrollbar, object: view, queue: .main, using: rescan
        ))
        // Theme changes post the surface UUID as the object; match by hand.
        appearanceObservers.append(center.addObserver(
            forName: .ghosttySurfaceThemeDidChange, object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self,
                      let changed = notification.object as? UUID,
                      changed == self.view.terminalSurface?.id else { return }
                self.scheduleScan()
            }
        })
    }

    private func removeObservers() {
        let center = NotificationCenter.default
        if let frameObserver {
            center.removeObserver(frameObserver)
            self.frameObserver = nil
        }
        for observer in appearanceObservers {
            center.removeObserver(observer)
        }
        appearanceObservers.removeAll()
    }

    // MARK: - Scanning

    /// Coalesces scans to one per run-loop turn, like
    /// `MobileTerminalRenderObserver.scheduleTerminalUpdateFlush`.
    private func scheduleScan() {
        guard isEnabled, !isInvalidated, !isScanScheduled else { return }
        isScanScheduled = true
        Task { @MainActor [weak self] in
            self?.isScanScheduled = false
            self?.scan()
        }
    }

    private func scan() {
        guard isEnabled, !isInvalidated else { return }
        let hadCandidate = hasCandidate
        hasCandidate = false
        defer {
            if let surfaceID = view.terminalSurface?.id {
                TerminalMathCandidateRouter.shared.markScanned(surfaceID: surfaceID)
            }
        }

        guard let surface = view.terminalSurface,
              let snapshot = surface.mobileRenderGridFrame(
                stateSeq: 0,
                full: true,
                scrollbackLines: 0,
                includeTheme: false,
                anchor: .viewport
              ) else {
            clearPlacements()
            noteScanResult(foundPlacements: false, hadCandidate: hadCandidate)
            return
        }
        let frame = snapshot.frame
        guard frame.activeScreen != .alternate else {
            clearPlacements()
            noteScanResult(foundPlacements: false, hadCandidate: hadCandidate)
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
        noteScanResult(foundPlacements: !placements.isEmpty, hadCandidate: hadCandidate)
        syncOverlay(frame: frame)
    }

    private func noteScanResult(foundPlacements: Bool, hadCandidate: Bool) {
        if foundPlacements || hadCandidate {
            idleScanCount = 0
            return
        }
        idleScanCount += 1
        if idleScanCount >= Self.idleScansBeforeRelease {
            releaseDemandIfNeeded()
        }
    }

    private func clearPlacements() {
        lastPlacements = []
        lastRejectedByFit = []
        let overlay = view.terminalMathOverlayView
        if !overlay.model.items.isEmpty {
            overlay.model = TerminalMathOverlayModel()
        }
        overlay.isHidden = true
    }

    // MARK: - Overlay sync

    /// Rebuilds the overlay model from `lastPlacements` and the raster cache,
    /// kicking off bounded async rasters for anything not yet cached.
    private func syncOverlay(frame: MobileTerminalRenderGridFrame) {
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

        var items: [TerminalMathOverlayModel.Item] = []
        var rejected: [TerminalMathPlacement] = []
        for placement in lastPlacements {
            let key = RasterKey(
                source: placement.source,
                isDisplay: placement.isDisplay,
                fontSizePt: fontSizePt,
                colorHex: colorHex,
                scale: scale
            )
            guard let raster = TerminalMathRasterizer.shared.cachedRaster(
                source: placement.source,
                isDisplay: placement.isDisplay,
                fontSizePt: fontSizePt,
                color: foregroundColor,
                scale: scale
            ) else {
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
                isDisplay: placement.isDisplay
            ) else {
                rejected.append(placement)
                continue
            }
            items.append(TerminalMathOverlayModel.Item(
                patchRects: layout.patchRects,
                imageRect: layout.imageRect,
                image: raster.image
            ))
        }
        lastRejectedByFit = rejected

        if overlay.frame != view.bounds {
            overlay.frame = view.bounds
        }
        overlay.model = TerminalMathOverlayModel(items: items, backgroundColor: backgroundColor)
        overlay.isHidden = items.isEmpty
    }

    private func requestRaster(key: RasterKey, color: NSColor) {
        guard !inFlightRasterKeys.contains(key),
              inFlightRasterKeys.count < Self.maxInFlightRasters else { return }
        inFlightRasterKeys.insert(key)
        Task { @MainActor [weak self] in
            _ = await TerminalMathRasterizer.shared.raster(
                source: key.source,
                isDisplay: key.isDisplay,
                fontSizePt: key.fontSizePt,
                color: color,
                scale: key.scale
            )
            guard let self else { return }
            self.inFlightRasterKeys.remove(key)
            // A completion only triggers another scan; that scan re-reads the
            // grid so a placement that has since scrolled away is not painted.
            guard !self.lastPlacements.isEmpty || self.hasCandidate else { return }
            self.scheduleScan()
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
            "terminalMath enabled=\(isEnabled) candidate=\(hasCandidate) demand=\(releaseDemand != nil) " +
            "inFlight=\(inFlightRasterKeys.count) overlayHidden=\(view.terminalMathOverlayView.isHidden) " +
            "items=\(view.terminalMathOverlayView.model.items.count)"
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
                "fitRejected=\(lastRejectedByFit.contains(placement)) source=\(placement.source)"
            )
        }
        if let reason = TerminalMathRasterizer.shared.lastRejectionReason {
            lines.append("rasterizer lastRejectionReason=\(reason)")
        }
        return lines.joined(separator: "\n")
    }
#endif
}
