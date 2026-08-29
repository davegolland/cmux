import CmuxFoundation
import CmuxTerminal
import Foundation

/// Routes "this surface just received bytes that may contain math" signals
/// from the PTY tee (IO thread) to the owning `GhosttyNSView`'s
/// `TerminalMathSurfaceController` on the main actor.
///
/// The tee raises a per-surface `AtomicBooleanGate` once and hops here; the
/// controller scans the rendered grid on the next frame and calls
/// ``markScanned(surfaceID:)`` so the IO thread can re-arm. Sustained output
/// therefore costs one main-actor hop per grid scan, not one per chunk.
@MainActor
final class TerminalMathCandidateRouter {
    // nonisolated: the singleton itself is an immutable `let` constructed
    // once; the IO thread only ever reads the reference to spawn a
    // main-actor Task, mirroring `MobileTerminalByteTee.shared`.
    nonisolated static let shared = TerminalMathCandidateRouter()

    /// Process-wide off-switch read lock-free on the IO thread before any
    /// byte scanning. Mirrors the `terminal.renderMath` setting; see
    /// ``setEnabled(_:)``.
    nonisolated static let isEnabledGate = AtomicBooleanGate(true)

    /// Per-surface edge flags owned by the tee contexts, keyed by surface id
    /// so the main actor can clear them after each scan.
    private var flagsBySurfaceID: [UUID: AtomicBooleanGate] = [:]
    /// Surfaces with a candidate that has not been scanned yet.
    private var pendingSurfaceIDs = Set<UUID>()

    nonisolated private init() {}

    // MARK: Candidates

    /// Records a candidate for `surfaceID` and asks the surface's controller
    /// to scan on the next rendered frame.
    ///
    /// - Parameters:
    ///   - surfaceID: The terminal surface whose PTY output contained an opener.
    ///   - flag: The tee context's edge flag; stored so ``markScanned(surfaceID:)``
    ///     can re-arm it.
    func noteCandidate(surfaceID: UUID, flag: AtomicBooleanGate) {
        flagsBySurfaceID[surfaceID] = flag
        pendingSurfaceIDs.insert(surfaceID)
        guard Self.isEnabledGate.loadAcquire() else {
            // Disabled between the IO-thread check and this hop: re-arm so a
            // later enable picks the next chunk up.
            markScanned(surfaceID: surfaceID)
            return
        }
        guard let surface = GhosttyApp.terminalSurfaceRegistry.terminalSurface(id: surfaceID) else {
            // The surface is gone (or not yet registered); let the tee re-arm
            // on its next chunk rather than leaving the flag stuck.
            markScanned(surfaceID: surfaceID)
            return
        }
        surface.hostedView.surfaceView.terminalMathController.noteCandidate()
        // The tee fires before Ghostty's VT parser consumes the bytes, so the
        // frame that already rendered may predate them. Schedule a fresh tick
        // to guarantee one post-parse frame notification.
        GhosttyApp.shared.scheduleTick()
    }

    /// Re-arms the surface's edge flag after the controller scanned the grid.
    ///
    /// - Parameter surfaceID: The surface whose scan completed.
    func markScanned(surfaceID: UUID) {
        pendingSurfaceIDs.remove(surfaceID)
        flagsBySurfaceID[surfaceID]?.storeRelease(false)
    }

    /// Whether a candidate is waiting for a scan on `surfaceID`.
    func hasPendingCandidate(surfaceID: UUID) -> Bool {
        pendingSurfaceIDs.contains(surfaceID)
    }

    /// Forgets every flag and pending candidate for a torn-down surface.
    ///
    /// - Parameter surfaceID: The surface id being torn down.
    func dropSurface(surfaceID: UUID) {
        pendingSurfaceIDs.remove(surfaceID)
        flagsBySurfaceID.removeValue(forKey: surfaceID)
    }

    // MARK: Enablement

    /// Flips the process-wide gate and, when turning off, clears every live
    /// surface's overlay so no stale raster stays on screen.
    ///
    /// - Parameter enabled: The new `terminal.renderMath` value.
    static func setEnabled(_ enabled: Bool) {
        isEnabledGate.storeRelease(enabled)
        for surface in GhosttyApp.terminalSurfaceRegistry.allTerminalSurfaces() {
            surface.hostedView.surfaceView.terminalMathController.setEnabled(enabled)
        }
        if !enabled {
            for surfaceID in shared.pendingSurfaceIDs {
                shared.flagsBySurfaceID[surfaceID]?.storeRelease(false)
            }
            shared.pendingSurfaceIDs.removeAll()
        }
    }
}
