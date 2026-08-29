import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The terminal math rasterizer: KaTeX in a hidden `WKWebView` produces a
/// transparent bitmap with baseline metrics, applies the same guards as the
/// markdown viewer (trust-gated commands, macro definitions, over-long
/// bodies), and serves repeated requests from its cache.
@MainActor
@Suite(.serialized)
final class TerminalMathRasterizerTests {
    private let rasterizer = TerminalMathRasterizer.shared

    @Test
    func fractionRendersWithFractionProportions() async throws {
        rasterizer.clearCache()
        let raster = try #require(await rasterizer.raster(
            source: "$\\frac{a}{b}$", isDisplay: false, fontSizePt: 13, color: .white, scale: 2))
        #expect(raster.widthPt > 0)
        #expect(raster.heightPt > raster.widthPt * 0.5)
        #expect(raster.baselinePt > 0)
        #expect(raster.baselinePt < raster.heightPt)
        #expect(raster.scale == 2)
        #expect(raster.image.size.width == raster.widthPt)
        #expect(raster.image.size.height == raster.heightPt)
        let rep = try #require(raster.image.representations.first as? NSBitmapImageRep)
        #expect(rep.pixelsWide == Int((raster.widthPt * 2).rounded()))
        #expect(rep.hasAlpha)
    }

    @Test
    func displayMathRendersTallerThanInline() async throws {
        rasterizer.clearCache()
        let inline = try #require(await rasterizer.raster(
            source: "$\\sum_{i=1}^n i$", isDisplay: false, fontSizePt: 13, color: .white, scale: 2))
        let display = try #require(await rasterizer.raster(
            source: "\\[\\sum_{i=1}^n i\\]", isDisplay: true, fontSizePt: 13, color: .white, scale: 2))
        #expect(display.heightPt > inline.heightPt)
    }

    @Test
    func rejectsTrustGatedCommand() async {
        rasterizer.clearCache()
        let raster = await rasterizer.raster(
            source: "$\\href{https://example.com}{x}$", isDisplay: false, fontSizePt: 13, color: .white, scale: 2)
        #expect(raster == nil)
        #expect(rasterizer.lastRejectionReason == "untrusted command")
        #expect(rasterizer.isCachedRejection(
            source: "$\\href{https://example.com}{x}$", isDisplay: false, fontSizePt: 13, color: .white, scale: 2))
    }

    @Test
    func rejectsMacroDefinitionWithoutTouchingThePage() async {
        rasterizer.clearCache()
        let before = rasterizer.renderCount
        let raster = await rasterizer.raster(
            source: "$\\def\\x{y}\\x$", isDisplay: false, fontSizePt: 13, color: .white, scale: 2)
        #expect(raster == nil)
        #expect(rasterizer.lastRejectionReason == "macro definitions are not rendered")
        #expect(rasterizer.renderCount == before)
    }

    @Test
    func rejectsOverlongBody() async {
        rasterizer.clearCache()
        let before = rasterizer.renderCount
        let body = String(repeating: "x", count: 5000)
        let raster = await rasterizer.raster(
            source: "$\(body)$", isDisplay: false, fontSizePt: 13, color: .white, scale: 2)
        #expect(raster == nil)
        #expect(rasterizer.lastRejectionReason == "body too long")
        #expect(rasterizer.renderCount == before)
    }

    @Test
    func rejectsParseError() async {
        rasterizer.clearCache()
        let raster = await rasterizer.raster(
            source: "$\\notarealmacro{x}$", isDisplay: false, fontSizePt: 13, color: .white, scale: 2)
        #expect(raster == nil)
        #expect(rasterizer.lastRejectionReason?.contains("Undefined control sequence") == true)
    }

    @Test
    func cacheHitReturnsTheSameImageAndRendersOnce() async throws {
        rasterizer.clearCache()
        let before = rasterizer.renderCount
        #expect(rasterizer.cachedRaster(source: "$x$", isDisplay: false, fontSizePt: 13, color: .white, scale: 2) == nil)
        let first = try #require(await rasterizer.raster(
            source: "$x$", isDisplay: false, fontSizePt: 13, color: .white, scale: 2))
        let second = try #require(await rasterizer.raster(
            source: "$x$", isDisplay: false, fontSizePt: 13, color: .white, scale: 2))
        #expect(first.image === second.image)
        #expect(rasterizer.renderCount == before + 1)
        let probed = try #require(rasterizer.cachedRaster(
            source: "$x$", isDisplay: false, fontSizePt: 13, color: .white, scale: 2))
        #expect(probed.image === first.image)
        // Delimiter style is not part of the key: same body, same bitmap.
        let paren = try #require(await rasterizer.raster(
            source: "\\(x\\)", isDisplay: false, fontSizePt: 13, color: .white, scale: 2))
        #expect(paren.image === first.image)
        #expect(rasterizer.renderCount == before + 1)
    }

    @Test
    func concurrentDuplicateRequestsRenderOnce() async throws {
        rasterizer.clearCache()
        let before = rasterizer.renderCount
        async let a = rasterizer.raster(source: "$y^2$", isDisplay: false, fontSizePt: 13, color: .white, scale: 2)
        async let b = rasterizer.raster(source: "$y^2$", isDisplay: false, fontSizePt: 13, color: .white, scale: 2)
        let (first, second) = await (a, b)
        let firstRaster = try #require(first)
        let secondRaster = try #require(second)
        #expect(firstRaster.image === secondRaster.image)
        #expect(rasterizer.renderCount == before + 1)
    }

    @Test
    func colorAndScaleAreCacheKeys() async throws {
        rasterizer.clearCache()
        let before = rasterizer.renderCount
        let white = try #require(await rasterizer.raster(
            source: "$z$", isDisplay: false, fontSizePt: 13, color: .white, scale: 2))
        let black = try #require(await rasterizer.raster(
            source: "$z$", isDisplay: false, fontSizePt: 13, color: .black, scale: 2))
        let oneX = try #require(await rasterizer.raster(
            source: "$z$", isDisplay: false, fontSizePt: 13, color: .white, scale: 1))
        #expect(white.image !== black.image)
        #expect(white.image !== oneX.image)
        #expect(oneX.scale == 1)
        #expect(rasterizer.renderCount == before + 3)
    }

    @Test
    func bodyStripsDelimitersAndTrims() {
        #expect(TerminalMathRasterizer.body(of: "$ x $") == "x")
        #expect(TerminalMathRasterizer.body(of: "$$x$$") == "x")
        #expect(TerminalMathRasterizer.body(of: "\\(x\\)") == "x")
        #expect(TerminalMathRasterizer.body(of: "\\[ x \\]") == "x")
        #expect(TerminalMathRasterizer.body(of: "x") == "x")
        #expect(TerminalMathRasterizer.body(of: "$") == "$")
    }

    @Test
    func precheckMatchesTheViewerGuards() {
        #expect(TerminalMathRasterizer.precheckRejection(body: "\\left(x\\right)") == nil)
        #expect(TerminalMathRasterizer.precheckRejection(body: "\\newcommand{\\a}{b}") != nil)
        #expect(TerminalMathRasterizer.precheckRejection(body: "\\DeclareMathOperator{\\f}{f}") != nil)
        #expect(TerminalMathRasterizer.precheckRejection(body: "\\letter") == nil)
        #expect(TerminalMathRasterizer.precheckRejection(body: String(repeating: "a", count: 4096)) == nil)
        #expect(TerminalMathRasterizer.precheckRejection(body: String(repeating: "a", count: 4097)) != nil)
    }
}
