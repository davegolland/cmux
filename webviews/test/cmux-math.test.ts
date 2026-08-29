import { describe, expect, test } from "bun:test";
import "../../Resources/markdown-viewer/cmux-math.js";

// Delimiter detection for the markdown viewer's LaTeX math support. These
// are the pure string rules; markdown-viewer-math.test.ts drives the whole
// shell (marked, sanitizer, KaTeX, copy, export) through jsdom.

const mathOf = (s: string) =>
  CmuxMath.splitText(s).filter((p) => p.type === "math").map((p) => p.data);
const textOf = (s: string) =>
  CmuxMath.splitText(s).map((p) => (p.type === "text" ? p.data : "<M>")).join("");

describe("acceptance inputs from a real Claude Code answer", () => {
  test("single italic variable", () => {
    expect(mathOf("$A$")).toEqual(["A"]);
  });

  test("mathcal with a brace group", () => {
    expect(mathOf("draw each entry from $\\mathcal{N}(0, 1/m)$.")).toEqual(["\\mathcal{N}(0, 1/m)"]);
  });

  test("approx, cdot, log", () => {
    expect(mathOf("The theory says $m \\approx C \\cdot k \\log(n/k)$.")).toEqual([
      "m \\approx C \\cdot k \\log(n/k)",
    ]);
  });

  test("brace group with a comma, two formulas in one line", () => {
    expect(mathOf("With $n = 100{,}000$ tags and $k = 10$ per document:")).toEqual([
      "n = 100{,}000",
      "k = 10",
    ]);
  });

  test("display dollars", () => {
    const parts = CmuxMath.splitText("$$k \\log(n/k) = 10 \\times \\ln(10{,}000) \\approx 92$$");
    expect(parts).toHaveLength(1);
    expect(parts[0]).toMatchObject({
      type: "math",
      display: true,
      data: "k \\log(n/k) = 10 \\times \\ln(10{,}000) \\approx 92",
    });
  });

  test("fraction, sigma, sqrt", () => {
    expect(mathOf("$\\frac{1}{\\sigma\\sqrt{2\\pi}}$")).toEqual(["\\frac{1}{\\sigma\\sqrt{2\\pi}}"]);
  });

  test("an unknown macro is still detected; the renderer degrades it later", () => {
    expect(mathOf("$\\notarealmacro{x}$")).toEqual(["\\notarealmacro{x}"]);
  });
});

describe("text that is not math stays literal", () => {
  test("shell variables", () => {
    expect(mathOf("echo $PATH")).toEqual([]);
    expect(textOf("echo $PATH")).toBe("echo $PATH");
    expect(mathOf("$1 $2 $HOME $$ $? ${FOO}")).toEqual([]);
    expect(mathOf("run $CMD and then $OTHER")).toEqual([]);
  });

  test("prices", () => {
    expect(mathOf("It costs $5 to $10.")).toEqual([]);
    expect(mathOf("between $5-$10 each")).toEqual([]);
    expect(mathOf("$5 and $10 and $15")).toEqual([]);
    expect(mathOf("The price is $1,000 (negotiable).")).toEqual([]);
  });

  test("escaped dollar never opens math", () => {
    expect(mathOf("cost \\$5 and \\$x\\$")).toEqual([]);
  });

  test("opening dollar followed by a space", () => {
    expect(mathOf("$ x$")).toEqual([]);
  });

  test("closing dollar preceded by a space", () => {
    expect(mathOf("$x $")).toEqual([]);
  });

  test("closing dollar followed by a digit", () => {
    expect(mathOf("$x$1")).toEqual([]);
  });

  test("unterminated delimiters (streaming: half-received $$)", () => {
    expect(mathOf("$x + y")).toEqual([]);
    expect(mathOf("$$x + y")).toEqual([]);
    expect(mathOf("\\(x + y")).toEqual([]);
    expect(mathOf("\\[x + y")).toEqual([]);
    expect(textOf("$$x + y")).toBe("$$x + y");
  });

  test("empty math", () => {
    expect(mathOf("$$$$")).toEqual([]);
    expect(mathOf("\\(\\)")).toEqual([]);
    expect(mathOf("\\[ \\]")).toEqual([]);
  });

  test("blank line inside", () => {
    expect(mathOf("$a\n\nb$")).toEqual([]);
    expect(mathOf("$$a\n\nb$$")).toEqual([]);
  });

  test("adjacent dollars are ambiguous and stay literal", () => {
    // "$a$" is followed by "$", which the Pandoc rule rejects as a close,
    // and a "$" right after another "$" never opens. Nothing renders.
    expect(mathOf("$a$$b$")).toEqual([]);
    expect(textOf("$a$$b$")).toBe("$a$$b$");
  });

  test("one character short of a closing $$ stays literal (streaming)", () => {
    expect(mathOf("$$\\frac{x}{y}$")).toEqual([]);
    expect(mathOf("$$x$")).toEqual([]);
    expect(mathOf("Price is $$5$ each.")).toEqual([]);
    expect(mathOf("$$x$$")).toEqual(["x"]);
  });

  test("a second variable never closes a first one", () => {
    expect(mathOf("cd $HOME/$USER")).toEqual([]);
    expect(mathOf("export PATH=$HOME/bin:$PATH")).toEqual([]);
    expect(mathOf("copy $SRC:$DST")).toEqual([]);
    expect(mathOf("use $a+$b")).toEqual([]);
    expect(mathOf("tag $BIN_$SUFFIX")).toEqual([]);
    expect(mathOf("PHP: call $this->foo($bar) now")).toEqual([]);
    expect(mathOf("JS: ${a}${b} in prose")).toEqual([]);
    expect(mathOf("jQuery: $(el).val($x)")).toEqual([]);
    // Punctuation after the closing dollar is still fine.
    expect(mathOf("the $x$-axis, then $y$. Also ($z$)")).toEqual(["x", "y", "z"]);
  });

  test("two literal $$ tokens in one sentence do not pair up", () => {
    expect(mathOf("the PID is $$ and the parent is $$ too")).toEqual([]);
    expect(mathOf("Perl deref $$ref and $$other")).toEqual([]);
    // A tight inline $$...$$ is still display math.
    expect(CmuxMath.splitText("so $$E=mc^2$$ holds")[1]).toMatchObject({ type: "math", display: true, data: "E=mc^2" });
  });

  test("markdown escapes for literal brackets and parentheses stay literal", () => {
    expect(mathOf("Use \\[Enter\\] to confirm")).toEqual([]);
    expect(mathOf("citation \\[1\\] says")).toEqual([]);
    expect(mathOf("Regex \\[a-z\\]+ matches")).toEqual([]);
    expect(mathOf("call \\(see above\\) for details")).toEqual([]);
    expect(mathOf("a \\(void\\) cast")).toEqual(["void"]); // no whitespace: reads as TeX
    expect(mathOf("so \\(x^2\\) and \\(n \\to \\infty\\) and \\(a + b\\)")).toEqual(["x^2", "n \\to \\infty", "a + b"]);
  });

  test("scans are bounded so unterminated delimiters cost linear time", () => {
    const long = "$a" + "b".repeat(CmuxMath.limits.inlineScan + 10) + "$";
    expect(mathOf(long)).toEqual([]);
    const ok = "$a" + "b".repeat(CmuxMath.limits.inlineScan - 10) + "$";
    expect(mathOf(ok)).toHaveLength(1);
    // Loose bound: bun runs on JavaScriptCore, where a plain char loop is
    // several times slower than on V8. The point is linear, not fast.
    const started = performance.now();
    CmuxMath.splitText("\\(a ".repeat(20_000));
    CmuxMath.splitText("$a{ ".repeat(20_000));
    CmuxMath.splitText("$1 ".repeat(50_000));
    expect(performance.now() - started).toBeLessThan(10_000);
  });
});

describe("delimiter forms", () => {
  test("paren inline; bracket only on its own line", () => {
    expect(mathOf("so \\(x^2\\) and \\[\\int_0^1 f\\]")).toEqual(["x^2"]);
    const parts = CmuxMath.splitText("intro\n\\[\\int_0^1 f\\]\nafter");
    expect(parts[1]).toMatchObject({ type: "math", display: true, data: "\\int_0^1 f" });
    expect(CmuxMath.splitText("\\[\\int_0^1 f\\]")[0]).toMatchObject({ type: "math", display: true });
    expect(mathOf("\\[a\\] trailing prose")).toEqual([]);
  });

  test("looksLikeTeX separates formulas from escaped prose", () => {
    expect(CmuxMath.looksLikeTeX("x")).toBe(true);
    expect(CmuxMath.looksLikeTeX("n \\to \\infty")).toBe(true);
    expect(CmuxMath.looksLikeTeX("a = b")).toBe(true);
    expect(CmuxMath.looksLikeTeX("see above")).toBe(false);
  });

  test("escaped dollar inside math does not close it", () => {
    expect(mathOf("$a \\$ b$")).toEqual(["a \\$ b"]);
  });

  test("dollar inside braces does not close", () => {
    expect(mathOf("$\\text{costs $5}$")).toEqual(["\\text{costs $5}"]);
  });

  test("underscore and asterisk survive", () => {
    expect(mathOf("$a_1 b_2 * c$")).toEqual(["a_1 b_2 * c"]);
  });

  test("display dollars may span lines", () => {
    expect(mathOf("$$\na = b\n$$")).toEqual(["a = b"]);
  });

  test("own-line display math may be indented, as Claude Code prints it in a terminal", () => {
    const claude = "  Result:\n  $$\n  k \\log(n/k) \\approx 92\n  $$\n  Done.";
    expect(mathOf(claude)).toEqual(["k \\log(n/k) \\approx 92"]);
    expect(textOf(claude)).toBe("  Result:\n  <M>  Done.");
    expect(mathOf("  \\[ a = b \\]\nnext")).toEqual(["a = b"]);
    // Four spaces is a code block in markdown and is not honored here either.
    expect(mathOf("    $$ a $$")).toEqual([]);
  });

  test("order and surrounding text", () => {
    expect(textOf("a $x$ b $y$ c")).toBe("a <M> b <M> c");
  });

  test("matchInline prefers $$ over $ $ and keeps the original delimiters", () => {
    const m = CmuxMath.matchInline("$$a$$");
    expect(m).toMatchObject({ display: true, text: "a", open: "$$", close: "$$", raw: "$$a$$" });
    const p = CmuxMath.matchInline("\\( b \\)");
    expect(p).toMatchObject({ display: false, text: "b", body: " b ", raw: "\\( b \\)" });
  });
});

describe("block form", () => {
  test("whole block equation, raw includes the line ending", () => {
    const m = CmuxMath.matchBlock("$$\na = b\n$$\nnext para");
    expect(m).toMatchObject({ raw: "$$\na = b\n$$\n", text: "a = b", display: true });
  });

  test("bracket form", () => {
    expect(CmuxMath.matchBlock("\\[a = b\\]")).toMatchObject({ text: "a = b", raw: "\\[a = b\\]" });
  });

  test("up to three spaces of indentation", () => {
    expect(CmuxMath.matchBlock("   $$x$$\n")).toMatchObject({ text: "x", raw: "   $$x$$\n" });
    expect(CmuxMath.matchBlock("    $$x$$\n")).toBeNull();
  });

  test("trailing prose on the closing line is not a block", () => {
    expect(CmuxMath.matchBlock("$$x$$ then prose")).toBeNull();
  });

  test("any amount of trailing whitespace after the closing line is fine", () => {
    const padded = "$$x$$" + " ".repeat(200) + "\nnext";
    expect(CmuxMath.matchBlock(padded)).toMatchObject({ text: "x", raw: "$$x$$" + " ".repeat(200) + "\n" });
    expect(CmuxMath.matchBlock("$$x$$\t\r\nnext")).toMatchObject({ raw: "$$x$$\t\r\n" });
  });

  test("unterminated is not a block", () => {
    expect(CmuxMath.matchBlock("$$x\n\nnot closed")).toBeNull();
  });

  test("blockStartIndex only reports a delimiter that follows a newline, within the paragraph", () => {
    // marked hands `start` the paragraph minus its first character, so a
    // delimiter at index 0 is mid-line, never a block start.
    expect(CmuxMath.blockStartIndex("a $$b$$ c")).toBe(-1);
    expect(CmuxMath.blockStartIndex(" $$b$$ c")).toBe(-1);
    expect(CmuxMath.blockStartIndex("$$x$$")).toBe(-1);
    expect(CmuxMath.blockStartIndex("intro\n$$\nx\n$$")).toBe(6);
    expect(CmuxMath.blockStartIndex("intro\n  \\[x\\]")).toBe(6);
    // A delimiter after a blank line belongs to the next paragraph.
    expect(CmuxMath.blockStartIndex("intro\n\nmore\n$$x$$")).toBe(-1);
    expect(CmuxMath.blockStartIndex("intro\n$$x$$\n\nmore")).toBe(6);
    // An unterminated $$ line is not a block, so the paragraph is not cut.
    expect(CmuxMath.blockStartIndex("intro\n$$x\nmore")).toBe(-1);
  });

  test("startIndex reports only a real match, inside a bounded window", () => {
    expect(CmuxMath.startIndex("abc $x$ \\(y\\)")).toBe(4);
    expect(CmuxMath.startIndex("abc \\(y\\) $x$")).toBe(4);
    expect(CmuxMath.startIndex("no math")).toBe(-1);
    expect(CmuxMath.startIndex("abc \\[y\\]")).toBe(-1);
    // Lone dollars and prices are skipped so marked does not cut its text
    // token there (JavaScriptCore re-joins cut text quadratically).
    expect(CmuxMath.startIndex("cost $5 and $10, then $x$ ok")).toBe(22);
    expect(CmuxMath.startIndex("$1 $2 $3")).toBe(-1);
    // After a run of failed openers the hint hands back a cut point.
    const many = "$1 ".repeat(CmuxMath.limits.startCandidates + 5);
    expect(CmuxMath.startIndex(many)).toBe((CmuxMath.limits.startCandidates - 1) * 3);
    const far = "a".repeat(CmuxMath.limits.startWindow + 100) + "$x$";
    expect(CmuxMath.startIndex(far)).toBe(CmuxMath.limits.startWindow);
    // A cut lands after whitespace, never inside a word or an autolink.
    const words = ("word ".repeat(CmuxMath.limits.startWindow / 5 - 4) + "mail user@example.com more ").padEnd(CmuxMath.limits.startWindow + 50, "x");
    const cut = CmuxMath.startIndex(words);
    expect(cut).toBeGreaterThan(0);
    expect(words[cut - 1]).toBe(" ");
    const lone = "$1 ".repeat(CmuxMath.limits.startCandidates + 5);
    const loneCut = CmuxMath.startIndex(lone);
    expect(lone[loneCut - 1]).toBe(" ");
  });
});

describe("source round trip", () => {
  test("bodyOf strips exactly the stored delimiters", () => {
    expect(CmuxMath.bodyOf("$x$")).toBe("x");
    expect(CmuxMath.bodyOf("$$ x $$")).toBe(" x ");
    expect(CmuxMath.bodyOf("\\(x\\)")).toBe("x");
    expect(CmuxMath.bodyOf("\\[x\\]")).toBe("x");
    expect(CmuxMath.bodyOf("plain")).toBe("plain");
  });

  test("placeholderHTML escapes and keeps the delimited source as text", () => {
    const m = CmuxMath.matchInline("$a<b & \"c\"$")!;
    const html = CmuxMath.placeholderHTML(m, false);
    expect(html).toBe(
      '<span class="cmux-math cmux-math-inline"><span class="cmux-source">$a&lt;b &amp; "c"$</span></span>',
    );
    const block = CmuxMath.matchBlock("$$\nx\n$$\n")!;
    expect(CmuxMath.placeholderHTML(block, true)).toBe(
      '<div class="cmux-math cmux-math-display"><span class="cmux-source">$$\nx\n$$</span></div>\n',
    );
  });
});
