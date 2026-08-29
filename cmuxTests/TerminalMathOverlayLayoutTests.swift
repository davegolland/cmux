import CmuxAgentChat
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Fit rule and patch geometry for the terminal math overlay. Coordinates are
/// top-origin because the overlay view is flipped.
@Suite struct TerminalMathOverlayLayoutTests {
    private let metrics = TerminalMathGridMetrics(cellWidth: 8, cellHeight: 16, xInset: 4, yInset: 6)

    private func placement(
        row: Int = 2,
        columns: Range<Int> = 3..<13,
        wrapped: [TerminalMathPlacement.Segment] = [],
        isDisplay: Bool = false
    ) -> TerminalMathPlacement {
        TerminalMathPlacement(
            row: row,
            startColumn: columns.lowerBound,
            endColumn: columns.upperBound,
            continuationRows: wrapped,
            source: isDisplay ? "$$x$$" : "$x$",
            body: "x",
            isDisplay: isDisplay
        )
    }

    @Test func naturalSizeWhenRasterFitsTheRow() throws {
        // 10 cells wide = 80pt patch; a 40x14 raster fits without scaling.
        let raster = TerminalMathOverlayLayout.RasterSize(widthPt: 40, heightPt: 14, baselinePt: 10)
        let frame = try #require(TerminalMathOverlayLayout.frame(
            for: placement(), raster: raster, metrics: metrics, isDisplay: false
        ))
        #expect(frame.scale == CGFloat(1))
        #expect(frame.patchRects == [CGRect(x: 4 + 3 * 8, y: 6 + 2 * 16, width: 80, height: 16)])
        // Centered on the row in both axes.
        #expect(frame.imageRect.width == CGFloat(40))
        #expect(frame.imageRect.height == CGFloat(14))
        #expect(frame.imageRect.minX == CGFloat(48))
        #expect(frame.imageRect.minY == CGFloat(39))
    }

    @Test func scaledDownToPatchWidth() throws {
        // 160pt wide raster over an 80pt patch scales by 0.5; 30pt tall
        // becomes 15pt, above the 0.7 * 16 = 11.2pt floor.
        let raster = TerminalMathOverlayLayout.RasterSize(widthPt: 160, heightPt: 30, baselinePt: 20)
        let frame = try #require(TerminalMathOverlayLayout.frame(
            for: placement(), raster: raster, metrics: metrics, isDisplay: true
        ))
        #expect(frame.scale == CGFloat(0.5))
        #expect(frame.imageRect.size == CGSize(width: 80, height: 15))
        #expect(frame.imageRect.minX == CGFloat(28))
    }

    @Test func rejectedWhenScalingDropsBelowSeventyPercentOfACell() {
        // Scaling 320 -> 80 is 0.25; 40pt tall becomes 10pt < 11.2pt.
        let raster = TerminalMathOverlayLayout.RasterSize(widthPt: 320, heightPt: 40, baselinePt: 30)
        #expect(TerminalMathOverlayLayout.frame(
            for: placement(), raster: raster, metrics: metrics, isDisplay: false
        ) == nil)
    }

    @Test func inlineRasterTallerThanACellIsScaledNotOverhung() throws {
        // Inline budget is one cell: a 20pt raster over a 16pt row scales to
        // 0.8 (12.8pt, above the floor); display math would keep it natural.
        let raster = TerminalMathOverlayLayout.RasterSize(widthPt: 20, heightPt: 20, baselinePt: 14)
        let inline = try #require(TerminalMathOverlayLayout.frame(
            for: placement(), raster: raster, metrics: metrics, isDisplay: false
        ))
        #expect(inline.scale == CGFloat(0.8))
        let display = try #require(TerminalMathOverlayLayout.frame(
            for: placement(isDisplay: true), raster: raster, metrics: metrics, isDisplay: true
        ))
        #expect(display.scale == CGFloat(1))
        // Display overhang: 2pt above and below the row.
        #expect(display.imageRect.minY == CGFloat(36))
        #expect(display.imageRect.maxY == CGFloat(56))
    }

    @Test func smallNaturalRasterIsNotRejectedByTheFloor() throws {
        // The floor only applies when scaling down: a naturally short raster
        // (a lone `x`) is still drawn.
        let raster = TerminalMathOverlayLayout.RasterSize(widthPt: 6, heightPt: 8, baselinePt: 7)
        let frame = try #require(TerminalMathOverlayLayout.frame(
            for: placement(), raster: raster, metrics: metrics, isDisplay: false
        ))
        #expect(frame.scale == CGFloat(1))
        #expect(frame.imageRect.height == CGFloat(8))
    }

    @Test func wrappedPlacementGetsOnePatchPerSegmentAndImageOnFirstRow() throws {
        let wrapped = placement(
            row: 5,
            columns: 70..<80,
            wrapped: [TerminalMathPlacement.Segment(row: 6, startColumn: 0, endColumn: 4)]
        )
        let raster = TerminalMathOverlayLayout.RasterSize(widthPt: 30, heightPt: 12, baselinePt: 9)
        let frame = try #require(TerminalMathOverlayLayout.frame(
            for: wrapped, raster: raster, metrics: metrics, isDisplay: false
        ))
        #expect(frame.patchRects == [
            CGRect(x: 4 + 70 * 8, y: 6 + 5 * 16, width: 80, height: 16),
            CGRect(x: 4, y: 6 + 6 * 16, width: 32, height: 16),
        ])
        #expect(frame.imageRect.minY >= CGFloat(86))
        #expect(frame.imageRect.maxY <= CGFloat(102))
    }

    @Test func rowsGrowDownwardInFlippedCoordinates() throws {
        let raster = TerminalMathOverlayLayout.RasterSize(widthPt: 10, heightPt: 10, baselinePt: 8)
        let top = try #require(TerminalMathOverlayLayout.frame(
            for: placement(row: 0), raster: raster, metrics: metrics, isDisplay: false
        ))
        let lower = try #require(TerminalMathOverlayLayout.frame(
            for: placement(row: 3), raster: raster, metrics: metrics, isDisplay: false
        ))
        #expect(top.patchRects[0].minY == CGFloat(6))
        #expect(lower.patchRects[0].minY == CGFloat(54))
        #expect(lower.imageRect.minY > top.imageRect.minY)
    }

    @Test func degenerateInputsAreRejected() {
        let raster = TerminalMathOverlayLayout.RasterSize(widthPt: 0, heightPt: 10, baselinePt: 8)
        #expect(TerminalMathOverlayLayout.frame(
            for: placement(), raster: raster, metrics: metrics, isDisplay: false
        ) == nil)
        let empty = placement(columns: 3..<3)
        let ok = TerminalMathOverlayLayout.RasterSize(widthPt: 10, heightPt: 10, baselinePt: 8)
        #expect(TerminalMathOverlayLayout.frame(
            for: empty, raster: ok, metrics: metrics, isDisplay: false
        ) == nil)
    }
}
