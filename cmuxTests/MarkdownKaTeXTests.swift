import AppKit
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// LaTeX math in the markdown viewer: the shipped shell tokenizes
/// `$...$`, `\(...\)`, `$$...$$`, and `\[...\]`, requests KaTeX through the
/// `cmuxLib` bridge only when math is present, renders every placeholder,
/// leaves prose dollar signs alone, degrades rejected expressions to their
/// source text, and hands the LaTeX source back on copy and export.
@MainActor
@Suite
final class MarkdownKaTeXTests {
    @Test
    func unknownLazyLibraryHasNoSources() {
        #expect(MarkdownWebRenderer.Coordinator.lazyLibrarySources(for: "not-a-lib", assets: .shared) == nil)
    }

    @Test
    func mathRendersThroughTheBridgeAndCopiesItsSource() async throws {
        let markdownURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-markdown-katex-\(UUID().uuidString).md")
        let frame = NSRect(x: 0, y: 0, width: 720, height: 480)
        let configuration = WKWebViewConfiguration()
        let bridge = MarkdownKaTeXBridgeHandler()
        configuration.userContentController.add(bridge, name: "cmuxLib")
        let webView = MarkdownWebView(frame: frame, configuration: configuration)
        bridge.webView = webView
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        window.orderFrontRegardless()
        defer {
            webView.navigationDelegate = nil
            configuration.userContentController.removeScriptMessageHandler(forName: "cmuxLib")
            window.close()
        }

        let loadDelegate = MarkdownKaTeXShellLoadDelegate()
        webView.navigationDelegate = loadDelegate
        try await loadDelegate.load(MarkdownViewerAssets.shared.shellHTML(isDark: false), in: webView, baseURL: markdownURL)

        // Prose only: the bridge must stay quiet.
        try await renderMarkdown("Run `echo $PATH` or echo $PATH. It costs $5 to $10.", in: webView)
        #expect(bridge.requestedLibs.isEmpty)
        #expect(try await count(".cmux-math", in: webView) == 0)

        try await renderMarkdown(
            """
            The theory says $m \\approx C \\cdot k \\log(n/k)$. Also \\(x^2\\) here.

            $$k \\log(n/k) = 10 \\times \\ln(10{,}000) \\approx 92$$

            \\[\\int_0^1 f(x)\\,dx\\]

            A bad macro $\\notarealmacro{x}$ and a price of $5 to $10.
            """,
            in: webView
        )
        #expect(bridge.requestedLibs == ["katex"])
        try await waitUntil("document.querySelectorAll('.cmux-math-render .katex').length === 4", in: webView)
        // The stylesheet arrived before the library and its data: URI fonts
        // resolved, so no relative bundle path was needed.
        #expect(try await count("style#cmux-katex-css", in: webView) == 1)
        #expect(try await evaluateBool("document.fonts.check('1em KaTeX_Main')", in: webView))
        #expect(try await count(".cmux-math", in: webView) == 5)
        #expect(try await count("div.cmux-math-display .katex-display", in: webView) == 2)
        #expect(try await count("p > .cmux-math-display", in: webView) == 0)
        #expect(try await count(".cmux-math-fallback", in: webView) == 1)
        #expect(try await count(".cmux-render-error, .cmux-math-error", in: webView) == 0)

        let fallbackSource = try await evaluateString(
            "document.querySelector('.cmux-math-fallback .cmux-source').textContent", in: webView)
        #expect(fallbackSource == "$\\notarealmacro{x}$")

        // Export returns the LaTeX source, not KaTeX markup.
        let exportedText = try await evaluateString("window.__cmuxRenderedText()", in: webView)
        #expect(exportedText.contains("The theory says $m \\approx C \\cdot k \\log(n/k)$. Also \\(x^2\\) here."))
        #expect(exportedText.contains("$$k \\log(n/k) = 10 \\times \\ln(10{,}000) \\approx 92$$"))
        #expect(exportedText.contains("a price of $5 to $10."))
        #expect(!exportedText.contains("katex"))
        let exportedHTML = try await evaluateString("window.__cmuxRenderedHTML()", in: webView)
        #expect(!exportedHTML.contains("katex"))
        #expect(exportedHTML.contains("$m \\approx C \\cdot k \\log(n/k)$"))

        // Cmd+C over the first paragraph puts the delimited source on the
        // clipboard. WebKit lets a page construct a ClipboardEvent with its
        // own DataTransfer, so the handler's payload can be read back.
        let copied = try await evaluateString(
            """
            (function() {
              var p = document.querySelector('#content p');
              var range = document.createRange();
              range.selectNodeContents(p);
              var selection = window.getSelection();
              selection.removeAllRanges();
              selection.addRange(range);
              var transfer = new DataTransfer();
              var event = new ClipboardEvent('copy', { bubbles: true, cancelable: true, clipboardData: transfer });
              p.dispatchEvent(event);
              return (event.defaultPrevented ? '1' : '0') + '|' + transfer.getData('text/plain');
            })();
            """,
            in: webView
        )
        #expect(copied == "1|The theory says $m \\approx C \\cdot k \\log(n/k)$. Also \\(x^2\\) here.")
    }

    private func renderMarkdown(_ markdown: String, in webView: WKWebView) async throws {
        let data = try JSONSerialization.data(withJSONObject: [markdown])
        let literal = try #require(String(data: data, encoding: .utf8))
        _ = try await webView.evaluateJavaScript("window.__cmuxRenderMarkdown(\(literal)[0]);")
    }

    private func count(_ selector: String, in webView: WKWebView) async throws -> Int {
        let data = try JSONSerialization.data(withJSONObject: [selector])
        let literal = try #require(String(data: data, encoding: .utf8))
        let result = try await webView.evaluateJavaScript("document.querySelectorAll(\(literal)[0]).length")
        return try #require((result as? NSNumber)?.intValue)
    }

    private func evaluateString(_ script: String, in webView: WKWebView) async throws -> String {
        let result = try await webView.evaluateJavaScript(script)
        return try #require(result as? String)
    }

    private func evaluateBool(_ script: String, in webView: WKWebView) async throws -> Bool {
        let result = try await webView.evaluateJavaScript("!!(\(script))")
        return try #require((result as? NSNumber)?.boolValue)
    }

    private func waitUntil(_ condition: String, in webView: WKWebView) async throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let result = try await webView.evaluateJavaScript("!!(\(condition))")
            if (result as? NSNumber)?.boolValue == true { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw MarkdownKaTeXTimeout(condition: condition)
    }
}

private struct MarkdownKaTeXTimeout: Error, CustomStringConvertible {
    let condition: String

    var description: String {
        "Timed out waiting for: \(condition)"
    }
}

private final class MarkdownKaTeXShellLoadDelegate: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?

    func load(_ html: String, in webView: WKWebView, baseURL: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            webView.loadHTMLString(html, baseURL: baseURL)
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }
}

/// Stands in for `MarkdownWebRenderer.Coordinator.handleLibRequest`, serving
/// `{lib: "katex"}` with the shipped injection sources so the test renders
/// through the real stylesheet and library, not a stub.
@MainActor
private final class MarkdownKaTeXBridgeHandler: NSObject, WKScriptMessageHandler {
    weak var webView: WKWebView?
    private(set) var requestedLibs: [String] = []

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "cmuxLib",
              let body = message.body as? [String: Any],
              let lib = body["lib"] as? String else { return }
        requestedLibs.append(lib)
        guard lib == "katex",
              let sources = MarkdownWebRenderer.Coordinator.lazyLibrarySources(for: lib, assets: .shared) else {
            return
        }
        var injection = ""
        for source in sources where !source.isEmpty {
            injection += source
            injection += "\n;"
        }
        injection += "\nwindow.__cmuxLibLoaded && window.__cmuxLibLoaded('katex');"
        webView?.evaluateJavaScript(injection, completionHandler: nil)
    }
}
