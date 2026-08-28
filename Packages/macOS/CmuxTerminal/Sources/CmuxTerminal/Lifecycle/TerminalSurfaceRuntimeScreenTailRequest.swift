internal import Foundation
internal import GhosttyKit

/// A bounded native screen-tail read serialized with native surface teardown.
///
/// The raw surface pointer remains owned by its ``TerminalSurface``. The runtime
/// coordinator executes this request without suspension, so an enqueued native
/// free cannot interleave after the read begins. `@unchecked Sendable` is
/// limited to transporting that borrowed pointer onto the coordinator actor.
struct TerminalSurfaceRuntimeScreenTailRequest: @unchecked Sendable {
    static let maximumRows = 10_000
    static let maximumBytes = 4 * 1024 * 1024

    let surface: ghostty_surface_t
    let maxRows: Int
    let maxBytes: Int

    func read() -> String? {
        guard maxRows > 0,
              maxRows <= Self.maximumRows,
              maxBytes > 0,
              maxBytes <= Self.maximumBytes else {
            return nil
        }
        var text = ghostty_text_s()
        guard ghostty_surface_read_screen_tail_vt(
            surface,
            UInt(maxRows),
            UInt(maxBytes),
            &text
        ) else {
            return nil
        }
        defer { ghostty_surface_free_text(surface, &text) }

        guard let bytes = text.text,
              let byteCount = Int(exactly: text.text_len),
              byteCount > 0,
              byteCount <= maxBytes else {
            return nil
        }
        return String(bytes: Data(bytes: bytes, count: byteCount), encoding: .utf8)
    }
}
