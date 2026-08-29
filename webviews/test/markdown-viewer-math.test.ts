import { afterEach, describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { JSDOM } from "jsdom";

const viewerDir = join(import.meta.dir, "..", "..", "Resources", "markdown-viewer");
const asset = (name: string) => readFileSync(join(viewerDir, name), "utf8");
const shellTemplate = asset("shell.html");
const githubMarkdownCSS = asset("github-markdown.css");
const highlightLightCSS = asset("highlight-github.css");
const highlightDarkCSS = asset("highlight-github-dark.css");
const markedJS = asset("marked.min.js");
const highlightJS = asset("highlight.min.js");
const viewerNavigationJS = asset("viewer-navigation.js");
const cmuxMathJS = asset("cmux-math.js");
const katexJS = asset("katex.min.js");
const katexCSS = asset("katex-fonts.min.css");

// Drives the real markdown viewer shell (Resources/markdown-viewer/shell.html)
// through jsdom: marked with the math extension, the HTML sanitizer, the
// lazy-library bridge, KaTeX, export, and copy. The Swift side splices the
// same placeholders (Sources/Panels/MarkdownViewerAssets.swift), so this is
// the byte-for-byte page the panel loads, minus WebKit.

type Shell = {
  dom: JSDOM;
  window: JSDOM["window"] & {
    __cmuxRenderMarkdown: (md: string) => void;
    __cmuxRenderedText: () => string;
    __cmuxRenderedHTML: () => string;
    __cmuxLibLoaded: (name: string) => void;
    __cmuxSetMathEnabled: (enabled: boolean) => void;
    katex?: unknown;
  };
  document: Document;
  libRequests: string[];
  loadKatex: () => void;
};

function splicedShell(): string {
  return shellTemplate
    .replace("{{githubMarkdownCSS}}", () => githubMarkdownCSS)
    .replace("{{highlightLightCSS}}", () => highlightLightCSS)
    .replace("{{highlightDarkCSS}}", () => highlightDarkCSS)
    .replace("{{markedJS}}", () => markedJS)
    .replace("{{highlightJS}}", () => highlightJS)
    .replace("{{viewerNavigationJS}}", () => viewerNavigationJS)
    .replace("{{cmuxMathJS}}", () => cmuxMathJS)
    .replace("{{localizedStringsJSON}}", () => "{}");
}

let active: Shell | null = null;

// bun cannot run jsdom's `runScripts` (its vm rejects jsdom's global proxy),
// so the shell's inline scripts run in this process with jsdom's window and
// document installed as globals, the same way test/app.test.tsx does. Each
// shell re-evaluates every script, so `marked` starts clean per test.
const swappedGlobals = [
  "window", "document", "navigator", "Element", "Node", "NodeFilter", "HTMLElement",
  "DocumentFragment", "Range", "Event", "requestAnimationFrame", "cancelAnimationFrame",
  "getComputedStyle", "marked", "hljs", "katex", "CmuxViewerNavigation", "CmuxMath",
];
const originalGlobals = new Map<string, unknown>();
for (const key of swappedGlobals) {
  originalGlobals.set(key, (globalThis as Record<string, unknown>)[key]);
}

function inlineScripts(html: string): string[] {
  const scripts: string[] = [];
  const re = /<script>([\s\S]*?)<\/script>/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(html)) !== null) {
    scripts.push(m[1]);
  }
  return scripts;
}

function runInShell(code: string): void {
  // Indirect eval runs in global scope, so a bundle's top-level `var hljs`
  // lands on globalThis the way a classic <script> lands it on window.
  (0, eval)(code);
}

function openShell(options: { bridgeThrows?: boolean } = {}): Shell {
  const libRequests: string[] = [];
  const html = splicedShell();
  const dom = new JSDOM(html, { pretendToBeVisual: true });
  const window = dom.window as Shell["window"];
  const w = window as unknown as Record<string, unknown>;
  w.matchMedia = () => ({
    matches: false,
    addEventListener() {},
    removeEventListener() {},
    addListener() {},
    removeListener() {},
  });
  w.ResizeObserver = class {
    observe() {}
    unobserve() {}
    disconnect() {}
  };
  w.webkit = {
    messageHandlers: {
      cmuxLib: {
        postMessage(message: { lib: string }) {
          if (options.bridgeThrows) {
            throw new Error("bridge unavailable");
          }
          libRequests.push(message.lib);
        },
      },
    },
  };

  const g = globalThis as Record<string, unknown>;
  g.window = window;
  g.document = window.document;
  g.navigator = window.navigator;
  for (const key of ["Element", "Node", "NodeFilter", "HTMLElement", "DocumentFragment", "Range", "Event"]) {
    g[key] = w[key];
  }
  g.requestAnimationFrame = window.requestAnimationFrame.bind(window);
  g.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
  g.getComputedStyle = window.getComputedStyle.bind(window);
  delete g.katex;
  // jsdom has no layout; the shell's scroll-anchor capture probes this.
  (window.document as unknown as Record<string, unknown>).elementFromPoint = () => null;

  for (const code of inlineScripts(html)) {
    runInShell(code);
    // The UMD bundles attach to this process's global; the shell's boot
    // check reads them off `window`, as WebKit would.
    for (const key of ["marked", "hljs", "CmuxViewerNavigation", "CmuxMath"]) {
      if (g[key] !== undefined) { w[key] = g[key]; }
    }
  }

  const shell: Shell = {
    dom,
    window,
    document: window.document,
    libRequests,
    loadKatex() {
      // Same shape as MarkdownWebRenderer.Coordinator.lazyLibrarySources:
      // stylesheet first, then the library, then the ready callback.
      const style = window.document.createElement("style");
      style.id = "cmux-katex-css";
      style.textContent = katexCSS;
      window.document.head.appendChild(style);
      runInShell(katexJS);
      if (g.katex === undefined) { g.katex = w.katex; }
      window.__cmuxLibLoaded("katex");
    },
  };
  active = shell;
  return shell;
}

afterEach(() => {
  active?.dom.window.close();
  active = null;
  const g = globalThis as Record<string, unknown>;
  for (const [key, value] of originalGlobals) {
    if (value === undefined) {
      delete g[key];
    } else {
      g[key] = value;
    }
  }
});

function content(shell: Shell): HTMLElement {
  return shell.document.getElementById("content") as HTMLElement;
}

function bootError(shell: Shell): string | null {
  const text = content(shell).textContent ?? "";
  return text.startsWith("Markdown viewer error:") || text.startsWith("markdown render error:") ? text : null;
}

const ANSWER = [
  "**Gaussian**: draw each entry from $\\mathcal{N}(0, 1/m)$.",
  "",
  "**How many rows?** The theory says $m \\approx C \\cdot k \\log(n/k)$.",
  "",
  "With $n = 100{,}000$ tags and $k = 10$ per document:",
  "",
  "$$k \\log(n/k) = 10 \\times \\ln(10{,}000) \\approx 92$$",
  "",
  "Also \\(x^2\\) and",
  "",
  "\\[\\int_0^1 f(x)\\,dx\\]",
  "",
  "A fraction $\\frac{1}{\\sigma\\sqrt{2\\pi}}$ and a bad macro $\\notarealmacro{x}$.",
].join("\n");

const NOT_MATH = [
  "Run `echo $PATH` or echo $PATH and $HOME.",
  "",
  "It costs $5 to $10. The invoice was $1,000 (negotiable).",
  "",
  "```sh",
  "export X=$Y",
  "echo $x^2$",
  "```",
  "",
  "Inline code `$x^2$` stays code.",
].join("\n");

describe("math placeholders", () => {
  test("the shell boots with the math extension installed", () => {
    const shell = openShell();
    expect(bootError(shell)).toBeNull();
    expect(typeof shell.window.CmuxMath).toBe("object");
  });

  test("inline, display, paren, and bracket forms become placeholders", () => {
    const shell = openShell();
    shell.window.__cmuxRenderMarkdown(ANSWER);
    expect(bootError(shell)).toBeNull();
    const root = content(shell);
    const inline = root.querySelectorAll(".cmux-math-inline");
    const display = root.querySelectorAll(".cmux-math-display");
    expect(inline).toHaveLength(7);
    expect(display).toHaveLength(2);
    // Raw LaTeX survives marked and the sanitizer untouched.
    const sources = Array.from(root.querySelectorAll(".cmux-math .cmux-source")).map((el) => el.textContent);
    expect(sources).toContain("$\\mathcal{N}(0, 1/m)$");
    expect(sources).toContain("$m \\approx C \\cdot k \\log(n/k)$");
    expect(sources).toContain("$n = 100{,}000$");
    expect(sources).toContain("$$k \\log(n/k) = 10 \\times \\ln(10{,}000) \\approx 92$$");
    expect(sources).toContain("\\(x^2\\)");
    expect(sources).toContain("\\[\\int_0^1 f(x)\\,dx\\]");
    expect(sources).toContain("$\\frac{1}{\\sigma\\sqrt{2\\pi}}$");
    // Standalone display math is its own block, not wrapped in a paragraph.
    expect(root.querySelector("p > .cmux-math-display")).toBeNull();
    expect(root.querySelectorAll("div.cmux-math-display")).toHaveLength(2);
    // Surrounding prose is intact, including the bold runs marked owns.
    expect(root.querySelector("p strong")?.textContent).toBe("Gaussian");
  });

  test("a $$ in the middle of a line stays inline and does not split the paragraph", () => {
    const shell = openShell();
    shell.window.__cmuxRenderMarkdown("a $$b$$ c");
    const paragraphs = content(shell).querySelectorAll("p");
    expect(paragraphs).toHaveLength(1);
    expect(paragraphs[0].querySelector("span.cmux-math-display")).not.toBeNull();
    expect(paragraphs[0].textContent?.replace(/\s+/g, " ")).toBe("a $$b$$ c");
    expect(paragraphs[0].innerHTML).not.toContain("\n<span");
  });

  test("dollar signs that are not math stay literal", () => {
    const shell = openShell();
    shell.window.__cmuxRenderMarkdown(NOT_MATH);
    const root = content(shell);
    expect(root.querySelectorAll(".cmux-math")).toHaveLength(0);
    expect(shell.libRequests).toEqual([]);
    const text = root.textContent ?? "";
    expect(text).toContain("echo $PATH and $HOME");
    expect(text).toContain("It costs $5 to $10.");
    expect(text).toContain("$1,000");
    expect(root.querySelector("pre code")?.textContent).toContain("echo $x^2$");
    expect(Array.from(root.querySelectorAll("p code")).map((el) => el.textContent)).toContain("$x^2$");
  });

  test("markdown emphasis and escapes inside math are left alone", () => {
    const shell = openShell();
    shell.window.__cmuxRenderMarkdown("$a_1 * b_2 * c$ and $\\{x\\}$ and $x^*$ then $g^*$");
    const root = content(shell);
    expect(root.querySelectorAll("em")).toHaveLength(0);
    const sources = Array.from(root.querySelectorAll(".cmux-source")).map((el) => el.textContent);
    expect(sources).toEqual(["$a_1 * b_2 * c$", "$\\{x\\}$", "$x^*$", "$g^*$"]);
  });

  test("markdown escapes for brackets and parentheses render as literal text", () => {
    const shell = openShell();
    shell.window.__cmuxRenderMarkdown("Use \\[Enter\\] to confirm, then call \\(see above\\) and cd $HOME/$USER.");
    const root = content(shell);
    expect(root.querySelectorAll(".cmux-math")).toHaveLength(0);
    expect(root.querySelector("p")?.textContent).toBe("Use [Enter] to confirm, then call (see above) and cd $HOME/$USER.");
    expect(shell.libRequests).toEqual([]);
  });

  test("large hostile input costs little more than marked alone", () => {
    const shell = openShell();
    const hostile = ["\\(a ".repeat(5_000), "$a{ ".repeat(5_000), "$1 ".repeat(8_000), "a\n\n".repeat(1_000)].join("\n\n");
    // Baseline: the same marked build with the shell's options and no
    // math extension. marked itself is slow on this input under JSC.
    const Marked = (shell.window as unknown as { marked: { Marked: new () => { use(o: unknown): void; parse(s: string): string } } }).marked.Marked;
    const baseline = new Marked();
    baseline.use({ gfm: true, breaks: false, pedantic: false });
    let started = performance.now();
    baseline.parse(hostile);
    const baselineMs = performance.now() - started;
    started = performance.now();
    shell.window.__cmuxRenderMarkdown(hostile);
    const shellMs = performance.now() - started;
    expect(bootError(shell)).toBeNull();
    expect(content(shell).querySelectorAll(".cmux-math")).toHaveLength(0);
    expect(shellMs).toBeLessThan(baselineMs * 3 + 1_500);
  }, { timeout: 60_000 });

  test("a half-received display block stays literal until it closes", () => {
    const shell = openShell();
    shell.window.__cmuxRenderMarkdown("Result:\n\n$$k \\log(n/k) = 10 \\times");
    expect(content(shell).querySelectorAll(".cmux-math")).toHaveLength(0);
    expect(content(shell).textContent).toContain("$$k \\log(n/k) = 10 \\times");
    expect(shell.libRequests).toEqual([]);
    shell.window.__cmuxRenderMarkdown("Result:\n\n$$k \\log(n/k) = 10 \\times \\ln(10{,}000) \\approx 92$$");
    expect(content(shell).querySelectorAll("div.cmux-math-display")).toHaveLength(1);
    expect(shell.libRequests).toEqual(["katex"]);
  });
});

describe("rendering through the lazy-library bridge", () => {
  test("katex is requested once, only when math is present, and renders every placeholder", () => {
    const shell = openShell();
    shell.window.__cmuxRenderMarkdown("Plain prose.");
    expect(shell.libRequests).toEqual([]);
    shell.window.__cmuxRenderMarkdown(ANSWER);
    expect(shell.libRequests).toEqual(["katex"]);
    shell.loadKatex();
    const root = content(shell);
    const math = Array.from(root.querySelectorAll(".cmux-math"));
    expect(math).toHaveLength(9);
    for (const el of math) {
      expect(el.getAttribute("data-rendered")).toBe("1");
    }
    const rendered = math.filter((el) => el.querySelector(".cmux-math-render .katex"));
    expect(rendered).toHaveLength(8);
    // KaTeX-specific output: an upright \log and a script N.
    expect(root.querySelector(".katex .mop")?.textContent).toBeDefined();
    expect(root.querySelector(".katex .mathcal")).not.toBeNull();
    // Display math uses KaTeX's display layout.
    expect(root.querySelectorAll("div.cmux-math-display .katex-display")).toHaveLength(2);
    // A second render of the same document reuses the loaded library and
    // renders again without duplicating anything.
    shell.window.__cmuxRenderMarkdown(ANSWER);
    expect(shell.libRequests).toEqual(["katex"]);
    for (const el of root.querySelectorAll(".cmux-math")) {
      expect(el.querySelectorAll(".cmux-math-render").length).toBeLessThanOrEqual(1);
    }
    expect(root.querySelectorAll(".cmux-math-render .katex")).toHaveLength(8);
  });

  test("an expression KaTeX rejects shows its raw source, with no error box", () => {
    const shell = openShell();
    shell.window.__cmuxRenderMarkdown("Bad: $\\notarealmacro{x}$ after.");
    shell.loadKatex();
    const el = content(shell).querySelector(".cmux-math") as HTMLElement;
    expect(el.classList.contains("cmux-math-fallback")).toBe(true);
    expect(el.querySelector(".cmux-math-render")).toBeNull();
    expect(el.querySelector(".cmux-source")?.textContent).toBe("$\\notarealmacro{x}$");
    expect(content(shell).querySelector(".cmux-render-error")).toBeNull();
    expect(content(shell).textContent).toContain("Bad: $\\notarealmacro{x}$ after.");
  });

  test("when the bridge is unavailable every placeholder degrades to its source", () => {
    const shell = openShell({ bridgeThrows: true });
    shell.window.__cmuxRenderMarkdown("So $x^2$ and $$y$$.");
    const math = Array.from(content(shell).querySelectorAll(".cmux-math"));
    expect(math).toHaveLength(2);
    for (const el of math) {
      expect(el.classList.contains("cmux-math-fallback")).toBe(true);
      expect(el.getAttribute("data-rendered")).toBe("1");
    }
    expect(content(shell).querySelector(".cmux-render-error")).toBeNull();
    expect(content(shell).textContent).toContain("So $x^2$ and $$y$$.");
  });

  test("a native load failure degrades pending math and lets the next render retry", () => {
    const shell = openShell();
    shell.window.__cmuxRenderMarkdown("So $x^2$.");
    expect(shell.libRequests).toEqual(["katex"]);
    (shell.window as unknown as { __cmuxLibFailed: (n: string) => void }).__cmuxLibFailed("katex");
    const el = content(shell).querySelector(".cmux-math") as HTMLElement;
    expect(el.classList.contains("cmux-math-fallback")).toBe(true);
    expect(content(shell).querySelector(".cmux-render-error")).toBeNull();
    shell.window.__cmuxRenderMarkdown("So $x^2$ again.");
    expect(shell.libRequests).toEqual(["katex", "katex"]);
  });

  test("math inside raw <code> markup stays as source", () => {
    const shell = openShell();
    shell.window.__cmuxRenderMarkdown("Raw <code>$HOME/$x$</code> and real $y$.");
    shell.loadKatex();
    const inCode = content(shell).querySelector("code .cmux-math") as HTMLElement | null;
    if (inCode) {
      expect(inCode.classList.contains("cmux-math-fallback")).toBe(true);
      expect(inCode.querySelector(".cmux-math-render")).toBeNull();
    }
    expect(content(shell).querySelector("code")?.textContent).toBe("$HOME/$x$");
    const real = Array.from(content(shell).querySelectorAll(".cmux-math")).filter((el) => !el.closest("code"));
    expect(real).toHaveLength(1);
    expect(real[0].querySelector(".cmux-math-render .katex")).not.toBeNull();
  });

  test("trust-gated commands, macro definitions, and huge bodies show their source", () => {
    const shell = openShell();
    const huge = "$$" + "x+".repeat(CmuxMath.limits.renderBody / 2 + 100) + "$$";
    shell.window.__cmuxRenderMarkdown([
      "Link $\\href{https://example.com}{docs}$.",
      "",
      "Macro $\\def\\a{x}\\a$.",
      "",
      huge,
      "",
      "Fine $x$.",
    ].join("\n"));
    shell.loadKatex();
    const math = Array.from(content(shell).querySelectorAll(".cmux-math"));
    expect(math).toHaveLength(4);
    expect(math.slice(0, 3).every((el) => el.classList.contains("cmux-math-fallback"))).toBe(true);
    expect(math.slice(0, 3).every((el) => el.querySelector(".cmux-math-render") === null)).toBe(true);
    expect(math[3].querySelector(".cmux-math-render .katex")).not.toBeNull();
    expect(content(shell).querySelector("a")).toBeNull();
    expect(content(shell).textContent).toContain("$\\href{https://example.com}{docs}$");
  });

  test("the math extension does not disturb mermaid or code blocks", () => {
    const shell = openShell();
    shell.window.__cmuxRenderMarkdown("```mermaid\nflowchart LR\n  a --> b\n```\n\n$x$\n");
    expect(shell.libRequests.sort()).toEqual(["katex", "mermaid"]);
    expect(content(shell).querySelector(".cmux-mermaid .cmux-source")?.textContent).toContain("a --> b");
  });
});

describe("copy and export return the LaTeX source", () => {
  test("text export substitutes each formula with its original source", () => {
    const shell = openShell();
    shell.window.__cmuxRenderMarkdown(ANSWER);
    shell.loadKatex();
    const text = shell.window.__cmuxRenderedText();
    expect(text).toContain("The theory says $m \\approx C \\cdot k \\log(n/k)$.");
    expect(text).toContain("$$k \\log(n/k) = 10 \\times \\ln(10{,}000) \\approx 92$$");
    expect(text).toContain("Also \\(x^2\\) and");
    expect(text).toContain("\\[\\int_0^1 f(x)\\,dx\\]");
    expect(text).not.toContain("katex");
    const html = shell.window.__cmuxRenderedHTML();
    expect(html).not.toContain("katex");
    expect(html).not.toContain("cmux-math");
    expect(html).toContain("$m \\approx C \\cdot k \\log(n/k)$");
  });

  test("Cmd+C over rendered math puts the delimited source on the clipboard", () => {
    const shell = openShell();
    shell.window.__cmuxRenderMarkdown("The theory says $m \\approx C \\cdot k \\log(n/k)$. Done.");
    shell.loadKatex();
    const paragraph = content(shell).querySelector("p") as HTMLElement;
    const range = shell.document.createRange();
    range.selectNodeContents(paragraph);
    const selection = shell.window.getSelection()!;
    selection.removeAllRanges();
    selection.addRange(range);

    const written: Record<string, string> = {};
    const event = new shell.window.Event("copy", { bubbles: true, cancelable: true });
    Object.defineProperty(event, "clipboardData", {
      value: {
        setData(type: string, value: string) {
          written[type] = value;
        },
      },
    });
    paragraph.dispatchEvent(event);

    expect(event.defaultPrevented).toBe(true);
    expect(written["text/plain"]).toBe("The theory says $m \\approx C \\cdot k \\log(n/k)$. Done.");
    expect(written["text/html"]).toContain("$m \\approx C \\cdot k \\log(n/k)$");
    expect(written["text/html"]).not.toContain("katex");
  });

  test("a selection that starts inside a formula still copies the whole source", () => {
    const shell = openShell();
    shell.window.__cmuxRenderMarkdown("See $a+b$ here.");
    shell.loadKatex();
    const math = content(shell).querySelector(".cmux-math") as HTMLElement;
    const paragraph = math.parentElement as HTMLElement;
    const glyph = math.querySelector(".cmux-math-render .katex-html") as HTMLElement;
    const range = shell.document.createRange();
    range.setStart(glyph, 0);
    range.setEnd(paragraph, paragraph.childNodes.length);
    const selection = shell.window.getSelection()!;
    selection.removeAllRanges();
    selection.addRange(range);

    const written: Record<string, string> = {};
    const event = new shell.window.Event("copy", { bubbles: true, cancelable: true });
    Object.defineProperty(event, "clipboardData", {
      value: { setData: (type: string, value: string) => { written[type] = value; } },
    });
    paragraph.dispatchEvent(event);
    expect(written["text/plain"]).toBe("$a+b$ here.");
  });

  test("a selection spanning two formulas that ends inside the second copies both sources", () => {
    const shell = openShell();
    shell.window.__cmuxRenderMarkdown("Second para with $c+d$ and $e+f$ math.");
    shell.loadKatex();
    const paragraph = content(shell).querySelector("p") as HTMLElement;
    const maths = paragraph.querySelectorAll(".cmux-math");
    const firstGlyph = maths[0].querySelector(".cmux-math-render .katex-html") as HTMLElement;
    const secondGlyph = maths[1].querySelector(".cmux-math-render .katex-html") as HTMLElement;
    const range = shell.document.createRange();
    range.setStart(firstGlyph, 0);
    range.setEnd(secondGlyph, 1);
    const selection = shell.window.getSelection()!;
    selection.removeAllRanges();
    selection.addRange(range);
    const written: Record<string, string> = {};
    const event = new shell.window.Event("copy", { bubbles: true, cancelable: true });
    Object.defineProperty(event, "clipboardData", {
      value: { setData: (type: string, value: string) => { written[type] = value; } },
    });
    paragraph.dispatchEvent(event);
    expect(written["text/plain"]).toBe("$c+d$ and $e+f$");

    // From the paragraph start to inside the second formula.
    range.setStart(paragraph, 0);
    selection.removeAllRanges();
    selection.addRange(range);
    paragraph.dispatchEvent(event);
    expect(written["text/plain"]).toBe("Second para with $c+d$ and $e+f$");
  });

  test("a selection wholly inside one formula copies that formula's source", () => {
    const shell = openShell();
    shell.window.__cmuxRenderMarkdown("Density $\\frac{1}{\\sigma\\sqrt{2\\pi}}$ here.\n\n$$\\int_0^1 x^2\\,dx = \\frac{1}{3}$$");
    shell.loadKatex();
    const check = (math: Element, expected: string, expectHtml: string) => {
      const glyphs = math.querySelector(".cmux-math-render .katex-html") as HTMLElement;
      const walker = shell.document.createTreeWalker(glyphs, shell.window.NodeFilter.SHOW_TEXT);
      const first = walker.nextNode() as Text;
      let last: Text = first;
      let node: Node | null;
      while ((node = walker.nextNode())) { last = node as Text; }
      const range = shell.document.createRange();
      range.setStart(first, 0);
      range.setEnd(last, last.data.length);
      const selection = shell.window.getSelection()!;
      selection.removeAllRanges();
      selection.addRange(range);
      const written: Record<string, string> = {};
      const event = new shell.window.Event("copy", { bubbles: true, cancelable: true });
      Object.defineProperty(event, "clipboardData", {
        value: { setData: (type: string, value: string) => { written[type] = value; } },
      });
      glyphs.dispatchEvent(event);
      expect(event.defaultPrevented).toBe(true);
      expect(written["text/plain"]).toBe(expected);
      expect(written["text/html"]).toBe(expectHtml);
    };
    const maths = content(shell).querySelectorAll(".cmux-math");
    check(maths[0], "$\\frac{1}{\\sigma\\sqrt{2\\pi}}$", "$\\frac{1}{\\sigma\\sqrt{2\\pi}}$");
    check(maths[1], "$$\\int_0^1 x^2\\,dx = \\frac{1}{3}$$", "<p>$$\\int_0^1 x^2\\,dx = \\frac{1}{3}$$</p>");
  });

  test("a pass that runs out of budget leaves the rest pending and a follow-up pass finishes them", async () => {
    const shell = openShell();
    const doc = Array.from({ length: 300 }, (_, i) => `Item $\\frac{${i}}{${i + 1}} + \\sqrt{${i}}$ here.`).join("\n\n");
    (shell.window as unknown as { __cmuxMathRenderBudgetMs: number }).__cmuxMathRenderBudgetMs = 0;
    shell.window.__cmuxRenderMarkdown(doc);
    shell.loadKatex();
    const root = content(shell);
    const renderedNow = root.querySelectorAll(".cmux-math-render .katex").length;
    expect(renderedNow).toBeLessThan(300);
    expect(root.querySelectorAll(".cmux-math-fallback")).toHaveLength(0);
    expect(root.querySelectorAll(".cmux-math:not([data-rendered])").length).toBe(300 - renderedNow);
    // The shell scheduled a continuation; with a normal budget it finishes.
    (shell.window as unknown as { __cmuxMathRenderBudgetMs: number | undefined }).__cmuxMathRenderBudgetMs = undefined;
    for (let tick = 0; tick < 50 && root.querySelectorAll(".cmux-math:not([data-rendered])").length > 0; tick++) {
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
    expect(root.querySelectorAll(".cmux-math-render .katex")).toHaveLength(300);
    expect(root.querySelectorAll(".cmux-math-fallback")).toHaveLength(0);
  });

  test("a display block one character short of closing stays literal while streaming", () => {
    const shell = openShell();
    shell.window.__cmuxRenderMarkdown("Result: $$\\frac{x}{y}$");
    expect(content(shell).querySelectorAll(".cmux-math")).toHaveLength(0);
    expect(content(shell).querySelector("p")?.textContent).toBe("Result: $$\\frac{x}{y}$");
    shell.window.__cmuxRenderMarkdown("Result: $$\\frac{x}{y}$$");
    expect(content(shell).querySelectorAll("span.cmux-math-display")).toHaveLength(1);
  });

  test("a selection with no math keeps the default copy", () => {
    const shell = openShell();
    shell.window.__cmuxRenderMarkdown("Prose only, then $x$.");
    shell.loadKatex();
    const paragraph = content(shell).querySelector("p") as HTMLElement;
    const range = shell.document.createRange();
    range.setStart(paragraph.firstChild!, 0);
    range.setEnd(paragraph.firstChild!, 5);
    const selection = shell.window.getSelection()!;
    selection.removeAllRanges();
    selection.addRange(range);
    const event = new shell.window.Event("copy", { bubbles: true, cancelable: true });
    Object.defineProperty(event, "clipboardData", { value: { setData() {} } });
    paragraph.dispatchEvent(event);
    expect(event.defaultPrevented).toBe(false);
  });
});

describe("markdown.renderMath (__cmuxSetMathEnabled)", () => {
  test("turning math off re-renders the document as source text and back on restores placeholders", () => {
    const shell = openShell();
    shell.window.__cmuxRenderMarkdown(ANSWER);
    expect(content(shell).querySelectorAll(".cmux-math")).toHaveLength(9);
    const requestsWhileOn = shell.libRequests.length;
    // Native pushes the global setting after the shell loads (and on every
    // change); off re-parses the cached source with the tokenizers gated.
    shell.window.__cmuxSetMathEnabled(false);
    expect(bootError(shell)).toBeNull();
    expect(content(shell).querySelectorAll(".cmux-math")).toHaveLength(0);
    expect(content(shell).textContent).toContain("$\\mathcal{N}(0, 1/m)$");
    expect(content(shell).textContent).toContain("$$k \\log(n/k) = 10 \\times \\ln(10{,}000) \\approx 92$$");
    // With the tokenizers gated, marked's own escape rule owns `\(` and `\[`
    // again (`\(x^2\)` -> `(x^2)`), exactly as the viewer rendered before math.
    expect(content(shell).textContent).toContain("Also (x^2) and");
    expect(content(shell).querySelector("p strong")?.textContent).toBe("Gaussian");
    // No placeholders means no further lazy KaTeX request.
    expect(shell.libRequests).toHaveLength(requestsWhileOn);
    // Documents rendered while off stay plain, too.
    shell.window.__cmuxRenderMarkdown("Only $x^2$ here.");
    expect(content(shell).querySelectorAll(".cmux-math")).toHaveLength(0);
    expect(content(shell).querySelector("p")?.textContent).toBe("Only $x^2$ here.");
    expect(shell.libRequests).toHaveLength(requestsWhileOn);
    // Back on: the cached source is re-parsed and placeholders return.
    shell.window.__cmuxSetMathEnabled(true);
    expect(content(shell).querySelectorAll(".cmux-math-inline")).toHaveLength(1);
    expect(content(shell).querySelector(".cmux-math .cmux-source")?.textContent).toBe("$x^2$");
    // Idempotent: the same value never re-renders.
    const before = content(shell).innerHTML;
    shell.window.__cmuxSetMathEnabled(true);
    expect(content(shell).innerHTML).toBe(before);
  });

  test("setting the flag before any document renders applies to the first render", () => {
    const shell = openShell();
    shell.window.__cmuxSetMathEnabled(false);
    shell.window.__cmuxRenderMarkdown("a $$b$$ c");
    expect(content(shell).querySelectorAll(".cmux-math")).toHaveLength(0);
    expect(content(shell).querySelector("p")?.textContent).toBe("a $$b$$ c");
  });
});
