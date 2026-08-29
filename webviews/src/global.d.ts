import type { DiffResponse } from "./diff/generated/protocol";

export {};

type AgentSessionNativeReply =
  | { ok: true; value: unknown }
  | { ok: false; error?: { code?: string; userMessage?: string } };

type CmuxMathMatch = {
  raw: string;
  open: string;
  close: string;
  body: string;
  text: string;
  display: boolean;
};

type CmuxMathPart =
  | { type: "text"; data: string }
  | { type: "math"; data: string; raw: string; display: boolean };

declare global {
  /** Global installed by Resources/markdown-viewer/cmux-math.js. */
  var CmuxMath: {
    findEndOfMath(delimiter: string, text: string, startIndex: number): number;
    matchInline(src: string): CmuxMathMatch | null;
    matchInlineDollar(src: string): CmuxMathMatch | null;
    matchDisplayDollar(src: string): CmuxMathMatch | null;
    matchParen(src: string): CmuxMathMatch | null;
    matchBracket(src: string): CmuxMathMatch | null;
    matchBlock(src: string): CmuxMathMatch | null;
    looksLikeTeX(body: string): boolean;
    startIndex(src: string): number;
    blockStartIndex(src: string): number;
    splitText(text: string): CmuxMathPart[];
    bodyOf(source: string): string;
    placeholderHTML(match: CmuxMathMatch, block: boolean): string;
    markedExtensions(): unknown[];
    renderPending(root: Element, katex: unknown, doc?: Document, options?: { budgetMs?: number }): { rendered: number; deferred: number };
    fallbackPending(root: Element): number;
    replaceWithSource(root: Element | DocumentFragment, doc?: Document): number;
    clipboardPayload(selection: Selection | null, root: Element, doc: Document): { text: string; html: string } | null;
    installCopyHandler(doc: Document, root: Element): () => void;
    limits: {
      inlineScan: number;
      displayScan: number;
      startWindow: number;
      startCandidates: number;
      renderBody: number;
      renderTimeBudgetMs: number;
    };
  };

  var CmuxViewerNavigation: {
    install(options: {
      target: Document | HTMLElement;
      getScroller: () => HTMLElement;
      shortcuts: Record<string, unknown>;
    }): () => void;
    installManualInputReset(options: {
      target: Document | HTMLElement;
      getScroller: () => HTMLElement;
    }): () => void;
    performAction(action: string, scroller: HTMLElement): boolean;
    resetSmoothTarget(scroller: HTMLElement): void;
  };

  interface Window {
    __cmuxPerformDiffViewerNavigationAction?: (action: string) => boolean;
    __cmuxDiffViewer?: {
      codeView?: unknown;
      codeViewItems?: unknown[];
      items?: unknown[];
      state?: unknown;
      streamMetrics?: unknown;
      workerPool?: unknown;
    };
    webkit?: {
      messageHandlers?: {
        agentSession?: {
          postMessage(message: unknown): Promise<AgentSessionNativeReply>;
        };
        cmuxDiff?: {
          postMessage(message: unknown): Promise<DiffResponse>;
        };
      };
    };
  }
}
