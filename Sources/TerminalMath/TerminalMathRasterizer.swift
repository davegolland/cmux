import AppKit
import Foundation
import WebKit

/// Rasterizes LaTeX math to transparent bitmaps for the terminal math
/// overlay, using one hidden `WKWebView` with KaTeX loaded once.
///
/// Rendering pipeline per request (all on the main actor, serialized so two
/// callers never share the page's `#stage` element):
///   1. `katex.renderToString` into `#stage` with the same guard options the
///      markdown viewer uses (`cmux-math.js`): `throwOnError`, `output: 'html'`,
///      a `trust` callback that refuses and records the refusal, `strict:
///      'ignore'`, `maxExpand: 100`, `maxSize: 100`, plus its body-length and
///      macro-definition rejections (also applied on the Swift side so a
///      rejection never costs a JavaScript round trip).
///   2. Force layout, wait for `document.fonts.ready` (all KaTeX faces are
///      preloaded at page load, so this is normally already settled).
///   3. Measure the stage box. The stage is an inline-block with
///      `line-height: 0` on itself and on `.katex`, so line boxes are sized
///      only by KaTeX's own struts and vlists (the typographic height and
///      depth KaTeX computed), not by font line-height. Baseline: a zero-size
///      inline-block probe appended to `.katex-html` sits with its bottom
///      edge on the line's baseline; `probe.bottom - box.top` is the
///      baseline offset.
///   4. `WKSnapshotConfiguration` with `rect` = the measured box (integral
///      CSS px, padded by 1 px for glyph overshoot) and `snapshotWidth` =
///      width x scale / devicePixelRatio. `snapshotWidth` is in points and
///      WebKit paints the snapshot at the page's device scale on top of it,
///      so dividing by the page's ratio yields exactly `scale` pixels per
///      point.
///
/// Parse errors, trust refusals, and the other guard rejections resolve to
/// `nil` and are cached as rejections; transient failures (snapshot errors,
/// a terminated web content process) are not cached.
///
/// The KaTeX assets are read through `MarkdownViewerAssets.shared.lazyAsset`
/// on the first render, never at app start, because touching
/// `MarkdownViewerAssets.shared` eagerly loads the markdown viewer bundle.
///
/// Colors are part of the cache key, so `.ghosttyConfigDidReload` and theme
/// changes need no invalidation here: a new foreground color is a new key.
@MainActor
final class TerminalMathRasterizer {

    static let shared = TerminalMathRasterizer()

    // MARK: - Types

    /// A rendered formula: the bitmap plus the metrics needed to place it on
    /// a text baseline. Metrics are in points (CSS px of the hidden page);
    /// the image's backing store is `scale` times larger in each dimension.
    struct Raster {
        let image: NSImage
        /// Image width in points.
        let widthPt: CGFloat
        /// Image height in points.
        let heightPt: CGFloat
        /// Distance from the top edge of the image down to the text baseline.
        /// Composite the image so that `imageTop + baselinePt == lineBaseline`.
        let baselinePt: CGFloat
        /// Snapshot scale factor (device pixels per point).
        let scale: CGFloat
    }

    private struct CacheKey: Hashable {
        var body: String
        var isDisplay: Bool
        var fontSizePt: CGFloat
        var colorHex: String
        var scale: CGFloat
    }

    private enum CacheEntry {
        case rendered(Raster, bytes: Int)
        case rejected(String)

        var bytes: Int {
            switch self {
            case .rendered(_, let bytes): return bytes
            case .rejected: return 0
            }
        }
    }

    private struct StageMetrics: Decodable {
        var ok: Bool
        var error: String?
        var x: Double?
        var y: Double?
        var width: Double?
        var height: Double?
        var baseline: Double?
        var dpr: Double?
    }

    // MARK: - Limits

    /// Longest body (UTF-16 units, matching JavaScript `String.length` in
    /// `cmux-math.js`) KaTeX is asked to typeset.
    static let maxRenderBodyLength = 4096

    /// Cap on the summed bitmap bytes held by the cache.
    static let cacheByteLimit = 64 * 1024 * 1024

    /// Cap on cache entries, so cheap rejections cannot grow without bound.
    static let cacheEntryLimit = 4096

    /// Size of the hidden page; formulas larger than this are clipped.
    private static let canvasSize = CGSize(width: 2048, height: 1024)

    /// Padding, in CSS px, added around the measured box so glyph overshoot
    /// (italic overhang, radicals, big delimiters) is never clipped.
    private static let padding: CGFloat = 1

    /// Macro definitions let a short body expand into arbitrarily much work
    /// (`maxExpand` bounds the count of expansions, not their size). Same
    /// pattern as `MACRO_DEFINITION` in `cmux-math.js`.
    private static let macroDefinitionPattern =
        #"\\(?:def|gdef|edef|xdef|let|futurelet|global|newcommand|renewcommand|providecommand|DeclareMathOperator)\b"#

    private static let macroDefinitionRegex: NSRegularExpression? =
        try? NSRegularExpression(pattern: macroDefinitionPattern)

    // MARK: - State

    private var cache: [CacheKey: CacheEntry] = [:]
    /// Least recently used first.
    private var cacheOrder: [CacheKey] = []
    private var cacheBytes = 0

    private var webView: WKWebView?
    private var navigationWatcher: NavigationWatcher?
    private var pageReady = false
    private var readyWaiters: [CheckedContinuation<Void, Never>] = []
    private var queueTail: Task<Void, Never>?

    /// Why the most recent request returned `nil`, for the debug dump.
    private(set) var lastRejectionReason: String?

    /// Number of times a formula was actually typeset in the page (cache
    /// misses that reached JavaScript). Test hook.
    private(set) var renderCount = 0

    private init() {}

    // MARK: - Public API

    /// Renders `source` (with or without its `$`, `$$`, `\(`, `\[`
    /// delimiters) and returns the transparent bitmap with its placement
    /// metrics, or `nil` when the input is rejected: a KaTeX parse error, a
    /// trust-gated command, a body over `maxRenderBodyLength`, or a macro
    /// definition. `lastRejectionReason` says why.
    func raster(source: String, isDisplay: Bool, fontSizePt: CGFloat, color: NSColor, scale: CGFloat) async -> Raster? {
        let key = Self.cacheKey(source: source, isDisplay: isDisplay, fontSizePt: fontSizePt, color: color, scale: scale)
        if let entry = lookup(key) {
            return raster(from: entry)
        }
        if let reason = Self.precheckRejection(body: key.body) {
            lastRejectionReason = reason
            store(key: key, entry: .rejected(reason))
            return nil
        }
        // Serialize: the page has one stage. Later callers wait for earlier
        // ones, and a duplicate in-flight request lands on the cache.
        let previous = queueTail
        let job = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            if self.cache[key] == nil {
                await self.renderUncontended(key: key)
            }
        }
        queueTail = job
        await job.value
        return lookup(key).flatMap { raster(from: $0) }
    }

    /// Synchronous cache probe for the draw path. Returns `nil` for both a
    /// miss and a cached rejection; use `raster(...)` to render.
    func cachedRaster(source: String, isDisplay: Bool, fontSizePt: CGFloat, color: NSColor, scale: CGFloat) -> Raster? {
        let key = Self.cacheKey(source: source, isDisplay: isDisplay, fontSizePt: fontSizePt, color: color, scale: scale)
        return lookup(key).flatMap { raster(from: $0) }
    }

    /// Whether the cache holds a rejection for this input, so the caller can
    /// stop asking without waiting on `raster(...)`.
    func isCachedRejection(source: String, isDisplay: Bool, fontSizePt: CGFloat, color: NSColor, scale: CGFloat) -> Bool {
        let key = Self.cacheKey(source: source, isDisplay: isDisplay, fontSizePt: fontSizePt, color: color, scale: scale)
        if case .rejected = cache[key] { return true }
        return false
    }

    func clearCache() {
        cache.removeAll()
        cacheOrder.removeAll()
        cacheBytes = 0
    }

    /// Strip math delimiters the way `CmuxMath.bodyOf` does, then trim.
    static func body(of source: String) -> String {
        let s = source
        let stripped: String
        if s.hasPrefix("$$"), s.hasSuffix("$$"), s.count >= 4 {
            stripped = String(s.dropFirst(2).dropLast(2))
        } else if s.hasPrefix("\\["), s.hasSuffix("\\]"), s.count >= 4 {
            stripped = String(s.dropFirst(2).dropLast(2))
        } else if s.hasPrefix("\\("), s.hasSuffix("\\)"), s.count >= 4 {
            stripped = String(s.dropFirst(2).dropLast(2))
        } else if s.hasPrefix("$"), s.hasSuffix("$"), s.count >= 2 {
            stripped = String(s.dropFirst().dropLast())
        } else {
            stripped = s
        }
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The Swift-side copy of the `cmux-math.js` pre-checks. Returns the
    /// rejection reason, or `nil` when KaTeX may be asked to typeset `body`.
    static func precheckRejection(body: String) -> String? {
        if body.utf16.count > maxRenderBodyLength {
            return "body too long"
        }
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        if let regex = macroDefinitionRegex, regex.firstMatch(in: body, range: range) != nil {
            return "macro definitions are not rendered"
        }
        return nil
    }

    // MARK: - Cache

    private static func cacheKey(source: String, isDisplay: Bool, fontSizePt: CGFloat, color: NSColor, scale: CGFloat) -> CacheKey {
        CacheKey(
            body: body(of: source),
            isDisplay: isDisplay,
            fontSizePt: fontSizePt,
            colorHex: hex(of: color),
            scale: scale
        )
    }

    private func lookup(_ key: CacheKey) -> CacheEntry? {
        guard let entry = cache[key] else { return nil }
        if let index = cacheOrder.lastIndex(of: key), index != cacheOrder.count - 1 {
            cacheOrder.remove(at: index)
            cacheOrder.append(key)
        }
        return entry
    }

    private func store(key: CacheKey, entry: CacheEntry) {
        if let existing = cache.updateValue(entry, forKey: key) {
            cacheBytes -= existing.bytes
            if let index = cacheOrder.lastIndex(of: key) {
                cacheOrder.remove(at: index)
            }
        }
        cacheOrder.append(key)
        cacheBytes += entry.bytes
        while cacheOrder.count > 1,
              cacheBytes > Self.cacheByteLimit || cacheOrder.count > Self.cacheEntryLimit {
            let evicted = cacheOrder.removeFirst()
            if let removed = cache.removeValue(forKey: evicted) {
                cacheBytes -= removed.bytes
            }
        }
    }

    private func raster(from entry: CacheEntry) -> Raster? {
        if case .rendered(let raster, _) = entry { return raster }
        return nil
    }

    // MARK: - Rendering

    private func renderUncontended(key: CacheKey) async {
        await waitForPage()
        guard let webView else {
            lastRejectionReason = "no web view"
            return
        }
        renderCount += 1
        let js = """
        return await window.__cmuxMathRaster.render(body, displayMode, fontSizePx, color, pad);
        """
        let arguments: [String: Any] = [
            "body": key.body,
            "displayMode": key.isDisplay,
            "fontSizePx": Double(key.fontSizePt),
            "color": key.colorHex,
            "pad": Double(Self.padding),
        ]
        let stage: StageMetrics
        do {
            let result = try await webView.callAsyncJavaScript(js, arguments: arguments, in: nil, contentWorld: .page)
            guard let json = result as? String, let data = json.data(using: .utf8) else {
                lastRejectionReason = "unexpected JS result"
                return
            }
            stage = try JSONDecoder().decode(StageMetrics.self, from: data)
        } catch {
            lastRejectionReason = "JS failure: \(error)"
            return
        }
        guard stage.ok,
              let x = stage.x, let y = stage.y,
              let width = stage.width, let height = stage.height,
              let baseline = stage.baseline,
              width > 0, height > 0 else {
            let reason = stage.error ?? "rejected"
            lastRejectionReason = reason
            store(key: key, entry: .rejected(reason))
            return
        }
        let rect = CGRect(x: x, y: y, width: width, height: height)
        let devicePixelRatio = CGFloat(stage.dpr ?? 1)
        let snapshotConfiguration = WKSnapshotConfiguration()
        snapshotConfiguration.rect = rect
        snapshotConfiguration.snapshotWidth = NSNumber(value: Double(width * key.scale / max(devicePixelRatio, 0.01)))
        let snapshot: NSImage
        do {
            snapshot = try await webView.takeSnapshot(configuration: snapshotConfiguration)
        } catch {
            lastRejectionReason = "snapshot failure: \(error)"
            return
        }
        // The snapshot comes back as an NSImage of `snapshotWidth` points
        // backed by a devicePixelRatio-scaled bitmap (width * scale pixels
        // after the division above); rewrap that bitmap as a `scale`x image
        // whose point size is the measured box.
        guard let cgImage = snapshot.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            lastRejectionReason = "snapshot has no bitmap"
            return
        }
        let pointSize = NSSize(width: width, height: height)
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = pointSize
        let image = NSImage(size: pointSize)
        image.addRepresentation(rep)
        let bytes = max(rep.bytesPerRow * rep.pixelsHigh, cgImage.width * cgImage.height * 4)
        let raster = Raster(
            image: image,
            widthPt: width,
            heightPt: height,
            baselinePt: baseline,
            scale: key.scale
        )
        lastRejectionReason = nil
        store(key: key, entry: .rendered(raster, bytes: bytes))
    }

    // MARK: - Page lifecycle

    private func ensureWebView() {
        guard webView == nil else { return }
        let assets = MarkdownViewerAssets.shared
        let katexJS = assets.lazyAsset(name: "katex.min", ext: "js")
        let katexCSS = assets.lazyAsset(name: "katex-fonts.min", ext: "css")

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.suppressesIncrementalRendering = true
        let webView = WKWebView(frame: CGRect(origin: .zero, size: Self.canvasSize), configuration: configuration)
        // Transparent page: no white backdrop behind the formula. The KVC
        // key is the long-standing way to reach WKWebView's private
        // `_drawsBackground` on macOS.
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        webView.allowsLinkPreview = false
        let watcher = NavigationWatcher()
        watcher.onFinish = { [weak self] in self?.pageDidLoad() }
        watcher.onProcessTerminated = { [weak self] in self?.pageDidTerminate() }
        webView.navigationDelegate = watcher
        self.webView = webView
        self.navigationWatcher = watcher
        pageReady = false
        webView.loadHTMLString(Self.pageHTML(katexJS: katexJS, katexCSS: katexCSS, padding: Self.padding), baseURL: nil)
    }

    private func pageDidLoad() {
        Task { [weak self] in
            guard let self, let webView = self.webView else { return }
            // Load every KaTeX face once so later renders never wait on
            // fonts. Failures here are not fatal: render() awaits
            // document.fonts.ready anyway.
            _ = try? await webView.callAsyncJavaScript(
                "return await window.__cmuxMathRaster.preloadFonts();", arguments: [:], in: nil, contentWorld: .page)
            self.pageReady = true
            self.resumeReadyWaiters()
        }
    }

    /// The web content process died: drop the page so the next request
    /// rebuilds it. Waiters resume and their render fails transiently
    /// (not cached), so a later request retries.
    private func pageDidTerminate() {
        webView?.navigationDelegate = nil
        webView = nil
        navigationWatcher = nil
        pageReady = false
        resumeReadyWaiters()
    }

    private func resumeReadyWaiters() {
        let waiters = readyWaiters
        readyWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func waitForPage() async {
        ensureWebView()
        if pageReady { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            readyWaiters.append(continuation)
        }
    }

    // MARK: - Colors

    /// `#RRGGBBAA` in sRGB. One string serves as both the cache key and the
    /// CSS `color` value, so the two can never disagree.
    private static func hex(of color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        func byte(_ v: CGFloat) -> Int { Int((max(0, min(1, v)) * 255).rounded()) }
        return String(
            format: "#%02x%02x%02x%02x",
            byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent), byte(c.alphaComponent)
        )
    }

    // MARK: - Page markup

    private static func pageHTML(katexJS: String, katexCSS: String, padding: CGFloat) -> String {
        // Content-Security-Policy: nothing may be fetched; fonts are data
        // URIs and the library is inline. The guard options and pre-checks
        // in `typeset` mirror `cachedRender` in cmux-math.js.
        let offset = Int(padding) + 8
        return """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; font-src data:;">
        <style>\(katexCSS)</style>
        <style>
        html, body { margin: 0; padding: 0; background: transparent; overflow: hidden; }
        /* The stage is an inline-block whose line boxes are sized only by
           KaTeX's struts and vlists: zero line-height on the stage and on
           .katex removes the font-driven strut of every plain inline box.
           Glyph positions are unchanged (baselines still align); only the
           boxes shrink to the typographic height + depth KaTeX computed. */
        #stage { position: absolute; left: \(offset)px; top: \(offset)px; display: inline-block; white-space: nowrap; line-height: 0; }
        #stage .katex { line-height: 0; color: inherit; }
        #stage .katex-display { margin: 0; }
        /* Zero-size inline-block: its bottom edge is the line's baseline. */
        #stage .cmux-baseline-probe { display: inline-block; width: 0; height: 0; vertical-align: baseline; }
        </style>
        <script>\(katexJS)</script>
        <script>
        window.__cmuxMathRaster = (function () {
          'use strict';
          var MAX_RENDER_BODY = \(maxRenderBodyLength);
          var MACRO_DEFINITION = /\\\\(?:def|gdef|edef|xdef|let|futurelet|global|newcommand|renewcommand|providecommand|DeclareMathOperator)\\b/;
          function typeset(body, displayMode) {
            if (body.length > MAX_RENDER_BODY) { throw new Error('body too long'); }
            if (MACRO_DEFINITION.test(body)) { throw new Error('macro definitions are not rendered'); }
            var sawUntrusted = false;
            var html = katex.renderToString(body, {
              displayMode: displayMode,
              throwOnError: true,
              output: 'html',
              trust: function () { sawUntrusted = true; return false; },
              strict: 'ignore',
              maxSize: 100,
              maxExpand: 100
            });
            if (sawUntrusted) { throw new Error('untrusted command'); }
            return html;
          }
          async function render(body, displayMode, fontSizePx, color, pad) {
            var stage = document.getElementById('stage');
            stage.style.fontSize = fontSizePx + 'px';
            stage.style.color = color;
            var html;
            try {
              html = typeset(body, displayMode);
            } catch (e) {
              stage.innerHTML = '';
              return JSON.stringify({ ok: false, error: String(e && e.message || e) });
            }
            stage.innerHTML = html;
            var htmlEl = stage.querySelector('.katex-html');
            if (!htmlEl) { stage.innerHTML = ''; return JSON.stringify({ ok: false, error: 'no katex-html output' }); }
            var probe = document.createElement('span');
            probe.className = 'cmux-baseline-probe';
            htmlEl.appendChild(probe);
            // Layout now so any glyph-triggered font load starts, then wait.
            stage.getBoundingClientRect();
            if (document.fonts && document.fonts.status !== 'loaded') { await document.fonts.ready; }
            var r = stage.getBoundingClientRect();
            var p = probe.getBoundingClientRect();
            var x = Math.floor(r.left) - pad;
            var y = Math.floor(r.top) - pad;
            var w = Math.ceil(r.right) + pad - x;
            var h = Math.ceil(r.bottom) + pad - y;
            return JSON.stringify({ ok: true, x: x, y: y, width: w, height: h, baseline: p.bottom - y,
              dpr: window.devicePixelRatio || 1 });
          }
          function preloadFonts() {
            if (!document.fonts) { return Promise.resolve(0); }
            var faces = Array.from(document.fonts);
            return Promise.all(faces.map(function (f) { return f.load(); })).then(function () { return faces.length; });
          }
          return { render: render, preloadFonts: preloadFonts };
        })();
        </script>
        </head><body><div id="stage"></div></body></html>
        """
    }
}

/// Navigation delegate kept separate so the rasterizer need not subclass
/// NSObject.
@MainActor
private final class NavigationWatcher: NSObject, WKNavigationDelegate {
    var onFinish: (() -> Void)?
    var onProcessTerminated: (() -> Void)?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onFinish?()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        // The page is inline HTML; a failed load leaves waiters parked until
        // the process is recycled. Treat it like a terminated process.
        onProcessTerminated?()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        onProcessTerminated?()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        onProcessTerminated?()
    }
}
