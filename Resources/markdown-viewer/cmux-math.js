/*
 * cmux-math: LaTeX math for the markdown viewer.
 *
 * Detects math delimiters in markdown source, emits placeholder elements
 * through a `marked` extension, and renders them with a lazily loaded KaTeX.
 * Plain ES5 with no DOM access outside the functions that take a document,
 * so the same file runs inside shell.html (WKWebView) and under bun test
 * with jsdom. Assigns one global, `CmuxMath`, like viewer-navigation.js.
 *
 * Delimiters:
 *   $$ ... $$      display: on its own line(s), or inline with no space
 *                  just inside the delimiters
 *   \[ ... \]      display: only on its own line(s). Mid-sentence `\[..\]`
 *                  is a markdown escape for a literal bracket.
 *   \( ... \)      inline, when the body has the shape of TeX (no space,
 *                  or an operator, backslash, brace, or script character)
 *   $ ... $        inline, Pandoc rules (see matchInlineDollar), plus: the
 *                  closing $ may not start an identifier or expansion
 *
 * Safety rules (a false positive is worse than no rendering):
 *   - `$PATH`, `echo $HOME`, `$1`, `$HOME/$USER`, `PATH=$HOME/bin:$PATH`,
 *     `echo $$`, and "it costs $5 to $10" stay literal.
 *   - Fenced code and code spans are never touched: marked tokenizes those
 *     before this extension sees the text. Placeholders that end up inside
 *     raw <code>/<pre> HTML are left as source at render time.
 *   - A half-received `$$` (streaming) stays literal until the closing
 *     delimiter arrives.
 *   - When KaTeX rejects an expression, never loads, or would be asked to
 *     do unbounded work, the element shows the raw source exactly as it
 *     was written. No error box.
 *   - Every scan is bounded: a delimiter search never looks further than
 *     a few kilobytes ahead, so hostile input cannot make parsing
 *     quadratic.
 *
 * Placeholder shape (the raw LaTeX lives in element text, never in an
 * attribute, so quotes and backslashes round-trip and the sanitizer in
 * shell.html, which strips data-cmux-* attributes, leaves it intact):
 *   <span class="cmux-math cmux-math-inline"><span class="cmux-source">$x$</span></span>
 *   <div class="cmux-math cmux-math-display"><span class="cmux-source">$$x$$</span></div>
 * The `.cmux-source` text is the ORIGINAL delimited source. It stays
 * visible until KaTeX renders, and copy and export hand it back to the
 * user (requirement: copy returns the LaTeX).
 */
(function(global) {
  'use strict';

  var INLINE_CLASS = 'cmux-math cmux-math-inline';
  var DISPLAY_CLASS = 'cmux-math cmux-math-display';
  var RENDER_CLASS = 'cmux-math-render';
  var FALLBACK_CLASS = 'cmux-math-fallback';
  var SOURCE_CLASS = 'cmux-source';

  /* Scan and render limits. Real formulas are far below every one of
   * these; the limits exist so hostile input degrades to plain text
   * instead of freezing the viewer. */
  var MAX_INLINE_SCAN = 2048;      // chars a $...$ or \(...\) may span
  var MAX_DISPLAY_SCAN = 8192;     // chars a $$...$$ or \[...\] may span
  var MAX_START_WINDOW = 4096;     // chars a start() hint looks ahead
  var MAX_START_CANDIDATES = 32;   // openers a start() hint tries per call
  var START_STEP_BUDGET = 8192;    // scan steps a start() hint may spend
  var MAX_RENDER_BODY = 4096;      // chars KaTeX is asked to typeset
  var RENDER_TIME_BUDGET_MS = 250; // per pass; the rest shows source
  var RENDER_CACHE_LIMIT = 4096;   // entries (the byte cap usually wins)
  var RENDER_CACHE_BYTES = 4 * 1024 * 1024;

  /* ---------- delimiter detection (pure string functions) ---------- */

  /* A scan context wraps one source string. Every scan runs on offsets
   * into that string, never on a fresh slice, and the position of the
   * next closing delimiter of each kind is cached: marked calls the
   * `start` hint for every text token, so a candidate opener must never
   * cost more than a few native searches. */
  function scanContext(text) {
    return { text: text, next: {}, budget: Infinity };
  }

  /* Index of `delim` in ctx.text within [from, limit), or -1. The search
   * never looks past `limit`, so a candidate with no closer ahead costs
   * one bounded native search, not a scan to the end of the document.
   * Cached per delimiter: once no closer exists in a range, later
   * candidates inside that range learn it in O(1). */
  function nextIndexOf(ctx, delim, from, limit) {
    var text = ctx.text;
    var entry = ctx.next[delim];
    var searchFrom = from;
    var extendsKnown = false;
    if (entry !== undefined) {
      if (entry.pos >= 0 && entry.pos >= from && entry.pos < limit) { return entry.pos; }
      if (entry.pos < 0 && from >= entry.from && from <= entry.limit) {
        if (limit <= entry.limit) { return -1; }
        // Known empty up to entry.limit and the new range touches it:
        // only the new tail needs a look.
        searchFrom = Math.max(from, entry.limit - (delim.length - 1));
        extendsKnown = true;
      }
    }
    var pos;
    if (limit >= text.length) {
      pos = text.indexOf(delim, searchFrom);
    } else {
      var rel = text.slice(searchFrom, limit + delim.length - 1).indexOf(delim);
      pos = rel < 0 ? -1 : searchFrom + rel;
    }
    if (pos >= limit) { pos = -1; }
    ctx.next[delim] = { pos: pos, from: extendsKnown ? entry.from : from, limit: limit };
    return pos;
  }

  /* Find the index of `delimiter` at or after `from`, skipping
   * backslash-escaped characters and anything inside braces, looking no
   * further than `maxScan` characters. Adapted from KaTeX auto-render
   * (MIT). Returns -1 when not found. */
  function findEndOfMath(ctx, delimiter, from, maxScan) {
    var text = ctx.text;
    var limit = Math.min(text.length, from + maxScan);
    if (nextIndexOf(ctx, delimiter, from, limit) < 0) { return -1; }
    var index = from;
    var braceLevel = 0;
    var first = delimiter.charCodeAt(0);
    while (index < limit) {
      if (--ctx.budget < 0) { return -1; }
      var code = text.charCodeAt(index);
      if (braceLevel <= 0 && code === first && text.startsWith(delimiter, index)) {
        return index;
      } else if (code === 92 /* \ */) {
        index++;
      } else if (code === 123 /* { */) {
        braceLevel++;
        // An open brace with no closing brace ahead can never balance.
        if (nextIndexOf(ctx, '}', index, limit) < 0) { return -1; }
      } else if (code === 125 /* } */) {
        braceLevel--;
      }
      index++;
    }
    return -1;
  }

  function isSpace(ch) {
    return ch === ' ' || ch === '\t' || ch === '\n' || ch === '\r' || ch === '\f' || ch === '\v';
  }

  function isDigit(ch) {
    return ch >= '0' && ch <= '9';
  }

  /* A character that would start an identifier or a shell/PHP/JS
   * expansion right after a `$`: `$HOME/$USER`, `$this->foo($bar)`,
   * `${a}${b}`, `$(cmd)`. */
  function startsIdentifier(ch) {
    return ch !== undefined && /[A-Za-z_({]/.test(ch);
  }

  function hasBlankLine(s) {
    return /\n *\r?\n/.test(s);
  }

  /* `\(...\)` is also how a careful markdown author escapes a literal
   * parenthesis. Accept it as math only when the body has the shape of
   * TeX: a single token (`\(x\)`, `\( x \)`), or an operator, backslash,
   * brace, bar, or script character somewhere. Prose such as
   * "\(see above\)" has inner spaces and none of those. */
  function looksLikeTeX(body) {
    return !/\s/.test(body.trim()) || /[\\^_=+\-*\/<>{}|]/.test(body);
  }

  function makeMatch(open, body, close, display) {
    return {
      raw: open + body + close,
      open: open,
      close: close,
      body: body,
      text: body.trim(),
      display: display
    };
  }

  /* Generic two-character delimiter pair at offset `i`. A blank line ends
   * a markdown paragraph, so a body that spans one is not math. With
   * `tight`, the body must touch both delimiters (no space just inside),
   * which keeps two literal `$$` tokens in one sentence from pairing up. */
  function matchPairAt(ctx, i, open, close, display, maxScan, tight) {
    var text = ctx.text;
    if (!text.startsWith(open, i)) { return null; }
    var end = findEndOfMath(ctx, close, i + open.length, maxScan);
    if (end < 0) { return null; }
    var body = text.slice(i + open.length, end);
    if (body.trim() === '' || hasBlankLine(body)) { return null; }
    if (tight && (isSpace(body[0]) || isSpace(body[body.length - 1]))) { return null; }
    return makeMatch(open, body, close, display);
  }

  function matchDisplayDollarAt(ctx, i) { return matchPairAt(ctx, i, '$$', '$$', true, MAX_DISPLAY_SCAN, true); }
  function matchBracketAt(ctx, i) { return matchPairAt(ctx, i, '\\[', '\\]', true, MAX_DISPLAY_SCAN, false); }
  function matchParenAt(ctx, i) {
    var m = matchPairAt(ctx, i, '\\(', '\\)', false, MAX_INLINE_SCAN, false);
    return m && looksLikeTeX(m.body) ? m : null;
  }

  /* $ ... $ at offset `i` with the Pandoc rules:
   *   - the opening $ has a non-space character immediately to its right,
   *     and that character is not another $ (that is display math);
   *   - the closing $ has a non-space character immediately to its left;
   *   - the closing $ is not immediately followed by a digit or another $;
   *   - no blank line inside;
   * and two rules Pandoc lacks:
   *   - the closing $ is not immediately followed by a letter, `_`, `(`,
   *     or `{`, so a second variable never closes a first one;
   *   - the opening $ is not immediately preceded by another $.
   * "$5 to $10" fails at "$10" (digit after) and at "to $" (space
   * before); "$HOME/$USER" fails at "$U"; "$PATH" never closes. */
  function matchInlineDollarAt(ctx, i) {
    var text = ctx.text;
    if (text.charCodeAt(i) !== 36 /* $ */) { return null; }
    // The second `$` of an unclosed `$$` never opens inline math, so a
    // streamed `$$x$` (one character short of its closer) stays literal.
    if (i > 0 && text.charCodeAt(i - 1) === 36) { return null; }
    var first = text[i + 1];
    if (first === undefined || first === '$' || isSpace(first)) { return null; }
    var limit = Math.min(text.length, i + MAX_INLINE_SCAN);
    if (nextIndexOf(ctx, '$', i + 1, limit) < 0) { return null; }
    var index = i + 1;
    var braceLevel = 0;
    while (index < limit) {
      if (--ctx.budget < 0) { return null; }
      var code = text.charCodeAt(index);
      if (code === 92 /* \ */) {
        index += 2;
        continue;
      }
      if (code === 123 /* { */) {
        braceLevel++;
        if (nextIndexOf(ctx, '}', index, limit) < 0) { return null; }
      } else if (code === 125 /* } */) {
        braceLevel--;
      } else if (code === 36 /* $ */ && braceLevel <= 0) {
        var before = text[index - 1];
        var after = text[index + 1];
        if (isSpace(before)) { return null; }
        if (after !== undefined && (isDigit(after) || after === '$' || startsIdentifier(after))) { return null; }
        var body = text.slice(i + 1, index);
        if (body.trim() === '' || hasBlankLine(body)) { return null; }
        return makeMatch('$', body, '$', false);
      }
      index++;
    }
    return null;
  }

  /* Inline candidate at offset `i`. `$$` is tried before `$` so it is
   * never read as an empty `$ $`. `\[` is not inline math. */
  function matchInlineAt(ctx, i) {
    var code = ctx.text.charCodeAt(i);
    if (code === 36 /* $ */) {
      return matchDisplayDollarAt(ctx, i) || matchInlineDollarAt(ctx, i);
    }
    if (code === 92 /* \ */) {
      return matchParenAt(ctx, i);
    }
    return null;
  }

  /* Public single-string forms. */
  function matchInline(src) { return matchInlineAt(scanContext(src), 0); }
  function matchInlineDollar(src) { return matchInlineDollarAt(scanContext(src), 0); }
  function matchDisplayDollar(src) { return matchDisplayDollarAt(scanContext(src), 0); }
  function matchParen(src) { return matchParenAt(scanContext(src), 0); }
  function matchBracket(src) { return matchBracketAt(scanContext(src), 0); }

  /* Block candidate at offset `i`, which is the beginning of a line (up
   * to three spaces of indentation allowed, like other markdown blocks).
   * The whole block is one display equation. The closing delimiter must
   * be followed by optional spaces and a newline or end of input, so that
   * "$$x$$ then prose" stays a paragraph and goes to the inline path.
   * The returned `raw` includes the indentation and the line ending. */
  function matchBlockAt(ctx, i) {
    var text = ctx.text;
    var indentMatch = /^[ \t]{0,3}/.exec(text.slice(i, i + 4));
    var indent = indentMatch ? indentMatch[0] : '';
    var at = i + indent.length;
    var m = null;
    if (text.startsWith('$$', at)) {
      m = matchPairAt(ctx, at, '$$', '$$', true, MAX_DISPLAY_SCAN, false);
    } else if (text.startsWith('\\[', at)) {
      m = matchBracketAt(ctx, at);
    }
    if (!m) { return null; }
    var after = at + m.raw.length;
    var k = after;
    while (k < text.length && (text.charCodeAt(k) === 32 || text.charCodeAt(k) === 9)) { k++; }
    if (k < text.length) {
      if (text.charCodeAt(k) === 13 && text.charCodeAt(k + 1) === 10) { k += 2; }
      else if (text.charCodeAt(k) === 10) { k += 1; }
      else { return null; }
    }
    m.raw = indent + m.raw + text.slice(after, k);
    return m;
  }

  function matchBlock(src) { return matchBlockAt(scanContext(src), 0); }

  /* Index of the next inline math that actually matches, or -1. Only a
   * real match is reported: marked cuts its text token at every reported
   * index, and a paragraph full of lone dollars would otherwise be cut
   * into thousands of pieces. Looks at most MAX_START_WINDOW characters
   * ahead and spends at most START_STEP_BUDGET scan steps; when nothing
   * matches within those bounds but text remains, returns a cut point so
   * marked cuts its text token there and asks again. That keeps one huge
   * paragraph linear. */
  /* A cut point for marked's text token at or before `at`: the position
   * just after the last whitespace in the preceding 256 characters, so a
   * cut never splits a word (a GFM autolink or email that straddles the
   * cut would otherwise be broken in two). Falls back to `at` itself. */
  function cutBeforeWord(src, at) {
    var floor = Math.max(1, at - 256);
    for (var k = at; k > floor; k--) {
      if (isSpace(src[k - 1])) { return k; }
    }
    return at;
  }

  function startIndex(src) {
    var ctx = scanContext(src);
    ctx.budget = START_STEP_BUDGET;
    var limit = Math.min(src.length, MAX_START_WINDOW);
    // The regex runs on the window only, so a candidate-free paragraph
    // costs one bounded scan per call, never a scan to its end.
    var window = limit < src.length ? src.slice(0, limit) : src;
    var re = /\$|\\\(/g;
    var m;
    var tried = 0;
    while ((m = re.exec(window)) !== null) {
      if (matchInlineAt(ctx, m.index)) { return m.index; }
      if (++tried >= MAX_START_CANDIDATES || ctx.budget < 0) { return cutBeforeWord(src, m.index + 1); }
      re.lastIndex = m.index + 1;
    }
    return src.length > MAX_START_WINDOW ? cutBeforeWord(src, MAX_START_WINDOW) : -1;
  }

  /* Index of the next line, within the current paragraph, that starts
   * (after up to three spaces) with a display block that matches, or -1.
   * Only a real block is reported, so a paragraph is never split for a
   * `$$` line that turns out to be unterminated. marked calls a block
   * `start` with the paragraph source minus its first character, so
   * index 0 of `src` is never a real line start: only a delimiter that
   * follows a newline counts, which keeps a mid-line `$$` from cutting a
   * paragraph (marked would re-join the pieces with a stray newline). The
   * search stops at the first blank line: a paragraph cannot cross one,
   * so a later delimiter is a later paragraph's business. */
  function blockStartIndex(src) {
    var ctx = scanContext(src);
    ctx.budget = START_STEP_BUDGET;
    // Find the paragraph's end (first space-only blank line) in a bounded
    // window, then look for delimiter lines inside that scope only.
    var head = src.length > MAX_START_WINDOW ? src.slice(0, MAX_START_WINDOW) : src;
    var blank = /\n *\r?\n/.exec(head);
    var scopeEnd = blank ? blank.index + 1 : head.length;
    var scope = scopeEnd < src.length ? src.slice(0, scopeEnd) : src;
    var re = /\n[ \t]{0,3}(?:\$\$|\\\[)/g;
    var m;
    while ((m = re.exec(scope)) !== null) {
      if (matchBlockAt(ctx, m.index + 1)) { return m.index + 1; }
      if (ctx.budget < 0) { return -1; }
      re.lastIndex = m.index + 1;
    }
    return -1;
  }

  /* Split plain text into [{type:'text', data}] and
   * [{type:'math', data, raw, display}] parts. For hosts that do not use
   * marked. Backslash-dollar never opens math. `\[...\]` counts only when
   * it starts a line (up to three spaces of indentation) and ends one; so
   * does a `$$...$$` with whitespace just inside. */
  function splitText(text) {
    var ctx = scanContext(text);
    var parts = [];
    var pos = 0;
    var i = 0;
    while (i < text.length) {
      var code = text.charCodeAt(i);
      if (code === 92 && text.charCodeAt(i + 1) === 36) { i += 2; continue; }
      if (code !== 36 && code !== 92) { i++; continue; }
      var m = null;
      var bracket = code === 92 && text.charCodeAt(i + 1) === 91 /* [ */;
      if (bracket || (code === 36 && text.charCodeAt(i + 1) === 36)) {
        // Own-line form: the delimiter starts a line, after at most three
        // spaces of indentation (Claude Code indents terminal output by
        // two). matchBlockAt is asked at the delimiter, so the indentation
        // stays in the surrounding text part.
        var back = i;
        while (back > 0 && back > i - 3 && text.charCodeAt(back - 1) === 32) { back--; }
        if (back === 0 || text.charCodeAt(back - 1) === 10) {
          m = matchBlockAt(ctx, i);
        }
      }
      if (!m && !bracket) {
        m = matchInlineAt(ctx, i);
      }
      if (!m) { i++; continue; }
      if (i > pos) { parts.push({ type: 'text', data: text.slice(pos, i) }); }
      parts.push({ type: 'math', data: m.text, raw: m.raw, display: m.display });
      i += m.raw.length;
      pos = i;
    }
    if (pos < text.length) { parts.push({ type: 'text', data: text.slice(pos) }); }
    return parts;
  }

  /* ---------- marked extension ---------- */

  function escapeHtmlText(s) {
    return String(s == null ? '' : s)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;');
  }

  function placeholderHTML(match, block) {
    var source = '<span class="' + SOURCE_CLASS + '">'
      + escapeHtmlText(match.open + match.body + match.close)
      + '</span>';
    if (match.display) {
      return '<' + (block ? 'div' : 'span') + ' class="' + DISPLAY_CLASS + '">'
        + source + '</' + (block ? 'div' : 'span') + '>' + (block ? '\n' : '');
    }
    return '<span class="' + INLINE_CLASS + '">' + source + '</span>';
  }

  /* Extensions for `marked.use({ extensions: ... })`. The block one takes a
   * `$$`/`\[` that starts a line and ends its line; the inline one takes
   * `$...$`, `\(...\)`, and a tight `$$...$$`. Both run before marked's own
   * escape and emphasis tokenizers, which would otherwise eat `\(`, `\{`,
   * `_`, and `*`. */
  function markedExtensions() {
    return [
      {
        name: 'cmuxMathBlock',
        level: 'block',
        start: function(src) {
          var i = blockStartIndex(src);
          return i < 0 ? undefined : i;
        },
        tokenizer: function(src) {
          var m = matchBlock(src);
          if (!m) { return undefined; }
          return { type: 'cmuxMathBlock', raw: m.raw, math: m };
        },
        renderer: function(token) {
          return placeholderHTML(token.math, true);
        }
      },
      {
        name: 'cmuxMath',
        level: 'inline',
        start: function(src) {
          var i = startIndex(src);
          return i < 0 ? undefined : i;
        },
        tokenizer: function(src) {
          var m = matchInline(src);
          if (m) { return { type: 'cmuxMath', raw: m.raw, math: m }; }
          // An unmatched `$$` is literal text. Consume both characters
          // here: marked hands later hints only the remaining substring,
          // so the second `$` would otherwise look like a fresh opener
          // (`$$x$` while streaming, `the PID is $$ and $$`).
          if (src.charCodeAt(0) === 36 && src.charCodeAt(1) === 36) {
            return { type: 'text', raw: '$$', text: '$$' };
          }
          return undefined;
        },
        renderer: function(token) {
          return placeholderHTML(token.math, false);
        }
      }
    ];
  }

  /* ---------- rendering ---------- */

  function sourceText(el) {
    var srcEl = el.querySelector('.' + SOURCE_CLASS);
    return srcEl ? srcEl.textContent : el.textContent;
  }

  function isDisplayElement(el) {
    return el.classList.contains('cmux-math-display');
  }

  /* Strip the delimiters from the stored source. The source always starts
   * with one of `$$`, `\[`, `\(`, `$` and ends with the matching close. */
  function bodyOf(source) {
    var s = String(source || '');
    if (s.startsWith('$$') && s.endsWith('$$') && s.length >= 4) { return s.slice(2, -2); }
    if (s.startsWith('\\[') && s.endsWith('\\]') && s.length >= 4) { return s.slice(2, -2); }
    if (s.startsWith('\\(') && s.endsWith('\\)') && s.length >= 4) { return s.slice(2, -2); }
    if (s[0] === '$' && s.endsWith('$') && s.length >= 2) { return s.slice(1, -1); }
    return s;
  }

  /* Macro definitions let a short body expand into arbitrarily much work
   * (maxExpand bounds the count of expansions, not their size). Formulas
   * that define macros show their source instead. */
  var MACRO_DEFINITION = /\\(?:def|gdef|edef|xdef|let|futurelet|global|newcommand|renewcommand|providecommand|DeclareMathOperator)\b/;

  var renderCache = {};
  var renderCacheKeys = [];
  var renderCacheBytes = 0;

  function evictRenderCache() {
    while (renderCacheKeys.length > RENDER_CACHE_LIMIT || renderCacheBytes > RENDER_CACHE_BYTES) {
      var key = renderCacheKeys.shift();
      renderCacheBytes -= renderCache[key].length;
      delete renderCache[key];
    }
  }

  /* Typeset `body`. Throws for anything that should show its source:
   * KaTeX parse errors, over-long bodies, macro definitions, and
   * trust-gated commands (\href, \url, \includegraphics, \html*), which
   * KaTeX would otherwise print in red without throwing. */
  function cachedRender(katex, body, display) {
    var key = (display ? 'D' : 'I') + body;
    if (Object.prototype.hasOwnProperty.call(renderCache, key)) {
      return renderCache[key];
    }
    if (body.length > MAX_RENDER_BODY) { throw new Error('cmux-math: body too long'); }
    if (MACRO_DEFINITION.test(body)) { throw new Error('cmux-math: macro definitions are not rendered'); }
    var sawUntrusted = false;
    var html = katex.renderToString(body, {
      displayMode: display,
      throwOnError: true,
      output: 'html',
      trust: function() { sawUntrusted = true; return false; },
      strict: 'ignore',
      maxSize: 100,
      maxExpand: 100
    });
    if (sawUntrusted) { throw new Error('cmux-math: untrusted command'); }
    renderCache[key] = html;
    renderCacheKeys.push(key);
    renderCacheBytes += html.length;
    evictRenderCache();
    return html;
  }

  /* Show the raw source in place. This is the pre-feature appearance. */
  function showFallback(el) {
    el.classList.add(FALLBACK_CLASS);
    var old = el.querySelector('.' + RENDER_CLASS);
    if (old) { old.remove(); }
  }

  function now() {
    return (global.performance && typeof global.performance.now === 'function')
      ? global.performance.now()
      : Date.now();
  }

  /* Render pending placeholders under `root` with `katex`. Returns
   * { rendered, deferred }: `deferred` counts elements left untouched
   * because the pass used its time budget; they stay pending (no
   * data-rendered) so a follow-up pass finishes them, and the caller
   * schedules that pass. Elements that KaTeX rejects or that sit inside
   * raw code markup fall back to their source text. Cached renders are
   * free, so a document re-rendered on every file change stays cheap.
   * `options.budgetMs` overrides the pass budget (tests). */
  function renderPending(root, katex, doc, options) {
    doc = doc || (root.ownerDocument || global.document);
    var budgetMs = options && typeof options.budgetMs === 'number' ? options.budgetMs : RENDER_TIME_BUDGET_MS;
    var rendered = 0;
    var deferred = 0;
    var started = now();
    var blocks = root.querySelectorAll('.cmux-math:not([data-rendered])');
    for (var i = 0; i < blocks.length; i++) {
      var el = blocks[i];
      var source = sourceText(el);
      var display = isDisplayElement(el);
      var body = bodyOf(source);
      var key = (display ? 'D' : 'I') + body;
      var cached = Object.prototype.hasOwnProperty.call(renderCache, key);
      if (!cached && now() - started > budgetMs) {
        deferred = blocks.length - i;
        break;
      }
      el.setAttribute('data-rendered', '1');
      if (el.closest && el.closest('code, pre, kbd, samp')) {
        showFallback(el);
        continue;
      }
      var html;
      try {
        html = cachedRender(katex, body, display);
      } catch (e) {
        showFallback(el);
        continue;
      }
      var out = doc.createElement(display ? 'div' : 'span');
      out.className = RENDER_CLASS;
      out.innerHTML = html;
      el.insertBefore(out, el.firstChild);
      rendered++;
    }
    return { rendered: rendered, deferred: deferred };
  }

  /* Mark every pending placeholder under `root` as fallback. Used when the
   * library never arrives. */
  function fallbackPending(root) {
    var blocks = root.querySelectorAll('.cmux-math:not([data-rendered])');
    Array.prototype.forEach.call(blocks, function(el) {
      el.setAttribute('data-rendered', '1');
      showFallback(el);
    });
    return blocks.length;
  }

  /* ---------- copy and export ---------- */

  /* Replace every math element under `root` with its source text, so an
   * export or a clipboard payload carries LaTeX instead of glyph soup.
   * Display math becomes its own block so line structure survives. */
  function replaceWithSource(root, doc) {
    doc = doc || root.ownerDocument || global.document;
    var nodes = root.querySelectorAll('.cmux-math');
    Array.prototype.forEach.call(nodes, function(el) {
      var source = sourceText(el);
      var replacement;
      if (isDisplayElement(el) && el.tagName && el.tagName.toLowerCase() === 'div') {
        replacement = doc.createElement('p');
        replacement.textContent = source;
      } else {
        replacement = doc.createTextNode(source);
      }
      if (el.parentNode) { el.parentNode.replaceChild(replacement, el); }
    });
    return nodes.length;
  }

  function touchedMath(range, root) {
    var nodes = root.querySelectorAll('.cmux-math');
    var touched = [];
    for (var i = 0; i < nodes.length; i++) {
      if (range.intersectsNode(nodes[i])) { touched.push(nodes[i]); }
    }
    return touched;
  }

  /* Text of a fragment as the user would see it. `innerText` needs layout,
   * so the fragment is parked off screen for the measurement. Falls back to
   * textContent where innerText is unavailable (jsdom). */
  function fragmentText(container, doc) {
    var wrapper = doc.createElement('div');
    wrapper.setAttribute('aria-hidden', 'true');
    wrapper.style.position = 'fixed';
    wrapper.style.left = '-100000px';
    wrapper.style.top = '0';
    wrapper.style.pointerEvents = 'none';
    wrapper.appendChild(container);
    doc.body.appendChild(wrapper);
    try {
      return container.innerText || container.textContent || '';
    } finally {
      wrapper.remove();
    }
  }

  /* Build the clipboard payload for a `copy` event whose selection touches
   * rendered math. Returns null when the default copy should proceed. */
  function clipboardPayload(selection, root, doc) {
    if (!selection || selection.rangeCount === 0 || selection.isCollapsed) { return null; }
    var range = selection.getRangeAt(0);
    var touched = touchedMath(range, root);
    if (touched.length === 0) { return null; }
    // Both ends inside one formula (a drag across its glyphs): the range's
    // common ancestor is inside the element, cloneContents never includes
    // the wrapper, and the glyph text is not even in reading order. The
    // payload is that formula's source, nothing else.
    var anchor = range.commonAncestorContainer;
    var host = anchor.nodeType === 1 ? anchor : anchor.parentNode;
    var inside = host && host.closest ? host.closest('.cmux-math') : null;
    if (inside) {
      var only = sourceText(inside);
      var block = isDisplayElement(inside) && inside.tagName && inside.tagName.toLowerCase() === 'div';
      return { text: only, html: block ? '<p>' + escapeHtmlText(only) + '</p>' : escapeHtmlText(only) };
    }
    var container = doc.createElement('div');
    container.appendChild(range.cloneContents());
    // A selection that starts or ends inside a formula clones a partial
    // element that may lack its .cmux-source child. cloneContents keeps
    // document order, so the k-th math element in the clone is the k-th
    // live element the range touches; recover the source from there.
    var partial = container.querySelectorAll('.cmux-math');
    Array.prototype.forEach.call(partial, function(el, k) {
      if (el.querySelector('.' + SOURCE_CLASS)) { return; }
      var live = touched[k];
      if (!live) { return; }
      var src = doc.createElement('span');
      src.className = SOURCE_CLASS;
      src.textContent = sourceText(live);
      el.textContent = '';
      el.appendChild(src);
    });
    replaceWithSource(container, doc);
    var html = container.innerHTML;
    var text = fragmentText(container, doc);
    return { text: text, html: html };
  }

  /* Install a document-level copy handler. Selections that do not touch a
   * formula keep WebKit's default behavior. Returns a dispose function. */
  function installCopyHandler(doc, root) {
    var listener = function(ev) {
      var clipboard = ev.clipboardData;
      if (!clipboard) { return; }
      var selection = doc.getSelection ? doc.getSelection() : (global.getSelection && global.getSelection());
      var payload;
      try {
        payload = clipboardPayload(selection, root, doc);
      } catch (e) {
        payload = null;
      }
      if (!payload) { return; }
      ev.preventDefault();
      clipboard.setData('text/plain', payload.text);
      clipboard.setData('text/html', payload.html);
    };
    doc.addEventListener('copy', listener);
    return function() {
      doc.removeEventListener('copy', listener);
    };
  }

  global.CmuxMath = {
    findEndOfMath: findEndOfMath,
    matchInline: matchInline,
    matchInlineDollar: matchInlineDollar,
    matchDisplayDollar: matchDisplayDollar,
    matchParen: matchParen,
    matchBracket: matchBracket,
    matchBlock: matchBlock,
    looksLikeTeX: looksLikeTeX,
    startIndex: startIndex,
    blockStartIndex: blockStartIndex,
    splitText: splitText,
    bodyOf: bodyOf,
    placeholderHTML: placeholderHTML,
    markedExtensions: markedExtensions,
    renderPending: renderPending,
    fallbackPending: fallbackPending,
    replaceWithSource: replaceWithSource,
    clipboardPayload: clipboardPayload,
    installCopyHandler: installCopyHandler,
    limits: {
      inlineScan: MAX_INLINE_SCAN,
      displayScan: MAX_DISPLAY_SCAN,
      startWindow: MAX_START_WINDOW,
      startCandidates: MAX_START_CANDIDATES,
      renderBody: MAX_RENDER_BODY,
      renderTimeBudgetMs: RENDER_TIME_BUDGET_MS
    }
  };
})(globalThis);
