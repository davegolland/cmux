import CmuxSwiftRender
import Foundation
import Testing
@testable import CmuxSidebarInterpreterClient

@Suite("Render worker write bounds")
struct RenderWorkerOutboundWriteTests {
    @Test("Coalesced scroll values stay within the pointer contract")
    func coalescedScrollDoesNotAmplifyWithoutBound() throws {
        let old = try #require(RenderWorkerOutboundWrite(
            message: .pointer(RenderPointerEvent(kind: .scroll, x: 1, y: 1, deltaY: 100_000)),
            remainingRelaunches: 0,
            ackSequence: nil
        ))
        let newer = try #require(RenderWorkerOutboundWrite(
            message: .pointer(RenderPointerEvent(kind: .scroll, x: 1, y: 1, deltaY: 100_000)),
            remainingRelaunches: 0,
            ackSequence: nil
        ))

        let merged = try #require(old.coalescing(with: newer))
        let event = try JSONDecoder().decode(RenderWorkerInbound.self, from: merged.data)
        guard case let .pointer(pointer) = event else {
            Issue.record("expected a pointer message")
            return
        }
        #expect(pointer.deltaY.isFinite)
        #expect(abs(pointer.deltaY) <= 100_000)
    }
}
