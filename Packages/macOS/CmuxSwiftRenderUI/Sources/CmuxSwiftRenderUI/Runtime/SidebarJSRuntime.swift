import CmuxSwiftRender
import Foundation
import JavaScriptCore
import Observation
import OSLog

private let sidebarJSRuntimeLogger = Logger(subsystem: "com.cmuxterm.app", category: "SidebarJSRuntime")

private enum SidebarRuntimeFailure: Equatable, Sendable {
    case contextUnavailable
    case watchdogUnavailable
    case preludeUnavailable
    case sourceTooLarge
    case script(line: Int32?)
    case sceneLimit
    case missingRoot

    var userMessage: String {
        switch self {
        case .contextUnavailable, .watchdogUnavailable:
            return String(
                localized: "sidebar.custom.runtime.unavailable",
                defaultValue: "This sidebar could not start safely.",
                bundle: .module
            )
        case .preludeUnavailable:
            return String(
                localized: "sidebar.custom.runtime.missing",
                defaultValue: "Sidebar runtime support is missing.",
                bundle: .module
            )
        case .sourceTooLarge:
            return String(
                localized: "sidebar.custom.runtime.sourceTooLarge",
                defaultValue: "This sidebar file is too large.",
                bundle: .module
            )
        case let .script(line):
            if let line, line > 0 {
                return String(
                    format: String(
                        localized: "sidebar.custom.runtime.scriptFailedLine",
                        defaultValue: "Sidebar script failed near line %d.",
                        bundle: .module
                    ),
                    line
                )
            }
            return String(
                localized: "sidebar.custom.runtime.scriptFailed",
                defaultValue: "Sidebar script failed. Check the sidebar source.",
                bundle: .module
            )
        case .sceneLimit:
            return String(
                localized: "sidebar.custom.runtime.resourceLimit",
                defaultValue: "This sidebar exceeded its resource limit.",
                bundle: .module
            )
        case .missingRoot:
            return String(
                localized: "sidebar.custom.runtime.noView",
                defaultValue: "This sidebar did not create a view.",
                bundle: .module
            )
        }
    }
}

/// Validation callbacks are synchronous today, but JavaScriptCore does not
/// promise that callback delivery will always stay on the calling thread.
/// Every mutable field is protected so the unchecked Sendable boundary remains
/// valid if that implementation detail changes.
private final class SidebarValidationState: @unchecked Sendable {
    private let lock = NSLock()
    private var firstFailure: SidebarRuntimeFailure?
    private var firstDiagnostic: String?
    private var sawRoot = false

    func recordFailure(_ failure: SidebarRuntimeFailure, diagnostic: String?) {
        lock.lock()
        defer { lock.unlock() }
        guard firstFailure == nil else { return }
        firstFailure = failure
        firstDiagnostic = diagnostic.map {
            SidebarSecurityLimits.boundedString(
                $0,
                maxBytes: SidebarSecurityLimits.maxDiagnosticComponentBytes
            )
        }
    }

    func recordRoot() {
        lock.lock()
        sawRoot = true
        lock.unlock()
    }

    func snapshot() -> (failure: SidebarRuntimeFailure?, diagnostic: String?, sawRoot: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (firstFailure, firstDiagnostic, sawRoot)
    }
}

/// JavaScriptCore may report an exception from the evaluator thread when a
/// watchdog interrupts execution. Recording first and applying on the owning
/// main-actor turn avoids `MainActor.assumeIsolated` becoming a crash path for
/// hostile script.
private final class SidebarRuntimeFailureState: @unchecked Sendable {
    private let lock = NSLock()
    private var failure: SidebarRuntimeFailure?
    private var diagnostic: String?

    func record(_ failure: SidebarRuntimeFailure, diagnostic: String?) {
        lock.lock()
        defer { lock.unlock() }
        guard self.failure == nil else { return }
        self.failure = failure
        self.diagnostic = diagnostic.map {
            SidebarSecurityLimits.boundedString(
                $0,
                maxBytes: SidebarSecurityLimits.maxDiagnosticComponentBytes
            )
        }
    }

    func clear() {
        lock.lock()
        failure = nil
        diagnostic = nil
        lock.unlock()
    }

    func take() -> (failure: SidebarRuntimeFailure, diagnostic: String?)? {
        lock.lock()
        defer { lock.unlock() }
        guard let failure else { return nil }
        let result = (failure: failure, diagnostic: diagnostic)
        self.failure = nil
        self.diagnostic = nil
        return result
    }
}

/// Hosts one sidebar program in a JavaScriptCore context and connects it to a
/// ``SceneStore``.
///
/// Lifecycle: the program runs ONCE (`start`), builds the retained scene, and
/// registers signal subscriptions on host data. After that the host only calls
/// `updateData` (per changed key) and `dispatchEvent` (taps, moves); the JS
/// side re-runs exactly the effects that depend on what changed and emits
/// minimal scene ops back. There is no per-tick re-evaluation.
///
/// Containment: the context gets no filesystem, network, or timer capability;
/// the only injected host functions are the scene-op sink, the action sink,
/// and a log. A watchdog (`JSContextGroupSetExecutionTimeLimit`) terminates
/// any single evaluation that runs longer than ``executionTimeLimit`` seconds,
/// so a hostile or buggy program degrades to an error state instead of
/// hanging the process.
@MainActor
@Observable
public final class SidebarJSRuntime {
    public let store = SceneStore()
    /// Set when the program threw (load, data update, or event). The host view
    /// shows this instead of the scene.
    public private(set) var errorMessage: String?
    /// Runs captured commands (cmux/openURL/log) on the host command surface.
    @ObservationIgnored public var dispatch: SidebarActionDispatch = .noop

    @ObservationIgnored private let watchdog: JSWatchdog
    @ObservationIgnored private let failureState = SidebarRuntimeFailureState()
    @ObservationIgnored private var context: JSContext?
    @ObservationIgnored private var setDataFunction: JSValue?
    @ObservationIgnored private var dispatchFunction: JSValue?
    nonisolated static let executionTimeLimit = 0.25

    public init() {
        watchdog = .system
    }

    /// Injectable initializer used by deterministic package tests.
    init(watchdog: JSWatchdog) {
        self.watchdog = watchdog
    }

    /// Loads the prelude and runs `source`. Returns false (and sets
    /// ``errorMessage``) when the program fails to produce a scene root.
    @discardableResult
    public func start(source: String) -> Bool {
        errorMessage = nil
        failureState.clear()
        setDataFunction = nil
        dispatchFunction = nil
        store.reset()
        guard source.utf8.count <= SidebarSecurityLimits.maxSourceBytes else {
            setFailure(.sourceTooLarge)
            return false
        }
        guard let context = JSContext() else {
            setFailure(.contextUnavailable)
            return false
        }
        self.context = context
        guard installWatchdog(context) else {
            setFailure(.watchdogUnavailable)
            return false
        }

        // Exceptions surface synchronously during evaluate/call, and every
        // entry point of this class is main-actor, so the handler runs on the
        // main actor; assumeIsolated keeps the errorMessage write synchronous
        // (the start() error checks below rely on that).
        let failureState = self.failureState
        context.exceptionHandler = { _, exception in
            // Do not inspect properties or call `toString()` on an arbitrary
            // thrown object. Authored JavaScript can throw a Proxy or an
            // object with hostile getters/toString methods; touching either
            // from the exception callback would re-enter the untrusted
            // interpreter while it is already unwinding. Keep diagnostics
            // deliberately generic and preserve the fail-closed state.
            _ = exception
            failureState.record(.script(line: nil), diagnostic: "script exception")
        }

        let applyOps: @convention(block) (String) -> Void = { [weak self, failureState] json in
            // JavaScriptCore normally calls a bridge synchronously on the
            // evaluator thread. Treat a future/off-main callback as hostile
            // input instead of using `assumeIsolated` and risking a process
            // crash. The next owning-actor entry point presents a safe error.
            guard Thread.isMainThread else {
                failureState.record(.script(line: nil), diagnostic: "sidebar host callback was off the main thread")
                return
            }
            MainActor.assumeIsolated {
                guard let self else { return }
                if !self.store.apply(opsJSON: json) {
                    self.setFailure(.sceneLimit, diagnostic: "scene operation batch rejected")
                }
            }
        }
        let action: @convention(block) (String) -> Void = { [weak self, failureState] json in
            guard Thread.isMainThread else {
                failureState.record(.script(line: nil), diagnostic: "sidebar action callback was off the main thread")
                return
            }
            MainActor.assumeIsolated {
                self?.runAction(json: json)
            }
        }
        let log: @convention(block) (String) -> Void = { message in
            #if DEBUG
            sidebarJSRuntimeLogger.debug("sidebar diagnostic: \(message, privacy: .private)")
            #endif
        }
        context.setObject(applyOps, forKeyedSubscript: "__host_applyOps" as NSString)
        context.setObject(action, forKeyedSubscript: "__host_action" as NSString)
        context.setObject(log, forKeyedSubscript: "__host_log" as NSString)

        guard let preludeURL = Bundle.module.url(forResource: "SidebarRuntime", withExtension: "js"),
              let prelude = try? String(contentsOf: preludeURL, encoding: .utf8) else {
            setFailure(.preludeUnavailable)
            return false
        }
        context.evaluateScript(prelude, withSourceURL: URL(fileURLWithPath: "SidebarRuntime.js"))
        applyPendingFailure()
        if errorMessage != nil { return false }

        // Keep callable JSValue references for host updates, then remove every
        // bridge name from the global object before authored source executes.
        // The prelude captured its own host closures lexically, so this does
        // not interrupt normal operation.
        setDataFunction = context.objectForKeyedSubscript("__setData")
        dispatchFunction = context.objectForKeyedSubscript("__dispatch")
        context.evaluateScript(
            "for (const key of ['__host_applyOps','__host_action','__host_log','__setData','__dispatch']) { try { delete globalThis[key]; } catch (_) {} globalThis[key] = undefined; }"
        )
        context.evaluateScript(source, withSourceURL: URL(fileURLWithPath: "sidebar.js"))
        applyPendingFailure()
        if errorMessage != nil { return false }
        if store.rootId == nil, errorMessage == nil {
            setFailure(.missingRoot)
        }
        return errorMessage == nil
    }

    /// Pushes one changed data key into the runtime. JSON-encodes `value`
    /// through the plain-JSON reading of ``SwiftValue``.
    public func updateData(key: String, value: SwiftValue) {
        guard errorMessage == nil,
              !key.isEmpty,
              key.utf8.count <= SidebarSecurityLimits.maxIdentifierBytes,
              !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let setDataFunction else { return }
        guard let json = Self.jsonString(value) else {
            setFailure(.sceneLimit, diagnostic: "data value could not be bounded")
            return
        }
        guard json.utf8.count <= SidebarSecurityLimits.maxDataJSONBytes else {
            setFailure(.sceneLimit, diagnostic: "data value exceeded limit")
            return
        }
        setDataFunction.call(withArguments: [key, json])
        applyPendingFailure()
    }

    /// Delivers a UI event (tap, move) to the node's JS handler.
    public func dispatchEvent(nodeId: String, event: String, payload: [String: Any] = [:]) {
        guard errorMessage == nil,
              !nodeId.isEmpty,
              !event.isEmpty,
              nodeId.utf8.count <= SidebarSecurityLimits.maxIdentifierBytes,
              event.utf8.count <= SidebarSecurityLimits.maxIdentifierBytes,
              !nodeId.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !event.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let dispatchFunction else { return }
        guard SidebarJSONGuard.isBoundedObject(
            payload,
            maximumBytes: SidebarSecurityLimits.maxEventJSONBytes,
            maximumCollectionItems: SidebarSecurityLimits.maxSceneChildren
        ),
        let data = try? JSONSerialization.data(withJSONObject: payload),
        let json = String(data: data, encoding: .utf8) else {
            setFailure(.sceneLimit, diagnostic: "event payload is not a bounded JSON object")
            return
        }
        guard json.utf8.count <= SidebarSecurityLimits.maxEventJSONBytes else {
            setFailure(.sceneLimit, diagnostic: "event payload exceeded limit")
            return
        }
        dispatchFunction.call(withArguments: [nodeId, event, json])
        applyPendingFailure()
    }

    // MARK: - Actions

    private func runAction(json: String) {
        guard errorMessage == nil,
              json.utf8.count <= SidebarSecurityLimits.maxActionJSONBytes else { return }
        guard let data = json.data(using: .utf8),
              SidebarJSONGuard.isBoundedSyntax(data, maximumDepth: SidebarSecurityLimits.maxDSLDepth),
              let raw = try? JSONSerialization.jsonObject(with: data),
              SidebarJSONGuard.isBoundedObject(
                  raw,
                  maximumBytes: SidebarSecurityLimits.maxActionJSONBytes,
                  maximumCollectionItems: SidebarSecurityLimits.maxActionParameters
              ),
              let object = raw as? [String: Any],
              let kind = object["kind"] as? String else { return }
        let action: ButtonAction
        switch kind {
        case "cmux":
            guard let method = object["method"] as? String,
                  !method.isEmpty,
                  method.utf8.count <= SidebarSecurityLimits.maxActionMethodBytes,
                  let rawParams = object["params"] as? [String: Any] else { return }
            let params: [String: String] = Dictionary(uniqueKeysWithValues: rawParams.compactMap { key, value in
                guard let value = value as? String else { return nil }
                return (key, value)
            })
            guard params.count == rawParams.count else { return }
            action = ButtonAction(commands: [.cmux(method: method, params: params)])
        case "openURL":
            guard let url = object["url"] as? String,
                  url.utf8.count <= SidebarSecurityLimits.maxActionURLBytes else { return }
            action = ButtonAction(commands: [.openURL(url)])
        case "log":
            guard let message = object["message"] as? String,
                  message.utf8.count <= SidebarSecurityLimits.maxActionLogBytes else { return }
            action = ButtonAction(commands: [.log(message)])
        default:
            return
        }
        // Deferred one runloop turn ON PURPOSE: the JS handler applies its
        // optimistic scene updates synchronously before calling cmux(...),
        // and a heavy host command (workspace.select swaps terminals) running
        // inside the same turn would block that paint - rapid click-click-
        // click then feels laggy even though the state already flipped.
        // Ordering between queued actions is preserved.
        guard let validated = SidebarActionPolicy.default.validated(action) else { return }
        let dispatch = self.dispatch
        DispatchQueue.main.async { [weak self] in
            guard let self, self.errorMessage == nil else { return }
            dispatch.run(validated)
        }
    }

    // MARK: - Watchdog

    private func installWatchdog(_ context: JSContext) -> Bool {
        watchdog.install(on: context, seconds: Self.executionTimeLimit)
    }

    // MARK: - Failure handling

    private func setFailure(_ failure: SidebarRuntimeFailure, diagnostic: String? = nil) {
        if let diagnostic {
            let bounded = SidebarSecurityLimits.boundedString(
                diagnostic,
                maxBytes: SidebarSecurityLimits.maxDiagnosticComponentBytes
            )
            sidebarJSRuntimeLogger.error("Sidebar runtime failure: \(bounded, privacy: .private)")
        }
        guard errorMessage == nil else { return }
        errorMessage = failure.userMessage
    }

    /// Applies a failure recorded by JavaScriptCore on a non-main callback
    /// thread. Call after every synchronous context entry point.
    private func applyPendingFailure() {
        guard let pending = failureState.take() else { return }
        setFailure(pending.failure, diagnostic: pending.diagnostic)
    }

    // MARK: - Validation

    /// Validates a JS sidebar program without a host: runs it against `state`
    /// in a throwaway context with no-op sinks and returns the first error, or
    /// nil when it produced a scene root. Thread-free (a fresh JSContext is
    /// usable on any thread), so the socket-CLI validator can call it directly.
    nonisolated static func validate(
        source: String,
        state: [String: SwiftValue],
        watchdog: JSWatchdog = .system
    ) -> String? {
        guard source.utf8.count <= SidebarSecurityLimits.maxSourceBytes else {
            return SidebarRuntimeFailure.sourceTooLarge.userMessage
        }
        guard let context = JSContext() else {
            return SidebarRuntimeFailure.contextUnavailable.userMessage
        }
        guard watchdog.install(on: context, seconds: executionTimeLimit) else {
            return SidebarRuntimeFailure.watchdogUnavailable.userMessage
        }

        // Validation is also a public/test-facing entry point. Do not let a
        // caller bypass the same state limits enforced by the live bridge.
        guard state.count <= SidebarSecurityLimits.maxDataKeys,
              state.keys.allSatisfy({ key in
                  !key.isEmpty
                      && key.utf8.count <= SidebarSecurityLimits.maxIdentifierBytes
                      && !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
              }),
              state.values.allSatisfy({ $0.isWithinSecurityLimits() }) else {
            return SidebarRuntimeFailure.sceneLimit.userMessage
        }

        let box = SidebarValidationState()
        context.exceptionHandler = { _, exception in
            // See the live handler above. Validation must not invoke
            // attacker-controlled getters or conversion methods while
            // handling an exception.
            _ = exception
            box.recordFailure(.script(line: nil), diagnostic: "script exception")
        }
        let applyOps: @convention(block) (String) -> Void = { json in
            guard let data = json.data(using: .utf8),
                  data.count <= SidebarSecurityLimits.maxSceneBatchJSONBytes,
                  SidebarJSONGuard.isBoundedSyntax(data),
                  let raw = try? JSONSerialization.jsonObject(with: data),
                  SidebarJSONGuard.isBoundedObject(
                      raw,
                      maximumBytes: SidebarSecurityLimits.maxSceneBatchJSONBytes,
                      maximumCollectionItems: SidebarSecurityLimits.maxSceneOperationsPerBatch,
                      maximumNumberMagnitude: SidebarSecurityLimits.maxSceneNumberMagnitude
                  ),
                  let ops = raw as? [[String: Any]],
                  ops.count <= SidebarSecurityLimits.maxSceneOperationsPerBatch else {
                box.recordFailure(.sceneLimit, diagnostic: "validation scene operation batch rejected")
                return
            }
            if ops.contains(where: { ($0["op"] as? String) == "root" }) {
                box.recordRoot()
            }
        }
        let noop: @convention(block) (String) -> Void = { _ in }
        context.setObject(applyOps, forKeyedSubscript: "__host_applyOps" as NSString)
        context.setObject(noop, forKeyedSubscript: "__host_action" as NSString)
        context.setObject(noop, forKeyedSubscript: "__host_log" as NSString)

        guard let preludeURL = Bundle.module.url(forResource: "SidebarRuntime", withExtension: "js"),
              let prelude = try? String(contentsOf: preludeURL, encoding: .utf8) else {
            return SidebarRuntimeFailure.preludeUnavailable.userMessage
        }
        context.evaluateScript(prelude, withSourceURL: URL(fileURLWithPath: "SidebarRuntime.js"))
        if let result = validationFailure(from: box) { return result }
        let setDataFunction = context.objectForKeyedSubscript("__setData")
        context.evaluateScript(
            "for (const key of ['__host_applyOps','__host_action','__host_log','__setData','__dispatch']) { try { delete globalThis[key]; } catch (_) {} globalThis[key] = undefined; }"
        )
        context.evaluateScript(source, withSourceURL: URL(fileURLWithPath: "sidebar.js"))
        if let result = validationFailure(from: box) { return result }
        for (key, value) in state {
            guard let json = jsonString(value) else {
                return SidebarRuntimeFailure.sceneLimit.userMessage
            }
            guard key.utf8.count <= SidebarSecurityLimits.maxIdentifierBytes,
                  json.utf8.count <= SidebarSecurityLimits.maxDataJSONBytes else {
                return SidebarRuntimeFailure.sceneLimit.userMessage
            }
            setDataFunction?.call(withArguments: [key, json])
            if let result = validationFailure(from: box) { return result }
        }
        if !box.snapshot().sawRoot {
            return SidebarRuntimeFailure.missingRoot.userMessage
        }
        return nil
    }

    private nonisolated static func validationFailure(from box: SidebarValidationState) -> String? {
        let snapshot = box.snapshot()
        if let diagnostic = snapshot.diagnostic {
            sidebarJSRuntimeLogger.error("Sidebar validation failure: \(diagnostic, privacy: .private)")
        }
        return snapshot.failure?.userMessage
    }

    // MARK: - SwiftValue → JSON

    /// The plain-JSON reading of a ``SwiftValue`` (its synthesized Codable form
    /// is tagged and unusable for JS).
    nonisolated static func jsonString(_ value: SwiftValue) -> String? {
        var budget = JSONProjectionBudget()
        guard let object = boundedJSONObject(value, depth: 0, budget: &budget) else { return nil }
        guard JSONSerialization.isValidJSONObject([object]) else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed]) else { return nil }
        guard data.count <= SidebarSecurityLimits.maxDataJSONBytes else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Kept as a small test/debug helper. Production bridge calls use the
    /// bounded optional form below so a malformed value is rejected instead
    /// of being recursively materialized without a budget.
    nonisolated static func jsonObject(_ value: SwiftValue) -> Any {
        var budget = JSONProjectionBudget()
        return boundedJSONObject(value, depth: 0, budget: &budget) ?? NSNull()
    }

    private struct JSONProjectionBudget {
        var nodes = 0
        var stringBytes = 0

        mutating func consumeNode() -> Bool {
            guard nodes < 100_000 else { return false }
            nodes += 1
            return true
        }
    }

    private nonisolated static func boundedJSONObject(
        _ value: SwiftValue,
        depth: Int,
        budget: inout JSONProjectionBudget
    ) -> Any? {
        guard depth <= SidebarSecurityLimits.maxDSLDepth,
              budget.consumeNode() else { return nil }
        switch value {
        case let .int(v): return v
        case let .double(v):
            guard v.isFinite, abs(v) <= SidebarSecurityLimits.maxSceneNumberMagnitude else { return nil }
            return v
        case let .string(v):
            let count = v.utf8.count
            guard count <= SidebarSecurityLimits.maxSceneStringBytes,
                  budget.stringBytes <= SidebarSecurityLimits.maxDataJSONBytes - count else { return nil }
            budget.stringBytes += count
            return v
        case let .bool(v): return v
        case let .range(lower, upper, inclusive):
            return ["lower": lower, "upper": upper, "inclusive": inclusive]
        case let .array(values):
            guard values.count <= SidebarSecurityLimits.maxSceneChildren else { return nil }
            var result: [Any] = []
            result.reserveCapacity(values.count)
            for child in values {
                guard let object = boundedJSONObject(child, depth: depth + 1, budget: &budget) else { return nil }
                result.append(object)
            }
            return result
        case let .object(fields):
            guard fields.count <= SidebarSecurityLimits.maxSceneProperties else { return nil }
            var result: [String: Any] = [:]
            result.reserveCapacity(fields.count)
            for (key, child) in fields {
                guard !key.isEmpty,
                      key.utf8.count <= SidebarSecurityLimits.maxIdentifierBytes,
                      !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                      let object = boundedJSONObject(child, depth: depth + 1, budget: &budget) else { return nil }
                result[key] = object
            }
            return result
        }
    }
}
