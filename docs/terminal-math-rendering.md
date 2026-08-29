# Typeset math in the terminal grid

Status: implemented (phases 1-5) on `feat/terminal-math-overlay`; not yet dogfooded on a running build. The section "As built" at the end records where the implementation departs from the design below.

## Problem

Claude Code prints LaTeX (`$m \approx C \cdot k \log(n/k)$`, `$$...$$`) into the terminal. Ghostty draws the source characters as cells. The markdown viewer now typesets the same text, but a user who runs `claude` in a terminal reads the grid, not a webview. This document fixes the four decisions the requirements left open and lays out the implementation in the order it should ship.

## Decisions

### 1. Surface order

1. Markdown viewer (`cmux markdown open`): shipped on `feat/markdown-viewer-math`.
2. Terminal grid: this document.
3. Agent-session webview: not planned. It is a `#if DEBUG` feature that spawns its own `claude -p --output-format stream-json` child, and its React build ships as `main.mjs.deflate` with no inflate path, so it does not run in release. If it is revived, `webviews/src/agent-session/shared/markdown.ts` can register `CmuxMath.markedExtensions()` the same way `shell.html` does; the detection rules are identical.

### 2. Detection point: the terminal text, read back from Ghostty

Three candidates were on the table.

- Raw PTY bytes. cmux sees every byte through the fork-only tee `ghostty_surface_set_pty_tee_cb` (Sources/TerminalSurfaceRuntimeWiring.swift:113-117, Sources/TerminalOutputTeeCallback.swift:4-15). The tee is read-only and runs on Ghostty's IO thread before the VT parser, so it can flag "this surface just received a `$`", but it cannot know where the text lands on screen: Claude Code is a TUI (ink) that redraws lines with cursor movement, so byte offsets do not map to cells.
- A Claude Code output hook. Out of scope by requirement, and Claude Code has no display-rewrite hook.
- The rendered grid. `ghostty_surface_render_grid_json_v2` (Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Surface/TerminalSurface+Mobile.swift:114-160) returns the viewport as rows with column-exact spans and styles (`MobileTerminalRenderGridFrame`, Packages/Shared/CMUXMobileCore). This is what the phone mirror uses. Wide cells and graphemes get their own spans (docs/ghostty-fork.md:1372-1385), so a span's column is a cell coordinate.

Decision: detect on the rendered grid, gated by the tee. The tee runs `TerminalMathSpanDetector.hasMath(in:)` on each chunk (a cheap `$`/`\(`/`\[` pre-check, no allocation) and raises a per-surface "math candidate" flag, the same shape as `PromptLineTurnDetector` in Sources/TerminalOutputTeeContext.swift:62-87. On the next `.ghosttyDidRenderFrame` (only while the flag is set, and coalesced like Sources/Mobile/MobileTerminalRenderObserver.swift:45-70), the main actor calls `mobileRenderGridFrame(anchor: .viewport)`, joins each row's spans into a line, stitches soft-wrapped rows (`rowSpans` carry the wrap flag; `TerminalArtifactTapHitTester` already does this for paths), and runs `TerminalMathSpanDetector().spans(in:)` on each logical line. The result is a list of `(row, startColumn, endColumn, source, isDisplay)`.

Never call `ghostty_surface_read_text` per byte or per frame without the gate: it takes the surface lock (see the note in Packages/iOS/.../GhosttySurfaceView+Artifacts.swift:12-22).

### 3. Image or text: an overlay view, not Kitty graphics

- Kitty graphics through `ghostty_surface_process_output` (Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Surface/TerminalSurface+Input.swift:647-652) would put images into the terminal's own state. Claude Code redraws its output region on every token, which clears and shifts placements, and the fork's bounded Kitty storage evicts them (docs/ghostty-fork.md:919-941). Selection would also break, and copy could not return the source.
- Unicode substitution cannot draw a fraction or a radical, and it would require rewriting bytes, which the tee cannot do.
- An overlay NSView above the Metal layer is how cmux already draws cell-aligned chrome: `keyboardCopyModeCursorOverlayView` (Sources/GhosttyTerminalView.swift:3906, 4039-4045) is positioned by `KeyboardCopyModeGridMetrics.appKitRect` from `ghostty_surface_grid_metrics` (Sources/KeyboardCopyModeGridMetrics.swift:10-29, GhosttyTerminalView.swift:5158-5175) and re-synced on every rendered frame (GhosttyTerminalView.swift:3827-3844, 5224-5242). `GhosttyFlashOverlayView` (Sources/GhosttyFlashOverlayView.swift) is the pass-through base class.

Decision: a `TerminalMathOverlayView` (a `GhosttyFlashOverlayView` subclass) that, for each detected span, paints an opaque patch in the terminal background color over the source cells and draws the typeset formula inside that patch. The patch is exactly `endColumn - startColumn` cells wide and one row tall for inline math; a display span may grow to two rows when the formula is taller than a cell, in which case the overlay draws it centered in the row and lets it overhang the row above and below by up to half a cell (the source line is only `$$...$$`, so the neighbors are prose or blank). When a formula does not fit its patch at the terminal font size, the overlay scales it down to fit; if that would drop below 70% of the cell height, it does not draw and the raw text stays visible (requirement R9).

Hit testing: the overlay keeps `hitTest` nil so selection and clicks reach Ghostty. Copy is handled in cmux, not Ghostty: `ghostty_surface_copy_selection_to_clipboard_bounded` (GhosttyTerminalView.swift:5416-5423) already copies the underlying cells, which are the LaTeX source. Requirement R5 is therefore met by construction: the grid still holds `$m \approx ...$`, only the pixels change.

### 4. Renderer: KaTeX in an offscreen WKWebView, rasterized

There is no native math typesetter in the bundle, and adding one (a TeX layout engine in Swift) is out of proportion. KaTeX is already bundled and verified in the markdown viewer.

Decision: one hidden `WKWebView` per app (`TerminalMathRasterizer`, main actor) that loads a tiny shell with `katex-fonts.min.css` and `katex.min.js` from `MarkdownViewerAssets.shared.lazyAsset`, plus `cmux-math.js` for the same guards (`trust:false`, `maxExpand:100`, 4 KB body cap, no macro definitions). It exposes `render(source:isDisplay:fontSizePt:color:) async -> NSImage?` by evaluating `katex.renderToString` into a sized `<div>` and calling `takeSnapshot(with:)` with a transparent background. Results are cached by `(source, isDisplay, fontSize, color, scale)` with a byte cap. Latency is roughly 10-30 ms per formula after the first render, and the overlay draws the raw text until the image arrives, so streaming output never flickers: a formula appears when its closing delimiter has been on screen for one frame.

Theme: the rasterizer reads the surface's foreground and background colors from the render-grid frame (`terminalForeground`, `terminalBackground`) and re-renders when they change; KaTeX uses `currentColor`.

Zoom: the terminal font size comes from `ghostty_surface_grid_metrics` cell height; the rasterizer sets the KaTeX font size so the x-height matches the cell font.

## Implementation phases

Each phase is a PR that can ship alone.

1. Detector (done): `TerminalMathSpanDetector`, `TerminalMathSpan`, `TerminalEscapeSequenceStripper` in CmuxAgentChat with Swift Testing coverage and JS parity.
2. Grid scan: `TerminalMathScanner` in the app target. Tee gate in `TerminalOutputTeeContext`; frame-coalesced scan using `mobileRenderGridFrame`; soft-wrap stitching; produces `[TerminalMathPlacement]` per surface. Debug-menu command to dump placements. Tests: pure stitching and placement math with fixture frames (the mobile tests under Packages/iOS/CmuxMobileShell/Tests have `MobileTerminalRenderGridFrame` fixtures to copy).
3. Overlay: `TerminalMathOverlayView` added to `GhosttyNSView` next to the copy-mode overlay, with a `RenderedFrameDeliveryReason` case so it re-syncs on scroll and reflow, and demand registration on `GhosttyMetalLayer`. First version draws only the background patch plus the source text in the terminal font (a no-op visually) to prove alignment across resize, scroll, split, and zoom.
4. Rasterizer: `TerminalMathRasterizer` with the KaTeX webview, cache, and fit rules. Overlay draws images.
5. Setting and toggle: `markdown.renderMath` and `terminal.renderMath` as `DefaultsKey<Bool>` in CmuxSettings (pattern: `AppCatalogSection.openMarkdownInCmuxViewer`, Packages/macOS/CmuxSettings/Sources/CmuxSettings/Keys/AppCatalogSection.swift:97-101), rows in AppSection.swift, entries in `supportedSettingsJSONPaths` (Sources/CmuxSettingsJSONPathSupport.swift), the cmux.json template, `web/data/cmux.schema.json` and every `web/messages/*.json`, a `CommandPaletteSettingToggleDescriptor`, and a `ShortcutAction` case for "toggle math on this surface". The markdown viewer reads its flag through `MarkdownPanel`'s existing `UserDefaults.didChangeNotification` observer and calls a new `window.__cmuxSetMathEnabled`.

## Risks

- Claude Code redraw churn: the TUI rewrites its output region on every token, so placements change constantly while streaming. The scan is coalesced per rendered frame and the rasterizer cache makes repeated formulas free, but the overlay must never draw a formula whose cells no longer hold that source. Rule: the overlay re-validates each placement against the latest frame before drawing; a mismatch hides it.
- Scrollback: placements are viewport-anchored. When the user scrolls, the next frame re-scans; nothing is drawn from stale rows.
- Alternate screen and full-screen TUIs (vim, less): skip the scan when the frame's `modes` report the alternate screen.
- Wide glyphs and combining characters inside a formula source are rare; spans are column-exact, so the patch still covers the right cells.
- A patch hides the cursor if the cursor sits inside a formula. Rule: do not draw over the cursor row while the cursor is inside the span.

## What needs Xcode

Phases 2-5 are Swift in the app target and cannot be compiled or run on the authoring machine (Command Line Tools only; SwiftPM manifest loading is also broken there). Phase 1 was verified with `swiftc`, a differential harness against `cmux-math.js`, and a Testing-framework run, all without Xcode. Phase 4 can be prototyped as a standalone `swiftc` program (a WKWebView rasterizer needs only AppKit and WebKit) before it is wired into the app.

## Verification plan

- Unit: placement math and wrap stitching with fixture frames; rasterizer fit rules with a fake image size.
- Integration (tagged Debug build, `./scripts/reload.sh --tag terminal-math --launch`): run `claude` and ask for the requirements document's acceptance answer; check every row of the acceptance table on screen; select and copy a formula and paste into a new prompt; resize, scroll, split, and zoom; switch the Ghostty theme; open vim and confirm no overlay.
- Performance: the tee gate adds one byte scan per chunk; measure typing latency with the `cmux-debugging` skill's checks before and after, and keep the scan off the IO thread.

## As built

The implementation follows the decisions above with these corrections, found while reading the code the design cites.

- `MobileTerminalRenderGridFrame.RowSpan` carries no wrap flag. `TerminalMathGridScanner` (CmuxAgentChat, pure) infers a soft wrap the way `TerminalArtifactTapHitTester` does: row r continues onto r+1 when r fills the width and r+1 starts with a non-space cell. A logical line is cut after 16 rows (32 when the following rows keep holding delimiters, so a closer is never orphaned into the next line), and a source longer than 1024 characters is dropped.
- `GhosttyFlashOverlayView` is `final`; `TerminalMathOverlayView` copies its two overrides (`acceptsFirstResponder = false`, `hitTest -> nil`) and is flipped. It sits below the copy-mode cursor overlay.
- No `RenderedFrameDeliveryReason` case was added. The controller retains the view-local rendered-frame demand (`retainLocalRenderedFrameNotifications()`) and observes `.ghosttyDidRenderFrame` for its own view, so the CmuxTerminal package is unchanged.
- The tee gate is `TerminalMathByteGate` (CmuxTerminalCore), a byte-level state machine, because `TerminalMathSpanDetector.hasMath(in:)` needs a `String`. It ignores bytes inside ESC/CSI/OSC sequences, tracks DEC private modes 47/1047/1049 so nothing fires on the alternate screen (leaving it fires once), and bumps a revision at most once per chunk. `TerminalOutputTeeContext` arms an `AtomicBooleanGate` and hops to `TerminalMathCandidateRouter` on the main actor; the router clears the flag after each frame-driven scan.
- Scan timing is a pure state machine, `TerminalMathScanPolicy` (CmuxAgentChat): a candidate only retains demand and requests a tick; the next rendered frame scans; frame-driven scans are throttled to one per 100 ms with a single trailing scan while placements are visible; two empty frame-driven scans release demand; a viewport change with nothing on screen probes at most every 500 ms without demand; enabling the setting scans at once. `TerminalMathSurfaceController` is the adapter that executes the policy's actions.
- The rasterizer loads `katex.min.js` and `katex-fonts.min.css` into a hidden, windowless `WKWebView` (`drawsBackground = false` is required for a transparent snapshot) and applies the same guards as `cmux-math.js`: `trust: false`, `maxExpand: 100`, `maxSize: 100`, 4 KB body cap, no macro definitions. Rejections are cached; transient failures are cached with a 2 s backoff doubling to 30 s; three page failures in a minute start a 60 s cooldown; the web view is dropped after five idle minutes. The KaTeX font size is the surface's live point size (`ghostty_surface_font_size`) times 0.52/0.431 so KaTeX's x-height matches the terminal font.
- The overlay hides while Ghostty has a selection or copy mode is active, because the opaque patch would cover the selection highlight. The image is centred on the row; Ghostty exposes no in-cell baseline. Display math may overhang half a cell into the rows above and below only when both rows exist and are blank.
- The toggle is global (`terminal.renderMath`), not per surface: `toggleTerminalMathRendering` flips the setting for every terminal.

