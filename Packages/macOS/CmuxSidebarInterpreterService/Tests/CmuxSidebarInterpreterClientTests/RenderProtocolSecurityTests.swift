import CmuxSwiftRender
import Foundation
import Testing
@testable import CmuxSidebarInterpreterClient

@Suite("Render protocol security boundaries")
struct RenderProtocolSecurityTests {
    @Test("Rejects non-finite and oversized surface geometry")
    func geometryIsBounded() {
        #expect(!RenderSurfaceGeometry(width: .nan, height: 100, scale: 2).isWithinSecurityLimits())
        #expect(!RenderSurfaceGeometry(width: 10_001, height: 100, scale: 2).isWithinSecurityLimits())
        #expect(!RenderSurfaceGeometry(width: 100, height: 100, scale: .infinity).isWithinSecurityLimits())
        #expect(RenderSurfaceGeometry(width: 100, height: 100, scale: 2).isWithinSecurityLimits())
    }

    @Test("Rejects hostile pointer values")
    func pointerIsBounded() {
        #expect(!RenderPointerEvent(kind: .down, x: .infinity, y: 1).isWithinSecurityLimits())
        #expect(!RenderPointerEvent(kind: .scroll, x: 1, y: 1, deltaY: 100_001).isWithinSecurityLimits())
        #expect(!RenderPointerEvent(kind: .down, x: 1, y: 1, clickCount: 101).isWithinSecurityLimits())
        #expect(RenderPointerEvent(kind: .down, x: 1, y: 1).isWithinSecurityLimits())
    }

    @Test("Requires an absolute supported sidebar path")
    func scenePathIsBounded() {
        let state: [String: SwiftValue] = ["title": .string("safe")]
        #expect(RenderScene(seq: 1, filePath: "sidebar.swift", state: state, topInset: 0, bottomInset: 0).isWithinSecurityLimits() == false)
        #expect(RenderScene(seq: 1, filePath: "/tmp/sidebar.txt", state: state, topInset: 0, bottomInset: 0).isWithinSecurityLimits() == false)
        #expect(RenderScene(seq: 1, filePath: "/tmp/sidebar.swift", state: state, topInset: 0, bottomInset: 0).isWithinSecurityLimits())
    }

    @Test("Rejects oversized source and host values")
    func requestValuesAreBounded() {
        let oversizedSource = String(repeating: "x", count: 1_048_577)
        #expect(!InterpreterRequest(id: 1, source: oversizedSource, state: [:]).isWithinSecurityLimits())

        let oversizedValue = SwiftValue.string(String(repeating: "x", count: 16_385))
        #expect(!InterpreterRequest(id: 1, source: "Text(\"ok\")", state: ["value": oversizedValue]).isWithinSecurityLimits())
    }

    @Test("Rejects a render tree deeper than the native view budget")
    func renderTreeDepthIsBounded() {
        var node = RenderNode(kind: .text, text: "leaf")
        for _ in 0..<65 {
            node = RenderNode(kind: .group, children: [node])
        }
        #expect(!node.isWithinSecurityLimits())

        let wide = RenderNode(
            kind: .group,
            children: Array(repeating: RenderNode(kind: .text, text: "x"), count: 2_049)
        )
        #expect(!wide.isWithinSecurityLimits())
    }

    @Test("Rejects a render tree whose aggregate strings exceed the budget")
    func renderTreeStringBudgetIsBounded() {
        let largeText = String(repeating: "x", count: 16_384)
        let wide = RenderNode(
            kind: .group,
            children: Array(repeating: RenderNode(kind: .text, text: largeText), count: 600)
        )
        #expect(!wide.isWithinSecurityLimits())
    }

    @Test("JSON preflight rejects deep or malformed frames without decoding")
    func jsonFramesAreBounded() {
        let validJSON = String(repeating: "[", count: 64) + String(repeating: "]", count: 64)
        let deepJSON = String(repeating: "[", count: 65) + String(repeating: "]", count: 65)
        let valid = Data(validJSON.utf8)
        let deep = Data(deepJSON.utf8)
        #expect(JSONFrameGuard.isBounded(valid))
        #expect(!JSONFrameGuard.isBounded(deep))
        #expect(!JSONFrameGuard.isBounded(Data(#"{"x":"\q"}"#.utf8)))
        #expect(!JSONFrameGuard.isBounded(Data()))
        #expect(!JSONFrameGuard.isBounded(Data(#"[{]"#.utf8)))
        let manyTokens = Data((String(repeating: "0,", count: JSONFrameGuard.defaultMaximumTokens) + "0").utf8)
        #expect(!JSONFrameGuard.isBounded(manyTokens))
    }

    @Test("Rejects an uninitialized render context")
    func renderContextIsBounded() {
        #expect(!RenderWorkerOutbound.context(0).isWithinSecurityLimits())
        #expect(RenderWorkerOutbound.context(1).isWithinSecurityLimits())
        #expect(RenderWorkerOutbound.ack(1).isWithinSecurityLimits())
    }
}
