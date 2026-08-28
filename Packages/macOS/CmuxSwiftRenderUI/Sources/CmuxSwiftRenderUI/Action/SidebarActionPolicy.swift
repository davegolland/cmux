import Foundation
import CmuxSwiftRender

/// Capability policy for commands emitted by an authored sidebar.
///
/// Custom sidebar files are data supplied to cmux, not a second trusted app.
/// The default policy permits the workspace and surface controls used by the
/// bundled examples and rejects commands that can read credentials, automate a
/// browser, execute remote or VM work, inject terminal input, or alter debug
/// state. The app applies this policy immediately before the socket boundary.
public struct SidebarActionPolicy: Sendable, Equatable {
    /// Commands needed by the supported workspace and agent-panel examples.
    public static let defaultAllowedMethods: Set<String> = [
        "pane.focus",
        "surface.focus",
        "window.focus",
        "workspace.action",
        "workspace.close",
        "workspace.group.action",
        "workspace.group.add",
        "workspace.group.collapse",
        "workspace.group.create",
        "workspace.group.expand",
        "workspace.group.remove",
        "workspace.group.rename",
        "workspace.move_to_window",
        "workspace.reorder",
        "workspace.reorder_many",
        "workspace.select",
    ]

    private let allowedMethods: Set<String>

    private static let allowedWorkspaceActions: Set<String> = [
        "pin", "unpin", "rename", "clear_name",
        "set_description", "clear_description",
        "move_up", "move_down", "move_top",
        "close_others", "close_above", "close_below",
        "mark_read", "mark_unread", "set_color", "clear_color",
    ]

    private static let allowedGroupActions: Set<String> = [
        "pin", "unpin", "ungroup", "delete",
    ]

    /// Creates a policy with an explicit method set. The app uses
    /// ``defaultAllowedMethods``; the initializer is useful to hosts and tests
    /// that need a narrower capability set.
    public init(allowedMethods: Set<String> = SidebarActionPolicy.defaultAllowedMethods) {
        self.allowedMethods = allowedMethods
    }

    /// The least-privilege policy used by the cmux custom-sidebar host.
    public static let `default` = SidebarActionPolicy()

    /// Returns the action when every command satisfies the policy. The whole
    /// action is rejected when one command is invalid, avoiding partial button
    /// execution.
    public func validated(_ action: ButtonAction) -> ButtonAction? {
        guard !action.commands.isEmpty,
              action.commands.count <= SidebarSecurityLimits.maxActionCommands else {
            return nil
        }

        for command in action.commands {
            switch command {
            case let .cmux(method, params):
                guard isSafeMethod(method), validParameters(params), validAction(method: method, params: params) else {
                    return nil
                }
            case let .openURL(url):
                guard isSafeURL(url) else { return nil }
            case let .log(message):
                guard validLogMessage(message) else { return nil }
            }
        }
        return action
    }

    /// Whether a command method is part of the explicit capability set.
    public func isSafeMethod(_ method: String) -> Bool {
        guard method.utf8.count <= SidebarSecurityLimits.maxActionMethodBytes,
              !method.isEmpty,
              method.unicodeScalars.allSatisfy({ scalar in
                  scalar == "." || scalar == "-" || scalar == "_"
                      || CharacterSet.alphanumerics.contains(scalar)
              }) else {
            return false
        }
        return allowedMethods.contains(method)
    }

    private func validParameters(_ params: [String: String]) -> Bool {
        guard params.count <= SidebarSecurityLimits.maxActionParameters else { return false }
        return params.allSatisfy { key, value in
            guard key.utf8.count <= SidebarSecurityLimits.maxActionParameterKeyBytes,
                  !key.isEmpty,
                  key.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
                  value.utf8.count <= SidebarSecurityLimits.maxActionParameterValueBytes else {
                return false
            }
            return value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
        }
    }

    private func validAction(method: String, params: [String: String]) -> Bool {
        switch method {
        case "workspace.action":
            guard let action = params["action"] else { return false }
            return Self.allowedWorkspaceActions.contains(action)
        case "workspace.group.action":
            guard let action = params["action"] else { return false }
            return Self.allowedGroupActions.contains(action)
        default:
            return true
        }
    }

    private func isSafeURL(_ value: String) -> Bool {
        guard value.utf8.count <= SidebarSecurityLimits.maxActionURLBytes,
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else {
            return false
        }
        return value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    private func validLogMessage(_ value: String) -> Bool {
        value.utf8.count <= SidebarSecurityLimits.maxActionLogBytes
            && value.unicodeScalars.allSatisfy { scalar in
                !CharacterSet.controlCharacters.contains(scalar)
                    || scalar == "\n" || scalar == "\t"
            }
    }
}
