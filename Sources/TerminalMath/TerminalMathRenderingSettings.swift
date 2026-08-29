import CmuxSettings
import Foundation

/// Runtime access to the global `terminal.renderMath` setting.
///
/// The catalog key (`SettingCatalog().terminal.renderMath`) is the single
/// source of truth; this enum adds the app-side conveniences the overlay
/// pipeline needs: a synchronous read, a change broadcast, and a single
/// observer that forwards the value into `TerminalMathCandidateRouter`, which
/// owns the IO-thread gate and every live surface's overlay controller.
///
/// The setting is app-wide. Every entrypoint (Settings row, command palette,
/// `cmux.json` reload, the `toggleTerminalMathRendering` shortcut) writes the
/// same `UserDefaults` key, so ``startObserving()`` listens to
/// `UserDefaults.didChangeNotification` in addition to
/// ``didChangeNotification`` and dedupes by value.
enum TerminalMathRenderingSettings {
    /// `UserDefaults` storage key (`"terminal.renderMath"`).
    static let key = SettingCatalog().terminal.renderMath.userDefaultsKey
    /// Catalog default (`true`).
    static let defaultIsEnabled = SettingCatalog().terminal.renderMath.defaultValue
    /// Posted (object `nil`) after an explicit write through ``setEnabled(_:defaults:notificationCenter:)``
    /// or a command-palette toggle.
    static let didChangeNotification = Notification.Name("cmux.terminalMathRenderingSettingsDidChange")

    /// Current value in the standard defaults.
    static var isEnabled: Bool { isEnabled(defaults: .standard) }

    /// Current value in `defaults`, falling back to the catalog default.
    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        SettingCatalog().terminal.renderMath.value(in: defaults)
    }

    /// Writes `enabled` and broadcasts ``didChangeNotification``.
    static func setEnabled(
        _ enabled: Bool,
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        SettingCatalog().terminal.renderMath.set(enabled, in: defaults)
        notifyDidChange(notificationCenter: notificationCenter)
    }

    /// Flips the setting and returns the new value.
    @discardableResult
    static func toggle(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) -> Bool {
        let next = !isEnabled(defaults: defaults)
        setEnabled(next, defaults: defaults, notificationCenter: notificationCenter)
        return next
    }

    static func notifyDidChange(notificationCenter: NotificationCenter = .default) {
        notificationCenter.post(name: didChangeNotification, object: nil)
    }

    // MARK: - Observation

    @MainActor private static var observers: [NSObjectProtocol] = []
    @MainActor private static var lastAppliedIsEnabled: Bool?
    /// The defaults being observed; kept on the main actor so the notification
    /// closures capture nothing non-Sendable.
    @MainActor private static var observedDefaults: UserDefaults = .standard

    /// Starts forwarding the setting into `TerminalMathCandidateRouter`.
    /// Idempotent; called once from `applicationDidFinishLaunching`. Applies
    /// the current value immediately so a persisted `false` disables the
    /// byte gate before the first terminal opens.
    @MainActor
    static func startObserving(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        guard observers.isEmpty else { return }
        observedDefaults = defaults
        observers.append(notificationCenter.addObserver(
            forName: didChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in applyCurrentValue() }
        })
        // Settings UI writes and cmux.json reloads land in UserDefaults
        // without posting didChangeNotification.
        observers.append(notificationCenter.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { _ in
            Task { @MainActor in applyCurrentValue() }
        })
        applyCurrentValue()
    }

    /// Stops observing; used by tests.
    @MainActor
    static func stopObserving(notificationCenter: NotificationCenter = .default) {
        for observer in observers {
            notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
        lastAppliedIsEnabled = nil
        observedDefaults = .standard
    }

    @MainActor
    private static func applyCurrentValue() {
        let enabled = isEnabled(defaults: observedDefaults)
        guard enabled != lastAppliedIsEnabled else { return }
        lastAppliedIsEnabled = enabled
        TerminalMathCandidateRouter.setEnabled(enabled)
    }
}

/// Runtime access to the global `markdown.renderMath` setting. Open markdown
/// viewers observe `UserDefaults.didChangeNotification` (see `MarkdownPanel`)
/// and push the value into the shell through `window.__cmuxSetMathEnabled`.
enum MarkdownMathRenderingSettings {
    /// `UserDefaults` storage key (`"markdown.renderMath"`).
    static let key = SettingCatalog().markdown.renderMath.userDefaultsKey
    /// Catalog default (`true`).
    static let defaultIsEnabled = SettingCatalog().markdown.renderMath.defaultValue

    /// Current value in the standard defaults.
    static var isEnabled: Bool { isEnabled(defaults: .standard) }

    /// Current value in `defaults`, falling back to the catalog default.
    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        SettingCatalog().markdown.renderMath.value(in: defaults)
    }

    /// Writes `enabled`. Viewers pick the change up via `UserDefaults.didChangeNotification`.
    static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        SettingCatalog().markdown.renderMath.set(enabled, in: defaults)
    }
}
