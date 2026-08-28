import CmuxSwiftRender
@testable import CmuxSwiftRenderUI
import Testing

@MainActor
struct SidebarJSRuntimeTests {
    /// Actions dispatch one main-queue turn after the event (paint-before-
    /// command); suspend so the queued dispatch runs before asserting.
    private func pumpActions() async {
        for _ in 0..<5 { await Task.yield() }
    }

    @Test func buildsRetainedScene() {
        let runtime = SidebarJSRuntime()
        let ok = runtime.start(source: """
        sidebar(() => VStack({ spacing: 8 }, [
            Text("Hello").font("headline"),
            Divider(),
        ]))
        """)
        #expect(ok)
        #expect(runtime.errorMessage == nil)
        let root = runtime.store.rootId.flatMap { runtime.store.node($0) }
        #expect(root?.type == "vstack")
        #expect(root?.double("spacing") == 8)
        let first = root?.children.first.flatMap { runtime.store.node($0) }
        #expect(first?.string("text") == "Hello")
        #expect(first?.string("font") == "headline")
    }

    @Test func reactivePropUpdatesOnlyOnDataChange() {
        let runtime = SidebarJSRuntime()
        runtime.start(source: """
        sidebar(() => Text(() => "count: " + (data.count() ?? 0)))
        """)
        let rootId = try! #require(runtime.store.rootId)
        #expect(runtime.store.node(rootId)?.string("text") == "count: 0")
        runtime.updateData(key: "count", value: .int(5))
        #expect(runtime.store.node(rootId)?.string("text") == "count: 5")
        // An unrelated key leaves the prop untouched.
        runtime.updateData(key: "other", value: .string("x"))
        #expect(runtime.store.node(rootId)?.string("text") == "count: 5")
    }

    @Test func keyedReconcileKeepsRowIdentityAcrossReorder() {
        let runtime = SidebarJSRuntime()
        runtime.start(source: """
        sidebar(() => ForEach(
            { items: () => data.items() ?? [], key: (w) => w.id },
            (w) => Text(() => w().title)
        ))
        """)
        let rootId = try! #require(runtime.store.rootId)
        runtime.updateData(key: "items", value: .array([
            .object(["id": .string("a"), "title": .string("A")]),
            .object(["id": .string("b"), "title": .string("B")]),
        ]))
        let before = try! #require(runtime.store.node(rootId)?.children)
        #expect(before.count == 2)

        // Reorder: identical node ids, swapped order (no remount).
        runtime.updateData(key: "items", value: .array([
            .object(["id": .string("b"), "title": .string("B")]),
            .object(["id": .string("a"), "title": .string("A")]),
        ]))
        let after = try! #require(runtime.store.node(rootId)?.children)
        #expect(after == before.reversed())

        // Removal disposes the row's nodes.
        runtime.updateData(key: "items", value: .array([
            .object(["id": .string("b"), "title": .string("B")]),
        ]))
        let remaining = try! #require(runtime.store.node(rootId)?.children)
        #expect(remaining.count == 1)
        #expect(runtime.store.node(before[0]) == nil)
    }

    @Test func rowContentUpdatesInPlace() {
        let runtime = SidebarJSRuntime()
        runtime.start(source: """
        sidebar(() => ForEach(
            { items: () => data.items() ?? [], key: (w) => w.id },
            (w) => Text(() => w().title)
        ))
        """)
        let rootId = try! #require(runtime.store.rootId)
        runtime.updateData(key: "items", value: .array([
            .object(["id": .string("a"), "title": .string("old")]),
        ]))
        let rowId = try! #require(runtime.store.node(rootId)?.children.first)
        runtime.updateData(key: "items", value: .array([
            .object(["id": .string("a"), "title": .string("new")]),
        ]))
        #expect(runtime.store.node(rootId)?.children.first == rowId)
        #expect(runtime.store.node(rowId)?.string("text") == "new")
    }

    @Test func buttonTapRunsCmuxCommand() async {
        let runtime = SidebarJSRuntime()
        var captured: [ActionCommand] = []
        runtime.dispatch = SidebarActionDispatch { action in
            captured.append(contentsOf: action.commands)
        }
        runtime.start(source: """
        sidebar(() => Button("Select", () => cmux("workspace.select", { workspace_id: "w1" })))
        """)
        let rootId = try! #require(runtime.store.rootId)
        runtime.dispatchEvent(nodeId: rootId, event: "tap")
        await pumpActions()
        #expect(captured == [.cmux(method: "workspace.select", params: ["workspace_id": "w1"])])
    }

    @Test func deferredActionQueueHasAHardAdmissionLimit() async {
        let runtime = SidebarJSRuntime()
        var captured = 0
        runtime.dispatch = SidebarActionDispatch { _ in captured += 1 }
        #expect(runtime.start(source: """
        sidebar(() => Button("Run", () => cmux("workspace.select", { workspace_id: "w1" })))
        """))
        let rootID = try! #require(runtime.store.rootId)

        // Dispatch from one owning-actor turn so the main queue cannot drain
        // between events. The queue may execute some work while the test
        // yields, but it must never retain more than the configured bound.
        for _ in 0..<(SidebarSecurityLimits.maxPendingActions + 32) {
            runtime.dispatchEvent(nodeId: rootID, event: "tap")
        }
        await pumpActions()
        #expect(captured <= SidebarSecurityLimits.maxPendingActions)
    }

    @Test func deferredActionFromAnOldSourceRevisionIsDropped() async {
        let runtime = SidebarJSRuntime()
        var captured = 0
        runtime.dispatch = SidebarActionDispatch { _ in captured += 1 }
        #expect(runtime.start(source: """
        sidebar(() => Button("old", () => cmux("workspace.select", { workspace_id: "w1" })))
        """))
        let oldRoot = try! #require(runtime.store.rootId)
        runtime.dispatchEvent(nodeId: oldRoot, event: "tap")
        // Replace the source before the deferred main-queue closure gets a
        // turn. The old command must not cross the new source lifecycle.
        #expect(runtime.start(source: "sidebar(() => Text(\"new\"))"))
        await pumpActions()
        #expect(captured == 0)
    }

    @Test func reorderableCarriesItemKeysAndMoveHandler() async {
        let runtime = SidebarJSRuntime()
        var captured: [ActionCommand] = []
        runtime.dispatch = SidebarActionDispatch { action in
            captured.append(contentsOf: action.commands)
        }
        runtime.start(source: """
        sidebar(() => Reorderable(
            {
                items: () => data.items() ?? [],
                key: (w) => w.id,
                onMove: (id, index) => cmux("workspace.reorder", { workspace_id: id, index: index }),
            },
            (w) => Text(() => w().title)
        ))
        """)
        let rootId = try! #require(runtime.store.rootId)
        runtime.updateData(key: "items", value: .array([
            .object(["id": .string("a"), "title": .string("A")]),
            .object(["id": .string("b"), "title": .string("B")]),
        ]))
        #expect(runtime.store.node(rootId)?.string("itemKeys") == #"["a","b"]"#)
        runtime.dispatchEvent(nodeId: rootId, event: "move", payload: ["id": "a", "index": 1])
        await pumpActions()
        #expect(captured == [.cmux(method: "workspace.reorder", params: ["workspace_id": "a", "index": "1"])])
    }

    @Test func contextMenuAttachesAsMenuChild() async {
        let runtime = SidebarJSRuntime()
        var captured: [ActionCommand] = []
        runtime.dispatch = SidebarActionDispatch { action in
            captured.append(contentsOf: action.commands)
        }
        runtime.start(source: """
        sidebar(() =>
          Text("row").contextMenu([
            Button("Pin", () => cmux("workspace.action", { action: "pin", workspace_id: "w1" })),
            Divider(),
            Menu("Move", [Button("Up", () => cmux("workspace.action", { action: "move_up" }))]),
          ])
        )
        """)
        let rootId = try! #require(runtime.store.rootId)
        let root = try! #require(runtime.store.node(rootId))
        #expect(root.type == "text")
        let menuId = try! #require(root.children.first)
        let menu = try! #require(runtime.store.node(menuId))
        #expect(menu.type == "contextMenu")
        #expect(menu.children.count == 3)
        // Menu item taps dispatch like any button.
        runtime.dispatchEvent(nodeId: menu.children[0], event: "tap")
        await pumpActions()
        #expect(captured == [.cmux(method: "workspace.action", params: ["action": "pin", "workspace_id": "w1"])])
        // Submenu node carries its title and item.
        let submenu = try! #require(runtime.store.node(menu.children[2]))
        #expect(submenu.type == "menu")
        #expect(submenu.string("text") == "Move")
    }

    @Test func textFieldEditEventFiresLive() {
        let runtime = SidebarJSRuntime()
        runtime.start(source: """
        const [q, setQ] = signal("");
        sidebar(() => VStack({}, [
            TextField("", { autofocus: false, onEdit: (t) => setQ(t) }),
            Text(() => "q:" + q()),
        ]))
        """)
        let rootId = try! #require(runtime.store.rootId)
        let root = try! #require(runtime.store.node(rootId))
        let fieldId = try! #require(root.children.first)
        let labelId = try! #require(root.children.dropFirst().first)
        #expect(runtime.store.node(fieldId)?.props["autofocus"] == .bool(false))
        runtime.dispatchEvent(nodeId: fieldId, event: "edit", payload: ["text": "se"])
        #expect(runtime.store.node(labelId)?.string("text") == "q:se")
        runtime.dispatchEvent(nodeId: fieldId, event: "edit", payload: ["text": "sess"])
        #expect(runtime.store.node(labelId)?.string("text") == "q:sess")
    }

    @Test func authorSignalsDriveBindings() {
        let runtime = SidebarJSRuntime()
        runtime.start(source: """
        const [open, setOpen] = signal(false);
        sidebar(() => Text(() => (open() ? "open" : "closed")).onTap(() => setOpen(!open())))
        """)
        let rootId = try! #require(runtime.store.rootId)
        #expect(runtime.store.node(rootId)?.string("text") == "closed")
        runtime.dispatchEvent(nodeId: rootId, event: "tap")
        #expect(runtime.store.node(rootId)?.string("text") == "open")
    }

    @Test func numericPropsWithValueOneStayNumeric() {
        // Regression: NSNumber(1) bridges to Bool via `as?`, which turned
        // lineLimit(1)/opacity(1) into booleans and silently dropped them.
        let runtime = SidebarJSRuntime()
        runtime.start(source: """
        sidebar(() => Text("t").lineLimit(1).opacity(1).padding(0).rotation(90).fade(30).marquee())
        """)
        let rootId = try! #require(runtime.store.rootId)
        let node = try! #require(runtime.store.node(rootId))
        #expect(node.props["lineLimit"] == .number(1))
        #expect(node.props["opacity"] == .number(1))
        #expect(node.props["padding"] == .number(0))
        #expect(node.props["rotation"] == .number(90))
        #expect(node.props["fade"] == .number(30))
        // Bare `.marquee()` defaults to true (delay comes from the host).
        #expect(node.props["marquee"] == .bool(true))
        // Booleans still decode as booleans.
        #expect(node.props["tappable"] == nil)
    }

    @Test func programErrorSurfacesWithoutInspectingThrownObjects() {
        let runtime = SidebarJSRuntime()
        let ok = runtime.start(source: "sidebar(() => notAFunction())")
        #expect(!ok)
        #expect(runtime.errorMessage?.contains("failed") == true)
        #expect(runtime.errorMessage?.contains("notAFunction") == false)
    }

    @Test func hostileThrownObjectDoesNotRunItsToStringOrGetter() {
        let runtime = SidebarJSRuntime()
        let ok = runtime.start(source: #"sidebar(() => { throw new Proxy({}, { get() { while (true) {} } , getOwnPropertyDescriptor() { while (true) {} } }); })"#)
        #expect(!ok)
        #expect(runtime.errorMessage?.contains("failed") == true)
    }

    @Test func privilegedBridgeIsHiddenFromAuthoredSource() {
        let runtime = SidebarJSRuntime()
        let ok = runtime.start(source: """
        sidebar(() => Text(() => typeof globalThis.__host_action + ":" + typeof globalThis.__setData))
        """)
        #expect(ok)
        let rootId = try! #require(runtime.store.rootId)
        #expect(runtime.store.node(rootId)?.string("text") == "undefined:undefined")
    }

    @Test func actionsRequireAHostDeliveredEvent() async {
        let runtime = SidebarJSRuntime()
        var captured: [ActionCommand] = []
        runtime.dispatch = SidebarActionDispatch { action in
            captured.append(contentsOf: action.commands)
        }
        let ok = runtime.start(source: """
        const act = () => cmux("workspace.select", { workspace_id: "w1" });
        act();
        sidebar(() => Text("row").onTap(() => act()))
        """)
        #expect(ok)
        await pumpActions()
        #expect(captured.isEmpty)
        let rootId = try! #require(runtime.store.rootId)
        runtime.dispatchEvent(nodeId: rootId, event: "tap")
        await pumpActions()
        #expect(captured == [.cmux(method: "workspace.select", params: ["workspace_id": "w1"])])
    }

    @Test func reactiveEffectsCannotInheritEventActionCapability() async {
        let runtime = SidebarJSRuntime()
        var captured: [ActionCommand] = []
        runtime.dispatch = SidebarActionDispatch { action in
            captured.append(contentsOf: action.commands)
        }
        let ok = runtime.start(source: """
        const [count, setCount] = signal(0);
        const label = computed(() => {
            const value = count();
            if (value > 0) cmux("workspace.close", { workspace_id: "w1" });
            return String(value);
        });
        sidebar(() => Text(() => label()).onTap(() => setCount(1)));
        """)
        #expect(ok)
        let rootId = try! #require(runtime.store.rootId)
        runtime.dispatchEvent(nodeId: rootId, event: "tap")
        await pumpActions()
        // The tap may update state, but the dependent effect runs after the
        // event capability closes and cannot issue a privileged command.
        #expect(captured.isEmpty)
        #expect(runtime.store.node(rootId)?.string("text") == "1")
    }

    @Test func sourceAndSceneLimitsFailClosed() {
        let sourceRuntime = SidebarJSRuntime()
        #expect(!sourceRuntime.start(source: String(repeating: " ", count: SidebarSecurityLimits.maxSourceBytes + 1)))
        #expect(sourceRuntime.errorMessage != nil)

        let store = SceneStore()
        let oversized = String(repeating: "x", count: SidebarSecurityLimits.maxSceneBatchJSONBytes + 1)
        #expect(!store.apply(opsJSON: oversized))
    }

    @Test func sceneGraphRejectsUnknownDuplicateAndCycleEdges() {
        let store = SceneStore()
        let initialOps = #"""
        [
          {"op":"create","id":"root","type":"vstack"},
          {"op":"create","id":"child","type":"text"},
          {"op":"children","id":"root","children":["child"]},
          {"op":"root","id":"root"}
        ]
        """#
        #expect(store.apply(opsJSON: initialOps))
        let root = try! #require(store.node("root"))
        #expect(root.children == ["child"])

        // A forged reference must not be allowed to reach recursive view
        // traversal, and the failed batch must leave the prior scene intact.
        #expect(!store.apply(opsJSON: #"[{"op":"children","id":"root","children":["missing"]}]"#))
        #expect(root.children == ["child"])

        #expect(!store.apply(opsJSON: #"[{"op":"children","id":"root","children":["child","child"]}]"#))
        #expect(root.children == ["child"])

        // The create and edge operations are rolled back when the resulting
        // graph contains a cycle.
        let cycleOps = #"""
        [
          {"op":"children","id":"root","children":["child"]},
          {"op":"children","id":"child","children":["root"]}
        ]
        """#
        #expect(!store.apply(opsJSON: cycleOps))
        #expect(root.children == ["child"])
        #expect(store.node("child")?.children.isEmpty == true)
    }

    @Test func sceneGraphRejectsOutOfRangeNumbers() {
        let store = SceneStore()
        #expect(store.apply(opsJSON: #"[{"op":"create","id":"n","type":"text"}]"#))
        #expect(!store.apply(opsJSON: "[{\"op\":\"update\",\"id\":\"n\",\"key\":\"width\",\"value\":\(SidebarSecurityLimits.maxSceneNumberMagnitude + 1)}]"))
        #expect(store.node("n")?.props["width"] == nil)
    }

    @Test func genericJSONGuardAcceptsWallClockEpochs() {
        // Data snapshots carry Unix seconds. The generic bridge must reject
        // non-finite numbers, but it must not apply the scene-geometry bound
        // to ordinary timestamps.
        let payload: [String: Any] = ["epoch": NSNumber(value: 1_780_000_000)]
        #expect(SidebarJSONGuard.isBoundedObject(
            payload,
            maximumBytes: SidebarSecurityLimits.maxEventJSONBytes,
            maximumCollectionItems: 16
        ))
        #expect(!SidebarJSONGuard.isBoundedObject(
            payload,
            maximumBytes: SidebarSecurityLimits.maxEventJSONBytes,
            maximumCollectionItems: 16,
            maximumNumberMagnitude: SidebarSecurityLimits.maxSceneNumberMagnitude
        ))
    }

    @Test func capturedJSONIntrinsicsSurviveAuthoredMutation() {
        let runtime = SidebarJSRuntime()
        let ok = runtime.start(source: """
        JSON.stringify = () => "broken";
        JSON.parse = () => ({ broken: true });
        sidebar(() => Text(() => data.value() || "missing"));
        """)
        #expect(ok)
        let rootId = try! #require(runtime.store.rootId)
        #expect(runtime.store.node(rootId)?.string("text") == "missing")
        runtime.updateData(key: "value", value: .string("kept"))
        // If __setData used the mutated global JSON.parse, the binding would
        // receive the wrong object instead of the host's value.
        #expect(runtime.store.node(rootId)?.string("text") == "kept")
        #expect(runtime.errorMessage == nil)
    }

    @Test func authoredIteratorMutationCannotCorruptHostWalks() {
        let runtime = SidebarJSRuntime()
        let ok = runtime.start(source: """
        try {
            const arrayIterator = Object.getPrototypeOf([][Symbol.iterator]());
            arrayIterator.next = () => ({ done: false, value: "forever" });
            const stringIterator = Object.getPrototypeOf(\"\"[Symbol.iterator]());
            stringIterator.next = () => ({ done: false, value: \"forever\" });
        } catch (_) {}
        sidebar(() => Text(\"safe\"));
        """)
        // The runtime uses for-of for bounded internal cleanup and string
        // sizing. Frozen iterator prototypes keep authored mutations from
        // turning those walks into an infinite loop.
        #expect(ok)
        let rootID = try! #require(runtime.store.rootId)
        #expect(runtime.store.node(rootID)?.string("text") == "safe")
    }

    @Test func hostValuesDoNotCoerceObjects() {
        let runtime = SidebarJSRuntime()
        let ok = runtime.start(source: """
        sidebar(() => Text({ toString() { throw new Error("coercion"); } }));
        """)

        #expect(ok)
        let rootID = try! #require(runtime.store.rootId)
        #expect(runtime.store.node(rootID)?.props["text"] == nil)
    }

    @Test func missingWatchdogDoesNotRunAuthoredCode() {
        let runtime = SidebarJSRuntime(watchdog: JSWatchdog { _, _ in false })
        #expect(!runtime.start(source: "sidebar(() => Text(\"never\"))"))
        #expect(runtime.errorMessage != nil)
    }

    @Test func missingRootIsAnError() {
        let runtime = SidebarJSRuntime()
        let ok = runtime.start(source: "const x = 1")
        #expect(!ok)
        #expect(runtime.errorMessage != nil)
    }

    @Test func repeatedSidebarMountIsRejected() {
        let runtime = SidebarJSRuntime()
        let ok = runtime.start(source: """
        sidebar(() => Text("first"));
        sidebar(() => Text("second"));
        """)
        #expect(!ok)
        #expect(runtime.errorMessage != nil)
    }

    @Test func failedSidebarMountCannotBeRetried() {
        let runtime = SidebarJSRuntime()
        let ok = runtime.start(source: """
        try { sidebar(() => { throw new Error("first mount failed") }); } catch (_) {}
        sidebar(() => Text("second"));
        """)
        // Authored code can catch the first exception. The runtime must still
        // consume its one retained-scene slot, rather than leaking the first
        // partial scene and accepting a second mount.
        #expect(!ok)
        #expect(runtime.errorMessage != nil)
    }

    @Test func validateAcceptsGoodProgramAndRejectsBadOne() {
        #expect(SidebarJSRuntime.validate(
            source: "sidebar(() => Text(\"ok\"))",
            state: CustomSidebarValidator.defaultDataContext
        ) == nil)
        #expect(SidebarJSRuntime.validate(
            source: "sidebar(() => missing())",
            state: [:]
        ) != nil)
    }

    @Test func watchdogTerminatesRunawayProgram() {
        // The hard limit resolves a non-public JSC symbol; skip when absent
        // (the test would otherwise hang forever).
        guard JSWatchdog.install(on: JSContextHolder.make(), seconds: 0.05) else { return }
        let message = SidebarJSRuntime.validate(source: "while (true) {}", state: [:])
        #expect(message != nil)
    }
}

import JavaScriptCore

enum JSContextHolder {
    static func make() -> JSContext { JSContext()! }
}
