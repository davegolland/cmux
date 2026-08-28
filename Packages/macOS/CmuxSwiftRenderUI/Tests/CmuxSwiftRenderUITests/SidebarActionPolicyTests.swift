import CmuxSwiftRender
@testable import CmuxSwiftRenderUI
import Testing

struct SidebarActionPolicyTests {
    private let policy = SidebarActionPolicy.default

    @Test func permitsBundledWorkspaceControls() {
        let action = ButtonAction(commands: [
            .cmux(method: "workspace.select", params: ["workspace_id": "w1"]),
            .cmux(method: "surface.focus", params: ["surface_id": "s1"]),
        ])
        #expect(policy.validated(action) == action)
    }

    @Test func rejectsSensitiveDispatcherMethods() {
        for method in ["auth.sign_out", "browser.eval", "vm.rm", "remote.tmux.attach", "send"] {
            let action = ButtonAction(commands: [.cmux(method: method, params: [:])])
            #expect(policy.validated(action) == nil)
        }
    }

    @Test func rejectsMalformedAndOversizedCommands() {
        #expect(policy.validated(ButtonAction(commands: [
            .cmux(method: "workspace.select\n", params: [:])
        ])) == nil)

        let parameters = Dictionary(uniqueKeysWithValues: (0..<33).map { ("p\($0)", "x") })
        #expect(policy.validated(ButtonAction(commands: [
            .cmux(method: "workspace.select", params: parameters)
        ])) == nil)
    }

    @Test func onlyHttpAndHttpsURLsAreAllowed() {
        #expect(policy.validated(ButtonAction(commands: [.openURL("https://example.com/path")])) != nil)
        #expect(policy.validated(ButtonAction(commands: [.openURL("http://localhost:3000")])) != nil)
        for url in ["file:///tmp/secret", "javascript:alert(1)", "data:text/plain,secret", "https://user:pass@example.com"] {
            #expect(policy.validated(ButtonAction(commands: [.openURL(url)])) == nil)
        }
    }
}
