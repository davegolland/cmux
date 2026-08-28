import AppKit
import CmuxSwiftRender
import CmuxSwiftRenderUI
import Foundation
import OSLog

/// Serial lane for in-process `cmux(...)` sidebar actions. Worker-lane methods
/// (browser JS, waits) must run off the main actor: on the main actor they
/// starve SwiftUI and deadlock on a not-yet-mounted webview, which is exactly
/// why they were moved off the main-actor dispatch path. Running the whole
/// action on one serial queue keeps every command in its authored order, so a
/// later command can't finish before an earlier browser navigate/click/wait.
private let cmuxSidebarWorkerQueue = DispatchQueue(label: "com.cmux.sidebar-action-worker")

/// Select-burst coalescing lives in ``SidebarSelectCoalescer``
/// (CmuxSwiftRenderUI), where its FIFO/newest-wins semantics are unit-tested.
private let sidebarSelectCoalescer = SidebarSelectCoalescer()
private let sidebarActionLogger = Logger(subsystem: "com.cmuxterm.app", category: "SidebarActions")

/// Bounds work waiting for the in-process action lane. A sidebar can receive
/// an unbounded stream of UI events while a workspace switch or browser
/// operation is in flight. Without admission control, each event retains its
/// command payload and grows the process heap until the worker catches up.
private final class SidebarActionBackpressure: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = 0
    private let maximumPending: Int

    init(maximumPending: Int) {
        self.maximumPending = max(1, maximumPending)
    }

    func reserve() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard pending < maximumPending else { return false }
        pending += 1
        return true
    }

    func release() {
        lock.lock()
        pending = max(0, pending - 1)
        lock.unlock()
    }
}

private let sidebarActionBackpressure = SidebarActionBackpressure(maximumPending: 256)

// The custom-sidebar rendering, interpreter, JSON DSL, resizable split, and
// the file-watching model now live in the `CmuxSwiftRender` (logic) and
// `CmuxSwiftRenderUI` (SwiftUI) packages. The app target keeps only the
// cmux-coupled action dispatch, the one piece that must reach
// `TerminalController`, and injects it into the package's view from
// `ContentView`.

/// Builds the action sink that runs interpreted sidebar buttons against the
/// live cmux command dispatcher.
///
/// `cmux(...)` commands run in-process through
/// `TerminalController.handleSocketLine(_:)` (the same worker-aware surface the
/// socket CLI uses); `log` is a debug-only no-op for now.
@MainActor
func makeCmuxSidebarActionDispatch() -> SidebarActionDispatch {
    let policy = SidebarActionPolicy.default
    return SidebarActionDispatch { action in
        guard let action = policy.validated(action) else {
            sidebarActionLogger.warning("Rejected custom-sidebar action by capability policy")
            return
        }
        // Convert every command before enqueueing the first one. The socket
        // bridge accepts a wider Foundation value shape than the sidebar
        // policy, so a malformed later parameter must reject the whole action
        // instead of allowing earlier commands to run.
        guard let preparedCommands = prepareSidebarCommands(action.commands) else {
            sidebarActionLogger.warning("Rejected malformed custom-sidebar action payload")
            return
        }
        // Capture the controller on the main actor, then run the whole command
        // sequence on the serial worker queue so the commands keep their authored
        // order. handleSocketLine runs worker-lane methods (browser JS, waits) on
        // this thread and hops main-actor methods back to the main actor itself,
        // so nothing here blocks SwiftUI and ordering is preserved end to end.
        let controller = TerminalController.shared
        let selectGeneration = sidebarSelectCoalescer.generation(for: action.commands)
        guard sidebarActionBackpressure.reserve() else {
            sidebarActionLogger.warning("Dropped custom-sidebar action because the action queue is full")
            return
        }
        cmuxSidebarWorkerQueue.async {
            defer { sidebarActionBackpressure.release() }
            // A newer select is already queued behind this one: skip the heavy
            // switch, the burst's final click defines the end state.
            if let selectGeneration, !sidebarSelectCoalescer.isCurrent(selectGeneration) {
                return
            }
            for command in preparedCommands {
                switch command {
                case let .socketLine(line):
                    _ = controller.handleSocketLine(line)
                case let .openURL(url):
                    // NSWorkspace.open is main-only; run it synchronously to keep the
                    // command's position in the sequence.
                    DispatchQueue.main.sync { _ = NSWorkspace.shared.open(url) }
                case .log:
                    break
                }
            }
        }
    }
}

private enum PreparedSidebarCommand: Sendable {
    case socketLine(String)
    case openURL(URL)
    case log
}

/// Converts the string-only action representation into the exact values sent
/// to the socket dispatcher. This is a complete preflight: no command is
/// executed until every command has a valid, bounded wire representation.
private func prepareSidebarCommands(_ commands: [ActionCommand]) -> [PreparedSidebarCommand]? {
    var prepared: [PreparedSidebarCommand] = []
    prepared.reserveCapacity(commands.count)

    for command in commands {
        switch command {
        case let .cmux(method, params):
            var payload: [String: Any] = ["method": method, "id": UUID().uuidString]
            if !params.isEmpty {
                var typed: [String: Any] = [:]
                typed.reserveCapacity(params.count)
                for (key, value) in params {
                    if let intValue = Int(value) {
                        typed[key] = intValue
                    } else if value.hasPrefix("[") {
                        guard let data = value.data(using: .utf8),
                              SidebarJSONGuard.isBoundedSyntax(
                                  data,
                                  maximumDepth: SidebarSecurityLimits.maxDSLDepth,
                                  maximumTokens: 200_000
                              ),
                              let raw = try? JSONSerialization.jsonObject(with: data),
                              SidebarJSONGuard.isBoundedObject(
                                  raw,
                                  maximumBytes: SidebarSecurityLimits.maxActionParameterValueBytes,
                                  maximumCollectionItems: SidebarSecurityLimits.maxSceneChildren
                              ),
                              let array = raw as? [Any],
                              array.count <= SidebarSecurityLimits.maxSceneChildren,
                              array.allSatisfy({ element in
                                  guard let string = element as? String else { return false }
                                  return !string.isEmpty
                                      && string.utf8.count <= SidebarSecurityLimits.maxIdentifierBytes
                                      && !string.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
                              }) else {
                            return nil
                        }
                        typed[key] = array
                    } else {
                        typed[key] = value
                    }
                }
                payload["params"] = typed
            }
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  data.count <= SidebarSecurityLimits.maxActionJSONBytes,
                  let line = String(data: data, encoding: .utf8) else { return nil }
            prepared.append(.socketLine(line))
        case let .openURL(urlString):
            guard let url = URL(string: urlString) else { return nil }
            prepared.append(.openURL(url))
        case .log:
            prepared.append(.log)
        }
    }
    return prepared
}
