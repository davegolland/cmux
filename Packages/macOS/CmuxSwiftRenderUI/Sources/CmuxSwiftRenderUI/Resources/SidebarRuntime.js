"use strict";
// cmux sidebar JS runtime prelude.
//
// A fine-grained reactive scene runtime, SolidJS-shaped: the sidebar program
// runs ONCE, builds a retained scene graph, and subscribes to host data via
// signals. Data changes re-run only the effects that read them, emitting
// minimal scene ops (single-prop updates, keyed child reconciles) that the
// host applies to @Observable scene nodes. Nothing re-renders per tick.
//
// Host bridge (injected by SidebarJSRuntime.swift before this file runs):
//   __host_applyOps(jsonString)  - apply a batch of scene ops
//   __host_action(jsonString)    - run captured commands (cmux/openURL/log)
//   __host_log(string)           - debug logging
// Host entry points (defined here, called by Swift):
//   __setData(key, jsonString)   - update one data key
//   __dispatch(nodeId, event, jsonString) - deliver a UI event
//   __mount(fn)                  - internal: run the sidebar program

(function () {
  // Capture mutable built-ins before authored source runs. The sidebar shares
  // this JavaScript realm, so source may replace globals for its own code, but
  // host-boundary checks must continue using the original functions.
  const intrinsicString = String;
  const intrinsicObjectKeys = Object.keys;
  const intrinsicObjectCreate = Object.create;
  const intrinsicArrayIsArray = Array.isArray;
  const intrinsicNumberIsFinite = Number.isFinite;
  const intrinsicNumberIsSafeInteger = Number.isSafeInteger;
  const intrinsicMathAbs = Math.abs;
  const intrinsicMathMax = Math.max;
  const intrinsicObjectGetPrototypeOf = Object.getPrototypeOf;
  const intrinsicIteratorSymbol = typeof Symbol === "function" ? Symbol.iterator : null;
  const intrinsicSet = Set;
  const intrinsicMap = Map;
  const intrinsicSetAdd = Set.prototype.add;
  const intrinsicSetDelete = Set.prototype.delete;
  const intrinsicSetClear = Set.prototype.clear;
  const intrinsicSetForEach = Set.prototype.forEach;
  const intrinsicSetHas = Set.prototype.has;
  const intrinsicArraySplice = Array.prototype.splice;
  const intrinsicMapGet = Map.prototype.get;
  const intrinsicMapSet = Map.prototype.set;
  const intrinsicMapDelete = Map.prototype.delete;
  const intrinsicMapForEach = Map.prototype.forEach;
  const intrinsicObjectIs = Object.is;

  // Authored code runs in this realm and can otherwise replace a collection
  // prototype after the prelude has created its internal state. Freeze only
  // the prototypes used by the runtime, while leaving ordinary object and
  // array instances mutable for sidebar authors.
  const intrinsicFreeze = Object.freeze;
  intrinsicFreeze(Set.prototype);
  intrinsicFreeze(Map.prototype);
  intrinsicFreeze(Array.prototype);
  intrinsicFreeze(Object.prototype);
  intrinsicFreeze(String.prototype);
  intrinsicFreeze(Function.prototype);
  // `for...of` is used by the host-side bookkeeping below. Freeze the
  // iterator prototypes as well as Array/String.prototype: authored code can
  // otherwise replace an iterator's `next()` method and make a bounded host
  // walk loop forever or skip its accounting checks.
  if (intrinsicIteratorSymbol) {
    const arrayIterator = [][intrinsicIteratorSymbol]();
    const stringIterator = ""[intrinsicIteratorSymbol]();
    intrinsicFreeze(intrinsicObjectGetPrototypeOf(arrayIterator));
    intrinsicFreeze(intrinsicObjectGetPrototypeOf(stringIterator));
  }

  // Capture the host functions before the host removes their global names.
  // Authored source runs after this prelude and must not be able to recover a
  // privileged bridge through `globalThis`.
  const hostApplyOps = globalThis.__host_applyOps;
  const hostAction = globalThis.__host_action;
  const hostLog = globalThis.__host_log;
  // Keep the JSON intrinsics out of authored-source reach. The source shares
  // this context and can replace `JSON.stringify`/`JSON.parse`; host messages
  // must continue to use the originals captured before it runs.
  const jsonStringify = JSON.stringify.bind(JSON);
  const jsonParse = JSON.parse.bind(JSON);
  if (typeof hostApplyOps !== "function" || typeof hostAction !== "function" || typeof hostLog !== "function") {
    throw new Error("sidebar host bridge is unavailable");
  }

  // An action is a capability granted only while the host is delivering a
  // real control event. This blocks source-time side effects, data-update
  // effects, and microtasks that try to act after the event returns.
  let eventDepth = 0;
  let actionsThisEvent = 0;
  const MAX_ACTIONS_PER_EVENT = 32;
  const MAX_SCENE_OPERATIONS = 4096;
  const MAX_SCENE_NODES = 4096;
  const MAX_SCENE_CHILDREN = 2048;
  const MAX_SCENE_PROPERTIES = 128;
  const MAX_STRING_LENGTH = 16 * 1024;
  const MAX_KEY_LENGTH = 128;
  const MAX_NUMBER_MAGNITUDE = 1_000_000;
  const MAX_FLATTEN_DEPTH = 64;
  const MAX_REACTIVE_SIGNALS = 4096;
  const MAX_REACTIVE_EFFECTS = 8192;
  const MAX_REACTIVE_SCOPES = 4096;
  const MAX_ITEM_JSON = 64 * 1024;
  const MAX_SCENE_BATCH_JSON = 2 * 1024 * 1024;
  const MAX_EVENT_JSON = 64 * 1024;
  const MAX_DATA_JSON = 4 * 1024 * 1024;
  const MAX_ACTION_JSON = 16 * 1024;
  const MAX_JSON_TOKENS = 200000;
  // Count both containers and leaves. Leave room for the nesting wrappers so
  // a flat list at the child limit remains valid.
  const MAX_FLATTEN_ITEMS = MAX_SCENE_CHILDREN + MAX_FLATTEN_DEPTH;

  function utf8Length(text) {
    let bytes = 0;
    for (const character of text) {
      const codePoint = character.codePointAt(0);
      bytes += codePoint <= 0x7f ? 1 : (codePoint <= 0x7ff ? 2 : (codePoint <= 0xffff ? 3 : 4));
    }
    return bytes;
  }

  // Return `limit + 1` as soon as the bound is exceeded.  A hostile source
  // can create a very long ASCII string, where scanning the complete value
  // just to reject it would waste the watchdog budget.
  function utf8LengthAtMost(text, limit) {
    if (text.length > limit) return limit + 1;
    let bytes = 0;
    for (const character of text) {
      const codePoint = character.codePointAt(0);
      bytes += codePoint <= 0x7f ? 1 : (codePoint <= 0x7ff ? 2 : (codePoint <= 0xffff ? 3 : 4));
      if (bytes > limit) return limit + 1;
    }
    return bytes;
  }

  // Coerce only primitive values. Calling an authored object's `toString`
  // while building a host message can execute arbitrary user code and create a
  // large temporary string; object values are rejected instead.
  function boundedString(value, limit = MAX_STRING_LENGTH) {
    let text;
    const type = typeof value;
    if (type === "string") text = value;
    else if (value === null || value === undefined) return "";
    // BigInt-to-string conversion is proportional to the integer's size.
    // Authored code can construct a very large BigInt, so do not let a host
    // message add another large allocation while trying to enforce a bound.
    else if (type === "number" || type === "boolean") text = intrinsicString(value);
    else return "";
    if (utf8LengthAtMost(text, limit) <= limit) return text;
    let result = "";
    let bytes = 0;
    for (const character of text) {
      const width = utf8LengthAtMost(character, limit);
      if (bytes + width > limit) break;
      result += character;
      bytes += width;
    }
    return result;
  }

  // Check JSON framing without invoking the recursive parser. The host sends
  // only bounded payloads, but this remains a defense if a future host passes
  // a forged event or data value into the context.
  function isBoundedJSONText(text, limit) {
    if (typeof text !== "string" || utf8Length(text) > limit) return false;
    const stack = [];
    let inString = false;
    let escaped = false;
    let unicodeDigits = 0;
    let tokens = 0;
    let sawValue = false;
    for (let i = 0; i < text.length; i += 1) {
      const byte = text.charCodeAt(i);
      if (inString) {
        if (unicodeDigits > 0) {
          if (!((byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 70) || (byte >= 97 && byte <= 102))) return false;
          unicodeDigits -= 1;
        } else if (escaped) {
          if (byte === 117) unicodeDigits = 4;
          else if (!(byte === 34 || byte === 92 || byte === 47 || byte === 98 || byte === 102 || byte === 110 || byte === 114 || byte === 116)) return false;
          escaped = false;
        } else if (byte === 92) {
          escaped = true;
        } else if (byte === 34) {
          inString = false;
        } else if (byte < 32) {
          return false;
        }
        continue;
      }
      if (byte === 34) {
        inString = true;
        sawValue = true;
      } else if (byte === 123 || byte === 91) {
        stack.push(byte);
        tokens += 1;
        sawValue = true;
        if (stack.length > MAX_FLATTEN_DEPTH || tokens > MAX_JSON_TOKENS) return false;
      } else if (byte === 125 || byte === 93) {
        const opener = stack.pop();
        if (!((opener === 123 && byte === 125) || (opener === 91 && byte === 93))) return false;
        tokens += 1;
        if (tokens > MAX_JSON_TOKENS) return false;
      } else if (byte === 44 || byte === 58) {
        tokens += 1;
        if (tokens > MAX_JSON_TOKENS) return false;
      } else if (byte !== 32 && byte !== 9 && byte !== 10 && byte !== 13) {
        sawValue = true;
      }
    }
    return sawValue && !inString && !escaped && unicodeDigits === 0 && stack.length === 0;
  }

  function parseBoundedJSON(text, limit) {
    if (!isBoundedJSONText(text, limit)) throw new Error("sidebar JSON value is invalid");
    return jsonParse(text);
  }

  function emitLog(message) {
    // Logs are diagnostic only and never carry a host command capability.
    hostLog(boundedString(message, 4096));
  }

  function emitAction(action) {
    // Effects are state propagation.  They must never inherit the event
    // capability from the handler that caused them, otherwise one click can
    // fan out into commands from every dependent binding.
    if (eventDepth <= 0 || currentEffect) {
      emitLog("blocked sidebar action outside a control event");
      return;
    }
    if (++actionsThisEvent > MAX_ACTIONS_PER_EVENT) {
      throw new Error("sidebar action limit exceeded");
    }
    hostAction(boundedJSON(action, MAX_ACTION_JSON));
  }

  // ---------------------------------------------------------------------
  // Reactive core
  // ---------------------------------------------------------------------
  let currentEffect = null;
  let currentScope = null;
  const pendingEffects = new intrinsicSet();
  let running = false;
  let reactiveSignalCount = 0;
  let reactiveEffectCount = 0;
  let reactiveScopeCount = 0;
  let rootScope = null;
  let sidebarMounted = false;
  let sidebarMounting = false;

  function createSignal(initial, persistent = false) {
    if (++reactiveSignalCount > MAX_REACTIVE_SIGNALS) {
      throw new Error("sidebar reactive signal limit exceeded");
    }
    let value = initial;
    const subscribers = new intrinsicSet();
    const lifetime = { disposed: false };
    const owner = currentScope || rootScope;
    if (owner && !persistent) owner.signals.push(lifetime);
    const read = () => {
      if (currentEffect) {
        intrinsicSetAdd.call(subscribers, currentEffect);
        currentEffect.deps.push(subscribers);
      }
      return value;
    };
    const write = (next) => {
      if (lifetime.disposed) return;
      if (intrinsicObjectIs(value, next)) return;
      value = next;
      const effects = [];
      intrinsicSetForEach.call(subscribers, (eff) => effects.push(eff));
      for (let i = 0; i < effects.length; i += 1) {
        intrinsicSetAdd.call(pendingEffects, effects[i]);
      }
      scheduleRun();
    };
    return [read, write];
  }

  function createEffect(fn) {
    if (++reactiveEffectCount > MAX_REACTIVE_EFFECTS) {
      throw new Error("sidebar reactive effect limit exceeded");
    }
    const eff = {
      deps: [],
      disposed: false,
      run() {
        if (eff.disposed) return;
        cleanupDeps(eff);
        const prevEffect = currentEffect;
        currentEffect = eff;
        try {
          fn();
        } finally {
          currentEffect = prevEffect;
        }
      },
    };
    if (currentScope) currentScope.effects.push(eff);
    eff.run();
    return eff;
  }

  function cleanupDeps(eff) {
    for (let i = 0; i < eff.deps.length; i += 1) {
      intrinsicSetDelete.call(eff.deps[i], eff);
    }
    eff.deps = [];
  }

  function scheduleRun() {
    // A handler may update a signal.  Keep the dependent effects queued until
    // the handler has returned and the event capability has been revoked.
    if (running || eventDepth > 0) return; // drained by the caller
    runPending();
  }

  function runPending() {
    running = true;
    try {
      let guard = 0;
      while (pendingEffects.size > 0) {
        if (++guard > 1000) {
          throw new Error("sidebar effect loop did not settle (1000 rounds)");
        }
        const batch = [];
        intrinsicSetForEach.call(pendingEffects, (eff) => batch.push(eff));
        intrinsicSetClear.call(pendingEffects);
        for (let i = 0; i < batch.length; i += 1) batch[i].run();
      }
    } finally {
      running = false;
      flushOps();
    }
  }

  // Scopes own effects and child nodes for disposal (row unmount).
  function createScope(parent) {
    if (++reactiveScopeCount > MAX_REACTIVE_SCOPES) {
      throw new Error("sidebar reactive scope limit exceeded");
    }
    return { effects: [], signals: [], nodes: [], children: [], parent, disposed: false };
  }

  function runInScope(scope, fn) {
    const prev = currentScope;
    if (prev) prev.children.push(scope);
    currentScope = scope;
    try {
      return fn();
    } finally {
      currentScope = prev;
    }
  }

  function disposeScope(scope) {
    if (scope.disposed) return;
    // Detach a row before clearing it.  Otherwise every keyed-list removal
    // leaves a disposed scope reachable from its parent until the parent is
    // itself removed.
    if (scope.parent) {
      const siblings = scope.parent.children;
      for (let index = 0; index < siblings.length; index += 1) {
        if (siblings[index] === scope) {
          intrinsicArraySplice.call(siblings, index, 1);
          break;
        }
      }
      scope.parent = null;
    }
    // Use an explicit post-order work list. Authored keyed lists can create a
    // deeply nested scope tree; recursive disposal would turn that input into
    // native-stack growth even though creation itself is bounded.
    const work = [{ scope, exiting: false }];
    while (work.length > 0) {
      const frame = work.pop();
      const current = frame.scope;
      if (frame.exiting) {
        for (const eff of current.effects) {
          eff.disposed = true;
          cleanupDeps(eff);
          intrinsicSetDelete.call(pendingEffects, eff);
          reactiveEffectCount = intrinsicMathMax(0, reactiveEffectCount - 1);
        }
        current.effects = [];
        for (const lifetime of current.signals) {
          if (!lifetime.disposed) {
            lifetime.disposed = true;
            reactiveSignalCount = intrinsicMathMax(0, reactiveSignalCount - 1);
          }
        }
        current.signals = [];
        for (const id of current.nodes) {
          delete handlers[id];
          intrinsicSetDelete.call(liveNodeIds, id);
          pushOp({ op: "remove", id });
        }
        current.nodes = [];
        current.parent = null;
        reactiveScopeCount = intrinsicMathMax(0, reactiveScopeCount - 1);
        continue;
      }
      if (current.disposed) continue;
      current.disposed = true;
      work.push({ scope: current, exiting: true });
      for (let index = current.children.length - 1; index >= 0; index -= 1) {
        work.push({ scope: current.children[index], exiting: false });
      }
      current.children = [];
    }
  }

  // ---------------------------------------------------------------------
  // Scene ops
  // ---------------------------------------------------------------------
  let nextId = 1;
  let ops = [];
  let pendingOpsBytes = 0;
  const liveNodeIds = new intrinsicSet();
  const handlers = intrinsicObjectCreate(null);

  function pushOp(op) {
    if (ops.length >= MAX_SCENE_OPERATIONS) {
      throw new Error("sidebar scene operation limit exceeded");
    }
    const encoded = boundedJSON(op, MAX_ITEM_JSON);
    const bytes = utf8Length(encoded);
    if (pendingOpsBytes > MAX_SCENE_BATCH_JSON - bytes) {
      throw new Error("sidebar scene operation batch is too large");
    }
    ops.push(op);
    pendingOpsBytes += bytes;
  }

  function flushOps() {
    if (ops.length === 0) return;
    const batch = ops;
    ops = [];
    pendingOpsBytes = 0;
    const encoded = boundedJSON(batch, MAX_SCENE_BATCH_JSON);
    hostApplyOps(encoded);
  }

  // ---------------------------------------------------------------------
  // Node handles and builders
  // ---------------------------------------------------------------------
  // Reactive prop: a function-valued prop re-evaluates in its own effect and
  // emits a single-prop update op when its value changes.
  function setProp(id, key, value) {
    if (typeof value === "function") {
      createEffect(() => {
        pushOp({ op: "update", id, key, value: normalizeProp(value()) });
      });
    } else {
      pushOp({ op: "update", id, key, value: normalizeProp(value) });
    }
  }

  function normalizeProp(v) {
    if (v === null || v === undefined) return null;
    const t = typeof v;
    if (t === "string") return boundedString(v);
    if (t === "boolean") return v;
    if (t === "number") {
      return intrinsicNumberIsFinite(v) && intrinsicMathAbs(v) <= MAX_NUMBER_MAGNITUDE ? v : null;
    }
    return null;
  }

  const chainableProps = [
    "font", "color", "padding", "background", "cornerRadius", "opacity",
    "bold", "italic", "monospaced", "lineLimit", "spacing", "size",
    "width", "height", "minWidth", "maxWidth", "minHeight", "maxHeight",
    "alignment", "fill", "stroke", "strokeWidth", "systemName", "value",
    "help", "truncation", "weight", "secondary", "borderColor", "borderWidth",
    "hoverBackground", "paddingHorizontal", "paddingVertical", "destructive",
    "paddingLeading", "paddingTrailing", "paddingTop", "paddingBottom",
    "fixed", "block", "layoutPriority", "marginLeading",
    "showOnHover", "hideOnHover", "dragBackground", "dragSet", "rotation",
    "fade", "marquee",
  ];

  function makeHandle(id) {
    const handle = { __nodeId: id };
    for (const key of chainableProps) {
      handle[key] = (value) => {
        // Bare `.bold()` / `.secondary()` style toggles default to true.
        setProp(id, key, value === undefined ? true : value);
        return handle;
      };
    }
    handle.frame = (spec) => {
      applyProps(id, spec || {});
      return handle;
    };
    handle.onTap = (fn) => {
      handlers[id] = handlers[id] || {};
      handlers[id].tap = fn;
      setProp(id, "tappable", true);
      return handle;
    };
    // Double-click (e.g. rename affordance). Coexists with onTap: the host
    // registers the two-click recognizer first, so a double fires this and
    // not two taps.
    handle.onDoubleTap = (fn) => {
      handlers[id] = handlers[id] || {};
      handlers[id].doubletap = fn;
      setProp(id, "doubleTappable", true);
      return handle;
    };
    // Right-click menu: the items (Button / Menu / Divider / Text) become a
    // contextMenu child node; the host renders it as the view's context menu
    // instead of inline content.
    handle.contextMenu = (children) => {
      const menu = makeNode("contextMenu", {}, children);
      pushOp({ op: "append", id, child: menu.__nodeId });
      return handle;
    };
    return handle;
  }

  function applyProps(id, props) {
    if (!props || typeof props !== "object") return;
    const keys = intrinsicObjectKeys(props || {});
    if (keys.length > MAX_SCENE_PROPERTIES) {
      throw new Error("sidebar property limit exceeded");
    }
    for (const key of keys) {
      if (key.length > MAX_KEY_LENGTH || utf8Length(key) > MAX_KEY_LENGTH) throw new Error("sidebar property key is too long");
      const value = props[key];
      if (key === "onTap" || key === "onMove") {
        handlers[id] = handlers[id] || {};
        handlers[id][key === "onTap" ? "tap" : "move"] = value;
        if (key === "onTap") setProp(id, "tappable", true);
        continue;
      }
      setProp(id, key, value);
    }
  }

  function childIds(children) {
    const out = [];
    for (const child of flatten(children)) {
      if (child && child.__nodeId) out.push(child.__nodeId);
    }
    if (out.length > MAX_SCENE_CHILDREN) {
      throw new Error("sidebar child limit exceeded");
    }
    return out;
  }

  function flatten(children) {
    if (!children) return [];
    if (!intrinsicArrayIsArray(children)) return [children];
    const out = [];
    const stack = [{ value: children, depth: 0 }];
    let inspected = 0;
    while (stack.length > 0) {
      const entry = stack.pop();
      if (++inspected > MAX_FLATTEN_ITEMS) {
        throw new Error("sidebar child nesting limit exceeded");
      }
      const value = entry.value;
      if (intrinsicArrayIsArray(value)) {
        if (entry.depth >= MAX_FLATTEN_DEPTH || value.length > MAX_FLATTEN_ITEMS) {
          throw new Error("sidebar child nesting limit exceeded");
        }
        for (let i = value.length - 1; i >= 0; i--) {
          stack.push({ value: value[i], depth: entry.depth + 1 });
        }
      } else {
        out.push(value);
        if (out.length > MAX_SCENE_CHILDREN) {
          throw new Error("sidebar child limit exceeded");
        }
      }
    }
    return out;
  }

  function boundedJSON(value, limit = MAX_ITEM_JSON) {
    let text;
    try {
      text = jsonStringify(value);
    } catch (_) {
      throw new Error("sidebar value is not serializable");
    }
    if (typeof text !== "string" || utf8Length(text) > limit) {
      throw new Error("sidebar value is too large");
    }
    return text;
  }

  function validatedListKey(value) {
    const type = typeof value;
    if (type !== "string" && type !== "number" && type !== "boolean") {
      throw new Error("sidebar list key is invalid");
    }
    if (typeof value === "string" && utf8Length(value) > MAX_KEY_LENGTH) {
      throw new Error("sidebar list key is too long");
    }
    if (type === "number" && (!intrinsicNumberIsFinite(value) || intrinsicMathAbs(value) > MAX_NUMBER_MAGNITUDE)) {
      throw new Error("sidebar list key is invalid");
    }
    const key = boundedString(value, MAX_KEY_LENGTH);
    if (!key || utf8Length(key) > MAX_KEY_LENGTH) {
      throw new Error("sidebar list key is invalid");
    }
    return key;
  }

  function makeNode(type, props, children) {
    if (typeof type !== "string" || !type || utf8Length(type) > MAX_KEY_LENGTH) {
      throw new Error("sidebar node type is invalid");
    }
    if (liveNodeIds.size >= MAX_SCENE_NODES) {
      throw new Error("sidebar node limit exceeded");
    }
    const id = "n" + nextId++;
    intrinsicSetAdd.call(liveNodeIds, id);
    if (currentScope) currentScope.nodes.push(id);
    pushOp({ op: "create", id, type });
    applyProps(id, props);
    if (children !== undefined) {
      pushOp({ op: "children", id, children: childIds(children) });
    }
    return makeHandle(id);
  }

  // Container builders accept (props, children) or just (children).
  function container(type) {
    return (a, b) => {
      if (intrinsicArrayIsArray(a) || (a && a.__nodeId)) return makeNode(type, {}, a);
      return makeNode(type, a || {}, b || []);
    };
  }

  const g = globalThis;
  g.VStack = container("vstack");
  g.HStack = container("hstack");
  g.ZStack = container("zstack");
  g.LazyVStack = container("lazyVStack");
  g.Group = container("group");

  g.Text = (text, props) => {
    const node = makeNode("text", props || {});
    setProp(node.__nodeId, "text", text);
    return node;
  };
  g.Image = (systemName, props) => makeNode("image", { systemName, ...(props || {}) });
  g.Spacer = (props) => makeNode("spacer", props || {});
  g.Divider = (props) => makeNode("divider", props || {});
  g.Circle = (props) => makeNode("circle", props || {});
  g.Capsule = (props) => makeNode("capsule", props || {});
  g.Rectangle = (props) => makeNode("rectangle", props || {});
  g.RoundedRectangle = (props) => makeNode("roundedRectangle", props || {});
  g.ProgressView = (props) => makeNode("progress", props || {});

  // Submenu inside a context menu (or a standalone menu button).
  g.Menu = (title, children) => {
    const node = makeNode("menu", {}, children);
    setProp(node.__nodeId, "text", title);
    return node;
  };

  // Editable one-line text field. `value` is the initial text (string or
  // binding); opts: placeholder, onSubmit(text), onCancel(), onEdit(text)
  // (fires per keystroke - live search), autofocus (default true; pass
  // false for persistent fields so mounting never steals focus). The host
  // focuses autofocus fields on appear; Return submits, Escape cancels.
  g.TextField = (value, opts) => {
    const node = makeNode("textfield", {});
    setProp(node.__nodeId, "text", value);
    if (opts && opts.placeholder) setProp(node.__nodeId, "placeholder", opts.placeholder);
    if (opts && opts.autofocus === false) setProp(node.__nodeId, "autofocus", false);
    handlers[node.__nodeId] = handlers[node.__nodeId] || {};
    if (opts && opts.onSubmit) handlers[node.__nodeId].submit = opts.onSubmit;
    if (opts && opts.onCancel) handlers[node.__nodeId].cancel = opts.onCancel;
    if (opts && opts.onEdit) handlers[node.__nodeId].edit = opts.onEdit;
    return node;
  };

  g.Button = (label, action, children) => {
    const node = makeNode("button", {}, children);
    if (typeof label === "string" || typeof label === "function") {
      setProp(node.__nodeId, "text", label);
    }
    if (typeof action === "function") {
      handlers[node.__nodeId] = handlers[node.__nodeId] || {};
      handlers[node.__nodeId].tap = action;
    }
    return node;
  };

  // ---------------------------------------------------------------------
  // Keyed list reconciliation (ForEach / Reorderable)
  // ---------------------------------------------------------------------
  // items: array or accessor; key: (item) => string; template: (itemAccessor,
  // keyString) => handle. Rows mount once per key; kept rows get their item
  // signal updated (value-compared, so unchanged rows do nothing); removed
  // rows dispose their scope (effects + nodes).
  function keyedList(type, opts, template) {
    const items = opts.items;
    // Keep the implicit key path convenient for primitive arrays and objects
    // with primitive `id` values. Do not coerce an authored object: its
    // `toString` method can execute code during host message construction.
    const keyFn = opts.key || ((item) => {
      const itemType = typeof item;
      if (itemType === "string" || itemType === "number" || itemType === "boolean") return item;
      if (item !== null && itemType === "object") {
        const id = item.id;
        const idType = typeof id;
        if (idType === "string" || idType === "number" || idType === "boolean") return id;
      }
      return null;
    });
    // Scalar options (e.g. spacing) become node props; the wiring keys are not.
    const props = {};
    for (const k of intrinsicObjectKeys(opts)) {
      if (k !== "items" && k !== "key" && k !== "onMove") props[k] = opts[k];
    }
    const node = makeNode(type, props, []);
    const id = node.__nodeId;
    if (opts.onMove) {
      handlers[id] = handlers[id] || {};
      handlers[id].move = opts.onMove;
    }
    const rows = new intrinsicMap(); // key -> {scope, rootId, setItem, serialized}
    const owner = currentScope;

    createEffect(() => {
      const list = typeof items === "function" ? items() : items;
      const arr = intrinsicArrayIsArray(list) ? list : [];
      if (arr.length > MAX_SCENE_CHILDREN) {
        throw new Error("sidebar list limit exceeded");
      }
      const seen = new intrinsicSet();
      const order = [];
      const listLength = arr.length;
      if (!intrinsicNumberIsSafeInteger(listLength) || listLength < 0 || listLength > MAX_SCENE_CHILDREN) {
        throw new Error("sidebar list limit exceeded");
      }
      const itemKeys = [];
      for (let index = 0; index < listLength; index += 1) {
        const item = arr[index];
        const key = validatedListKey(keyFn(item));
        if (intrinsicSetHas.call(seen, key)) continue; // ignore duplicate keys
        intrinsicSetAdd.call(seen, key);
        itemKeys.push(key);
        let row = intrinsicMapGet.call(rows, key);
        const serialized = boundedJSON(item);
        if (!row) {
          const scope = createScope(owner);
          let readItem;
          let writeItem;
          const handle = runInScope(scope, () => {
            [readItem, writeItem] = createSignal(item);
            return template(readItem, key);
          });
          row = { scope, rootId: handle ? handle.__nodeId : null, setItem: writeItem, serialized };
          intrinsicMapSet.call(rows, key, row);
        } else if (row.serialized !== serialized) {
          row.serialized = serialized;
          row.setItem(item);
        }
        if (row.rootId) order.push(row.rootId);
      }
      const staleRows = [];
      intrinsicMapForEach.call(rows, (row, key) => staleRows.push([key, row]));
      for (let i = 0; i < staleRows.length; i += 1) {
        const key = staleRows[i][0];
        const row = staleRows[i][1];
        if (!intrinsicSetHas.call(seen, key)) {
          disposeScope(row.scope);
          intrinsicMapDelete.call(rows, key);
        }
      }
      pushOp({ op: "children", id, children: order });
      // Reorderable rows carry their item keys (JSON array, parallel to
      // children) so the host can report moves by item id.
      if (type === "reorderable") {
        pushOp({ op: "update", id, key: "itemKeys", value: jsonStringify(itemKeys) });
      }
    });
    return node;
  }

  g.ForEach = (opts, template) => keyedList("group", opts, template);
  g.Reorderable = (opts, template) => keyedList("reorderable", opts, template);

  // ---------------------------------------------------------------------
  // Host data and actions
  // ---------------------------------------------------------------------
  const dataSignals = new intrinsicMap(); // key -> [read, write]

  function dataSignal(key) {
    if (typeof key !== "string" || !key || utf8Length(key) > MAX_KEY_LENGTH) {
      throw new Error("sidebar data key is invalid");
    }
    let sig = intrinsicMapGet.call(dataSignals, key);
    if (!sig) {
      if (dataSignals.size >= MAX_REACTIVE_SIGNALS) {
        throw new Error("sidebar data signal limit exceeded");
      }
      // Data signals are shared by the whole runtime.  They outlive keyed row
      // scopes, so do not attach their accounting token to the first row that
      // happens to read a key.
      sig = createSignal(undefined, true);
      intrinsicMapSet.call(dataSignals, key, sig);
    }
    return sig;
  }

  g.data = new Proxy({}, {
    get(_t, key) {
      if (typeof key !== "string") return undefined;
      return () => dataSignal(key)[0]();
    },
  });

  // Author-facing reactive state: `const [open, setOpen] = signal(false)`.
  // Reads inside any function-valued prop subscribe it; writes re-run exactly
  // the bindings that read it.
  g.signal = (initial) => createSignal(initial);
  g.computed = (fn) => {
    const [read, write] = createSignal(undefined);
    createEffect(() => write(fn()));
    return read;
  };

  g.cmux = (method, params) => {
    // Null-prototype records cannot inherit an authored `toJSON` or
    // `__proto__` setter. They cross the bridge as plain JSON after this point.
    if (typeof method !== "string" || !method || utf8LengthAtMost(method, MAX_KEY_LENGTH) > MAX_KEY_LENGTH) {
      throw new Error("sidebar command method is invalid");
    }
    if (params !== undefined && params !== null && typeof params !== "object") {
      throw new Error("sidebar command parameters are invalid");
    }
    const p = intrinsicObjectCreate(null);
    const keys = intrinsicObjectKeys(params || {});
    if (keys.length > 32) throw new Error("sidebar parameter limit exceeded");
    for (const k of keys) {
      if (k.length > MAX_KEY_LENGTH) throw new Error("sidebar parameter key is too long");
      if (utf8Length(k) > MAX_KEY_LENGTH) throw new Error("sidebar parameter key is too long");
      const rawValue = params[k];
      const rawType = typeof rawValue;
      if (rawType !== "string" && rawType !== "number" && rawType !== "boolean" && rawValue !== null) {
        throw new Error("sidebar parameter value is invalid");
      }
      if (rawType === "number" && (!intrinsicNumberIsFinite(rawValue) || intrinsicMathAbs(rawValue) > MAX_NUMBER_MAGNITUDE)) {
        throw new Error("sidebar parameter value is invalid");
      }
      if (rawType === "string" && utf8LengthAtMost(rawValue, 4096) > 4096) {
        throw new Error("sidebar parameter value is too long");
      }
      const value = boundedString(rawValue, 4096);
      if (utf8Length(value) > 4096) throw new Error("sidebar parameter value is too long");
      p[k] = value;
    }
    const action = intrinsicObjectCreate(null);
    action.kind = "cmux";
    action.method = boundedString(method, MAX_KEY_LENGTH);
    action.params = p;
    emitAction(action);
  };
  g.openURL = (url) => {
    if (typeof url !== "string" || utf8LengthAtMost(url, 2048) > 2048) throw new Error("sidebar URL is invalid");
    const action = intrinsicObjectCreate(null);
    action.kind = "openURL";
    action.url = boundedString(url, 2048);
    emitAction(action);
  };
  g.log = (message) => {
    if (typeof message !== "string") throw new Error("sidebar log message is invalid");
    const action = intrinsicObjectCreate(null);
    action.kind = "log";
    action.message = boundedString(message, 4096);
    emitAction(action);
  };

  // ---------------------------------------------------------------------
  // Host entry points
  // ---------------------------------------------------------------------
  g.__setData = (key, json) => {
    if (typeof key !== "string" || !key || utf8Length(key) > MAX_KEY_LENGTH
        || typeof json !== "string" || utf8Length(json) > 4 * 1024 * 1024) {
      throw new Error("sidebar data key is invalid");
    }
    dataSignal(key)[1](parseBoundedJSON(json, MAX_DATA_JSON));
    runPending();
  };

  g.__dispatch = (nodeId, event, json) => {
    if (typeof nodeId !== "string" || !nodeId || utf8Length(nodeId) > MAX_KEY_LENGTH
        || typeof event !== "string" || utf8Length(event) > MAX_KEY_LENGTH
        || (json !== undefined && json !== null && (typeof json !== "string" || utf8Length(json) > MAX_EVENT_JSON))) {
      throw new Error("sidebar event is invalid");
    }
    const nodeHandlers = handlers[nodeId];
    if (!nodeHandlers) return;
    const payload = json ? parseBoundedJSON(json, MAX_EVENT_JSON) : null;
    eventDepth += 1;
    actionsThisEvent = 0;
    try {
      if (event === "tap" && nodeHandlers.tap) nodeHandlers.tap(payload);
      if (event === "move" && nodeHandlers.move && payload) nodeHandlers.move(payload.id, payload.index, payload);
      if (event === "doubletap" && nodeHandlers.doubletap) nodeHandlers.doubletap(payload);
      if (event === "submit" && nodeHandlers.submit) nodeHandlers.submit(payload ? payload.text : "");
      if (event === "cancel" && nodeHandlers.cancel) nodeHandlers.cancel(payload);
      if (event === "edit" && nodeHandlers.edit) nodeHandlers.edit(payload ? payload.text : "");
    } finally {
      eventDepth -= 1;
    }
    // Effects caused by a handler are state propagation, not a fresh user
    // gesture. Drain them after the capability window closes so an effect or
    // a queued callback cannot turn one click into an unbounded action stream.
    runPending();
  };

  // Optional second argument: surface options applied as root props.
  // `surface: "glass"` asks the host to render the whole sidebar surface as
  // translucent material (liquid glass) instead of its opaque backdrop.
  g.sidebar = (fn, opts) => {
    // A runtime owns one retained scene. Allowing authored code to call
    // `sidebar` repeatedly would leave the previous root, effects, handlers,
    // and signals live while replacing only the host root id. Reject both
    // repeated and re-entrant mounts before allocating another scope.
    if (sidebarMounted || sidebarMounting) {
      throw new Error("sidebar may only be mounted once");
    }
    sidebarMounting = true;
    let mounted = false;
    try {
      // Scope allocation is part of the untrusted-program boundary. Keep it
      // inside the guarded region so a rejected scope cannot strand the
      // runtime in the re-entrant "mounting" state.
      rootScope = createScope(null);
      const handle = runInScope(rootScope, fn);
      if (!handle || !handle.__nodeId) {
        throw new Error("sidebar(fn) must return a view (e.g. VStack([...]))");
      }
      if (opts) applyProps(handle.__nodeId, opts);
      pushOp({ op: "root", id: handle.__nodeId });
      runPending();
      sidebarMounted = true;
      mounted = true;
    } finally {
      sidebarMounting = false;
      // A failed mount can be caught by authored code. Consume the one-shot
      // mount slot anyway, so a partially built scene cannot be retried into
      // an unbounded collection of retained nodes and reactive state.
      if (!mounted) sidebarMounted = true;
    }
  };
})();
