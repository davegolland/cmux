import AppKit
import Bonsplit

/// Retained native source whose terminal callback owns Vault drag completion.
@MainActor
final class SessionDragSessionSource: NSObject, NSDraggingSource {
    private enum Phase {
        case active
        case finished
    }

    let dragID: UUID
    private let registry: SessionDragRegistry
    private let transferRegistration: TabDragTransferRegistration
    private let transferRegistry: TabDragTransferRegistry
    private let onFinish: @MainActor (UUID) -> Void
    private var phase: Phase = .active

    init(
        dragID: UUID,
        registry: SessionDragRegistry,
        transferRegistration: TabDragTransferRegistration,
        transferRegistry: TabDragTransferRegistry,
        onFinish: @escaping @MainActor (UUID) -> Void
    ) {
        self.dragID = dragID
        self.registry = registry
        self.transferRegistration = transferRegistration
        self.transferRegistry = transferRegistry
        self.onFinish = onFinish
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
#if DEBUG
        cmuxDebugLog(
            "vault.drag.source.end drag=\(dragID.uuidString.prefix(5)) operation=\(operation.rawValue)"
        )
#endif
        finishDrag()
        // AppKit may retain the tab-transfer UTI after the source ends. The
        // registry entry was revoked by `finishDrag`, so a stale pasteboard
        // value no longer resolves to a live transfer. Do not clear the
        // shared pasteboard here, because a newer drag may already own it.
    }

    func finishDrag() {
        guard case .active = phase else { return }
        phase = .finished
        transferRegistry.end(transferRegistration)
        registry.discard(id: dragID)
        onFinish(dragID)
    }
}
