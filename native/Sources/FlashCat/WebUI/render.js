/* flashCat WebUI · live render — 视图层
 *
 * 只做两件事：把 store 的视图模型拼成 HTML 字符串，以及把状态增量 patch 到
 * 既有 DOM 上（避免整页重绘闪屏）。不发起命令、不监听事件——那是 actions
 * 层的职责；可以调用 store 的选择器与格式化工具。
 */

import { LOG_SEED, MODELS, colorWithAlpha, computedColor, fcMorphModelButton, flowState, icon, inspectChartSegment, logCount, logLinesHtml, resolvedTheme, startFlowVisualization, state, syncEngineConfigControls, syncThinkingTriggerLabel, updateSlidingSegments, updateThemeIcon } from "./app.js";
import { FCChatMarkdown } from "./chat-markdown.js";
import { FCChatStream } from "./chat-stream.js";
import { FCChatThinking } from "./chat-thinking.js";
import { FCEngineWorkspace } from "./engine-workspace.js";
import { esc } from "./esc.js";
import { FCModelBrand } from "./model-brand.js";
import { FCModelWorkspace } from "./model-workspace.js";
import { FCWidgets } from "./overview-components.js";
import { FLOW_GAP_MS, FLOW_WINDOW_MS, S, canonicalModel, clamp, currentDecodeRate, displayModel, downloadRowText, downloadShape, engineGlyph, engineInstall, engineMeta, engineStatusText, flowPillClass, flowPillText, flowPoints, fmtBytes, fmtClock, fmtRate, fmtUptime, formatContextK, formatThousands, fullModelName, hubLocally, hubSnapshot, isRunning, memoryBlocks, memoryHint, memoryPercent, nameEngineOf, prefillSteps, q, qa, rateNumberText, rateValue, rawEngineOf, requestMeta, requestRate, requestStateClass, restoreModalFocus, rollingText, setNodeText, setText, shortModel, stashModalFocus, ttftPercent } from "./store.js";

// ---------- page rendering ----------
export function pageHTML() {
  if (S.snap.launchPage || (S.snap.recommendation && S.snap.recommendation.show)) return launchPageHTML();
  const rate = rateValue();
  switch (state.page) {
    case "overview": return FCWidgets.overview(state, rate);
    case "chat": return chatPageHTML();
    case "models": return modelsPageHTML();
    case "engines": return FCEngineWorkspace.render(state);
    case "logs": return logsPageHTML();
    case "settings": return settingsPageHTML();
    default: return FCWidgets.overview(state, rate);
  }
}

export function render(animate = false) {
  if (!S.snap) return;
  const frame = q("#pageFrame");
  const main = q("#mainContent");
  if (!frame) return;
  const focus = captureFocus(frame);
  const scroll = main.scrollTop;
  const chatScroll = captureChatScroll();
  const html = pageHTML();
  if (animate && document.startViewTransition && !window.matchMedia("(prefers-reduced-motion: reduce)").matches && S.rendered) {
    document.startViewTransition(() => {
      frame.innerHTML = html;
      afterRender(frame);
    });
  } else {
    frame.innerHTML = html;
    afterRender(frame);
  }
  if (document.title.startsWith("flashCat · ")) document.title = "flashCat";
  frame.dataset.view = S.snap.launchPage || (S.snap.recommendation && S.snap.recommendation.show) ? "launch" : state.page;
  main.dataset.view = frame.dataset.view;
  if (state.page === "chat" || frame.dataset.view === "chat") {
    restoreChatScroll(chatScroll);
  } else {
    main.scrollTop = scroll;
  }
  restoreFocus(focus);
  S.rendered = true;
  // From here on the window has content: errors are diagnosed through
  // __fcErrors / 日志, never by covering the UI with a red bar.
  S.pagePainted = true;
}

export function afterRender(root) {
  if (!root) return;
  // 离开模型页就不再记悬停：键盘切页时指针没动，回来不该凭空带一张彩色
  // 描边的卡片。
  if (state.page !== "models") S.modelHoverName = "";
  if (state.page === "overview") {
    requestAnimationFrame(() => {
      if (inspectChartSegment) inspectChartSegment();
      if (startFlowVisualization) startFlowVisualization();
      if (updateSlidingSegments) updateSlidingSegments();
    });
  }
  if (state.page === "models") {
    // 重建前指针停在哪张卡，新节点首帧就带上悬停态：描边不闪。
    restoreModelHover();
    requestAnimationFrame(() => updateSlidingSegments && updateSlidingSegments());
  }
  if (state.page === "chat") {
    const input = q("#chatInput");
    if (input && S.pendingDraft != null) { input.value = S.pendingDraft; S.pendingDraft = null; }
    if (input) autosize(input);
    settleMessageEntrances(root);
    // A page paint during a live reply (opening the thread mid-stream, a
    // settings change) rebuilds the markup, so the new node needs its reveal
    // engine. It continues from the static prefix instead of retyping it.
    const messages = state.chatMessages || [];
    const last = messages[messages.length - 1];
    if (last && last.role === "assistant" && last.streaming && FCChatStream) {
      const node = q("#messagesInner .message:last-child");
      if (node) FCChatStream.push(node, last);
    }
  }
  if (state.page === "settings" || state.page === "logs") {
    requestAnimationFrame(() => updateSlidingSegments && updateSlidingSegments());
  }
  if (state.page === "logs") {
    // 整页刚画完，记下这一版的行 id，后续推送才能只追加尾部。
    markLogsRendered();
  }
  if (state.page === "logs" && !state.logPaused) {
    requestAnimationFrame(() => {
      const body = q("#consoleBody");
      if (body) body.scrollTop = body.scrollHeight;
    });
  }
  if (state.page === "engines" && state.engineConfigOpen) {
    requestAnimationFrame(() => {
      if (syncEngineConfigControls) syncEngineConfigControls();
    });
  }
  requestAnimationFrame(() => {
    if (updateSlidingSegments) updateSlidingSegments();
    if (syncThinkingTriggerLabel) syncThinkingTriggerLabel();
  });
  tick();
}

export function captureFocus(root) {
  const active = document.activeElement;
  if (!active || active === document.body || !root.contains(active)) return null;
  const key = active.id || active.getAttribute("data-cfg") || active.getAttribute("data-fc-engine-field")
    || active.getAttribute("data-setfield") || active.getAttribute("data-hub-input");
  if (!key) return null;
  return {
    key,
    value: "value" in active ? active.value : null,
    start: active.selectionStart,
    end: active.selectionEnd,
  };
}

export function restoreFocus(focus) {
  if (!focus) return;
  requestAnimationFrame(() => {
    const target = q(`#${CSS.escape(focus.key)}, [data-cfg="${CSS.escape(focus.key)}"], [data-fc-engine-field="${CSS.escape(focus.key)}"], [data-setfield="${CSS.escape(focus.key)}"], [data-hub-input="${CSS.escape(focus.key)}"]`);
    if (!target) return;
    if (focus.value != null && target.value !== focus.value) target.value = focus.value;
    target.focus({ preventScroll: true });
    if (typeof focus.start === "number" && target.setSelectionRange) {
      try { target.setSelectionRange(focus.start, focus.end); } catch (error) { /* number input */ }
    }
  });
}

export function captureChatScroll() {
  const messages = q("#chatMessages");
  if (!messages) return null;
  return { top: messages.scrollTop, nearBottom: messages.scrollHeight - messages.scrollTop - messages.clientHeight < 60 };
}

export function restoreChatScroll(saved) {
  const messages = q("#chatMessages");
  if (!messages) return;
  if (!saved || saved.nearBottom) {
    messages.scrollTop = messages.scrollHeight;
  } else {
    messages.scrollTop = saved.top;
  }
  requestAnimationFrame(() => {
    const node = q("#chatMessages");
    if (node && (!saved || saved.nearBottom)) node.scrollTop = node.scrollHeight;
  });
}

export function autosize(input) {
  input.style.height = "46px";
  input.style.height = `${Math.min(130, input.scrollHeight)}px`;
}

// ---------- chrome ----------
export function updateChrome() {
  if (!S.snap) return;
  const dot = q("#topEngineDot");
  const name = q("#topEngineName");
  const label = q("#topEngineState");
  const rate = q("#topEngineRate");
  const action = q("#topEngineAction");
  const control = q("#topEngineControl");
  if (!dot) return;
  const busy = state.engineBusy;
  const running = state.engineRunning;
  dot.classList.toggle("is-stopped", !running && !busy);
  dot.classList.toggle("is-busy", busy);
  if (name) name.textContent = state.engine;
  if (label) label.textContent = busy ? (S.snap.engine && S.snap.engine.switching ? "切换中" : "启动中") : running ? "运行中" : "已停止";
  const decode = currentDecodeRate();
  if (rate) rate.textContent = running && decode > 0 ? fmtRate(decode) : "—";
  if (action) {
    const glyph = busy ? "loader" : running ? "stop" : "play";
    if (action.dataset.glyph !== glyph) {
      action.dataset.glyph = glyph;
      action.innerHTML = icon(glyph, 11);
    }
  }
  if (control) control.setAttribute("aria-label", running ? "停止引擎" : "启动引擎");

  const badge = q("#downloadBadge");
  if (badge) {
    const count = ((S.snap.downloads && S.snap.downloads.tasks) || []).filter((t) => t.status === "downloading" || t.status === "queued").length
      + (S.snap.downloads && S.snap.downloads.active ? 1 : 0);
    badge.textContent = String(count);
    badge.classList.toggle("has-badge", count > 0);
  }
  const themeIcon = q("#themeIcon");
  if (themeIcon) updateThemeIcon();
}

export function applyShell() {
  const theme = resolvedTheme();
  const width = `${state.sidebarWidth}px`;
  if (document.documentElement.dataset.theme !== theme) document.documentElement.dataset.theme = theme;
  if (document.documentElement.style.getPropertyValue("--sidebar-width") !== width) {
    document.documentElement.style.setProperty("--sidebar-width", width);
  }
  document.body.classList.toggle("sidebar-collapsed", !!state.sidebarCollapsed);
  const toggle = q("#sidebarToggle");
  if (toggle) {
    toggle.setAttribute("aria-expanded", String(!state.sidebarCollapsed));
    toggle.setAttribute("aria-label", state.sidebarCollapsed ? "展开边栏" : "折叠边栏");
    toggle.title = `${state.sidebarCollapsed ? "展开" : "折叠"}边栏（⌘\\）`;
  }
}

// ---------- navigation / recents ----------
export function renderRecents() {
  const host = q("#recentList");
  if (!host) return;
  const threads = (S.snap && S.snap.threads) || [];
  // Every snapshot used to rebuild this list even when nothing had changed,
  // which made the glass sidebar repaint on each push. Keyed by content, the
  // list only touches the DOM when a thread row really differs.
  const key = threads.slice(0, 12)
    .map((thread) => `${thread.id}|${thread.title}|${thread.updatedAt}|${thread.id === state.threadID ? "1" : "0"}`).join("~");
  if (key === S.recentsKey) return;
  S.recentsKey = key;
  if (!threads.length) {
    host.innerHTML = `<div class="recent-empty">还没有对话</div>`;
    return;
  }
  host.innerHTML = threads.slice(0, 12).map((thread) => `
    <button class="recent-item ${thread.id === state.threadID ? "active" : ""}" type="button"
            data-thread="${esc(thread.id)}" title="${esc(thread.title)}">
      <span class="recent-dot"></span>
      <span>${esc(thread.title || "未命名对话")}</span>
      <time>${esc(fmtClock(thread.updatedAt))}</time>
    </button>`).join("");
}

export function clearModelHover() {
  if (!S.modelHoverName) return;
  S.modelHoverName = "";
  qa(".fc-model-card.is-hovered").forEach((card) => card.classList.remove("is-hovered"));
}

export function restoreModelHover() {
  const cards = qa("#modelsGrid .fc-model-card.is-hovered");
  const node = S.modelHoverName
    ? q(`#modelsGrid .fc-model-card[data-model-name="${CSS.escape(S.modelHoverName)}"]`)
    : null;
  cards.forEach((card) => { if (card !== node) card.classList.remove("is-hovered"); });
  if (node && !node.classList.contains("is-hovered")) node.classList.add("is-hovered");
}

// 只有模型页挂载着、并且网格里已经有卡片时才补。卡片集合变了（筛选、
// 搜索、库更新）指纹会变，走整页渲染，这里不负责新增/删除节点。
export function patchModelProgress() {
  if (state.page !== "models" || !S.snap) return;
  if (S.snap.launchPage || (S.snap.recommendation && S.snap.recommendation.show)) return;
  const grid = q("#modelsGrid");
  if (!grid || !FCModelWorkspace || typeof FCModelWorkspace.patchProgress !== "function") return;
  FCModelWorkspace.patchProgress(grid, MODELS, state);
}

// 切换模型只会移动「使用中」：补两张卡的描边、状态胶囊和操作按钮，
// 其它卡片保持原节点。整页 render 会把所有卡片重建一遍，读者会看到
// 一整个网格同时重排/重放描边过渡。
export function patchModelSelection() {
  if (state.page !== "models" || !S.snap) return;
  if (S.snap.launchPage || (S.snap.recommendation && S.snap.recommendation.show)) return;
  const grid = q("#modelsGrid");
  if (!grid || !FCModelWorkspace || typeof FCModelWorkspace.patchSelection !== "function") return;
  FCModelWorkspace.patchSelection(grid, MODELS, state);
}

export function markLogsRendered() {
  const lines = (S.snap && S.snap.logs) || [];
  S.logsRendered = {
    ids: lines.map((line) => String(line.id)),
    filter: state.logFilter,
    search: state.logSearch,
  };
}

export function patchLogs() {
  if (!S.snap || state.page !== "logs") return false;
  const body = q("#consoleBody");
  if (!body) return false;
  if (S.logsRendered.filter !== state.logFilter || S.logsRendered.search !== state.logSearch) return false;
  const lines = LOG_SEED;
  const ids = lines.map((line) => String(line.id));
  const previous = S.logsRendered.ids;
  if (!previous.length) return false;
  // 快照是 `logs.suffix(800)`：行数到顶之后每来一行，头部就掉一行。拿上一版
  // 的最后一行当锚点，算出这次从头部挤掉了几行 —— 只删头部、只补尾部。
  const anchorIndex = ids.lastIndexOf(previous[previous.length - 1]);
  if (anchorIndex < 0) return false;
  const drop = previous.length - 1 - anchorIndex;
  if (drop < 0) return false;
  for (let index = drop; index < previous.length; index += 1) {
    if (ids[index - drop] !== previous[index]) return false;
  }
  const rows = qa(".log-line", body);
  if (rows.length !== previous.length) return false;
  const added = lines.slice(previous.length - drop);
  if (!drop && !added.length) return true;
  const nearBottom = body.scrollHeight - body.scrollTop - body.clientHeight < 48;
  rows.slice(0, drop).forEach((row) => row.remove());
  if (added.length) body.insertAdjacentHTML("beforeend", logLinesHtml(added));
  S.logsRendered.ids = ids;
  refreshLogCounters(lines);
  if (nearBottom) body.scrollTop = body.scrollHeight;
  return true;
}

export function refreshLogCounters(lines) {
  qa(".filter-pill[data-log-filter]").forEach((pill) => {
    const badge = q("b", pill);
    if (badge) setNodeText(badge, String(logCount(pill.dataset.logFilter, lines)));
  });
  const head = q(".console-head");
  const counter = head && qa("span", head).pop();
  if (counter && /\d+\s*行/.test(counter.textContent)) setNodeText(counter, `${lines.length} 行`);
}

// ---------- engine install progress (in place) ----------
// 安装进度只值一条宽度和两个数字。整页重建会把卡片、按钮和进度条一起换掉，
// 宽度上没有过渡可播，所以看着就是一格一格地跳；卡片一重建，`fc-engine-signal`
// 那排呼吸条也会从头开始。这里按卡片原地补，只有阶段变化才走整页。
export function patchEngineProgress() {
  if (!S.snap) return;
  const install = S.snap.enginesInstall || {};
  qa("[data-engine-view], [data-launch-engine]").forEach((card) => {
    const raw = card.dataset.launchEngine || rawEngineOf(card.dataset.engineView || "");
    const info = install[raw] || install[card.dataset.engineView] || {};
    const host = q(".fc-engine-progress, .fc-launch-progress", card);
    if (!host || info.progress == null) return;
    const percent = Math.round(Number(info.progress) * 100);
    if (!Number.isFinite(percent)) return;
    const bar = q("span > i", host);
    if (bar) {
      const width = `${Math.max(3, Math.min(100, percent))}%`;
      if (bar.style.width !== width) bar.style.width = width;
    }
    setNodeText(q("b", host), `${percent}%`);
    setNodeText(q("small", host), info.step || "正在安装");
  });
}

export function updateNavBadge() {
  const badge = q('.nav-item[data-page="models"] .nav-badge');
  if (!badge) return;
  const count = state.loadedModels || 0;
  badge.textContent = String(count);
  badge.style.display = count > 0 ? "" : "none";
}

export function updateLaunchMode() {
  const standalone = !!(S.snap.launchPage || (S.snap.recommendation && S.snap.recommendation.show));
  document.body.classList.toggle("launch-mode", standalone);
}

// Live numbers that change every second without changing the page's shape.
export function tick() {
  if (!S.snap) return;
  updateChrome();
  if (S.snap.launchPage || (S.snap.recommendation && S.snap.recommendation.show)) {
    patchEngineProgress();
    return;
  }
  if (state.page === "chat") {
    syncChatChrome();
    return;
  }
  if (state.page === "models") {
    patchModelSelection();
    return;
  }
  if (state.page === "settings") {
    // 默认模型跟随当前模型（没有单独默认值时）。换模型不重建设置页，
    // 只换这一行文字，开关和分段控件的状态不受影响。
    const settings = S.snap.settings || {};
    setText("[data-default-model]", displayModel(settings.defaultModel || state.model));
    return;
  }
  if (state.page === "overview") {
    syncOverviewChrome();
    const stats = S.snap.stats || {};
    const context = S.snap.context || { used: 0, total: 0 };
    const running = isRunning();
    const rate = currentDecodeRate();
    const sessions = S.snap.sessions || [];
    const requests = sessions.slice(-5).reverse();
    const active = sessions.filter((session) => session.state === "prefill" || session.state === "decode");
    // 两个大数字读同一个平滑值。旧版 flowRate 取原始最新样本、
    // rate 取另一个口径，同一个页面上会出现两个互相矛盾的读数。
    const rateText = running ? rateNumberText(rate) : "—";
    setText("[data-live='rate']", rateText);
    setText("[data-live='flowRate']", rateText);
    setText("[data-live='context']", running ? formatContextK(context.used || 0) : "—");
    setText("[data-live='context-unit']", context.total ? `/ ${formatContextK(context.total)}` : "");
    setText("[data-live='ctx-label']", running ? `${formatContextK(context.used || 0)} tokens` : "等待运行");
    setText("[data-live='ttft']", running && stats.ttftMilliseconds != null
      ? String(Math.round(stats.ttftMilliseconds)) : "—");
    setText("[data-live='prefill']", running && stats.prefillTokensPerSecond
      ? formatThousands(Math.round(stats.prefillTokensPerSecond)) : "—");
    setText("[data-live='memory']", running ? memoryPercent() : "—");
    setText("[data-live='switch-stage'] span",
      String((S.snap.engine && S.snap.engine.switchStage) || "").trim() || "正在切换模型");
    setText("[data-live='context-hint']", running ? (context.total ? "当前会话" : "等待引擎上报窗口") : "引擎未运行");
    setText("[data-live='ttft-hint']", running
      ? (stats.ttftMilliseconds != null ? "最近请求" : "引擎未上报") : "引擎未运行");
    setText("[data-live='prefill-hint']", running
      ? (stats.prefillTokensPerSecond ? "引擎采样值" : "引擎未上报") : "引擎未运行");
    setText("[data-live='memory-hint']", running ? memoryHint() : "引擎未运行");
    setText("[data-live='sessions']", `${active.length} SESSIONS`);
    setText("[data-live='requests-count']", `${requests.length} 条`);
    setText("[data-live='requests-total']", String(Number(stats.requestsCompleted || 0)));
    setText("[data-live='requests-failed']", String(Number(stats.requestsFailed || 0)));

    const liveHead = q("[data-live='live-head']");
    if (liveHead) {
      const label = state.engineBusy
        ? (S.snap.engine && S.snap.engine.switching ? "SWITCHING" : "STARTING")
        : sessions.some((session) => session.state === "decode") ? "LIVE DECODE"
          : running ? (sessions.some((session) => session.state === "prefill") ? "PREFILL" : "ENGINE READY")
            : "ENGINE IDLE";
      if (liveHead.dataset.label !== label) {
        liveHead.innerHTML = `<i></i>${label}`;
        liveHead.dataset.label = label;
      }
    }

    const pill = q("[data-live='flow-pill']");
    if (pill) {
      const label = flowPillText();
      if (pill.dataset.label !== label) {
        pill.className = `online-pill ${flowPillClass()}`;
        pill.innerHTML = `<i></i>${label}`;
        pill.dataset.label = label;
      }
    }

    const meter = q("[data-live='ctx-meter']");
    if (meter) {
      const percent = running && context.total ? Math.min(100, (context.used / context.total) * 100) : 0;
      meter.style.width = `${percent}%`;
      if (meter.parentElement) meter.parentElement.classList.toggle("is-empty", !running || !context.total);
    }

    const dot = q("[data-live='ttft-dot']");
    if (dot) {
      const position = ttftPercent();
      dot.style.left = `${position == null ? 4 : position}%`;
      if (dot.parentElement) dot.parentElement.classList.toggle("is-empty", position == null);
    }

    const burst = q("[data-live='prefill-burst']");
    if (burst) {
      const steps = prefillSteps();
      burst.classList.toggle("is-empty", !steps);
      qa("i", burst).forEach((bar, index) => bar.classList.toggle("on", index < steps));
    }

    const blocks = q("[data-live='memory-blocks']");
    if (blocks) {
      const filled = memoryBlocks();
      blocks.classList.toggle("is-empty", !filled);
      qa("i", blocks).forEach((bar, index) => bar.classList.toggle("filled", index < filled));
    }

    updateRhythm();
    updateRequestRows(sessions);
    // With reduced motion app.js draws the chart once instead of starting the
    // animation loop. A new snapshot must still paint its new samples.
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) redrawFlowFrame();
  }
  if (state.page === "engines") patchEngineProgress();
  setText("[data-live='uptime']", isRunning() ? fmtUptime(S.snap.stats && S.snap.stats.startedAt) : "—");
}

export function redrawFlowFrame() {
  const canvas = q("#flowCanvas");
  const stage = q("#flowStage");
  if (!canvas || !stage) return;
  const ctx = canvas.getContext("2d");
  if (!ctx) return;
  const rect = stage.getBoundingClientRect();
  drawFlowFieldLive(ctx, rect.width, rect.height, performance.now());
}

// The engine rhythm is the last 20 s of real throughput: each bar's height
// is that sample against the current peak. Idle collapses to a baseline.
export function updateRhythm() {
  const host = q("[data-live='rhythm']");
  if (!host) return;
  const bars = qa("i", host);
  if (!bars.length) return;
  if (!isRunning()) {
    host.classList.add("is-empty");
    bars.forEach((bar) => { if (bar.style.height !== "3px") bar.style.height = "3px"; });
    return;
  }
  const now = Date.now();
  const values = S.flowTimeline
    .filter((point) => point.t >= now - 20_000 && point.t <= now + 1_000)
    .slice(-bars.length)
    .map((point) => point.v);
  host.classList.toggle("is-empty", !values.length);
  const offset = bars.length - values.length;
  // 用整张 60 秒图的 y 轴上限做标尺，而不是这 20 秒里的峰值：
  // 局部峰值滚进滚出时，旧版所有柱子会一起缩放，看起来像速度在跳。
  const scale = Math.max(10, S.flowDomainMax || 10);
  bars.forEach((bar, index) => {
    const value = index >= offset ? values[index - offset] : null;
    const height = value == null ? "6%" : `${Math.round(12 + Math.min(1, value / scale) * 88)}%`;
    if (bar.style.height !== height) bar.style.height = height;
  });
}

export function updateRequestRows(sessions) {
  qa("[data-session-id]").forEach((row) => {
    const session = sessions.find((item) => String(item.id) === row.dataset.sessionId);
    if (!session) return;
    const rate = q("[data-live='req-rate']", row);
    if (rate) rate.innerHTML = `${requestRate(session)}<small>tok/s</small>`;
    const meta = q("[data-live='req-meta']", row);
    if (meta) meta.textContent = requestMeta(session);
    const stateNode = q("[data-live='req-state']", row);
    if (stateNode) stateNode.className = `request-state ${requestStateClass(session)}`;
  });
}

export function overviewHTML() {
  const engine = S.snap.engine || {};
  const running = isRunning();
  const busy = state.engineBusy;
  const statusText = engineStatusText();
  const sessions = S.snap.sessions || [];
  const stats = S.snap.stats || {};
  const context = S.snap.context || { used: 0, total: 0 };
  const requests = sessions.slice(-5).reverse();
  const activeSessions = sessions.filter((session) => session.state === "prefill" || session.state === "decode");
  const decoding = sessions.some((session) => session.state === "decode");
  const prefill = sessions.some((session) => session.state === "prefill");
  const liveHead = busy
    ? (engine.switching ? "SWITCHING" : "STARTING")
    : decoding ? "LIVE DECODE" : running ? (prefill ? "PREFILL" : "ENGINE READY") : "ENGINE IDLE";
  const ttft = running && stats.ttftMilliseconds != null ? String(Math.round(stats.ttftMilliseconds)) : "—";
  const prefillRate = running && stats.prefillTokensPerSecond
    ? formatThousands(Math.round(stats.prefillTokensPerSecond)) : "—";
  const memory = running ? memoryPercent() : "—";
  const memoryText = running ? memoryHint() : "引擎未运行";
  const switching = !!engine.switching;
  const switchStage = String(engine.switchStage || "").trim();
  const modelTitle = displayModel(state.model);
  return `
    <div class="overview-widget-grid">
      <section class="widget engine-widget widget-span-8" data-widget="engine">
        <div class="engine-widget-main">
          <div class="engine-widget-copy">
            <span class="status-pill ${running ? "" : "stopped"}"><i></i>${esc(state.engine)} · ${statusText}</span>
            <h2 class="model-title ${modelTitle.length > 28 ? "is-long" : ""}" data-model-title data-model-key="${esc(fullModelName(state.model))}" title="${esc(fullModelName(state.model))}">${rollingText(modelTitle)}</h2>
            ${switching ? `<div class="model-switch-stage" data-live="switch-stage"><i></i><span>${esc(switchStage || "正在切换模型")}</span></div>` : ""}
            <div class="engine-actions">
              <button class="button primary" type="button" data-action="model-menu" ${switching ? 'aria-busy="true"' : ""}>
                ${icon("layers", 14)}<span>切换模型</span>
              </button>
              <button class="button ${running ? "danger" : ""}" type="button" data-action="toggle-engine">
                ${icon(busy ? "loader" : running ? "stop" : "play", 14)}
                <span>${busy ? "处理中" : running ? "停止引擎" : "启动引擎"}</span>
              </button>
            </div>
          </div>
          <div class="engine-live-panel ${running ? "" : "is-idle"}">
            <div class="engine-live-head">
              <span data-live="live-head"><i></i>${liveHead}</span>
              <b data-live="sessions">${activeSessions.length} SESSIONS</b>
            </div>
            <div class="engine-live-rate">
              <strong data-live="rate">${rateNumberText(currentDecodeRate())}</strong><span>tok/s</span>
            </div>
            <div class="engine-live-rhythm ${running && S.flowTimeline.length ? "" : "is-empty"}" data-live="rhythm" aria-hidden="true">
              ${Array.from({ length: 20 }, () => `<i style="--h:6%"></i>`).join("")}
            </div>
          </div>
        </div>
      </section>

      <section class="widget gateway-widget widget-span-4" data-widget="gateway">
        <div class="widget-topline">
          <div class="widget-identity">
            <span class="widget-symbol gateway-symbol">${icon("network", 16)}</span>
            <div><strong>API 网关</strong><span>OpenAI + Claude</span></div>
          </div>
          <span class="online-pill ${S.snap.settings && S.snap.settings.gatewayEnabled ? "" : "is-off"}"><i></i>${S.snap.settings && S.snap.settings.gatewayEnabled ? "ONLINE" : "OFFLINE"}</span>
        </div>
        <div class="gateway-addresses">
          ${gatewayAddress("OpenAI", state.gatewayURL || "—", "openai")}
          ${gatewayAddress("Claude", state.gatewayClaudeURL || "—", "claude")}
        </div>
      </section>

      <div class="metric-widget-row widget-span-12">
        ${metricWidget("context", "layers", "当前上下文", "CTX", running ? formatContextK(context.used || 0) : "—", context.total ? `/ ${formatContextK(context.total)}` : "", running ? "当前会话" : "引擎未运行")}
        ${metricWidget("ttft", "timer", "首字延迟", "TTFT", ttft, "ms", running ? (ttft === "—" ? "引擎未上报" : "最近请求") : "引擎未运行")}
        ${metricWidget("prefill", "arrowUp", "预填充", "PREFILL", prefillRate, "tok/s", running ? (prefillRate === "—" ? "引擎未上报" : "引擎采样值") : "引擎未运行")}
        ${metricWidget("memory", "hardDrive", "内存压力", "MEM", memory, "%", memoryText)}
      </div>

      <section class="widget token-widget widget-span-8" data-widget="token-flow">
        <div class="flow-minimal-head">
          <span>总解码 · 最近 60 秒</span>
          <span class="online-pill ${flowPillClass()}" data-live="flow-pill"><i></i>${flowPillText()}</span>
        </div>
        <div class="flow-total">
          <strong data-live="flowRate">${running ? rateNumberText(currentDecodeRate()) : "—"}</strong>
          <span>tok/s</span>
        </div>
        <div class="flow-stage" id="flowStage">
          <canvas id="flowCanvas" aria-label="实时 Token 流可视化"></canvas>
          <div class="flow-cursor" id="flowCursor" aria-hidden="true"></div>
          <div class="flow-tooltip" id="flowTooltip" aria-hidden="true">
            <span>PROBE</span><strong>— tok/s</strong><small>— tokens</small>
          </div>
        </div>
      </section>

      <section class="widget requests-widget widget-span-4" data-widget="requests">
        <div class="requests-head">
          <span>最近请求</span>
          <span data-live="requests-count">${requests.length} 条</span>
        </div>
        <div class="request-list">
          ${requests.length ? requests.map((request) => `
            <button class="request-row" type="button" data-action="request-detail" data-session-id="${esc(String(request.id))}">
              <span class="request-state ${requestStateClass(request)}" data-live="req-state"><i></i></span>
              <span class="request-row-main">
                <strong>${esc(String(request.dialect || "").toLowerCase() === "claude" ? "Claude" : "OpenAI")} <small>#${esc(String(request.id || "").slice(0, 4))}</small></strong>
                <span data-live="req-meta">${esc(requestMeta(request))}</span>
              </span>
              <span class="request-row-rate" data-live="req-rate">${requestRate(request)}<small>tok/s</small></span>
            </button>`).join("") : `<div class="fc-widget-empty">还没有经过网关的请求</div>`}
        </div>
        <div class="requests-foot"><span>全部请求</span><strong data-live="requests-total">${Number(stats.requestsCompleted || 0)}</strong><span>失败</span><strong data-live="requests-failed">${Number(stats.requestsFailed || 0)}</strong></div>
      </section>
    </div>`;
}

/// Overview equivalent of `syncChatChrome`: engine start/stop and model
/// switches move only the engine widget, so the rest of the control surface
/// (charts, metric cards, the model title's roll) is not rebuilt under the
/// reader. Without this, every switch stage replayed the title animation.
export function syncOverviewChrome() {
  if (state.page !== "overview") return;
  const widget = q('[data-widget="engine"]');
  if (!widget) return;
  const engine = (S.snap && S.snap.engine) || {};
  const running = isRunning();
  const busy = state.engineBusy;
  const switching = !!engine.switching;

  const pill = q(".status-pill", widget);
  if (pill) {
    const key = `${state.engine}|${running}|${busy}|${engine.state}|${switching}`;
    if (pill.dataset.engineKey !== key) {
      pill.dataset.engineKey = key;
      pill.classList.toggle("stopped", !running);
      pill.innerHTML = `<i></i>${esc(state.engine)} · ${engineStatusText()}`;
    }
  }

  const title = q("[data-model-title]", widget);
  const modelKey = fullModelName(state.model);
  if (title && title.dataset.modelKey !== modelKey) {
    const modelTitle = displayModel(state.model);
    title.dataset.modelKey = modelKey;
    title.title = modelKey;
    title.className = `model-title ${modelTitle.length > 28 ? "is-long" : ""}`;
    title.innerHTML = rollingText(modelTitle);
    // 逐字翻滚是「换模型」这个动作的落点。以前只有整页首次渲染才带这个
    // 类，快照里的原地更新会把字直接换掉 —— 标题就成了硬切。
    title.classList.remove("is-switching");
    void title.offsetWidth;
    title.classList.add("is-switching");
    clearTimeout(title.__rollTimer);
    title.__rollTimer = setTimeout(() => title.classList.remove("is-switching"), 640 + Array.from(modelTitle).length * 17);
  }

  const stage = q('[data-live="switch-stage"]', widget);
  if (switching) {
    if (stage) {
      setText('[data-live="switch-stage"] span', String(engine.switchStage || "").trim() || "正在切换模型");
    } else if (title) {
      title.insertAdjacentHTML("afterend",
        `<div class="model-switch-stage" data-live="switch-stage"><i></i><span>${esc(String(engine.switchStage || "").trim() || "正在切换模型")}</span></div>`);
    }
  } else if (stage) {
    stage.remove();
  }

  const modelButton = q('[data-action="model-menu"]', widget);
  if (modelButton) {
    if (switching) modelButton.setAttribute("aria-busy", "true");
    else modelButton.removeAttribute("aria-busy");
  }

  const toggle = q('[data-action="toggle-engine"]', widget);
  if (toggle) {
    const key = `${busy}|${running}`;
    if (toggle.dataset.engineKey !== key) {
      toggle.dataset.engineKey = key;
      toggle.classList.toggle("danger", running);
      toggle.innerHTML = `${icon(busy ? "loader" : running ? "stop" : "play", 14)}<span>${busy ? "处理中" : running ? "停止引擎" : "启动引擎"}</span>`;
    }
  }

  const live = q(".engine-live-panel", widget);
  if (live) live.classList.toggle("is-idle", !running);
}

export function gatewayAddress(label, address, kind) {
  return `
    <div class="gateway-address">
      <span class="provider-mark ${kind}"><img class="provider-glyph" src="brand-${esc(kind)}.png" alt=""></span>
      <div>
        <span>${esc(label)}</span>
        <code title="${esc(address)}">${esc(address)}</code>
      </div>
      <button class="copy-btn" type="button" data-copy="${esc(address)}"
              aria-label="复制 ${esc(label)} 地址">${icon("copy", 13)}</button>
    </div>`;
}

export function metricWidget(key, iconName, label, tag, value, unit, hint) {
  return `
    <section class="widget metric-widget metric-${key}" data-widget="metric-${key}">
      <div class="metric-widget-head">
        <span class="metric-widget-icon">${icon(iconName, 14)}</span>
        <span>${esc(label)}</span>
        <span class="metric-widget-tag">${esc(tag)}</span>
      </div>
      <div class="metric-widget-value">
        <strong data-live="${key}">${esc(value)}</strong><span data-live="${key}-unit">${esc(unit)}</span>
      </div>
      <div class="metric-widget-hint" data-live="${key}-hint">${esc(hint)}</div>
      ${metricVisual(key)}
    </section>`;
}

export function metricVisual(kind) {
  const context = S.snap.context || { used: 0, total: 0 };
  const percent = context.total ? Math.min(100, (context.used / context.total) * 100) : 0;
  if (kind === "context") {
    return `<div class="metric-context-meter ${isRunning() && context.total ? "" : "is-empty"}" aria-hidden="true">
      <i data-live="ctx-meter" style="width:${isRunning() ? percent : 0}%"></i><span data-live="ctx-label">${esc(formatContextK(context.used || 0))} tokens</span>
    </div>`;
  }
  if (kind === "ttft") {
    const position = ttftPercent();
    return `<div class="metric-latency ${position == null ? "is-empty" : ""}" aria-hidden="true">
      <span></span><span></span><span></span><span></span><span></span><span></span><span></span>
      <i data-live="ttft-dot" style="left:${position == null ? 4 : position}%"></i>
    </div>`;
  }
  if (kind === "prefill") {
    const steps = prefillSteps();
    return `<div class="metric-burst ${steps ? "" : "is-empty"}" data-live="prefill-burst" aria-hidden="true">
      ${Array.from({ length: 5 }, (_, index) =>
        `<i class="${index < steps ? "on" : ""}" style="--h:${[34, 50, 66, 82, 100][index]}%"></i>`).join("")}
    </div>`;
  }
  const filled = memoryBlocks();
  return `<div class="metric-capacity ${filled ? "" : "is-empty"}" data-live="memory-blocks" aria-hidden="true">${Array.from({ length: 22 }, (_, index) =>
    `<i class="${index < filled ? "filled" : ""}" style="--d:${index * 22}ms"></i>`).join("")}</div>`;
}

FCWidgets.overview = function liveOverview() { return overviewHTML(); };

// The preview's draw function renders a fabricated 60-point wave. This one
// renders the real sampled timeline: x comes from each sample's timestamp,
// the y domain from the current peak, and gaps longer than 3 s break the line
// instead of pretending the engine was decoding through them.
export function drawFlowFieldLive(ctx, width, height, time) {
  const dark = resolvedTheme() === "dark";
  const accent = computedColor("--accent");
  const accent2 = computedColor("--accent-2");
  const accent3 = computedColor("--accent-3");
  const text3 = computedColor("--text-3");
  ctx.clearRect(0, 0, width, height);

  ctx.strokeStyle = dark ? "rgba(255, 255, 255, .035)" : "rgba(31, 41, 60, .045)";
  ctx.lineWidth = 1;
  ctx.setLineDash([3, 8]);
  for (let ratio = .2; ratio < 1; ratio += .2) {
    ctx.beginPath();
    ctx.moveTo(width * ratio, 13);
    ctx.lineTo(width * ratio, height - 13);
    ctx.stroke();
  }
  ctx.setLineDash([]);

  const now = Date.now();
  const padX = 16;
  const top = 24;
  const bottom = height - 18;
  const samples = flowPoints(now);
  if (!samples.length) {
    ctx.strokeStyle = dark ? "rgba(255, 255, 255, .08)" : "rgba(31, 41, 60, .08)";
    ctx.setLineDash([4, 7]);
    ctx.beginPath();
    ctx.moveTo(padX, bottom);
    ctx.lineTo(width - padX, bottom);
    ctx.stroke();
    ctx.setLineDash([]);
    ctx.font = "10px SFMono-Regular, Menlo, monospace";
    ctx.textAlign = "center";
    ctx.fillStyle = colorWithAlpha(text3, .75);
    ctx.fillText(isRunning() ? "等待解码数据…" : "引擎未运行 · 暂无解码数据", width / 2, height / 2 + 3);
    ctx.textAlign = "left";
    // 大数字由 tick() 统一写：过去这里每 240ms 用原始最新样本覆盖
    // flowRate，和 tick 的平滑值互相打架，数字会在两套口径间来回闪。
    return;
  }

  const xOf = (t) => padX + ((t - (now - FLOW_WINDOW_MS)) / FLOW_WINDOW_MS) * (width - padX * 2);
  const yOf = (v) => bottom - (clamp(v, 0, S.flowDomainMax) / S.flowDomainMax) * (bottom - top);
  const points = samples.map((sample) => ({ t: sample.t, v: sample.v, x: xOf(sample.t), y: yOf(sample.v) }));
  const segments = [];
  let segment = [points[0]];
  for (let index = 1; index < points.length; index += 1) {
    if (points[index].t - points[index - 1].t > FLOW_GAP_MS) {
      segments.push(segment);
      segment = [points[index]];
    } else {
      segment.push(points[index]);
    }
  }
  segments.push(segment);

  const trace = (part) => {
    ctx.beginPath();
    ctx.moveTo(part[0].x, part[0].y);
    for (let index = 1; index < part.length - 1; index += 1) {
      const point = part[index];
      const next = part[index + 1];
      ctx.quadraticCurveTo(point.x, point.y, (point.x + next.x) / 2, (point.y + next.y) / 2);
    }
    const last = part[part.length - 1];
    ctx.lineTo(last.x, last.y);
  };

  ctx.save();
  ctx.globalCompositeOperation = dark ? "lighter" : "source-over";
  const area = ctx.createLinearGradient(0, 0, 0, height);
  area.addColorStop(0, colorWithAlpha(accent, dark ? .16 : .13));
  area.addColorStop(.72, colorWithAlpha(accent3, dark ? .05 : .045));
  area.addColorStop(1, colorWithAlpha(accent, 0));
  const stroke = ctx.createLinearGradient(0, 0, width, 0);
  stroke.addColorStop(0, colorWithAlpha(accent3, 0));
  stroke.addColorStop(.12, colorWithAlpha(accent3, .7));
  stroke.addColorStop(.5, colorWithAlpha(accent, .84));
  stroke.addColorStop(.85, colorWithAlpha(accent2, .8));
  stroke.addColorStop(1, colorWithAlpha(accent2, 0));

  segments.forEach((part) => {
    if (part.length === 1) {
      const only = part[0];
      ctx.fillStyle = colorWithAlpha(accent, .8);
      ctx.beginPath();
      ctx.arc(only.x, only.y, 2.4, 0, Math.PI * 2);
      ctx.fill();
      return;
    }
    trace(part);
    const last = part[part.length - 1];
    const first = part[0];
    ctx.lineTo(last.x, bottom);
    ctx.lineTo(first.x, bottom);
    ctx.closePath();
    ctx.fillStyle = area;
    ctx.fill();

    trace(part);
    ctx.save();
    ctx.shadowColor = colorWithAlpha(accent, .26);
    ctx.shadowBlur = 18;
    ctx.strokeStyle = stroke;
    ctx.lineWidth = isRunning() ? 2 : 1.25;
    ctx.stroke();
    ctx.restore();
  });
  ctx.restore();

  const head = points[points.length - 1];
  const latest = samples[samples.length - 1];
  const fresh = now - latest.t <= 5_000;
  ctx.save();
  ctx.shadowColor = colorWithAlpha(accent2, .85);
  ctx.shadowBlur = fresh && isRunning() ? 18 : 8;
  ctx.fillStyle = colorWithAlpha(accent2, fresh && isRunning() ? .95 : .45);
  ctx.beginPath();
  ctx.arc(head.x, head.y, fresh && isRunning() ? 3.2 : 2.2, 0, Math.PI * 2);
  ctx.fill();
  ctx.restore();

}

export function updateFlowProbeLive(width, height) {
  if (!flowState || flowState.hoverX == null) return;
  const cursor = q("#flowCursor");
  const tooltip = q("#flowTooltip");
  const x = Math.max(12, Math.min(width - 12, flowState.hoverX));
  const now = Date.now();
  const at = now - FLOW_WINDOW_MS + ((x - 16) / Math.max(1, width - 32)) * FLOW_WINDOW_MS;
  let nearest = null;
  let distance = Infinity;
  flowPoints(now).forEach((point) => {
    const delta = Math.abs(point.t - at);
    if (delta < distance) { distance = delta; nearest = point; }
  });
  if (cursor) {
    cursor.style.left = `${x}px`;
    cursor.style.opacity = "1";
  }
  if (tooltip) {
    if (nearest) {
      const secondsAgo = Math.max(0, Math.round((now - nearest.t) / 1000));
      tooltip.innerHTML = `<span>${secondsAgo === 0 ? "NOW" : `${secondsAgo} 秒前`}</span>` +
        `<strong>${nearest.v.toFixed(1)} tok/s</strong>` +
        `<small>${new Date(nearest.t).toTimeString().slice(0, 8)}</small>`;
    } else {
      tooltip.innerHTML = `<span>NO DATA</span><strong>— tok/s</strong><small>等待解码</small>`;
    }
    const left = x > width - 130 ? x - 126 : x + 12;
    const top = Math.max(36, Math.min(height - 87, (flowState.hoverY || 58) + 16));
    tooltip.style.left = `${left}px`;
    tooltip.style.top = `${top}px`;
    tooltip.style.opacity = "1";
  }
}

// ---------- chat ----------
export function chatModelGlyph(model, size) {
  return FCModelBrand ? FCModelBrand.inline(model, size) : icon("layers", size);
}

export function chatPageHTML() {
  const context = S.snap.context || { used: 0, total: 0 };
  return `
    <section class="chat-page minimal-chat">
      <header class="chat-utilitybar">
        <button class="chat-model-line" type="button" data-action="model-menu"
                data-model-key="${esc(canonicalModel(state.model))}" title="${esc(fullModelName(state.model))}">
          <span class="model-glyph" data-model-glyph>${chatModelGlyph(state.model, 12)}</span>
          <span class="model-label" data-model-label>${esc(displayModel(state.model))}</span>
          ${icon("chevronDown", 11)}
        </button>
        <span class="chat-context" title="当前会话上下文">${esc(formatContextK(context.used || 0))} / ${context.total ? formatContextK(context.total) : "—"}</span>
        <span class="spacer"></span>
        <button class="chat-header-icon" type="button" data-action="chat-more" aria-label="更多对话操作" title="更多对话操作">${icon("ellipsis", 14)}</button>
        <button class="button" type="button" data-action="new-chat">${icon("messagePlus", 13)}<span>新对话</span></button>
      </header>
      <div class="chat-messages" id="chatMessages">
        <div class="messages-inner" id="messagesInner">${chatBodyHTML()}</div>
      </div>
      <div class="chat-composer-wrap">
        <div class="chat-composer">
          <label class="visually-hidden" for="chatInput">消息</label>
          <textarea id="chatInput" rows="1" placeholder="输入消息…  ⏎ 发送 · ⇧⏎ 换行"></textarea>
          <div class="composer-row">
            <button class="composer-chip" type="button" data-action="model-menu"
                    data-model-key="${esc(canonicalModel(state.model))}" title="${esc(fullModelName(state.model))}">
              <span class="model-glyph" data-model-glyph>${chatModelGlyph(state.model, 12)}</span>
              <span class="model-label" data-model-label>${esc(displayModel(state.model))}</span>
            </button>
            <button class="composer-chip" type="button" data-action="open-inspector">${icon("sliders", 12)}<span>参数</span></button>
            ${FCChatThinking ? FCChatThinking.trigger(state) : ""}
            <span class="spacer"></span>
            <button class="send-button" id="sendButton" type="button" data-action="send-chat"
                    data-glyph="${state.chatStreaming ? "stop" : "arrowUp"}"
                    aria-label="${state.chatStreaming ? "停止生成" : "发送消息"}">
              ${icon(state.chatStreaming ? "stop" : "arrowUp", 14)}
            </button>
          </div>
        </div>
      </div>
    </section>`;
}

export function chatBodyHTML() {
  const messages = state.chatMessages || [];
  return messages.length
    ? messages.map((message, index) => messageHTML(message, index === messages.length - 1)).join("")
    : chatEmptyHTML();
}

/// Keep the chat shell in place while only its live values move. Called on
/// every snapshot (and from `tick()`), so switching models never has to
/// rebuild the page just to relabel the model chip.
export function syncChatChrome() {
  if (state.page !== "chat") return;
  const page = q("#pageFrame .chat-page");
  if (!page) return;

  const running = isRunning();

  const modelKey = canonicalModel(state.model);
  const modelLabel = displayModel(state.model);
  const line = q(".chat-model-line", page);
  if (line && line.dataset.modelKey !== modelKey) {
    line.dataset.modelKey = modelKey;
    line.title = fullModelName(state.model);
    // 名字变了要「换」而不是「替换」：旧名做成残影淡出，新名浮上来，
    // 按钮宽度补一段动画，右侧的上下文计数才会跟着滑过去。老页面没有
    // 标签槽时才退回直接写 innerHTML。
    const glyph = chatModelGlyph(state.model, 12);
    if (fcMorphModelButton && line.querySelector("[data-model-label]")) {
      fcMorphModelButton(line, { label: modelLabel, glyph });
    } else {
      line.innerHTML = `<span class="model-glyph" data-model-glyph>${glyph}</span>` +
        `<span class="model-label" data-model-label>${esc(modelLabel)}</span>${icon("chevronDown", 11)}`;
    }
  }
  const chip = q('.composer-chip[data-action="model-menu"]', page);
  if (chip && chip.dataset.modelKey !== modelKey) {
    chip.dataset.modelKey = modelKey;
    chip.title = fullModelName(state.model);
    const glyph = chatModelGlyph(state.model, 12);
    if (fcMorphModelButton && chip.querySelector("[data-model-label]")) {
      fcMorphModelButton(chip, { label: modelLabel, glyph });
    } else {
      chip.innerHTML = `<span class="model-glyph" data-model-glyph>${glyph}</span>` +
        `<span class="model-label" data-model-label>${esc(modelLabel)}</span>`;
    }
  }

  const context = S.snap.context || { used: 0, total: 0 };
  setText(".chat-context", `${formatContextK(context.used || 0)} / ${context.total ? formatContextK(context.total) : "—"}`);

  const empty = q(".fc-chat-empty p", page);
  if (empty) {
    const copy = `当前由 <b>${esc(state.engine)}</b> 加载 <b>${esc(modelLabel)}</b>。数据不出本机，离线也能用。`;
    if (empty.dataset.copy !== copy) {
      empty.dataset.copy = copy;
      empty.innerHTML = copy;
    }
  }

  const send = q("#sendButton", page);
  const glyph = state.chatStreaming ? "stop" : "arrowUp";
  if (send && send.dataset.glyph !== glyph) {
    send.dataset.glyph = glyph;
    send.innerHTML = icon(glyph, 14);
    send.setAttribute("aria-label", state.chatStreaming ? "停止生成" : "发送消息");
  }

  // The thinking trigger is part of the composer, which stays mounted now.
  // A settings change (mode or effort) has to relabel it in place.
  if (syncThinkingTriggerLabel) syncThinkingTriggerLabel();
}

/// Same-page chat update: refresh the message body in place instead of
/// replacing the whole page. The sidebar and titlebar never repaint, and the
/// composer keeps focus while a reply streams.
/// `resetThread` is set when Swift reports a different threadID (new chat or
/// reopening a history thread): the composer and the stream engine then belong
/// to the previous conversation, so the message list is swapped wholesale but
/// the chat shell itself still stays mounted.
export function updateChatPage(options = {}) {
  const resetThread = !!(options && options.resetThread);
  const saved = captureChatScroll();
  if (resetThread) {
    releaseChatMessages();
    resetChatComposer();
    // A thread swap replaces the whole list at once. Mark its messages as
    // already seen so a long history does not replay .4s of rise-and-blur on
    // every bubble — that reads as another full-screen flash.
    (state.chatMessages || []).forEach((message) => S.seenMessages.add(message.id));
  }
  if (!resetThread && patchStreamingMessage()) {
    restoreChatScroll(saved);
    tick();
    return;
  }
  const host = q("#messagesInner");
  if (host) {
    const html = chatBodyHTML();
    if (host.innerHTML !== html) {
      host.innerHTML = html;
      settleMessageEntrances(host);
    }
  }
  restoreChatScroll(saved);
  tick();
}

/// Retire everything the reveal engine attached to the outgoing conversation:
/// per-message timers/carets and the shared "回到最新" jump control. Without
/// this, a thread swap can leave a stale jump button (or a settle callback
/// writing the old reply back into the new thread).
export function releaseChatMessages() {
  const host = q("#messagesInner");
  if (host && FCChatStream) {
    qa(".message[data-msg-id]", host).forEach((node) => FCChatStream.release(node));
  }
  qa(".fc-jump").forEach((node) => node.remove());
}

/// The composer used to be recreated by the full-page render on a new chat,
/// which dropped the draft. Keep that behaviour now that it stays mounted.
export function resetChatComposer() {
  const input = q("#chatInput");
  if (!input) return;
  input.value = "";
  input.style.height = "46px";
}

/// 流式回复只改最后一条气泡的正文文本，不动 `#messagesInner` 里的其它节点：
/// 整段替换会把光标和「正在思考」的三点一起重建，动画每来一个 token 就重启
/// 一次（看起来像卡住），长对话里还要重排整串气泡。结构真的变了（新消息、
/// 换行、回复结束）就返回 false，让调用方走整段重绘。
export function patchStreamingMessage() {
  const messages = state.chatMessages || [];
  const last = messages[messages.length - 1];
  const host = q("#messagesInner");
  if (!last || last.role !== "assistant" || !host) return false;
  const articles = qa(".message[data-msg-id]", host);
  if (articles.length !== messages.length) return false;
  const node = articles[articles.length - 1];
  if (node.dataset.msgId !== String(last.id)) return false;

  if (!FCChatStream) return false;

  if (last.streaming) {
    // Every snapshot is just a new target; the reveal engine decides how the
    // text reaches the screen. Nothing here rebuilds the DOM, so the caret,
    // the thinking fold and the markdown blocks keep their state.
    FCChatStream.push(node, last);
    return true;
  }

  // The final snapshot arrives while the reader is still watching the last
  // characters land. Hand the finished text over with the meta row, but only
  // after the reveal has drained and the caret has retired — otherwise the
  // reply would jump to full height the instant generation stops.
  if (FCChatStream.isAnimating(node)) {
    FCChatStream.push(node, last, {
      onSettled: () => {
        if (state.page !== "chat") return;
        const saved = captureChatScroll();
        const inner = q("#messagesInner");
        if (!inner) return;
        inner.innerHTML = chatBodyHTML();
        settleMessageEntrances(inner);
        restoreChatScroll(saved);
      },
    });
    return true;
  }
  return false;
}

/// The `is-new` class only exists while the entrance animation runs. Drop it
/// on `animationend` so a node that survives a later patch never carries a
/// stale animation marker.
export function settleMessageEntrances(root) {
  qa(".message.is-new", root || document).forEach((node) => {
    if (node.dataset.entranceBound) return;
    node.dataset.entranceBound = "1";
    node.addEventListener("animationend", () => {
      node.classList.remove("is-new");
      delete node.dataset.entranceBound;
    }, { once: true });
  });
}

export function chatEmptyHTML() {
  return `<div class="fc-chat-empty">
    <div class="fc-chat-empty-mark"><img src="app-icon.png" alt=""></div>
    <h2>把推理留在这台 Mac 上</h2>
    <p>当前由 <b>${esc(state.engine)}</b> 加载 <b>${esc(displayModel(state.model))}</b>。数据不出本机，离线也能用。</p>
    <div class="fc-chat-suggestions">
      <button type="button" data-suggest="用三句话介绍本地大模型的优势。">用三句话介绍本地大模型的优势</button>
      <button type="button" data-suggest="帮我总结一下这段对话的要点。">总结这段对话的要点</button>
    </div>
  </div>`;
}

/// The AI avatar carries the mark of the model that wrote the reply, not a
/// generic brain/sunset chip. `message.model` is persisted with the thread,
/// so older answers keep their family icon after a switch; snapshots that
/// predate that field fall back to the active model.
export function messageAvatar(message) {
  const model = message.model || state.model;
  if (FCModelBrand && typeof FCModelBrand.tile === "function") {
    return FCModelBrand.tile(model, { size: 15, className: "avatar ai-icon model-avatar" });
  }
  return `<div class="avatar ai-icon">${icon("brain", 14)}</div>`;
}

export function messageHTML(message, isLast) {
  // Only a message that has not been painted in this thread enters with the
  // rise-and-blur animation. Repaints caused by a switch or a streaming
  // token must leave the bubbles visually still.
  const isNew = !S.seenMessages.has(message.id);
  if (isNew) S.seenMessages.add(message.id);
  const entering = isNew ? " is-new" : "";
  if (message.role === "user") {
    return `<article class="message user${entering}" data-msg-id="${esc(message.id)}">
      <div class="message-body"><div class="user-bubble">${esc(message.content)}</div></div>
    </article>`;
  }
  const answer = FCChatStream
    ? FCChatStream.answerHTML(message)
    : `<div class="md-body">${FCChatMarkdown ? FCChatMarkdown.render(message.content) : esc(message.content)}</div>`;
  const thinking = FCChatStream ? FCChatStream.thinkingHTML(message) : "";
  return `<article class="message ai${entering}${thinking ? " has-think" : ""}" data-msg-id="${esc(message.id)}">
    ${messageAvatar(message)}
    <div class="message-body">
      ${thinking}
      <div class="assistant-card ${message.streaming ? "is-streaming" : ""}${!message.content ? " is-empty" : ""}" ${message.streaming ? 'id="streamingAnswer"' : ""}>
        <div class="assistant-text">${answer}</div>
      </div>
      ${message.streaming ? "" : `<div class="message-meta">
        <span>${message.rate ? `${esc(message.rate)} tok/s` : "— tok/s"}</span>
        <span>首字 ${message.ttft ? `${esc(message.ttft)} ms` : "—"}</span>
        <span>${message.tokens ? `${esc(message.tokens)} tokens` : "— tokens"}</span>
        ${isLast && !state.chatStreaming ? `<button type="button" data-action="regenerate">重新生成</button>` : ""}
        ${message.content ? `<button type="button" data-copy="${esc(message.content)}">复制</button>` : ""}
      </div>`}
    </div>
  </article>`;
}

// ---------- models ----------
export function modelsPageHTML() {
  return FCModelWorkspace.render(state, MODELS);
}

// ---------- logs ----------
export function logsPageHTML() {
  const lines = LOG_SEED;
  const counts = {};
  ["全部", "提示", "警告", "错误"].forEach((filter) => { counts[filter] = logCount(filter, lines); });
  const html = logLinesHtml(lines);
  const logName = `${String(state.engine || "engine").toLowerCase().replace(/\s+/g, "-")}.log`;
  return `
    <section class="logs-workspace">
      <div class="logs-topbar">
        <div class="filter-pills sliding-segments" data-sliding-segments>
          <span class="segment-slider" aria-hidden="true"></span>
          ${["全部", "提示", "警告", "错误"].map((filter) =>
            `<button class="filter-pill ${state.logFilter === filter ? "active" : ""}" type="button" data-log-filter="${filter}">${filter}<b>${counts[filter]}</b></button>`).join("")}
        </div>
        <label class="search-field">
          ${icon("search", 14)}
          <input id="logSearch" type="search" placeholder="搜索" value="${esc(state.logSearch)}" autocomplete="off">
        </label>
        <span class="spacer"></span>
        <button class="button icon-only quiet" type="button" data-action="log-copy" aria-label="复制日志" title="复制可见日志">${icon("copy", 13)}</button>
        <button class="button icon-only quiet" type="button" data-action="open-log-file" aria-label="打开日志文件" title="打开日志文件">${icon("fileText", 13)}</button>
        <button class="button" type="button" data-action="toggle-log-pause">
          ${icon(state.logPaused ? "play" : "pause", 13)}<span>${state.logPaused ? "继续" : "暂停"}</span>
        </button>
        <button class="button icon-only quiet" type="button" data-action="clear-logs" aria-label="清空日志">${icon("trash", 13)}</button>
      </div>
      <section class="console">
        <header class="console-head">
          <span class="live-toggle"><i></i>${state.logPaused ? "PAUSED" : "LIVE"}</span>
          <span>${esc(logName)}</span>
          <span class="spacer"></span>
          <span>${lines.length} 行</span>
        </header>
        <div class="console-body" id="consoleBody">${html}</div>
      </section>
    </section>`;
}

// ---------- settings ----------
export function settingsPageHTML() {
  const settings = state.settings || {};
  const rec = state.recommendation || {};
  const enginePorts = (S.snap.engineCatalog || []).map((item) => {
    const info = (S.snap.enginesInstall || {})[item.id] || {};
    return { id: item.id, name: item.name, port: info.port != null ? info.port : item.defaultPort, accent: item.accent };
  });
  return `
    <section class="settings-workspace">
      <div class="settings-two-column">
        <section class="settings-group">
          <div class="settings-row">
            <div class="settings-copy"><strong>外观</strong><span>跟随系统或固定外观</span></div>
            <div class="settings-segmented sliding-segments" data-appearance-choice data-sliding-segments>
              <span class="segment-slider" aria-hidden="true"></span>
              ${["system", "light", "dark"].map((choice) =>
                `<button type="button" class="${state.theme === choice ? "active" : ""}" data-appearance="${choice}">${choice === "system" ? "跟随系统" : choice === "light" ? "浅色" : "深色"}</button>`).join("")}
            </div>
          </div>
          <div class="settings-row">
            <div class="settings-copy"><strong>登录时启动</strong><span>加入 macOS 登录项</span></div>
            <button class="toggle ${settings.login ? "on" : ""}" type="button" data-setting-toggle="login" role="switch" aria-checked="${settings.login}"></button>
          </div>
          <div class="settings-row">
            <div class="settings-copy"><strong>随应用启动引擎</strong><span>打开应用时拉起默认引擎</span></div>
            <button class="toggle ${settings.launchEngine ? "on" : ""}" type="button" data-setting-toggle="launchEngine" role="switch" aria-checked="${settings.launchEngine}"></button>
          </div>
        </section>

        <section class="settings-group">
          <div class="settings-row">
            <div class="settings-copy"><strong>API 网关</strong><span>OpenAI 与 Claude 双协议</span></div>
            <button class="toggle ${settings.gateway ? "on" : ""}" type="button" data-setting-toggle="gateway" role="switch" aria-checked="${settings.gateway}"></button>
          </div>
          <div class="settings-row">
            <div class="settings-copy"><strong>网关端口</strong><span>固定入口，客户端不用改</span></div>
            <label class="fc-setting-field"><span>:</span>
              <input id="gatewayPortInput" type="number" min="1024" max="65535" value="${esc(String(settings.gatewayPort || ""))}" data-gateway-port>
            </label>
          </div>
          <div class="settings-row">
            <div class="settings-copy"><strong>思考模式</strong><span>回答前是否输出推理过程</span></div>
            <div class="settings-segmented sliding-segments" data-thinking-choice data-sliding-segments>
              <span class="segment-slider" aria-hidden="true"></span>
              ${["自动", "关闭", "开启"].map((choice) =>
                `<button type="button" class="${settings.thinking === choice ? "active" : ""}" data-thinking="${choice}">${choice}</button>`).join("")}
            </div>
          </div>
          <div class="settings-row">
            <div class="settings-copy"><strong>默认模型</strong><span data-default-model>${esc(displayModel(settings.defaultModel || state.model))}</span></div>
            <button class="button" type="button" data-action="model-menu">${icon("layers", 13)}<span>更改</span></button>
          </div>
          <div class="settings-row">
            <div class="settings-copy"><strong>思考等级</strong><span>等级由当前引擎提供</span></div>
            <div class="settings-segmented sliding-segments fc-effort-segment" data-effort-choice data-sliding-segments>
              <span class="segment-slider" aria-hidden="true"></span>
              ${(settings.reasoningEfforts || []).map((effort) =>
                `<button type="button" class="${settings.reasoningEffort === effort.value ? "active" : ""}" data-effort="${esc(effort.value)}">${esc(effort.label)}</button>`).join("")}
            </div>
          </div>
        </section>

        <section class="settings-group settings-ports">
          <div class="settings-row">
            <div class="settings-copy"><strong>引擎端口</strong><span>各引擎固定起始端口，互不抢占</span></div>
          </div>
          <div class="fc-port-grid">
            ${enginePorts.map((engine) => `
              <label class="fc-port-row">
                <span class="fc-port-mark" style="--c:${esc(engine.accent || "#8d78e8")}">${esc(engine.name.slice(0, 1))}</span>
                <span class="fc-port-name">${esc(engine.name)}</span>
                <span class="fc-setting-field"><span>:</span>
                  <input type="number" min="1024" max="65535" value="${esc(String(engine.port || ""))}"
                         data-port-engine="${esc(engine.id)}" aria-label="${esc(engine.name)} 端口">
                </span>
              </label>`).join("")}
          </div>
          <div class="settings-row">
            <div class="settings-copy"><strong>下载缓存</strong><span>Hugging Face 缓存目录</span></div>
            <label class="fc-setting-wide"><input id="hfCacheInput" type="text" value="${esc(settings.hfCache || "")}"
              placeholder="默认使用 HF_HUB_CACHE" spellcheck="false" data-hf-cache></label>
          </div>
        </section>

        <section class="settings-group about-settings">
          <div class="settings-row">
            <div class="settings-copy"><strong>flashCat</strong><span>本地推理控制台 · ${esc(state.appVersion || "开发版")}</span></div>
            <span class="about-device">${esc(rec.chip || "Apple Silicon")}</span>
          </div>
          <div class="settings-row">
            <div class="settings-copy"><strong>这台 Mac</strong><span>${esc(rec.chip || "Apple Silicon")}${rec.memoryGB ? ` · ${esc(String(rec.memoryGB))} GB 统一内存` : ""}</span></div>
            <span class="about-device">${rec.freeDiskText ? `可用 ${esc(rec.freeDiskText)}` : "macOS"}</span>
          </div>
          <div class="settings-row">
            <div class="settings-copy"><strong>对话参数</strong><span>温度 ${esc(String(settings.temperature))} · Top P ${esc(String(settings.topP))} · 最大输出 ${settings.maxTokens ? esc(String(settings.maxTokens)) : "最大上下文"}</span></div>
            <button class="button" type="button" data-action="open-inspector">${icon("sliders", 13)}<span>调整</span></button>
          </div>
          <div class="settings-row">
            <div class="settings-copy"><strong>首次启动引导</strong><span>重新打开引擎安装页</span></div>
            <button class="button" type="button" data-action="open-launch">${icon("power", 13)}<span>打开</span></button>
          </div>
          <div class="settings-row">
            <div class="settings-copy"><strong>恢复默认</strong><span>外观、启动与网关设置</span></div>
            <button class="button quiet" type="button" data-action="reset-settings">${icon("refresh", 13)}<span>恢复</span></button>
          </div>
        </section>
      </div>
    </section>`;
}

// ---------- first run / launch page ----------
export function launchPageHTML() {
  const rec = S.snap.recommendation || {};
  if (rec.show) return recommendPageHTML(rec);
  return firstRunPageHTML();
}

export function launchShell(inner) {
  const rec = state.recommendation || {};
  return `<div class="fc-launch">
    <header class="fc-launch-brand">
      <img src="app-icon.png" alt="">
      <div><strong>flashCat</strong><span>本地推理控制台</span></div>
    </header>
    ${inner}
    <p class="fc-launch-note">${esc(rec.chip || "")}${rec.memoryGB ? ` · ${esc(String(rec.memoryGB))} GB 统一内存` : ""}${rec.freeDiskText ? ` · 可用 ${esc(rec.freeDiskText)}` : ""}</p>
  </div>`;
}

export function recommendPageHTML(rec) {
  const rows = rec.rows || [];
  return launchShell(`
    <div class="fc-launch-head">
      <span class="eyebrow">FIRST RUN</span>
      <h1>为你挑选好了</h1>
      <p>按这台机器的内存和可用磁盘算的：每个引擎给一档最能发挥它的模型。引擎装好后会自动下载这一档。</p>
    </div>
    <div class="fc-launch-list">
      ${rows.map((row) => {
        const meta = engineMeta(nameEngineOf(row.engine));
        const info = engineInstall(nameEngineOf(row.engine));
        const busy = info.progress != null;
        const percent = Math.round(Number(info.progress || 0) * 100);
        const fit = row.fit === "good" || row.fit === "unknown";
        return `<article class="fc-launch-card ${fit ? "" : "is-tight"}" data-launch-engine="${esc(row.engine)}">
          <span class="fc-launch-mark" style="--c:${esc(meta.accent || "#8d78e8")}">${esc(engineGlyph(meta.name))}</span>
          <div class="fc-launch-copy">
            <strong>${esc(meta.name)}</strong>
            <h2>${esc(row.display || row.model)}</h2>
            <p>${esc(row.reason || "")}</p>
            <div class="fc-launch-tags">
              ${row.minMemory ? `<span>${esc(String(row.minMemory))} GB 内存起</span>` : ""}
              ${row.sizeText ? `<span>${esc(row.sizeText)}</span>` : ""}
              ${(meta.capabilities || []).slice(0, 3).map((cap) => `<span>${esc(cap.label || cap.id)}</span>`).join("")}
            </div>
            ${row.fit === "tight" ? `<small class="fc-launch-warn">这台机器低于这一档的内存下限，仍可安装，但可能跑不动。</small>` : ""}
            ${row.fit === "diskShort" ? `<small class="fc-launch-warn">可用磁盘小于这一档的体积，下载可能中途失败。</small>` : ""}
          </div>
          <div class="fc-launch-action">
            ${busy
              ? `<div class="fc-launch-progress"><span><i style="width:${Math.max(3, percent)}%"></i></span><b>${percent}%</b><small>${esc(info.step || "正在安装")}</small></div>`
              : `<button class="fc-launch-install" type="button" data-action="recommend-install" data-engine="${esc(row.engine)}">
                  ${icon("arrowRight", 13)}<span>用这个引擎</span>
                </button>`}
          </div>
        </article>`;
      }).join("") || `<div class="fc-widget-empty">没有找到可推荐的模型</div>`}
    </div>
    <div class="fc-launch-foot">
      <button class="button quiet" type="button" data-action="skip-recommendation">跳过，我自己选</button>
      <span>推荐只算这一次</span>
    </div>`);
}

export function firstRunPageHTML() {
  const catalog = S.snap.engineCatalog || [];
  const installed = catalog.filter((engine) => (S.snap.enginesInstall || {})[engine.id]?.versions?.length);
  return launchShell(`
    <div class="fc-launch-head">
      <span class="eyebrow">ENGINE SETUP</span>
      <h1>选择你的推理引擎</h1>
      <p>引擎不随应用打包。选一个下载安装，它就是你的默认引擎；之后可以随时从引擎页添加或切换到别的引擎。</p>
    </div>
    ${installed.length ? `<p class="fc-launch-found">检测到本机已安装：${installed.map((engine) => `${esc(engine.name)} v${esc(((S.snap.enginesInstall || {})[engine.id].versions || []).slice(-1)[0] || "")}`).join(" · ")}</p>` : ""}
    ${S.snap.packIndex && S.snap.packIndex.error ? `<div class="fc-launch-warn">无法读取发布索引：${esc(S.snap.packIndex.error)}</div>` : ""}
    <div class="fc-launch-list">
      ${catalog.map((engine) => {
        const info = (S.snap.enginesInstall || {})[engine.id] || {};
        const versions = info.versions || [];
        const latest = info.latestRelease && info.latestRelease.version;
        const busy = info.progress != null;
        const percent = Math.round(Number(info.progress || 0) * 100);
        const current = Boolean(engine.installed) || (latest ? versions.includes(latest) : versions.length > 0);
        return `<article class="fc-launch-card" data-launch-engine="${esc(engine.id)}">
          <span class="fc-launch-mark" style="--c:${esc(engine.accent || "#8d78e8")}">${esc(engineGlyph(engine.name))}</span>
          <div class="fc-launch-copy">
            <strong>${esc(engine.name)}</strong>
            <h2>${esc(engine.summary || "本地推理运行时")}</h2>
            <div class="fc-launch-tags">
              ${(engine.capabilities || []).map((cap) => `<span>${esc(cap.label || cap.id)}</span>`).join("")}
              ${versions.length ? `<span>已安装 v${esc(versions[versions.length - 1])}</span>` : ""}
              ${latest ? `<span>最新 v${esc(latest)}</span>` : ""}
            </div>
          </div>
          <div class="fc-launch-action">
            ${busy
              ? `<div class="fc-launch-progress"><span><i style="width:${Math.max(3, percent)}%"></i></span><b>${percent}%</b><small>${esc(info.step || "正在安装")}</small></div>`
              : current
                ? `<span class="fc-launch-done">${icon("check", 12)}<span>已安装</span></span>`
                : latest
                  ? `<button class="fc-launch-install" type="button" data-action="install-engine" data-engine="${esc(engine.id)}" data-launch="1">${icon("download", 13)}<span>安装</span></button>`
                  : `<span class="fc-launch-muted">暂无可用版本</span>`}
          </div>
        </article>`;
      }).join("")}
    </div>
    <div class="fc-launch-foot">
      <button class="button primary" type="button" data-action="finish-launch" ${S.snap.launchNeedsSetup ? "disabled" : ""}>${icon("arrowRight", 13)}<span>开始使用</span></button>
    </div>`);
}

// ---------- confirmations ----------
export function refreshOverlayLayer() {
  const layer = q("#overlayLayer");
  if (!layer) return;
  const needed = Boolean(state.currentOverlay) || Boolean(q("#fcPending"));
  layer.classList.toggle("is-open", needed);
  layer.setAttribute("aria-hidden", String(!needed));
}

export function renderPending() {
  const pending = S.snap && S.snap.pending;
  const pendingInstall = S.snap && S.snap.pendingInstall;
  const host = q("#overlayLayer");
  let node = q("#fcPending");
  if (!pending && !pendingInstall) {
    if (node) {
      node.remove();
      restoreModalFocus(); // 焦点还给打开确认弹窗的触发元素
    }
    S.pendingSignature = "";
    refreshOverlayLayer();
    return;
  }
  if (!host) return;
  const signature = JSON.stringify([pending, pendingInstall]);
  if (signature === S.pendingSignature) return;
  S.pendingSignature = signature;
  if (!node) {
    node = document.createElement("div");
    node.id = "fcPending";
    node.className = "fc-scrim";
    host.appendChild(node);
  }
  let title = "";
  let text = "";
  let confirm = "";
  let cancel = "";
  if (pending && pending.kind === "use") {
    title = pending.needsDownload ? "下载并使用模型" : "切换模型";
    text = pending.needsDownload
      ? `「${shortModel(pending.model)}」尚未下载（${nameEngineOf(pending.engine)} 引擎），确认后将开始下载，完成后自动启用。`
      : `切换到 ${nameEngineOf(pending.engine)} 引擎的「${shortModel(pending.model)}」？当前引擎会先停止。`;
    confirm = `<button class="button primary" type="button" data-pending="confirm-use">${icon(pending.needsDownload ? "cloudDownload" : "check", 13)}<span>${pending.needsDownload ? "下载并使用" : "确认使用"}</span></button>`;
    cancel = `<button class="button quiet" type="button" data-pending="cancel-use">${icon("x", 13)}<span>取消</span></button>`;
  } else if (pending && pending.kind === "switch") {
    title = "切换模型";
    // oMLX / MLX-Serve swap the model in place; Splash / MTPLX restart the
    // process. Tell the reader which one they are about to get instead of
    // always claiming a restart.
    const hotSwitch = String(engineMeta(state.engine).switchMode || "") === "hot";
    text = `切换到「${shortModel(pending.model)}」？${hotSwitch
      ? "当前引擎会热切换模型，正在处理的请求不受影响。"
      : "正在运行的服务将重启以加载新模型。"}`;
    confirm = `<button class="button primary" type="button" data-pending="confirm-switch">${icon("check", 13)}<span>确认切换</span></button>`;
    cancel = `<button class="button quiet" type="button" data-pending="cancel-switch">${icon("x", 13)}<span>取消</span></button>`;
  } else if (pendingInstall) {
    title = `${nameEngineOf(pendingInstall)} 还没安装`;
    text = `这个模型由 ${nameEngineOf(pendingInstall)} 引擎驱动，先安装它才能切换到这一档。`;
    confirm = `<button class="button primary" type="button" data-pending="confirm-install">${icon("download", 13)}<span>去安装</span></button>`;
    cancel = `<button class="button quiet" type="button" data-pending="cancel-install">${icon("x", 13)}<span>取消</span></button>`;
  }
  refreshOverlayLayer();
  node.innerHTML = `<div class="fc-modal glass-sheet" role="dialog" aria-modal="true" aria-labelledby="fcPendingTitle">
    <span class="eyebrow">CONFIRM</span>
    <h2 id="fcPendingTitle">${esc(title)}</h2>
    <p>${esc(text)}</p>
    <footer>${cancel}${confirm}</footer>
  </div>`;
  stashModalFocus();
  // 键盘用户的入口：焦点落在取消（破坏性最小的动作）上，Tab 由焦点陷阱接管。
  node.querySelector("button")?.focus({ preventScroll: true });
}

export function renderHub(force) {
  const node = q("#fcHub");
  if (!node || !S.hubState.open) return;
  const hub = hubSnapshot();
  const signature = JSON.stringify({
    view: S.hubState.view,
    tab: S.hubState.tab,
    detailRepo: S.hubState.detailRepo,
    hub: [hub.query, hub.sort, hub.filter, hub.page, hub.hasMore, hub.loading,
          hub.detailLoading, hub.error, hub.results, hub.detail, hub.local, hub.shared],
  });
  if (!force && signature === S.hubSignature) return;
  S.hubSignature = signature;
  const active = document.activeElement;
  const keepFocus = active && active.id === "hubQuery"
    ? { start: active.selectionStart, end: active.selectionEnd }
    : null;
  node.innerHTML = S.hubState.view === "detail" ? hubDetailHTML(hub) : hubListHTML(hub);
  if (keepFocus) {
    const input = q("#hubQuery");
    if (input) {
      input.focus({ preventScroll: true });
      try { input.setSelectionRange(keepFocus.start, keepFocus.end); } catch (error) { /* search input */ }
    }
  }
}

export function hubCloseButton() {
  return `<button class="glass-icon-btn small" type="button" data-hub-close aria-label="关闭模型广场"><span class="sr-only">关闭</span>${icon("x", 14)}</button>`;
}

export function hubChip(label, action, dataKey, value, active) {
  return `<button class="fc-hub-chip ${active ? "is-on" : ""}" type="button"
    data-action="${action}" data-${dataKey}="${esc(value)}" aria-pressed="${active}">${esc(label)}</button>`;
}

export function hubKindLabel(model) {
  if (model.mtplx) return "MTP";
  if (model.gguf) return "GGUF";
  if (model.mlx) return "MLX";
  return "MODEL";
}

export function hubCount(value) {
  const count = Number(value) || 0;
  if (count >= 1e9) return `${(count / 1e9).toFixed(1)}B`;
  if (count >= 1e6) return `${(count / 1e6).toFixed(count >= 1e7 ? 0 : 1)}M`;
  if (count >= 1e3) return `${(count / 1e3).toFixed(count >= 1e4 ? 0 : 1)}k`;
  return String(count);
}

export function hubParams(value) {
  const count = Number(value) || 0;
  if (count >= 1e12) return `${(count / 1e12).toFixed(1)}T`;
  if (count >= 1e9) return `${(count / 1e9).toFixed(1)}B`;
  if (count >= 1e6) return `${(count / 1e6).toFixed(0)}M`;
  return hubCount(count);
}

export function hubMemoryText(model) {
  const low = Number(model.memoryMin) || 0;
  const high = Number(model.memoryMax) || 0;
  if (!low) return "";
  if (high && high !== low) return `≈${low}–${high} GB`;
  return `≈${low} GB`;
}

export function hubEngineLabel(model) {
  const id = model.engineID || "none";
  return id === "none" ? "无推荐引擎" : nameEngineOf(id);
}

export function hubRowHTML(model) {
  const local = hubLocally(model.id);
  const size = Number(model.size) || 0;
  const downloads = Number(model.downloads) || 0;
  const memory = hubMemoryText(model);
  const engine = model.engineID && model.engineID !== "none" ? model.engineID : "";
  const tags = [
    `<span class="fc-hub-tag ${engine ? "is-engine" : "is-muted"}">${esc(hubEngineLabel(model))}</span>`,
    model.quantization ? `<span class="fc-hub-tag">${esc(model.quantization)}</span>` : "",
    size ? `<span class="fc-hub-tag">${esc(fmtBytes(size))}</span>` : "",
    memory ? `<span class="fc-hub-tag">${esc(memory)} 内存</span>` : "",
    downloads ? `<span class="fc-hub-tag">↓ ${esc(hubCount(downloads))}</span>` : "",
  ].filter(Boolean).join("");
  // The left square used to repeat MLX / GGUF on every row, so the only way
  // to tell two Qwen packs apart was to read the repo id. It now carries the
  // family glyph (Qwen, MiMo, …); the weight format moves into the tooltip
  // and the engine tag below still names the runtime.
  const kind = hubKindLabel(model);
  const series = FCModelBrand && typeof FCModelBrand.seriesOf === "function"
    ? FCModelBrand.seriesOf(model)
    : null;
  const mark = series && typeof FCModelBrand.glyph === "function"
    ? `<span class="fc-hub-mark" style="--fc-series:${esc(series.color)}"
           title="${esc(series.label)} · ${esc(kind)}">${FCModelBrand.glyph(series, 17)}</span>`
    : `<span class="fc-hub-mark is-plain" title="${esc(kind)}">${esc(kind)}</span>`;
  // The row body is one real <button> so keyboard users get the platform
  // behaviour for free; the download action stays a sibling, never nested.
  // The repo id is the only name that stays true across owners and quants,
  // so it is the headline instead of a shortened product name plus a
  // subtitle repeating the same string.
  return `<article class="fc-hub-row">
    <button class="fc-hub-open" type="button" data-action="hub-open"
        data-hub-repo="${esc(model.id)}" aria-label="查看 ${esc(model.id)} 的模型卡">
      ${mark}
      <span class="fc-hub-copy">
        <strong title="${esc(model.id)}">${esc(model.id)}</strong>
        <span class="fc-hub-tags">${tags}</span>
      </span>
    </button>
    <div class="fc-hub-actions">
      ${local
        ? `<span class="fc-hub-local">${icon("check", 11)}<span>已在本机</span></span>`
        : `<button class="fc-hub-download" type="button" data-action="hub-download"
             data-hub-repo="${esc(model.id)}" data-hub-engine="${esc(engine)}">${icon("download", 12)}<span>下载</span></button>`}
    </div>
  </article>`;
}

export function hubListHTML(hub) {
  const results = hub.results || [];
  const sort = hub.sort || "trending";
  const filter = hub.filter || "all";
  const page = Math.max(0, Number(hub.page) || 0);
  const loading = !!hub.loading;
  const error = hub.error || "";
  // No "「keyword」· N 个仓库" strip: the count never changes a decision and
  // the line cost every list a row of height. Only progress and failure still
  // need a sentence, so the strip appears solely in those two states.
  const status = [
    loading ? `<span class="fc-hub-loading">${icon("loader", 11)} 搜索中…</span>` : "",
    error ? `<span class="fc-hub-error">${esc(error)}</span>` : "",
  ].filter(Boolean).join("");
  // An empty query with no rows is the plaza's first paint, before the
  // trending request comes back — not a failed keyword search.
  const empty = loading || (!hub.query && !results.length)
    ? "正在从 Hugging Face 取列表…"
    : error
      ? esc(error)
      : page > 0
        ? "这一页没有更多仓库了"
        : "没搜到仓库，换个关键词试试";
  return `
    <header class="fc-hub-head">
      <div>
        <span class="eyebrow">HUGGING FACE</span>
        <h2>模型广场</h2>
      </div>
      ${hubCloseButton()}
    </header>
    <div class="fc-hub-search">
      <label class="search-field">
        ${icon("search", 14)}
        <input id="hubQuery" type="search" value="${esc(S.hubState.query || hub.query || "")}"
               placeholder="搜索 Hugging Face 仓库…" autocomplete="off" spellcheck="false"
               aria-label="搜索 Hugging Face 仓库">
      </label>
      <button class="button" type="button" data-action="hub-search">${icon("search", 13)}<span>搜索</span></button>
    </div>
    <div class="fc-hub-filters">
      <div class="fc-hub-chip-group" role="group" aria-label="排序">
        <span class="fc-hub-chip-label">排序</span>
        ${hubChip("推荐", "hub-sort", "hub-sort", "trending", sort === "trending")}
        ${hubChip("下载量", "hub-sort", "hub-sort", "downloads", sort === "downloads")}
      </div>
      <div class="fc-hub-chip-group" role="group" aria-label="权重格式">
        ${hubChip("全部", "hub-filter", "hub-filter", "all", filter === "all")}
        ${hubChip("MLX", "hub-filter", "hub-filter", "mlx", filter === "mlx")}
        ${hubChip("GGUF", "hub-filter", "hub-filter", "gguf", filter === "gguf")}
      </div>
    </div>
    ${status ? `<div class="fc-hub-meta">${status}</div>` : ""}
    <div class="fc-hub-list">
      ${results.length
        ? results.map(hubRowHTML).join("")
        : `<div class="fc-hub-empty">${empty}</div>`}
    </div>
    <footer class="fc-hub-pager">
      <button class="button quiet" type="button" data-action="hub-page" data-hub-page="${page - 1}"
        ${page > 0 && !loading ? "" : "disabled"}>${icon("chevronLeft", 12)}<span>上一页</span></button>
      <span class="fc-hub-page-num">第 ${page + 1} 页</span>
      <button class="button quiet" type="button" data-action="hub-page" data-hub-page="${page + 1}"
        ${hub.hasMore && !loading ? "" : "disabled"}><span>下一页</span>${icon("chevronRight", 12)}</button>
    </footer>`;
}

/// HF READMEs mix markdown with raw HTML (centered logos, shields badges,
/// tables). There is no markdown renderer in this UI, so strip the markup and
/// keep readable text instead of dumping source at the reader.
export function hubCardText(text) {
  return String(text || "")
    .replace(/<br\s*\/?>/gi, "\n")
    .replace(/<img[^>]*>/gi, "")
    .replace(/<[^>]{0,400}>/g, "")
    .replace(/!\[[^\]]*\]\([^)]*\)/g, "")
    .replace(/\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/&nbsp;/g, " ").replace(/&middot;/g, "·")
    .replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"').replace(/&#39;/g, "'")
    .replace(/^[>\s]*/gm, "")
    .replace(/[#*`|]/g, "")
    .split("\n").map((line) => line.trim())
    .filter((line) => line && !/^[-\s=]{3,}$/.test(line))
    .join("\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

export function hubDetailHTML(hub) {
  // A card only belongs to the row that asked for it: while the next one is
  // in flight the previous card must not flash under the new title.
  const wanted = S.hubState.detailRepo || "";
  const model = hub.detail && (!wanted || hub.detail.id === wanted) ? hub.detail : null;
  const back = `<button class="fc-hub-back" type="button" data-action="hub-back">
    ${icon("arrowLeft", 12)}<span>返回模型广场</span></button>`;
  if (!model) {
    // Until Swift answers, the card is "loading" — not "pick a repository",
    // which is what the empty viewport used to say right after a click.
    const waiting = hub.detailLoading || (wanted && !hub.error
      && (!hub.detail || hub.detail.id !== wanted));
    return `
      <header class="fc-hub-head">
        <div><span class="eyebrow">MODEL CARD</span><h2>${esc(wanted ? shortModel(wanted) : "模型卡")}</h2></div>
        ${hubCloseButton()}
      </header>
      ${back}
      <div class="fc-hub-empty">${waiting ? "正在取模型卡…" : esc(hub.error || "选一个仓库看看")}</div>`;
  }
  const tab = S.hubState.tab || "card";
  const files = model.files || [];
  const local = hubLocally(model.id);
  let body = "";
  if (tab === "files") {
    body = files.length
      ? files.map((file) => `<div class="fc-hub-file">
          <span class="fc-hub-file-name" title="${esc(file.name)}">${esc(file.name)}</span>
          <span class="fc-hub-file-size">${file.size ? esc(fmtBytes(file.size)) : "—"}</span>
        </div>`).join("")
      : `<div class="fc-hub-empty">这个仓库没有文件清单</div>`;
  } else if (tab === "tags") {
    body = (model.tags || []).length
      ? `<div class="fc-hub-tag-cloud">${model.tags.map((tag) => `<span class="fc-hub-tag">${esc(tag)}</span>`).join("")}</div>`
      : `<div class="fc-hub-empty">这个仓库没有标签</div>`;
  } else {
    const card = hubCardText(model.modelCard || "");
    body = card
      ? `<div class="fc-hub-card-text">${esc(card)}</div>`
      : `<div class="fc-hub-empty">这个仓库没有模型卡（README）</div>`;
  }
  const facts = [
    ["体积", model.size ? fmtBytes(model.size) : "—"],
    ["参数", model.parameters ? `${hubParams(model.parameters)} 参数` : "—"],
    ["下载", model.downloads ? `↓ ${hubCount(model.downloads)}` : "—"],
    ["点赞", model.likes ? `♥ ${hubCount(model.likes)}` : "—"],
    ["更新", String(model.updated || "").slice(0, 10) || "—"],
    ["许可", model.license || "—"],
    ["任务", model.pipeline || model.io || "—"],
    ["内存", hubMemoryText(model) || "—"],
  ];
  const engine = model.engineID && model.engineID !== "none" ? model.engineID : "";
  return `
    <header class="fc-hub-head">
      <div><span class="eyebrow">MODEL CARD</span><h2>${esc(shortModel(model.id))}</h2></div>
      ${hubCloseButton()}
    </header>
    ${back}
    <div class="fc-hub-detail">
      <div class="fc-hub-detail-id">
        <span class="fc-hub-repo">${esc(model.id)}</span>
        <span class="fc-hub-tag ${engine ? "is-engine" : "is-muted"}">${esc(hubEngineLabel(model))}</span>
        ${local ? `<span class="fc-hub-tag is-ok">已在本机</span>` : ""}
        ${model.gated ? `<span class="fc-hub-tag is-warn">需授权</span>` : ""}
      </div>
      <div class="fc-hub-facts">
        ${facts.map(([key, value]) => `<div class="fc-hub-fact">
          <span class="fc-hub-fact-key">${esc(key)}</span>
          <span class="fc-hub-fact-value">${esc(value)}</span>
        </div>`).join("")}
      </div>
      <div class="fc-hub-tabs" role="tablist" aria-label="模型卡内容">
        <button class="fc-hub-tab ${tab === "card" ? "is-on" : ""}" type="button" role="tab"
          aria-selected="${tab === "card"}" data-action="hub-tab" data-hub-tab="card">模型卡</button>
        <button class="fc-hub-tab ${tab === "files" ? "is-on" : ""}" type="button" role="tab"
          aria-selected="${tab === "files"}" data-action="hub-tab" data-hub-tab="files">文件${files.length ? ` ${files.length}` : ""}</button>
        <button class="fc-hub-tab ${tab === "tags" ? "is-on" : ""}" type="button" role="tab"
          aria-selected="${tab === "tags"}" data-action="hub-tab" data-hub-tab="tags">标签</button>
      </div>
      <div class="fc-hub-detail-body">${body}</div>
      <footer class="fc-hub-detail-foot">
        <button class="button quiet" type="button" data-action="hub-link" data-hub-repo="${esc(model.id)}">
          ${icon("external", 12)}<span>在 Hugging Face 打开</span>
        </button>
        ${local
          ? `<span class="fc-hub-local">${icon("check", 12)}<span>已在本机</span></span>`
          : `<button class="button primary" type="button" data-action="hub-download"
               data-hub-repo="${esc(model.id)}" data-hub-engine="${esc(engine)}">
               ${icon("download", 13)}<span>下载</span></button>`}
      </footer>
    </div>`;
}

export function downloadRows(downloads) {
  const tasks = Array.isArray(downloads.tasks) ? downloads.tasks.slice() : [];
  if (downloads.active && downloads.active.model && !tasks.some((task) => task.model === downloads.active.model)) {
    tasks.unshift({ ...downloads.active, status: "downloading" });
  }
  return tasks;
}

export function renderDownloads(force) {
  const sheet = q("#downloadSheet");
  const list = q("#downloadList");
  if (!sheet || !list) return;
  const downloads = state.downloads || {};
  const tasks = downloadRows(downloads);
  const shape = downloadShape(downloads);
  if (!force && shape === S.downloadsShape && list.querySelector(".download-item")) {
    patchDownloadRows(list, downloads);
    return;
  }
  S.downloadsShape = shape;
  if (!tasks.length) {
    list.innerHTML = `<div class="fc-download-empty">${icon("download", 18)}<strong>没有下载任务</strong><span>从模型页或模型广场开始</span></div>`;
    return;
  }
  list.innerHTML = tasks.map((task) => {
    // The row's format comes from the engine that owns it, not from a
    // substring: `…-oQ4e-mtp` is MLX weights with an MTP head, not MTPLX.
    const adapter = engineMeta(nameEngineOf(task.engine)).adapter;
    const kind = /gguf/i.test(task.model) ? "GGUF"
      : adapter === "mtplx" ? "MTPLX"
        : (adapter === "splash" || adapter === "strata") ? "GGUF" : "MLX";
    const row = downloadRowText(task, downloads);
    return `<article class="download-item" data-download-model="${esc(task.model)}">
      <div class="download-type ${kind === "GGUF" ? "gguf" : ""}">${kind}</div>
      <div class="download-copy">
        <strong>${esc(displayModel(task.model))}</strong>
        <span>${row.meta}</span>
        <div class="progress-track ${row.status === "paused" ? "queued" : ""}"><i style="width:${row.fraction}%"></i></div>
      </div>
      <span class="download-percent ${row.status === "paused" ? "muted" : ""}">${row.fraction}%</span>
      <div class="fc-download-actions">
        ${row.status === "downloading"
          ? `<button class="fc-download-btn" type="button" data-dl="pause" data-engine="${esc(task.engine)}" data-model="${esc(task.model)}" aria-label="暂停">${icon("pause", 12)}</button>`
          : `<button class="fc-download-btn" type="button" data-dl="resume" data-engine="${esc(task.engine)}" data-model="${esc(task.model)}" aria-label="继续">${icon("play", 12)}</button>`}
        <button class="fc-download-btn" type="button" data-dl="cancel" data-engine="${esc(task.engine)}" data-model="${esc(task.model)}" aria-label="取消">${icon("x", 12)}</button>
      </div>
    </article>`;
  }).join("");
}

// 只改数字：行、按钮、图标都留在原节点上，悬停和按压不会被打断。
export function patchDownloadRows(list, downloads) {
  const byModel = new Map(downloadRows(downloads).map((task) => [task.model, task]));
  list.querySelectorAll(".download-item").forEach((node) => {
    const task = byModel.get(node.dataset.downloadModel);
    if (!task) return;
    const row = downloadRowText(task, downloads);
    const meta = node.querySelector(".download-copy > span");
    if (meta && meta.textContent !== row.meta) meta.textContent = row.meta;
    const percent = node.querySelector(".download-percent");
    const label = `${row.fraction}%`;
    if (percent && percent.textContent !== label) percent.textContent = label;
    const bar = node.querySelector(".progress-track > i");
    if (bar) {
      const width = `${row.fraction}%`;
      if (bar.style.width !== width) bar.style.width = width;
    }
  });
}

export function updateChoiceUI() {
  const settings = state.settings;
  qa("[data-thinking]").forEach((button) => {
    button.classList.toggle("active", button.dataset.thinking === settings.thinking);
  });
  qa("[data-effort]").forEach((button) => {
    button.classList.toggle("active", button.dataset.effort === settings.reasoningEffort);
  });
  if (updateSlidingSegments) requestAnimationFrame(() => updateSlidingSegments());
  if (syncThinkingTriggerLabel) syncThinkingTriggerLabel();
}

export function renderPage(animate, options) {
  render(Boolean(animate) && !(options && options.instant));
}
