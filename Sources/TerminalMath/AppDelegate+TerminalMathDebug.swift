#if DEBUG
import AppKit

extension AppDelegate {
    /// Debug menu: logs the focused terminal's math placements, overlay state,
    /// and the rasterizer's last rejection reason through `cmuxDebugLog`.
    @objc func debugDumpTerminalMathPlacements(_ sender: Any?) {
        guard let manager = activeTabManagerForCommands(),
              let panel = manager.selectedWorkspace?.focusedTerminalPanel else {
            cmuxDebugLog("terminalMath.dump: no focused terminal panel")
            return
        }
        let surfaceView = panel.surface.hostedView.surfaceView
        cmuxDebugLog(
            "terminalMath.dump surface=\(panel.surface.id.uuidString.prefix(5))\n"
                + surfaceView.terminalMathController.debugDump()
        )
    }
}
#endif
