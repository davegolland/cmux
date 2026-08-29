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

    // MARK: - Cache limits (G5)

    @Test
    func entryLimitEvictsTheLeastRecentlyUsedEntry() async throws {
        rasterizer.clearCache()
        let savedLimit = rasterizer.cacheEntryLimit
        defer { rasterizer.cacheEntryLimit = savedLimit }
        rasterizer.cacheEntryLimit = 2
        func render(_ source: String) async -> TerminalMathRasterizer.Raster? {
            await rasterizer.raster(source: source, isDisplay: false, fontSizePt: 13, color: .white, scale: 2)
        }
        func cached(_ source: String) -> TerminalMathRasterizer.Raster? {
            rasterizer.cachedRaster(source: source, isDisplay: false, fontSizePt: 13, color: .white, scale: 2)
        }
        let a = try #require(await render("$a$"))
        _ = try #require(await render("$b$"))
        // Touch a so b becomes the least recently used.
        #expect(cached("$a$")?.image === a.image)
        let c = try #require(await render("$c$"))
        #expect(cached("$b$") == nil)
        #expect(cached("$a$")?.image === a.image)
        #expect(cached("$c$")?.image === c.image)
        let before = rasterizer.renderCount
        _ = try #require(await render("$b$"))
        #expect(rasterizer.renderCount == before + 1)
        // Re-rendering b evicted a (c was touched more recently than a).
        #expect(cached("$a$") == nil)
        #expect(cached("$c$")?.image === c.image)
    }

    @Test
    func byteLimitEvictsButKeepsTheEntryJustStored() async throws {
        rasterizer.clearCache()
        let savedLimit = rasterizer.cacheByteLimit
        defer { rasterizer.cacheByteLimit = savedLimit }
        rasterizer.cacheByteLimit = 1
        let a = try #require(await rasterizer.raster(
            source: "$a$", isDisplay: false, fontSizePt: 13, color: .white, scale: 2))
        #expect(rasterizer.cachedRaster(source: "$a$", isDisplay: false, fontSizePt: 13, color: .white, scale: 2)?.image === a.image)
        let b = try #require(await rasterizer.raster(
            source: "$b$", isDisplay: false, fontSizePt: 13, color: .white, scale: 2))
        #expect(rasterizer.cachedRaster(source: "$a$", isDisplay: false, fontSizePt: 13, color: .white, scale: 2) == nil)
        #expect(rasterizer.cachedRaster(source: "$b$", isDisplay: false, fontSizePt: 13, color: .white, scale: 2)?.image === b.image)
        // Storing a zero-byte rejection while still over the byte budget
        // evicts the bitmap, never the entry just stored.
        _ = await rasterizer.raster(source: "$\\def\\q{1}$", isDisplay: false, fontSizePt: 13, color: .white, scale: 2)
        #expect(rasterizer.isCachedRejection(source: "$\\def\\q{1}$", isDisplay: false, fontSizePt: 13, color: .white, scale: 2))
        #expect(rasterizer.cachedRaster(source: "$b$", isDisplay: false, fontSizePt: 13, color: .white, scale: 2) == nil)
    }

    // MARK: - Transient failures (G2)

    @Test
    func transientFailureIsNegativeCachedWithDoublingBackoff() async throws {
        rasterizer.clearCache()
        defer { rasterizer.debugResetFailureTracking() }
        func render() async -> TerminalMathRasterizer.Raster? {
            await rasterizer.raster(source: "$t$", isDisplay: false, fontSizePt: 13, color: .white, scale: 2)
        }
        rasterizer.debugFailNextRender = true
        #expect(await render() == nil)
        #expect(rasterizer.lastRejectionReason == "simulated transient failure")
        // Not a rejection, not a hit: the draw path sees a miss, but a
        // request inside the backoff returns nil without rendering.
        #expect(!rasterizer.isCachedRejection(source: "$t$", isDisplay: false, fontSizePt: 13, color: .white, scale: 2))
        #expect(rasterizer.cachedRaster(source: "$t$", isDisplay: false, fontSizePt: 13, color: .white, scale: 2) == nil)
        let before = rasterizer.renderCount
        #expect(await render() == nil)
        #expect(rasterizer.renderCount == before)
        rasterizer.clockOffset = 1.5
        #expect(await render() == nil)
        #expect(rasterizer.renderCount == before)
        // Expired (2 s): the next request renders again; make it fail a
        // second time so the backoff doubles to 4 s.
        rasterizer.clockOffset = 2.5
        rasterizer.debugFailNextRender = true
        #expect(await render() == nil)
        rasterizer.clockOffset = 2.5 + 3
        #expect(await render() == nil)
        #expect(rasterizer.renderCount == before)
        rasterizer.clockOffset = 2.5 + 4.5
        let raster = try #require(await render())
        #expect(raster.widthPt > 0)
        #expect(rasterizer.renderCount == before + 1)
        #expect(rasterizer.cachedRaster(source: "$t$", isDisplay: false, fontSizePt: 13, color: .white, scale: 2)?.image === raster.image)
    }

    @Test
    func repeatedPageFailuresEnterACooldownThatExpires() async throws {
        rasterizer.clearCache()
        defer { rasterizer.debugResetFailureTracking() }
        _ = try #require(await rasterizer.raster(
            source: "$c_0$", isDisplay: false, fontSizePt: 13, color: .white, scale: 2))
        #expect(!rasterizer.isInCooldown)
        rasterizer.debugSimulatePageFailure()
        rasterizer.debugSimulatePageFailure()
        #expect(!rasterizer.isInCooldown)
        rasterizer.debugSimulatePageFailure()
        #expect(rasterizer.isInCooldown)
        #expect(!rasterizer.debugHasWebView)
        let before = rasterizer.renderCount
        let during = await rasterizer.raster(
            source: "$c_1$", isDisplay: false, fontSizePt: 13, color: .white, scale: 2)
        #expect(during == nil)
        #expect(rasterizer.renderCount == before)
        #expect(!rasterizer.debugHasWebView)
        #expect(rasterizer.lastRejectionReason?.contains("cooling down") == true)
        // Cache hits keep working during the cooldown.
        #expect(rasterizer.cachedRaster(source: "$c_0$", isDisplay: false, fontSizePt: 13, color: .white, scale: 2) != nil)
        #expect(await rasterizer.raster(source: "$c_0$", isDisplay: false, fontSizePt: 13, color: .white, scale: 2) != nil)
        rasterizer.clockOffset = TerminalMathRasterizer.cooldownDuration + 1
        #expect(!rasterizer.isInCooldown)
        let after = try #require(await rasterizer.raster(
            source: "$c_1$", isDisplay: false, fontSizePt: 13, color: .white, scale: 2))
        #expect(after.widthPt > 0)
        #expect(rasterizer.renderCount == before + 1)
        #expect(rasterizer.debugHasWebView)
    }

    // MARK: - Page lifecycle (G1, G4)

    @Test
    func pageFailureWhileLoadingFailsTheRequestAndTheRebuiltPageLoadsCleanly() async throws {
        rasterizer.clearCache()
        defer { rasterizer.debugResetFailureTracking() }
        rasterizer.debugTeardownWebView()
        #expect(!rasterizer.debugHasWebView)
        async let pending = rasterizer.raster(
            source: "$p$", isDisplay: false, fontSizePt: 13, color: .white, scale: 2)
        // Let the request reach ensureWebView, then kill the page before
        // it finishes loading.
        for _ in 0..<100 where !rasterizer.debugHasWebView { await Task.yield() }
        #expect(rasterizer.debugHasWebView)
        #expect(!rasterizer.debugIsPageReady)
        rasterizer.debugSimulatePageFailure()
        #expect(await pending == nil)
        #expect(rasterizer.lastRejectionReason == "no web view")
        #expect(!rasterizer.debugIsPageReady)
        // The failed request is negative-cached; a fresh request rebuilds
        // the page, which must be marked ready by its own load, not by the
        // stale one.
        let before = rasterizer.renderCount
        #expect(await rasterizer.raster(source: "$p$", isDisplay: false, fontSizePt: 13, color: .white, scale: 2) == nil)
        #expect(rasterizer.renderCount == before)
        let other = try #require(await rasterizer.raster(
            source: "$q$", isDisplay: false, fontSizePt: 13, color: .white, scale: 2))
        #expect(other.widthPt > 0)
        #expect(rasterizer.debugIsPageReady)
        rasterizer.clockOffset = 3
        let retried = try #require(await rasterizer.raster(
            source: "$p$", isDisplay: false, fontSizePt: 13, color: .white, scale: 2))
        #expect(retried.widthPt > 0)
        #expect(rasterizer.renderCount == before + 2)
    }

    @Test
    func idleTeardownReleasesTheWebViewAndRebuildsLazily() async throws {
        rasterizer.clearCache()
        let savedInterval = rasterizer.idleTeardownInterval
        defer { rasterizer.idleTeardownInterval = savedInterval }
        rasterizer.idleTeardownInterval = 0.05
        let first = try #require(await rasterizer.raster(
            source: "$i$", isDisplay: false, fontSizePt: 13, color: .white, scale: 2))
        #expect(rasterizer.debugHasWebView)
        for _ in 0..<100 where rasterizer.debugHasWebView {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!rasterizer.debugHasWebView)
        // The cache survives the teardown; a miss rebuilds the page.
        #expect(rasterizer.cachedRaster(source: "$i$", isDisplay: false, fontSizePt: 13, color: .white, scale: 2)?.image === first.image)
        let before = rasterizer.renderCount
        let second = try #require(await rasterizer.raster(
            source: "$j$", isDisplay: false, fontSizePt: 13, color: .white, scale: 2))
        #expect(second.widthPt > 0)
        #expect(rasterizer.renderCount == before + 1)
        #expect(rasterizer.debugHasWebView)
        rasterizer.idleTeardownInterval = savedInterval
        // Re-arm the timer with the restored interval so the teardown
        // scheduled at 0.05 s does not fire under a later test.
        _ = await rasterizer.raster(source: "$j$", isDisplay: false, fontSizePt: 13, color: .white, scale: 2)
    }

    @Test
    func formulaWiderThanTheCanvasIsRejectedAndCached() async {
        rasterizer.clearCache()
        let source = "$" + String(repeating: "x+", count: 300) + "x$"
        let raster = await rasterizer.raster(source: source, isDisplay: false, fontSizePt: 13, color: .white, scale: 2)
        #expect(raster == nil)
        #expect(rasterizer.lastRejectionReason == "formula exceeds the raster canvas")
        #expect(rasterizer.isCachedRejection(source: source, isDisplay: false, fontSizePt: 13, color: .white, scale: 2))
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
