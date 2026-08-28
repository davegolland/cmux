import Darwin
import Foundation
import JavaScriptCore

/// Installs the JavaScriptCore execution limit used to contain authored code.
///
/// The system implementation resolves Apple's private symbol at runtime. The
/// injectable closure is intentional: tests can exercise the fail-closed path
/// without depending on a particular SDK image, and hosts can provide a
/// platform-specific installer when JavaScriptCore changes.
/// The installer is called synchronously by the owning runtime. The unchecked
/// Sendable marker covers the closure container only; no `JSContext` escapes
/// that call, and the runtime itself remains main-actor isolated.
struct JSWatchdog: @unchecked Sendable {
    typealias Installer = (JSContext, Double) -> Bool
    private let installer: Installer
    private typealias TerminateCallback = @convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool
    private typealias SetLimitFn = @convention(c) (
        JSContextGroupRef?, Double, TerminateCallback?, UnsafeMutableRawPointer?
    ) -> Void

    private static let setLimit: SetLimitFn? = {
        guard let symbol = dlsym(dlopen(nil, RTLD_LAZY), "JSContextGroupSetExecutionTimeLimit") else {
            return nil
        }
        return unsafeBitCast(symbol, to: SetLimitFn.self)
    }()

    /// Creates a watchdog backed by an installer closure.
    init(installer: @escaping Installer) {
        self.installer = installer
    }

    /// The process's JavaScriptCore watchdog implementation.
    static let system = JSWatchdog { context, seconds in
        guard let setLimit else { return false }
        let group = JSContextGetGroup(context.jsGlobalContextRef)
        setLimit(group, seconds, { _, _ in true }, nil)
        return true
    }

    /// Installs the limit on `context`'s group. Returns whether the hard
    /// watchdog is active.
    @discardableResult
    func install(on context: JSContext, seconds: Double) -> Bool {
        installer(context, seconds)
    }

    /// Compatibility entry point for package tests and diagnostics.
    @discardableResult
    static func install(on context: JSContext, seconds: Double) -> Bool {
        system.install(on: context, seconds: seconds)
    }
}
