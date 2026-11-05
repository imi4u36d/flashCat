/* flashCat WebUI · live bridge adapter — 组合根
 *
 * 视觉层是 liquid-glass 预览（index.html + styles.css + 从 preview/liquid-glass
 * 复制来的组件模块）。live 层把 Swift 快照变成这些组件的视图状态，把点击变回
 * bridge 命令。职责拆分：
 *   store.js   — 快照整形（adapt）、状态容器 S、Swift 桥（cmd）、错误上报、共享工具
 *   render.js  — HTML 构建、DOM patch、canvas 绘制
 *   actions.js — 事件处理与用户意图
 *   live.js    — 本文件：Swift 入口接线（window.__fc__）、启动、公共门面
 *
 * preview/liquid-glass 是设计的事实来源。它变更时复制件被刷新，本适配层按
 * 新组件签名重新核对。
 */

import { closeHub, closeOverlays, handleLiveChange, handleLiveClick, handleLiveInput, handleLiveKeydown, handleTitlebarDrag, trackModelHover, trackModelHoverMove } from "./actions.js";
import { bindGlobalEvents, renderNav, renderToolbarIcons, resolvedTheme, showToast, startAmbient, startClock, state, syncNavActive } from "./app.js";
import { FCChatStream } from "./chat-stream.js";
import { applyShell, markLogsRendered, patchLogs, patchModelProgress, refreshOverlayLayer, render, renderDownloads, renderHub, renderPending, renderRecents, tick, updateChatPage, updateChrome, updateLaunchMode, updateNavBadge } from "./render.js";
import { S, adapt, errorText, fingerprint, q, scrimCancelOnEscape, surfaceError, trapModalTab } from "./store.js";

// ---- 门面：app.js 与打包入口只从这里 import（内部实现见分层模块） ----
export {
  closeOverlays, openOverlay, openCommand, copyText, liveHandleAction as handleAction, navigate,
  openDownloads, renderCommandResults, runEngineInstall, removeEngineRuntime,
  saveEngineConfig, selectModel, sendChat, setTheme, startChatDownload,
  toggleEngine, toggleSetting, toggleSidebar,
} from "./actions.js";
export { renderPage, drawFlowFieldLive as drawFlowField, updateFlowProbeLive as updateFlowProbe } from "./render.js";

export const FC_LIVE = {
  init, push: pushSnapshot, render, adapt,
  get snapshot() { return S.snap; },
};

// Swift's WebBridge talks to these entry points through evaluateJavaScript.
// An exception escaping one of them leaves the JS task and, on file://,
// WebKit reports it as a scrubbed "Script error." with no stack. Catch it
// here instead so recordError() sees the real Error object.
function guardEntry(label, fn) {
  return function () {
    try { return fn.apply(this, arguments); }
    catch (error) {
      surfaceError((error && error.message) || "WebUI exception", errorText(error), label);
    }
  };
}

// Swift's token pipe arrives as a frame-sized batch. Deltas are applied
// straight to the live turn; the snapshot watermark tells the renderer which
// of those tokens it already has, so the two channels cannot double-paint.
function pushStreamEvents(events) {
  if (!FCChatStream) return;
  FCChatStream.ingest(events);
}

window.__fc__ = {
  push: guardEntry("__fc__.push", pushSnapshot),
  stream: guardEntry("__fc__.stream", pushStreamEvents),
  setSidebar: guardEntry("__fc__.setSidebar", (visible) => {
    state.sidebarCollapsed = !visible;
    applyShell();
  }),
};

window.__fcToast = guardEntry("__fcToast", (message) => showToast(String(message || "")));

// navigate/setTheme/toggleSidebar 等交互函数在 actions.js，经上方门面 re-export
// 供 app.js import；不再有 window 覆盖。

// ---------- boot ----------
function init() {
  document.documentElement.dataset.theme = resolvedTheme();
  document.documentElement.style.setProperty("--sidebar-width", `${state.sidebarWidth}px`);
  renderToolbarIcons();
  renderNav();
  renderRecents();
  if (bindGlobalEvents) bindGlobalEvents();
  if (startClock) startClock();
  if (startAmbient) startAmbient();
  if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
    document.documentElement.classList.add("reduce-motion");
  }
  bindExtraEvents();
  const frame = q("#pageFrame");
  if (frame) frame.innerHTML = `<div class="fc-boot"><span></span><strong>正在连接 flashCat…</strong></div>`;
}

function bindExtraEvents() {
  const overlayLayer = q("#overlayLayer");
  if (overlayLayer) {
    overlayLayer.addEventListener("click", guardEntry("overlay.click", (event) => {
      if (event.target !== overlayLayer && !event.target.classList.contains("command-backdrop")) return;
      if (S.hubState.open) closeHub();
      if (state.currentOverlay) closeOverlays();
    }));
  }
  // The same guard as the Swift entry points: DOM callbacks are the other
  // common place an exception can escape as an opaque "Script error.".
  document.addEventListener("click", guardEntry("click", handleLiveClick), true);
  document.addEventListener("input", guardEntry("input", handleLiveInput));
  document.addEventListener("change", guardEntry("change", handleLiveChange));
  document.addEventListener("keydown", guardEntry("keydown", handleLiveKeydown));
  // aria-modal 对话框的键盘治理：捕获相位先于其它监听，Tab 循环在对话框内、
  // Escape 关最上层的 scrim 弹窗（详见 store.js 的焦点治理一节）。
  document.addEventListener("keydown", guardEntry("keydown", (event) => {
    if (!trapModalTab(event)) scrimCancelOnEscape(event);
  }), true);
  document.addEventListener("mousedown", guardEntry("mousedown", handleTitlebarDrag));
  document.addEventListener("pointerover", guardEntry("pointerover", trackModelHover), true);
  document.addEventListener("pointerout", guardEntry("pointerout", trackModelHover), true);
  document.addEventListener("pointermove", guardEntry("pointermove", trackModelHoverMove), true);
  document.addEventListener("contextmenu", guardEntry("contextmenu", (event) => {
    if (!event.target.closest("input, textarea, [contenteditable='true'], [data-selectable]")) event.preventDefault();
  }));
  document.addEventListener("selectstart", guardEntry("selectstart", (event) => {
    if (!event.target.closest("input, textarea, [contenteditable='true'], [data-selectable]")) event.preventDefault();
  }));
}

function pushSnapshot(snap) {
  if (FCChatStream && snap && Number.isFinite(Number(snap.streamSeq))) {
    FCChatStream.setWatermark(snap.streamSeq);
  }
  const previousPage = state.page;
  const previousThread = state.threadID;
  const first = !S.snap;
  S.snap = snap;
  adapt(snap);
  applyShell();
  updateChrome();
  renderRecents();
  updateNavBadge();
  updateLaunchMode();
  if (snap.toast && snap.toast !== S.lastToast && Date.now() - S.toastShownAt > 700) {
    S.lastToast = snap.toast;
    S.toastShownAt = Date.now();
    showToast(snap.toast);
  }
  renderPending();
  refreshOverlayLayer();
  if (S.hubState.open) renderHub();
  if (state.currentOverlay === "downloads") renderDownloads();
  // 换 thread 不等于换页。以前把 threadID 变化算进 pageChanged，点「新对话」
  // 时 Swift 换一个 threadID，chat 页就会被当成一次页面切换：走带 view
  // transition 的整页 innerHTML 替换（淡出 + 淡入）、composer 重建、所有入场
  // 动画重播 —— 用户看到的就是页面闪一下。只有真正换了页面才做整页过渡，
  // 换 thread 交给 updateChatPage() 只换消息列表。
  const pageChanged = previousPage !== state.page;
  const threadChanged = previousThread !== state.threadID;
  const key = fingerprint();
  // threadID 可能单独变化而消息/页面结构没变（清空一个空对话、删掉当前历史
  // 会话等）。这种情况也要收口一次，让 composer 草稿和流式状态归位；但不能
  // 因此把整页重绘一遍。
  const shapeChanged = first || key !== S.lastKey || pageChanged;
  if (shapeChanged || threadChanged) {
    try {
      S.lastKey = key;
      if (pageChanged) syncNavActive();
      // Once the chat page is mounted, message/streaming updates only touch
      // the message body. Replacing the whole page here was what made a model
      // switch (and every streaming token) visibly flash the app.
      const patchChat = !first && !pageChanged
        && state.page === "chat"
        && !S.snap.launchPage
        && !(S.snap.recommendation && S.snap.recommendation.show)
        && q("#pageFrame .chat-page");
      // 日志页：新行只追加，不重绘整个控制台。`.log-line` 带 0.36s 入场动画，
      // 替换 console-body 会让屏幕上已有的每一行都重播一次，整屏闪。
      const patchLogsPage = !first && !pageChanged
        && state.page === "logs"
        && !S.snap.launchPage
        && !(S.snap.recommendation && S.snap.recommendation.show)
        && q("#pageFrame .logs-workspace");
      if (patchChat) updateChatPage({ resetThread: threadChanged });
      else if (patchLogsPage && patchLogs()) markLogsRendered();
      else if (!shapeChanged) tick();
      else render(pageChanged && !first);
      if (pageChanged && !first) S.lastKey = fingerprint();
    } catch (error) {
      // Record the real stack here. Rethrowing used to let the exception
      // escape __fc__.push: on file:// WebKit then reported a second,
      // scrubbed "Script error." and the rest of the snapshot was skipped.
      surfaceError(error && error.message, errorText(error), "render");
    }
  } else {
    // 指纹没变：进度这类纯数字的变化就停在这里，只补卡片上的百分比，
    // 不重建页面（否则悬停中的卡片会跟着每半秒闪一次）。
    patchModelProgress();
    tick();
  }
}
