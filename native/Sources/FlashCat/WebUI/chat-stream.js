/*
 * flashCat · chat stream (v2)
 *
 * A token-accurate streaming renderer for the assistant turn.
 *
 * The old version was a typewriter: Swift pushed whole snapshots every 100 ms
 * and the web view replayed the growing string at 22–62 characters per second.
 * A local engine decoding at 100+ tok/s builds a backlog that never drains, so
 * the reply appeared to stutter and kept "typing" long after generation ended.
 *
 * This version has no artificial pacing at all:
 *
 *   SSE delta ──► Swift event pipe (16 ms batch) ──► ingest()
 *                                                      │
 *   full snapshot (100 ms, authoritative) ──► push() ──┤
 *                                                      ▼
 *                                      one shared rAF ──► DOM
 *
 *   • delta events append straight to a channel; snapshots merge with what is
 *     already on screen instead of replacing it (live text may legitimately be
 *     ahead of a throttled snapshot). Divergence or a missing sequence number
 *     resyncs to the snapshot, so a lost IPC message can never corrupt a reply.
 *   • one requestAnimationFrame drives every live turn; a frame paints at most
 *     once, and Markdown only repatches the block that is still growing.
 *   • the thinking band and the answer are independent channels: reasoning can
 *     still arrive while the answer is being written, each keeps its own scroll.
 *   • scroll follows only while the reader is at the bottom; scrolling up pins
 *     the view and offers a "回到最新" jump control instead of yanking them back.
 *
 * Public surface (the first block is the historical contract used by app.js,
 * live.js and page-components.js):
 *   FCChatStream.answerHTML(message) / thinkingHTML(message) / waitHTML(message)
 *   FCChatStream.push(article, message, { onSettled })
 *   FCChatStream.isAnimating(article) / toggleThinking(block) / release(article)
 *
 *   FCChatStream.ingest(event | [events])   ← new low-latency delta pipe
 *   FCChatStream.prefersReducedMotion()
 */
(function () {
  "use strict";

  if (window.FCChatStream) return;

  var FOLD_WRITING_MS = 620;   // let "思考了 8.4 秒" be read before folding
  var FOLD_DONE_MS = 380;
  var CLOCK_MS = 100;
  var SETTLE_GRACE_MS = 1100;  // wait for the final snapshot before settling
  var JUMP_DISTANCE = 56;      // keep in step with live.js's near-bottom test
  var PROGRAMMATIC_MS = 180;   // ignore scroll events caused by our own follow

  var VIEWS = new WeakMap();   // article → view
  var BY_ID = new Map();       // message id → article (only live turns)
  var ACTIVE = new Set();      // views that still need a clock
  var FRAMES = new Set();      // views with pending paint work
  var SCROLLERS = new WeakMap();
  var DURATIONS = new Map();   // id → measured thinking seconds
  var MANUAL = new Map();      // id → reader's fold choice (never overridden)
  var STARTS = new Map();      // id → begin timestamp (ms), for late mounts
  var raf = 0;
  var ticker = 0;
  /// Highest stream event already folded into an authoritative snapshot. A
  /// delta at or below it is a duplicate as far as the reader is concerned.
  var WATERMARK = 0;

  function setWatermark(seq) {
    var value = Number(seq);
    if (Number.isFinite(value) && value > WATERMARK) WATERMARK = value;
  }

  function prefersReducedMotion() {
    return Boolean(window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches);
  }

  function escapeHTML(value) {
    return String(value == null ? "" : value)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  function icon(name, size) {
    if (window.FCIcons && typeof window.FCIcons.svg === "function") {
      return window.FCIcons.svg(name, "fc-stream-icon", size || 12);
    }
    return "";
  }

  function safeID(value) {
    return String(value == null ? "" : value).replace(/[^\w-]/g, "");
  }

  function durationFor(message) {
    var explicit = Number(message && message.thinkingSeconds);
    if (Number.isFinite(explicit) && explicit > 0) return explicit;
    var stored = DURATIONS.get(String(message && message.id));
    return Number.isFinite(stored) && stored > 0 ? stored : null;
  }

  function formatDuration(seconds) {
    if (!Number.isFinite(seconds) || seconds <= 0) return "";
    if (seconds < 60) return (seconds < 10 ? seconds.toFixed(1) : Math.round(seconds)) + " 秒";
    var minutes = Math.floor(seconds / 60);
    var rest = Math.round(seconds % 60);
    return minutes + " 分" + (rest ? " " + rest + " 秒" : "");
  }

  function phaseOf(message) {
    if (!message.streaming) return "done";
    return message.content ? "writing" : "thinking";
  }

  /// Last meaningful line of a reasoning stream, stripped of Markdown noise.
  /// Shown in the collapsed row so the folded band still says something useful.
  function latestLine(raw) {
    var lines = String(raw == null ? "" : raw).split("\n");
    for (var i = lines.length - 1; i >= 0; i -= 1) {
      var line = lines[i].trim();
      if (!line) continue;
      line = line
        .replace(/^#{1,6}\s+/, "")
        .replace(/^[-*+]\s+/, "")
        .replace(/^>\s*/, "")
        .replace(/\[([^\]]+)\]\([^)]*\)/g, "$1")
        .replace(/[*_`~]/g, "")
        .trim();
      if (!line) continue;
      return line.length > 86 ? "…" + line.slice(-84) : line;
    }
    return "";
  }

  function thinkLabel(phase, seconds) {
    if (phase === "thinking") return "思考中";
    // A model that answers in the same frame has no thinking phase to report.
    if (Number.isFinite(seconds) && seconds >= 0.1) return "思考了 " + formatDuration(seconds);
    return "思考过程";
  }

  // ---------- static markup (history + first paint) ------------------------
  function thinkingMarkup(message) {
    var reasoning = String(message.reasoning || "");
    // No band until there is something to read. Models without a reasoning
    // channel show the compact waiting state in the answer area instead.
    if (!reasoning.trim()) return "";

    var phase = phaseOf(message);
    var seconds = durationFor(message);
    var id = safeID(message.id);
    var expanded = MANUAL.has(id) ? MANUAL.get(id) : phase === "thinking";
    var label = thinkLabel(phase, seconds);
    var bodyID = "fc-reason-" + (id || "live");
    var time = phase === "thinking"
      ? '<span class="fc-reason-time" data-think-time>0.0 秒</span>' : "";

    return '<section class="think fc-reason' + (expanded ? " is-open" : "") + '"' +
      ' data-think data-think-id="' + escapeHTML(id) + '" data-state="' + phase + '"' +
      ' aria-label="思考过程">' +
      '<button class="think-head fc-reason-head" type="button" data-action="toggle-reasoning"' +
      ' aria-expanded="' + (expanded ? "true" : "false") + '" aria-controls="' + escapeHTML(bodyID) + '">' +
      '<span class="fc-reason-mark" aria-hidden="true">' +
      '<span class="fc-reason-mark-icon">' + icon("brain", 12) + '</span>' +
      '<span class="fc-reason-mark-check">' + icon("check", 11) + '</span></span>' +
      '<span class="fc-reason-copy">' +
      '<span class="fc-reason-line"><span class="think-label fc-reason-label">' + escapeHTML(label) +
      '</span>' + time + '</span>' +
      '<span class="think-peek fc-reason-peek" data-think-peek aria-hidden="true">' +
      escapeHTML(latestLine(reasoning)) + '</span></span>' +
      '<span class="fc-reason-activity" aria-hidden="true"><i></i><i></i><i></i></span>' +
      '<span class="think-chevron fc-reason-chevron" aria-hidden="true">' + icon("chevronDown", 11) + '</span>' +
      '</button>' +
      '<div class="think-body fc-reason-body" id="' + escapeHTML(bodyID) + '">' +
      '<div class="think-clip fc-reason-clip"><div class="think-viewport fc-reason-viewport" data-think-view>' +
      (reasoning.trim()
        ? '<div class="md-body md-think" data-think-md>' + window.FCChatMarkdown.render(reasoning) + '</div>'
        : '<div class="fc-reason-skeleton" data-think-skeleton aria-hidden="true"><i></i><i></i><i></i></div>') +
      '</div></div></div></section>';
  }

  function waitMarkup(message) {
    var label = message && message.reasoning ? "正在整理回答" : "正在生成回答";
    return '<span class="fc-wait" role="status" aria-label="' + escapeHTML(label) + '">' +
      '<span class="fc-wait-dots" aria-hidden="true"><i></i><i></i><i></i></span>' +
      '<span class="fc-wait-text">' + escapeHTML(label) + '</span>' +
      '<span class="fc-wait-sheen" aria-hidden="true"></span></span>';
  }

  function answerMarkup(message) {
    if (!message.content) {
      if (message.streaming) return waitMarkup(message);
      return message.reasoning
        ? '<span class="fc-empty-note">本次只输出了思考，没有生成正文。</span>'
        : "";
    }
    return '<div class="md-body fc-md" data-fc-md>' +
      window.FCChatMarkdown.render(message.content) + '</div>';
  }

  // ---------- channels ------------------------------------------------------
  function channel() {
    return { text: "", snapshot: "", dirty: false };
  }

  /// Merge an authoritative snapshot into a channel that may be ahead of it.
  /// The snapshot is a 100 ms debounced view of the Swift model; the delta pipe
  /// is real time. Both orders are normal, so neither may blindly win.
  function mergeChannel(ch, incoming) {
    var text = String(incoming == null ? "" : incoming);
    ch.snapshot = text;
    if (text === ch.text) return;
    if (ch.text && text.startsWith(ch.text)) {
      // Snapshot is ahead: a delta was dropped (page reload, IPC backpressure).
      ch.text = text;
      ch.dirty = true;
    } else if (ch.text.startsWith(text)) {
      // Live text is ahead: keep painting it, the next snapshot will catch up.
    } else {
      // Divergence: Swift rewrote the text (canonical/final form) or the view
      // was rebuilt. The snapshot is the source of truth.
      ch.text = text;
      ch.dirty = true;
    }
  }

  function appendDelta(ch, text) {
    var piece = String(text == null ? "" : text);
    if (!piece) return;
    ch.text += piece;
    ch.dirty = true;
  }

  // ---------- scroll governor ----------------------------------------------
  function scrollerOf(article) {
    return article.closest(".chat-messages, #chatMessages, .messages-scroll");
  }

  function scrollState(node) {
    var state = SCROLLERS.get(node);
    if (state) return state;
    state = { node: node, pinned: false, unread: false, ignoreUntil: 0, button: null, bound: false };
    SCROLLERS.set(node, state);
    return state;
  }

  function jumpButton(state) {
    if (state.button) return state.button;
    var host = state.node.closest(".chat-page") || state.node.parentNode;
    if (!host) return null;
    var button = document.createElement("button");
    button.type = "button";
    button.className = "fc-jump";
    button.setAttribute("aria-hidden", "true");
    button.innerHTML = '<span class="fc-jump-icon">' + icon("arrowUp", 13) + '</span>' +
      '<span class="fc-jump-label">回到最新</span>';
    button.addEventListener("click", function () {
      state.pinned = false;
      state.unread = false;
      state.ignoreUntil = performance.now() + PROGRAMMATIC_MS;
      hideJump(state);
      state.node.scrollTop = state.node.scrollHeight;
    });
    host.appendChild(button);
    state.button = button;
    return button;
  }

  function showJump(state) {
    var button = jumpButton(state);
    if (!button) return;
    button.classList.add("is-visible");
    button.setAttribute("aria-hidden", "false");
    var label = button.querySelector(".fc-jump-label");
    if (label) label.textContent = state.unread ? "有新内容 · 回到最新" : "回到最新";
  }

  function hideJump(state) {
    if (!state.button) return;
    state.button.classList.remove("is-visible");
    state.button.setAttribute("aria-hidden", "true");
  }

  function onScrollerScroll(event) {
    var state = SCROLLERS.get(event.currentTarget);
    if (!state) return;
    var distance = state.node.scrollHeight - state.node.scrollTop - state.node.clientHeight;
    // A scroll away from the bottom is always the reader's own action: our
    // follow only ever lands at the bottom, so it can never produce this.
    if (distance > JUMP_DISTANCE) {
      if (!state.pinned) { state.pinned = true; state.unread = false; }
      showJump(state);
      return;
    }
    // Our own scrollTop writes fire a scroll event too; only let a genuine
    // reader gesture clear the pin.
    if (performance.now() < state.ignoreUntil) return;
    if (distance < 40) {
      state.pinned = false;
      state.unread = false;
      hideJump(state);
    }
  }

  function bindScroller(view) {
    var node = scrollerOf(view.article);
    if (!node) return;
    var state = scrollState(node);
    view.scroller = state;
    if (!state.bound) {
      state.bound = true;
      node.addEventListener("scroll", onScrollerScroll, { passive: true });
    }
  }

  function follow(state) {
    if (!state || !state.node || !state.node.isConnected) return;
    if (state.pinned) {
      if (!state.unread) {
        state.unread = true;
        showJump(state);
      }
      return;
    }
    state.ignoreUntil = performance.now() + PROGRAMMATIC_MS;
    state.node.scrollTop = state.node.scrollHeight;
  }

  // ---------- view lifecycle ------------------------------------------------
  function makeCaret() {
    var caret = document.createElement("span");
    caret.className = "fc-caret";
    caret.setAttribute("aria-hidden", "true");
    return caret;
  }

  /// live.js rebuilds #messagesInner wholesale when the thread changes. Drop
  /// views whose articles were detached so ids and scroll listeners never pile
  /// up across conversations.
  function sweep() {
    BY_ID.forEach(function (old, id) {
      if (!old) BY_ID.delete(id);
      else if (!old.isConnected) release(old);
    });
    STARTS.forEach(function (at, id) {
      if (Date.now() - at > 60000) STARTS.delete(id);
    });
  }

  function attach(article, message) {
    var textHost = article.querySelector(".assistant-text");
    if (!textHost) return null;
    sweep();

    var id = String(message.id == null ? "" : message.id);
    var explicit = Number(message.thinkingSeconds);
    var created = Number(message.createdAt) || 0;
    var beginAt = STARTS.get(id) || 0;
    var plausible = created > 0 && Date.now() - created < 10 * 60 * 1000 ? created : 0;
    var startedAt = plausible || beginAt || Date.now();

    var view = {
      article: article,
      id: id,
      textHost: textHost,
      body: textHost.querySelector("[data-fc-md]") || null,
      think: article.querySelector("[data-think]") || null,
      thinkMD: null,
      answer: channel(),
      reason: channel(),
      caret: makeCaret(),
      phase: "idle",
      streaming: Boolean(message.streaming),
      finishing: false,
      settled: false,
      ended: !message.streaming,
      onSettled: null,
      settleAt: 0,
      startedAt: startedAt,
      duration: Number.isFinite(explicit) && explicit > 0 ? explicit : (DURATIONS.get(id) || null),
      lastSeq: WATERMARK,
      degraded: false,
      lastClock: 0,
      foldTimer: 0,
      dismissTimer: 0,
      scroller: null,
      viewPinned: false,
      reduce: prefersReducedMotion(),
    };

    view.answer.text = String(message.content || "");
    view.answer.snapshot = view.answer.text;
    view.reason.text = String(message.reasoning || "");
    view.reason.snapshot = view.reason.text;

    if (view.think) {
      view.thinkMD = view.think.querySelector("[data-think-md]");
      var head = view.think.querySelector(".think-head");
      var expanded = head ? head.getAttribute("aria-expanded") === "true" : false;
      view.think.classList.toggle("is-open", expanded);
    }

    VIEWS.set(article, view);
    BY_ID.set(id, article);
    view.phase = phaseOf(message);
    if (view.duration == null) {
      var stored = DURATIONS.get(id);
      if (Number.isFinite(stored)) view.duration = stored;
    }

    if (view.streaming) {
      ACTIVE.add(view);
      bindScroller(view);
      article.classList.add("is-streaming");
      article.setAttribute("aria-busy", "true");
      var card = article.querySelector(".assistant-card");
      if (card) card.classList.add("is-streaming");
      if (view.body) placeCaret(view);
      updateFold(view, true);
      ensureTicker();
      schedule(view);
    } else {
      view.settled = true;
      article.classList.add("is-done");
      article.setAttribute("aria-busy", "false");
    }
    return view;
  }

  function ensureBody(view) {
    if (view.body) return view.body;
    var wait = view.textHost.querySelector(".fc-wait");
    if (wait) {
      if (view.reduce) wait.remove();
      else {
        wait.classList.add("is-leaving");
        window.setTimeout(function () { if (wait.parentNode) wait.parentNode.removeChild(wait); }, 200);
      }
    }
    var empty = view.textHost.querySelector(".fc-empty-note");
    if (empty) empty.remove();
    var card = view.article.querySelector(".assistant-card");
    if (card) card.classList.remove("is-empty");
    var body = document.createElement("div");
    body.className = "md-body fc-md";
    body.setAttribute("data-fc-md", "");
    view.textHost.appendChild(body);
    view.body = body;
    return body;
  }

  function placeCaret(view) {
    if (!view.caret || !view.body || view.settled) return;
    var body = view.body;
    var host = body;
    var node = body.lastElementChild;
    while (node) {
      if (node.tagName === "HR") break;
      if (node.tagName === "TABLE") {
        var cell = node.querySelector("tbody tr:last-child td:last-child") ||
          node.querySelector("thead th:last-child");
        if (cell) host = cell;
        break;
      }
      host = node;
      var next = null;
      for (var i = node.children.length - 1; i >= 0; i -= 1) {
        var child = node.children[i];
        if (child === view.caret) continue;
        // Reveal chunks are transient inline wrappers: they are unwrapped as
        // soon as the fade ends, so the caret must never live inside one.
        if (child.classList && child.classList.contains("fc-reveal")) continue;
        next = child;
        break;
      }
      if (!next || next.tagName === "BR") break;
      node = next;
    }
    host.appendChild(view.caret);
  }

  function createThink(view) {
    if (view.think) return view.think;
    var holder = document.createElement("div");
    holder.innerHTML = thinkingMarkup({
      id: view.id,
      reasoning: view.reason.text,
      content: view.answer.text,
      streaming: view.streaming,
      thinkingSeconds: view.duration,
    });
    var block = holder.firstElementChild;
    if (!block) return null;
    block.classList.add("is-enter");
    block.addEventListener("animationend", function () { block.classList.remove("is-enter"); }, { once: true });
    var card = view.article.querySelector(".assistant-card");
    if (card && card.parentNode) card.parentNode.insertBefore(block, card);
    else view.article.querySelector(".message-body").appendChild(block);
    view.article.classList.add("has-think");
    view.think = block;
    view.thinkMD = block.querySelector("[data-think-md]");
    updateFold(view, true);
    return block;
  }

  function ensureThinkBody(view) {
    if (view.thinkMD || !view.think) return view.thinkMD;
    var skeleton = view.think.querySelector("[data-think-skeleton]");
    if (skeleton) skeleton.remove();
    var host = view.think.querySelector("[data-think-view]");
    if (!host) return null;
    var md = document.createElement("div");
    md.className = "md-body md-think";
    md.setAttribute("data-think-md", "");
    host.appendChild(md);
    view.thinkMD = md;
    return md;
  }

  // ---------- fold ----------------------------------------------------------
  function openThink(block) {
    var body = block.querySelector(".fc-reason-body");
    if (!body) { block.classList.add("is-open"); return; }
    if (block.classList.contains("is-open")) return;
    var token = (block.__reasonToken = (block.__reasonToken || 0) + 1);
    window.clearTimeout(block.__reasonTimer);
    var viewport = block.querySelector("[data-think-view]");
    var target = Math.min(260, viewport ? viewport.scrollHeight : 0);
    body.style.height = "0px";
    block.classList.add("is-open", "is-animating");
    void body.offsetHeight;
    body.style.height = target + "px";
    var done = function (event) {
      if (event && event.propertyName !== "height") return;
      body.removeEventListener("transitionend", done);
      if (block.__reasonToken !== token || !block.classList.contains("is-open")) return;
      body.style.height = "";
      block.classList.remove("is-animating");
    };
    body.addEventListener("transitionend", done);
    block.__reasonTimer = window.setTimeout(done, 380);
  }

  function closeThink(block) {
    if (!block || !block.classList.contains("is-open")) return;
    var body = block.querySelector(".fc-reason-body");
    if (!body) { block.classList.remove("is-open"); return; }
    var token = (block.__reasonToken = (block.__reasonToken || 0) + 1);
    window.clearTimeout(block.__reasonTimer);
    var current = body.getBoundingClientRect().height;
    body.style.height = current + "px";
    block.classList.add("is-animating");
    block.classList.remove("is-open");
    void body.offsetHeight;
    body.style.height = "0px";
    var done = function (event) {
      if (event && event.propertyName !== "height") return;
      body.removeEventListener("transitionend", done);
      if (block.__reasonToken !== token || block.classList.contains("is-open")) return;
      body.style.height = "";
      block.classList.remove("is-animating");
    };
    body.addEventListener("transitionend", done);
    block.__reasonTimer = window.setTimeout(done, 380);
  }

  function updateFold(view, immediate) {
    var block = view.think;
    if (!block) return;
    var manual = MANUAL.has(view.id) ? MANUAL.get(view.id) : null;
    var open = manual != null ? manual : view.phase === "thinking";
    var currently = block.classList.contains("is-open");
    var head = block.querySelector(".think-head");
    if (head) head.setAttribute("aria-expanded", String(open));
    if (open === currently) return;
    if (immediate || view.reduce) {
      block.classList.toggle("is-open", open);
      var body = block.querySelector(".fc-reason-body");
      if (body) body.style.height = "";
    } else if (open) {
      openThink(block);
    } else {
      closeThink(block);
    }
  }

  function scheduleFold(view) {
    window.clearTimeout(view.foldTimer);
    if (view.phase === "thinking" || MANUAL.has(view.id)) return;
    view.foldTimer = window.setTimeout(function () {
      if (!view.think || !view.think.isConnected) return;
      if (MANUAL.has(view.id) || view.phase === "thinking") return;
      updateFold(view);
    }, view.phase === "writing" ? FOLD_WRITING_MS : FOLD_DONE_MS);
  }

  // ---------- rendering -----------------------------------------------------
  function renderAnswer(view) {
    view.answer.dirty = false;
    if (!view.answer.text) return;
    var body = ensureBody(view);
    window.FCChatMarkdown.sync(body, view.answer.text, {
      streaming: view.streaming || view.finishing,
      // Text lands immediately; only the fade is staggered. Nothing queues up.
      reveal: !view.reduce && view.streaming,
    });
    placeCaret(view);
  }

  function updatePeek(view) {
    if (!view.think) return;
    var peek = view.think.querySelector("[data-think-peek]");
    if (!peek) return;
    var line = latestLine(view.reason.text);
    if (peek.textContent !== line) peek.textContent = line;
  }

  function renderReason(view) {
    view.reason.dirty = false;
    if (!view.think) {
      if (view.reason.text.trim()) createThink(view);
      else return;
    }
    if (!view.reason.text.trim()) return;
    if (!view.thinkMD) ensureThinkBody(view);
    if (!view.thinkMD) return;
    window.FCChatMarkdown.sync(view.thinkMD, view.reason.text, {
      streaming: view.phase === "thinking",
      reveal: !view.reduce && view.phase === "thinking",
    });
    updatePeek(view);
    var viewport = view.think.querySelector("[data-think-view]");
    if (viewport && !view.viewPinned) {
      if (viewport.scrollHeight <= viewport.clientHeight + 2) viewport.scrollTop = 0;
      else viewport.scrollTop = viewport.scrollHeight;
    }
  }

  function paintThinkState(view) {
    var block = view.think;
    if (!block) return;
    block.dataset.state = view.phase;
    block.classList.toggle("is-live", view.phase === "thinking");
    var label = block.querySelector(".fc-reason-label");
    if (label) label.textContent = thinkLabel(view.phase, view.duration);
    var time = block.querySelector("[data-think-time]");
    if (time && view.phase !== "thinking") time.textContent = "";
  }

  function clock(view, stamp) {
    if (view.phase !== "thinking" || !view.think || view.duration != null) return;
    if (stamp - view.lastClock < CLOCK_MS - 20) return;
    view.lastClock = stamp;
    var time = view.think.querySelector("[data-think-time]");
    if (!time) return;
    var seconds = Math.max(0, (Date.now() - view.startedAt) / 1000);
    time.textContent = (seconds < 10 ? seconds.toFixed(1) : String(Math.round(seconds))) + " 秒";
  }

  function refreshPhase(view) {
    var next = !view.streaming ? "done" : (view.answer.text ? "writing" : "thinking");
    if (next === view.phase) return;
    var previous = view.phase;
    view.phase = next;
    if ((previous === "thinking" || previous === "idle") && next !== "thinking") {
      if (view.duration == null && view.startedAt) {
        view.duration = Math.max(0, (Date.now() - view.startedAt) / 1000);
        DURATIONS.set(view.id, view.duration);
      }
    }
    paintThinkState(view);
    if (next !== "thinking") scheduleFold(view);
    else window.clearTimeout(view.foldTimer);
    schedule(view);
  }

  // ---------- frame scheduler ----------------------------------------------
  function schedule(view) {
    if (view) FRAMES.add(view);
    if (!raf) raf = window.requestAnimationFrame(frame);
  }

  function frame() {
    raf = 0;
    var touched = new Set();
    FRAMES.forEach(function (view) {
      FRAMES.delete(view);
      if (!view.article.isConnected) { release(view.article); return; }
      var changed = false;
      if (view.reason.dirty) { renderReason(view); changed = true; }
      if (view.answer.dirty) { renderAnswer(view); changed = true; }
      refreshPhase(view);
      paintThinkState(view);
      clock(view, performance.now());
      if (changed && view.scroller) touched.add(view.scroller);
    });
    touched.forEach(follow);
  }

  function ensureTicker() {
    if (ticker) return;
    ticker = window.setInterval(function () {
      var stamp = performance.now();
      var now = Date.now();
      ACTIVE.forEach(function (view) {
        if (!view.article.isConnected) { release(view.article); return; }
        if (view.phase === "thinking") clock(view, stamp);
        if (view.finishing && view.settleAt && now >= view.settleAt && !view.settled) settle(view);
      });
      if (!ACTIVE.size) {
        window.clearInterval(ticker);
        ticker = 0;
      }
    }, CLOCK_MS);
  }

  // ---------- completion ----------------------------------------------------
  function finish(view, cancelled) {
    if (view.finishing || view.settled) return;
    if (view.duration == null && view.startedAt) {
      view.duration = Math.max(0, (Date.now() - view.startedAt) / 1000);
      DURATIONS.set(view.id, view.duration);
    }
    view.streaming = false;
    view.ended = true;
    view.finishing = true;
    refreshPhase(view);
    paintThinkState(view);
    view.article.setAttribute("aria-busy", "false");
    if (view.reduce || cancelled) {
      view.settleAt = 0;
      settle(view);
    } else {
      view.settleAt = Date.now() + SETTLE_GRACE_MS;
    }
    // The final snapshot carries onSettled (and the meta row). Prefer handing
    // over through it; otherwise settle after a short grace period.
    if (view.onSettled) settle(view);
    ensureTicker();
    schedule(view);
  }

  function settle(view) {
    if (view.settled) return;
    // The final snapshot can add text in the same call that ends the stream.
    // Flush it before tearing down the frame loop, or those characters would
    // never reach the DOM.
    if (view.reason.dirty) renderReason(view);
    if (view.answer.dirty) renderAnswer(view);
    // The turn is over: drop any fade still in flight so the final static
    // reply is fully opaque and has no transient wrapper spans left.
    if (window.FCChatMarkdown && window.FCChatMarkdown.settleReveals) {
      window.FCChatMarkdown.settleReveals(view.body);
      window.FCChatMarkdown.settleReveals(view.thinkMD);
    }
    view.settled = true;
    view.finishing = false;
    view.phase = "done";
    ACTIVE.delete(view);
    FRAMES.delete(view);
    window.clearTimeout(view.foldTimer);
    window.clearTimeout(view.dismissTimer);
    view.article.classList.add("is-done");
    view.article.classList.remove("is-streaming");
    view.article.setAttribute("aria-busy", "false");
    var card = view.article.querySelector(".assistant-card");
    if (card) {
      card.classList.remove("is-streaming");
      card.classList.add("is-settled");
    }
    if (view.caret && view.caret.parentNode) {
      view.caret.classList.add("is-retiring");
      var caret = view.caret;
      window.setTimeout(function () { if (caret.parentNode) caret.parentNode.removeChild(caret); }, 260);
    }
    // The final snapshot may have supplied the authoritative thinking time.
    paintThinkState(view);
    // A rebuild is coming: fold without a transition that would be cut off.
    updateFold(view, view.reduce || typeof view.onSettled === "function");
    var callback = view.onSettled;
    view.onSettled = null;
    if (typeof callback === "function") {
      window.setTimeout(function () {
        try { callback(); } finally { release(view.article); }
      }, view.reduce ? 0 : 280);
    } else {
      schedule(view);
    }
    if (!ACTIVE.size && ticker) { window.clearInterval(ticker); ticker = 0; }
  }

  // ---------- delta pipe ----------------------------------------------------
  function findArticle(id) {
    var article = BY_ID.get(id);
    if (!article) return null;
    if (!article.isConnected) { BY_ID.delete(id); return null; }
    return article;
  }

  function beginEvent(event) {
    var id = String(event.id || "");
    if (!id) return;
    STARTS.set(id, Number(event.at) || Date.now());
    var article = findArticle(id);
    if (!article) return;  // the next snapshot mounts it with the same id
    var view = VIEWS.get(article);
    if (!view) return;
    view.lastSeq = Math.max(view.lastSeq, WATERMARK);
    view.degraded = false;
    view.ended = false;
    view.settled = false;
    view.finishing = false;
    view.startedAt = Number(event.at) || view.startedAt;
    if (!view.streaming) {
      view.streaming = true;
      ACTIVE.add(view);
      ensureTicker();
    }
    refreshPhase(view);
  }

  function deltaEvent(event) {
    var id = String(event.id || "");
    var article = findArticle(id);
    // A delta that beats the first snapshot is intentionally dropped: the
    // snapshot already contains it, and applying both would duplicate text.
    if (!article) return;
    var view = VIEWS.get(article);
    if (!view || view.settled || view.degraded) return;
    var seq = Number(event.seq) || 0;
    if (seq && seq <= WATERMARK) return;  // the snapshot already carries it
    if (seq && view.lastSeq) {
      if (seq <= view.lastSeq) return;
      if (seq !== view.lastSeq + 1) {
        // A gap means missing text. Stop trusting the pipe until the next
        // authoritative snapshot repairs the channel.
        view.degraded = true;
        return;
      }
    }
    if (seq) view.lastSeq = seq;
    var target = event.channel === "reasoning" ? view.reason : view.answer;
    appendDelta(target, event.text);
    schedule(view);
  }

  function endEvent(event) {
    var id = String(event.id || "");
    var article = findArticle(id);
    if (!article) return;  // final snapshot will carry streaming = false
    var view = VIEWS.get(article);
    if (!view || view.settled) return;
    finish(view, Boolean(event.cancelled));
  }

  function ingest(payload) {
    if (!payload) return;
    var events = Array.isArray(payload) ? payload : [payload];
    for (var i = 0; i < events.length; i += 1) {
      var event = events[i];
      if (!event || typeof event !== "object") continue;
      if (event.type === "begin") beginEvent(event);
      else if (event.type === "delta") deltaEvent(event);
      else if (event.type === "end") endEvent(event);
    }
  }

  // ---------- snapshot path (authoritative) --------------------------------
  function push(article, message, options) {
    if (!article || !message) return null;
    var view = VIEWS.get(article);
    if (!view) view = attach(article, message);
    if (!view) return null;

    view.degraded = false;
    if (WATERMARK > view.lastSeq) view.lastSeq = WATERMARK;
    // Swift measures TTFT itself and persists it with the thread; prefer that
    // over the wall clock we started when the turn first appeared.
    var explicit = Number(message.thinkingSeconds);
    if (Number.isFinite(explicit) && explicit > 0) {
      view.duration = explicit;
      DURATIONS.set(view.id, explicit);
    }
    if (options && typeof options.onSettled === "function") view.onSettled = options.onSettled;

    if (view.settled && !message.streaming && !view.finishing) {
      view.message = message;
      return view;
    }

    // Reasoning can start after the turn was mounted; grow the band on demand.
    var reasoning = String(message.reasoning || "");
    if (reasoning.trim() && !view.think) createThink(view);
    if (view.think && reasoning.trim()) ensureThinkBody(view);

    mergeChannel(view.reason, reasoning);
    mergeChannel(view.answer, message.content || "");
    if (view.answer.dirty || view.reason.dirty) schedule(view);

    var waitLabel = article.querySelector(".fc-wait-text");
    if (waitLabel && reasoning.trim() && !message.content) waitLabel.textContent = "正在整理回答";

    if (view.ended && message.streaming) {
      // A throttled snapshot from before the end event. Keep the finished view.
      return view;
    }

    if (message.streaming) {
      if (!view.streaming) {
        view.streaming = true;
        view.settled = false;
        view.finishing = false;
        ACTIVE.add(view);
        bindScroller(view);
        article.classList.add("is-streaming");
        article.removeAttribute("aria-busy");
        article.setAttribute("aria-busy", "true");
        var streamingCard = article.querySelector(".assistant-card");
        if (streamingCard) streamingCard.classList.add("is-streaming");
        placeCaret(view);
        ensureTicker();
      }
      refreshPhase(view);
      // Fold state is owned by the phase transition, not by every snapshot:
      // re-asserting it here would collapse the band before its read delay.
      schedule(view);
    } else if (!view.finishing && !view.settled) {
      finish(view, false);
    } else if (view.finishing && view.onSettled) {
      settle(view);
    }
    return view;
  }

  function isAnimating(article) {
    var view = article && VIEWS.get(article);
    return Boolean(view && !view.settled && (view.streaming || view.finishing || ACTIVE.has(view)));
  }

  function release(article) {
    var view = article && VIEWS.get(article);
    if (!view) return;
    ACTIVE.delete(view);
    FRAMES.delete(view);
    window.clearTimeout(view.foldTimer);
    window.clearTimeout(view.dismissTimer);
    if (view.think) {
      window.clearTimeout(view.think.__reasonTimer);
      view.think.__reasonToken = (view.think.__reasonToken || 0) + 1;
    }
    if (view.caret && view.caret.parentNode) view.caret.parentNode.removeChild(view.caret);
    if (view.scroller && view.scroller.button && !ACTIVE.size) {
      // The jump control belongs to the scroller, not to one turn. Only retire
      // it when no other turn is streaming in that conversation.
      var keep = false;
      ACTIVE.forEach(function (other) { if (other.scroller === view.scroller) keep = true; });
      if (!keep) {
        if (view.scroller.button.parentNode) view.scroller.button.parentNode.removeChild(view.scroller.button);
        view.scroller.button = null;
        view.scroller.pinned = false;
        if (view.scroller.bound) {
          view.scroller.node.removeEventListener("scroll", onScrollerScroll);
          view.scroller.bound = false;
        }
      }
    }
    if (BY_ID.get(view.id) === article) BY_ID.delete(view.id);
    VIEWS.delete(article);
    if (!ACTIVE.size && ticker) { window.clearInterval(ticker); ticker = 0; }
  }

  function toggleThinking(block) {
    if (!block) return;
    var id = safeID(block.dataset.thinkId);
    var open = !block.classList.contains("is-open");
    if (id) MANUAL.set(id, open);
    var head = block.querySelector(".think-head");
    if (head) head.setAttribute("aria-expanded", String(open));
    if (open) {
      openThink(block);
      var viewport = block.querySelector("[data-think-view]");
      if (viewport) viewport.scrollTop = viewport.scrollHeight;
    } else {
      closeThink(block);
    }
  }

  window.FCChatStream = {
    answerHTML: answerMarkup,
    thinkingHTML: thinkingMarkup,
    waitHTML: waitMarkup,
    push: push,
    ingest: ingest,
    setWatermark: setWatermark,
    isAnimating: isAnimating,
    release: release,
    toggleThinking: toggleThinking,
    prefersReducedMotion: prefersReducedMotion,
  };
}());
