/* flashCat WebUI · live actions — 交互层
 *
 * 事件处理与用户意图：把点击/输入/快捷键翻译成 bridge 命令（cmd）或状态
 * 迁移，需要重绘时调用 render 层。只被 live.js 的组合根接线，不被视图层
 * 反向依赖。
 */

import { NAV_ITEMS, closeEngineConfig, closeOverlaysBase, drawAmbient, icon, openCommandBase, openEngineConfig, openOverlayBase, rangeRow, resolvedTheme, showToast, state, syncNavActive, updateNavIndicator, updateRangeVisual, updateSlidingSegments, updateThemeIcon } from "./app.js";
import { FCChatStream } from "./chat-stream.js";
import { FCChatThinking } from "./chat-thinking.js";
import { esc } from "./esc.js";
import { FCModelBrand } from "./model-brand.js";
import { FCOverlayBounds } from "./overlay-bounds.js";
import { autosize, clearModelHover, refreshOverlayLayer, render, renderDownloads, renderHub, tick, updateChoiceUI, updateChrome } from "./render.js";
import { S, activeEngineRaw, cmd, displayModel, fingerprint, fullModelName, hubLocally, hubSnapshot, isRunning, modelOwner, nameEngineOf, q, qa, rawEngineIds, rawEngineOf, requestRate, restoreModalFocus, sameModel, stashModalFocus, tokenForThinking } from "./store.js";

export function navigate(page, options = {}) {
  if (!NAV_ITEMS.some((item) => item.id === page)) return;
  if (!options.force && state.page === page && !S.snap.launchPage) {
    const main = q("#mainContent");
    if (main) main.scrollTop = 0;
    return;
  }
  closeOverlays();
  if (S.hubState.open) closeHub();
  S.liveNavIntent = { page, at: Date.now() };
  state.page = page;
  state.engineConfigOpen = null;
  state.engineConfigDraft = null;
  syncNavActive();
  render(!!options.animate);
  S.lastKey = fingerprint();
  cmd("nav", { page });
}

export function openThread(id) {
  const leavingPage = state.page !== "chat";
  state.page = "chat";
  syncNavActive();
  // Already on chat: the incoming snapshot swaps just the message list (see
  // updateChatPage). Rendering the whole page here as well used to fire a
  // second view transition right before the snapshot arrived.
  if (leavingPage) render(true);
  cmd("openThread", { id });
}


// ---------- theme / sidebar ----------
export function setTheme(theme) {
  state.theme = theme;
  state.settings.appearance = theme;
  document.documentElement.dataset.theme = resolvedTheme();
  updateThemeIcon();
  if (drawAmbient) drawAmbient(performance.now());
  cmd("appearance", { mode: theme });
  if (state.page === "settings") {
    qa("[data-appearance]").forEach((button) => button.classList.toggle("active", button.dataset.appearance === theme));
    if (updateSlidingSegments) updateSlidingSegments();
  }
}

export function toggleSidebar() {
  state.sidebarCollapsed = !state.sidebarCollapsed;
  document.body.classList.add("sidebar-animating");
  document.body.classList.toggle("sidebar-collapsed", state.sidebarCollapsed);
  const toggle = q("#sidebarToggle");
  if (toggle) {
    toggle.setAttribute("aria-expanded", String(!state.sidebarCollapsed));
    toggle.setAttribute("aria-label", state.sidebarCollapsed ? "展开边栏" : "折叠边栏");
  }
  clearTimeout(toggleSidebar.timer);
  toggleSidebar.timer = setTimeout(() => {
    document.body.classList.remove("sidebar-animating");
    if (updateNavIndicator) updateNavIndicator();
  }, 340);
  cmd("toggleSidebar");
}

export function closeOverlays(options) {
  closeOverlaysBase(options);
  refreshOverlayLayer();
}

export function openOverlay(kind) {
  if (S.hubState.open && kind !== "hub") closeHub();
  openOverlayBase(kind);
}

export function openCommand() {
  if (S.hubState.open) closeHub();
  openCommandBase();
}

export function handleTitlebarDrag(event) {
  if (event.button !== 0) return;
  if (!event.target.closest(".titlebar")) return;
  if (event.target.closest("button, input, a")) return;
  cmd("dragWindow");
}

export function trackModelHover(event) {
  const target = event.target;
  const card = target && typeof target.closest === "function"
    ? target.closest(".fc-model-card[data-model-name]")
    : null;
  if (!card) return;
  if (event.type === "pointerout") {
    const next = event.relatedTarget;
    if (next && card.contains(next)) return;
    if (S.modelHoverName !== card.dataset.modelName) return;
    S.modelHoverName = "";
    card.classList.remove("is-hovered");
    return;
  }
  const name = card.dataset.modelName || "";
  if (!name || name === S.modelHoverName) return;
  S.modelHoverName = name;
  qa(".fc-model-card.is-hovered").forEach((node) => {
    if (node !== card) node.classList.remove("is-hovered");
  });
  card.classList.add("is-hovered");
}

// 指针换了地方就清掉：卡片被移除时不会补发 pointerout，键盘切页也会留下
// 一个「其实没在悬停」的旧名字。指针每次移动都校验一次最便宜。
export function trackModelHoverMove(event) {
  if (!S.modelHoverName) return;
  const target = event.target;
  const card = target && typeof target.closest === "function"
    ? target.closest(".fc-model-card[data-model-name]")
    : null;
  if (card && card.dataset.modelName === S.modelHoverName) return;
  clearModelHover();
}

export function openHub() {
  closeOverlays({ immediate: true, restoreFocus: false });
  S.hubState.open = true;
  S.hubState.view = "list";
  S.hubState.tab = "card";
  S.hubState.detailRepo = "";
  const hub = hubSnapshot();
  S.hubState.query = String(hub.query || "");
  let node = q("#fcHub");
  if (!node) {
    node = document.createElement("section");
    node.id = "fcHub";
    node.className = "fc-hub glass-sheet";
    node.setAttribute("role", "dialog");
    node.setAttribute("aria-label", "模型广场");
    // Keep the hub outside #overlayLayer: in WKWebView a fixed sheet inside
    // that visibility/pointer-events layer remained visible but every click
    // landed on the page behind it. A body-level fixed panel is hit-tested
    // normally and still paints above the window UI.
    document.body.appendChild(node);
  }
  let dim = q("#fcHubDim");
  if (!dim) {
    dim = document.createElement("div");
    dim.id = "fcHubDim";
    dim.className = "fc-hub-dim";
    dim.setAttribute("data-hub-close", "");
    document.body.insertBefore(dim, node);
  }
  dim.classList.add("is-open");
  node.classList.add("is-open");
  S.hubSignature = "";
  renderHub(true);
  // The plaza opens on the Hub's trending list, like the README promises.
  // An empty sheet waiting for a keyword is a dead end, and the last query
  // is kept when the user reopens it.
  if (!hub.query && !(hub.results || []).length && !hub.loading) {
    hubSearch("", "trending", "all", 0);
  }
  requestAnimationFrame(() => q("#hubQuery")?.focus());
}

export function closeHub() {
  S.hubState.open = false;
  S.hubState.view = "list";
  S.hubState.tab = "card";
  S.hubState.detailRepo = "";
  const node = q("#fcHub");
  if (node) node.classList.remove("is-open");
  q("#fcHubDim")?.remove();
  refreshOverlayLayer();
  // The card is a transient lookup; the list survives so reopening the plaza
  // is instant, and the query stays in the box.
  cmd("closeHubDetail");
  requestAnimationFrame(() => q('[data-action="open-hub"]')?.focus());
}

export function closeHubDetail() {
  S.hubState.view = "list";
  S.hubState.tab = "card";
  S.hubState.detailRepo = "";
  cmd("closeHubDetail");
  renderHub(true);
  requestAnimationFrame(() => q("#hubQuery")?.focus());
}

/// Send one search to Swift. `query` left undefined means "what is in the
/// box right now"; sort/filter/page left undefined keep the current ones.
export function hubSearch(query, sort, filter, page) {
  const hub = hubSnapshot();
  const input = q("#hubQuery");
  const value = query == null
    ? (input ? input.value : (S.hubState.query || ""))
    : String(query);
  S.hubState.query = String(value || "").trim();
  S.hubState.view = "list";
  S.hubState.tab = "card";
  S.hubState.detailRepo = "";
  cmd("searchHub", {
    query: S.hubState.query,
    sort: sort || hub.sort || "trending",
    filter: filter || hub.filter || "all",
    page: Math.max(0, Number(page) || 0),
  });
}

export function openHubDetail(repo) {
  if (!repo) return;
  S.hubState.view = "detail";
  S.hubState.tab = "card";
  S.hubState.detailRepo = repo;
  renderHub(true);
  cmd("hubDetail", { repo });
}

export function downloadHubModel(element) {
  const repo = element.dataset.hubRepo || "";
  if (!repo) return;
  if (hubLocally(repo)) {
    showToast("这个仓库已经在本机了");
    return;
  }
  // Weights go to the shared folder once, then the engine that owns the
  // format gets the visibility grant. A repository no engine claims still
  // downloads — the row says so, and the model page's share sheet can add
  // more engines afterwards.
  const browsed = (S.snap && S.snap.library && S.snap.library.engine) || activeEngineRaw();
  const recommended = element.dataset.hubEngine || "";
  const engines = recommended && recommended !== "none" ? [recommended] : [browsed];
  cmd("downloadRepo", { repo, engines });
  showToast(`开始下载 ${displayModel(repo)}`);
}


// ---------- downloads ----------
export function openDownloads() {
  closeOverlays({ immediate: true, restoreFocus: false });
  openOverlay("downloads");
  renderDownloads(true);
}

// ---------- inspector ----------
export function openInspector() {
  closeOverlays({ immediate: true, restoreFocus: false });
  openOverlay("inspector");
  const params = state.params || {};
  const settings = state.settings || {};
  const efforts = settings.reasoningEfforts || [];
  const maxTokens = Number(params.tokens || 0);
  q("#inspector").innerHTML = `
    <div class="inspector-grabber" aria-hidden="true"></div>
    <header class="inspector-head">
      <div><span class="eyebrow">CHAT PARAMETERS</span><h2 id="inspectorTitle">生成参数</h2></div>
      <button class="glass-icon-btn small" type="button" data-close-inspector aria-label="关闭参数面板">${icon("x", 14)}</button>
    </header>
    <div class="inspector-body">
      ${rangeRow("temperature", "温度", params.temperature, 0, 2, 0.05, "精确", "发散")}
      ${rangeRow("topP", "Top P", params.topP, 0, 1, 0.01, "聚焦", "多样")}
      <div class="param-row">
        <div class="param-head"><span>最大输出</span><b data-range-value="tokens">${maxTokens ? maxTokens : "最大上下文"}</b></div>
        <input class="range-input" type="range" min="512" max="32768" step="512"
               value="${Math.min(32768, Math.max(512, maxTokens || 8192))}" data-param="tokens" aria-label="最大输出">
        <div class="param-hint"><span>512</span><span>32768</span></div>
      </div>
      <div class="param-row">
        <div class="param-head"><span>思考模式</span><b>${esc(settings.thinking || "自动")}</b></div>
        <div class="settings-segmented think-segment sliding-segments" data-thinking-choice data-sliding-segments>
          <span class="segment-slider" aria-hidden="true"></span>
          ${["自动", "关闭", "开启"].map((choice) => `<button type="button" class="${settings.thinking === choice ? "active" : ""}" data-thinking="${choice}">${choice}</button>`).join("")}
        </div>
      </div>
      ${efforts.length ? `<div class="param-row">
        <div class="param-head"><span>思考等级</span><b>${esc(settings.reasoningEffortLabel || "")}</b></div>
        <div class="settings-segmented sliding-segments fc-effort-segment" data-effort-choice data-sliding-segments>
          <span class="segment-slider" aria-hidden="true"></span>
          ${efforts.map((effort) => `<button type="button" class="${settings.reasoningEffort === effort.value ? "active" : ""}" data-effort="${esc(effort.value)}">${esc(effort.label)}</button>`).join("")}
        </div>
      </div>` : ""}
    </div>
    <footer class="inspector-foot">
      <button class="button" type="button" data-action="reset-params">重置</button>
      <button class="button primary" type="button" data-action="save-params">应用</button>
    </footer>`;
  requestAnimationFrame(() => {
    qa(".range-input", q("#inspector")).forEach(updateRangeVisual);
    if (updateSlidingSegments) updateSlidingSegments();
  });
}

export function applyChatParams() {
  const params = state.params || {};
  const settings = state.settings || {};
  const payload = {
    temperature: Number(params.temperature),
    topP: Number(params.topP),
    maxTokens: Number(params.tokens || 0),
    thinking: settings.thinkingMode || tokenForThinking(settings.thinking),
    effort: settings.reasoningEffort,
  };
  cmd("saveSettings", payload);
  closeOverlays();
  showToast("生成参数已应用");
}

// ---------- model switcher ----------
export function openModelPopover(anchor) {
  if (q("#overlayLayer").classList.contains("model-open")) { closeOverlays(); return; }
  closeOverlays({ immediate: true, restoreFocus: false });
  // An engine can be installed with no weights yet (Strata on this machine,
  // for example). Keep its empty group out of the switcher instead of dropping
  // a bare header the user cannot act on.
  const menus = ((S.snap && S.snap.modelsMenu) || [])
    .map((group) => ({ ...group, models: (group.models || []).filter(Boolean) }))
    .filter((group) => group.models.length);
  const popover = q("#modelPopover");
  const switching = !!(S.snap && S.snap.engine && S.snap.engine.switching);
  if (!menus.length) {
    popover.innerHTML = `<div class="fc-model-menu-empty">已安装的引擎还没有可用模型<br><span>到「模型」页下载一档后再切换</span></div>`;
  } else {
    let index = 0;
    popover.innerHTML = menus.map((group) => {
      const engineName = nameEngineOf(group.engine);
      return `<div class="fc-model-menu-group">
        <div class="fc-model-menu-head">${esc(engineName)}</div>
        ${group.models.map((id) => {
          const current = group.engine === activeEngineRaw() && sameModel(id, state.model);
          const owner = modelOwner(id);
          const detail = [owner, engineName].filter(Boolean).join(" · ");
          return `<button class="model-option ${current ? "is-current" : ""}" style="--i:${index++}" type="button"
                    data-menu-model="${esc(id)}" data-menu-engine="${esc(group.engine)}"
                    title="${esc(fullModelName(id))}" ${current ? 'aria-current="true"' : ""}>
            ${FCModelBrand
              ? FCModelBrand.tile(id, { size: 15, className: "model-option-icon fc-series-tile" })
              : `<span class="model-option-icon">${icon(current ? "check" : "brain", 14)}</span>`}
            <span class="model-option-copy"><strong>${esc(displayModel(id))}</strong><span>${esc(detail)}</span></span>
            ${current ? `<span class="model-option-check">${icon("check", 14)}</span>` : ""}
          </button>`;
        }).join("")}
      </div>`;
    }).join("");
    if (switching) {
      popover.querySelectorAll(".model-option.is-current").forEach((row) => {
        row.insertAdjacentHTML("beforeend", `<span class="model-option-state">切换中</span>`);
      });
    }
  }
  // The switcher only lists weights already on disk. Keep a path to the model
  // page for the other case: the pack the reader wants is not downloaded yet.
  popover.insertAdjacentHTML("beforeend", `<div class="fc-model-menu-foot">
    <button class="model-option fc-model-menu-manage" type="button" data-action="open-models">
      <span class="model-option-icon">${icon("layers", 14)}</span>
      <span class="model-option-copy"><strong>管理模型…</strong><span>下载更多权重或清理本机模型</span></span>
    </button>
  </div>`);
  openOverlay("model");
  if (FCOverlayBounds) {
    FCOverlayBounds.place(anchor || document.body, popover, {
      boundary: ".window",
      preferredSide: "bottom",
      align: "start",
      gap: 8,
      padding: 14,
      width: 330,
      maxHeight: 440,
      scroll: true,
      flip: true,
      clamp: true,
    });
  }
  // The list is taller than the panel on a full shelf. Open it on the active
  // model instead of at the top, otherwise the check mark (and the "切换中"
  // badge during a switch) sits below the fold.
  requestAnimationFrame(() => {
    const current = popover.querySelector(".model-option.is-current");
    if (!current || popover.scrollHeight <= popover.clientHeight + 1) return;
    const top = current.offsetTop;
    const bottom = top + current.offsetHeight;
    if (top < popover.scrollTop) {
      popover.scrollTop = Math.max(0, top - 6);
    } else if (bottom > popover.scrollTop + popover.clientHeight) {
      popover.scrollTop = bottom - popover.clientHeight + 6;
    }
  });
}

export function openChatMenu(anchor) {
  openActionMenu(anchor, [
    { label: "新对话", detail: "保留当前历史，开一段新的", icon: "messagePlus", run: () => cmd("newChat") },
    { label: "复制整段对话", detail: "按「你 / AI」分段复制", icon: "copy", run: () => cmd("copyConversation") },
    { label: "清空当前对话", detail: "历史里仍保留这一条", icon: "trash", run: () => cmd("clearChat") },
    { label: "下载中心", detail: "查看模型下载进度", icon: "download", run: () => openDownloads() },
  ]);
}

export function openModelMoreMenu(anchor, name) {
  const model = state.modelIndex && state.modelIndex.get(name);
  if (!model) return;
  const items = [
    { label: "在 Finder 中显示", detail: "定位到权重目录", icon: "folderOpen", run: () => cmd("revealModel", { engine: model.engineId, id: name }) },
    { label: "复制模型 ID", detail: name, icon: "copy", run: () => cmd("copyText", { text: name, label: "模型 ID 已复制" }) },
  ];
  if (model.entry && model.entry.shared) {
    items.push({ label: "放到哪些引擎…", detail: "共享目录的可见性", icon: "layers", run: () => openShareEngines(model) });
  }
  items.push({ label: "删除模型…", detail: "会删除权重文件，无法恢复", icon: "trash", run: () => cmd("removeModel", { engine: model.engineId, id: name }) });
  openActionMenu(anchor, items);
}

export function openShareEngines(model) {
  const entry = model.entry || {};
  const engines = rawEngineIds();
  const stateMap = Object.fromEntries(engines.map((id) => [id, (entry.engines || []).includes(id)]));
  const node = document.createElement("div");
  node.className = "fc-scrim";
  node.id = "fcShare";
  node.innerHTML = `<div class="fc-modal glass-sheet" role="dialog" aria-modal="true">
    <span class="eyebrow">MODEL SHARING</span>
    <h2>${esc(displayModel(model.name))} 给哪些引擎用</h2>
    <p>公共目录里的权重只有一份。勾选的引擎会在自己的模型目录里看到它；取消勾选只收回可见性，不删文件。</p>
    <div class="fc-share-engines">
      ${engines.map((id) => `<button type="button" class="fc-share-engine ${stateMap[id] ? "on" : ""}" data-share-engine="${esc(id)}">
        ${icon(stateMap[id] ? "check" : "cpu", 12)}<span>${esc(nameEngineOf(id))}</span>
      </button>`).join("")}
    </div>
    <footer>
      <button class="button quiet" type="button" data-share-cancel>${icon("x", 13)}<span>取消</span></button>
      <button class="button primary" type="button" data-share-save="${esc((entry.repo || model.name).split(":")[0])}">${icon("check", 13)}<span>保存</span></button>
    </footer>
  </div>`;
  document.body.appendChild(node);
  stashModalFocus();
  node.querySelector("button")?.focus({ preventScroll: true }); // 焦点入口，Tab 循环见 store.js
  const closeShare = () => {
    node.remove();
    restoreModalFocus();
  };
  node.addEventListener("click", (event) => {
    const toggle = event.target.closest("[data-share-engine]");
    if (toggle) {
      toggle.classList.toggle("on");
      toggle.innerHTML = `${icon(toggle.classList.contains("on") ? "check" : "cpu", 12)}<span>${esc(nameEngineOf(toggle.dataset.shareEngine))}</span>`;
      return;
    }
    if (event.target.closest("[data-share-cancel]")) {
      closeShare();
      return;
    }
    const save = event.target.closest("[data-share-save]");
    if (save) {
      const chosen = qa("[data-share-engine].on", node).map((item) => item.dataset.shareEngine);
      cmd("setModelEngines", { repo: save.dataset.shareSave, engines: chosen });
      closeShare();
    }
  });
}

export function openActionMenu(anchor, items) {
  if (q("#overlayLayer").classList.contains("model-open")) { closeOverlays(); return; }
  closeOverlays({ immediate: true, restoreFocus: false });
  const popover = q("#modelPopover");
  popover.innerHTML = items.map((item, index) => `
    <button class="model-option" style="--i:${index}" type="button" data-menu-action="${index}">
      <span class="model-option-icon">${icon(item.icon, 14)}</span>
      <span class="model-option-copy"><strong>${esc(item.label)}</strong><span>${esc(item.detail || "")}</span></span>
    </button>`).join("");
  popover.__items = items;
  openOverlay("model");
  if (FCOverlayBounds) {
    FCOverlayBounds.place(anchor || document.body, popover, {
      boundary: ".window", preferredSide: "bottom", align: "start", gap: 8, padding: 14,
      width: 300, maxHeight: 400, scroll: true, flip: true, clamp: true,
    });
  }
}

// ---------- actions ----------
export function liveHandleAction(action, element) {
  switch (action) {
    case "refresh-overview":
      tick();
      showToast("状态已刷新");
      break;
    case "request-detail": {
      const id = element && element.dataset ? element.dataset.sessionId : "";
      const session = ((S.snap && S.snap.sessions) || []).find((item) => String(item.id) === String(id));
      if (!session) {
        showToast("这条请求已经结束");
        break;
      }
      const stateText = session.state === "decode" ? "解码中"
        : session.state === "prefill" ? "预填充"
          : session.state === "failed" ? "失败" : "完成";
      showToast(`${session.dialect === "claude" ? "Claude" : "OpenAI"} #${session.id} · ${stateText} · ` +
        `${requestRate(session)} tok/s · ${Number(session.completionTokens || 0)} tokens`);
      break;
    }
    case "toggle-engine":
      toggleEngine();
      break;
    case "model-menu":
      openModelPopover(element);
      break;
    case "open-models":
      closeOverlays();
      navigate("models");
      break;
    case "open-inspector":
      openInspector();
      break;
    case "engine-config":
      openEngineConfigFromAnywhere(element);
      break;
    case "downloads":
      openDownloads();
      break;
    case "send-chat":
      sendChat();
      break;
    case "regenerate":
      cmd("regenerate");
      break;
    case "open-log-file":
      cmd("openFinder", { kind: "logs" });
      break;
    case "toggle-reasoning": {
      const block = element.closest("[data-think]");
      if (!block) break;
      if (FCChatStream) FCChatStream.toggleThinking(block);
      else {
        const open = block.classList.toggle("is-open");
        element.setAttribute("aria-expanded", String(open));
      }
      break;
    }
    case "chat-more":
      openChatMenu(element);
      break;
    case "new-chat":
      cmd("newChat");
      break;
    case "thinking-cycle":
      cycleThinking();
      break;
    case "search-hub":
    case "open-hub":
      openHub();
      break;
    case "hub-search":
      hubSearch();
      break;
    case "hub-sort":
      hubSearch(S.hubState.query, element.dataset.hubSort, undefined, 0);
      break;
    case "hub-filter":
      hubSearch(S.hubState.query, undefined, element.dataset.hubFilter, 0);
      break;
    case "hub-page":
      hubSearch(S.hubState.query, undefined, undefined, Number(element.dataset.hubPage));
      break;
    case "hub-open":
      openHubDetail(element.dataset.hubRepo);
      break;
    case "hub-back":
      closeHubDetail();
      break;
    case "hub-tab":
      S.hubState.tab = element.dataset.hubTab || "card";
      renderHub(true);
      break;
    case "hub-link": {
      const repo = element.dataset.hubRepo || (hubSnapshot().detail || {}).id;
      if (repo) cmd("openURL", { url: `https://huggingface.co/${repo}` });
      break;
    }
    case "hub-download":
      downloadHubModel(element);
      break;
    case "refresh-models":
      cmd("rescan", { engine: activeEngineRaw() });
      showToast("正在重新扫描模型目录");
      break;
    case "refresh-engines":
    case "check-updates":
      cmd("nav", { page: "engines" });
      showToast("正在检查引擎版本");
      break;
    case "use-model":
      cmd("useModel", { engine: activeEngineRaw(), id: state.model });
      break;
    case "model-detail":
    case "model-more":
      openModelPopover(element);
      break;
    case "toggle-log-pause":
      state.logPaused = !state.logPaused;
      render();
      S.lastKey = fingerprint();
      showToast(state.logPaused ? "日志已暂停跟随" : "日志已恢复实时跟随");
      break;
    case "clear-logs":
      cmd("clearLogs");
      break;
    case "log-copy":
      copyVisibleLogs();
      break;
    case "reset-settings":
      resetSettings();
      break;
    case "reset-params":
      state.params = { temperature: 0.7, topP: 0.95, tokens: 0, thinking: state.settings.thinking };
      openInspector();
      break;
    case "save-params":
      applyChatParams();
      break;
    case "recommend-install":
      cmd("recommendInstall", { engine: element.dataset.engine });
      break;
    case "skip-recommendation":
      cmd("skipRecommendation");
      break;
    case "install-engine":
      cmd("installEngine", { engine: element.dataset.engine, launch: element.dataset.launch === "1" });
      break;
    case "finish-launch":
      cmd("finishLaunch");
      break;
    case "open-launch":
      cmd("openLaunchPage");
      break;
    case "open-finder-logs":
      cmd("openFinder", { kind: "logs" });
      break;
    default:
      break;
  }
}

export function toggleEngine(engineId) {
  const name = engineId || state.engine;
  const raw = rawEngineOf(name);
  if (name === state.engine) {
    if (state.engineBusy) return;
    if (isRunning()) cmd("stopService");
    else cmd("startService");
    state.engineBusy = true;
    updateChrome();
    return;
  }
  cmd("switchEngine", { engine: raw });
  showToast(`正在切换到 ${name}`);
}

export function sendChat() {
  if (state.chatStreaming) {
    cmd("stopGeneration");
    return;
  }
  const input = q("#chatInput");
  const text = input && input.value ? input.value.trim() : "";
  if (!text) return;
  if (!isRunning()) {
    showToast("请先启动推理引擎", "error");
    return;
  }
  cmd("sendChat", { text });
  if (input) {
    input.value = "";
    input.style.height = "46px";
  }
  state.chatStreaming = true;
  const send = q("#sendButton");
  if (send) send.innerHTML = icon("stop", 14);
}

export function stopChatStream() {
  cmd("stopGeneration");
}

export function startChatDownload(name) {
  const model = state.modelIndex && state.modelIndex.get(name);
  const engine = model ? model.engineId : activeEngineRaw();
  cmd("downloadModel", { engine, id: name });
  showToast(`开始下载 ${displayModel(name)}`);
}

export function selectModel(name) {
  const model = state.modelIndex && state.modelIndex.get(name);
  if (model) {
    cmd("useModel", { engine: model.engineId, id: name });
  } else {
    cmd("useModel", { engine: activeEngineRaw(), id: name });
  }
  closeOverlays();
}

export function toggleSetting(key) {
  const settings = state.settings;
  if (key === "login") {
    settings.login = !settings.login;
    cmd("saveSettings", { launchAtLogin: settings.login });
  } else if (key === "launchEngine") {
    settings.launchEngine = !settings.launchEngine;
    cmd("saveSettings", { autoStart: settings.launchEngine });
  } else if (key === "gateway") {
    settings.gateway = !settings.gateway;
    cmd("setGatewayEnabled", { on: settings.gateway });
    showToast(`API 网关已${settings.gateway ? "开启" : "关闭"}`);
  }
  qa(`[data-setting-toggle="${key}"]`).forEach((button) => {
    const on = key === "gateway" ? settings.gateway : key === "login" ? settings.login : settings.launchEngine;
    button.classList.toggle("on", !!on);
    button.setAttribute("aria-checked", String(!!on));
  });
}

export function cycleThinking() {
  const order = ["automatic", "off", "on"];
  const current = state.settings.thinkingMode || "automatic";
  const next = order[(order.indexOf(current) + 1) % order.length];
  state.settings.thinkingMode = next;
  state.settings.thinking = next === "on" ? "开启" : next === "off" ? "关闭" : "自动";
  state.params.thinking = state.settings.thinking;
  cmd("saveSettings", { thinking: next });
  showToast(`思考模式 · ${state.settings.thinking}`);
  if (state.page === "chat" || state.page === "settings") render();
}

export function saveEngineConfig() {
  const id = state.engineConfigOpen;
  const draft = state.engineConfigDraft;
  if (!id || !draft) return;
  const panel = q(".fc-engine-panel");
  if (panel) {
    qa("[data-cfg], [data-fc-engine-field]", panel).forEach((input) => {
      const key = input.dataset.cfg || input.dataset.fcEngineField;
      if (!key) return;
      let value = input.value;
      if (input.type === "number") {
        if (value === "") value = null;
        else value = Number(value);
      }
      if (key === "port") draft.port = input.value;
      else draft.tuning[key] = value;
    });
  }
  const tuning = Object.assign({}, draft.tuning);
  Object.keys(tuning).forEach((key) => {
    if (tuning[key] === "" || tuning[key] === undefined) delete tuning[key];
  });
  cmd("saveEngineConfig", { engine: rawEngineOf(id), tuning, port: String(draft.port || "") });
  closeEngineConfig();
}

export function runEngineInstall(id, kind) {
  cmd("installEngine", { engine: rawEngineOf(id), launch: false });
  showToast(kind === "update" ? `正在更新 ${id}` : `正在下载 ${id}`);
}

export function removeEngineRuntime(id) {
  cmd("removeEngine", { engine: rawEngineOf(id) });
}

export function resetSettings() {
  cmd("saveSettings", {
    autoStart: false,
    launchAtLogin: false,
    hfCache: "",
    thinking: "automatic",
    effort: "medium",
    temperature: 0.7,
    topP: 0.95,
    maxTokens: 0,
  });
  cmd("setGatewayEnabled", { on: true });
  cmd("setGatewayPort", { port: 9000 });
  cmd("appearance", { mode: "system" });
  showToast("设置已恢复为默认值");
}

export function copyVisibleLogs() {
  const text = qa(".log-line:not(.hidden) .msg").map((node) => node.textContent).join("\n");
  if (text) cmd("copyLogText", { text });
}

export function openEngineConfigFromAnywhere(element) {
  const name = (element && element.dataset && (element.dataset.engineConfig || element.dataset.engineView)) || state.engine;
  if (state.page !== "engines") {
    state.page = "engines";
    state.activeEngineView = name;
    syncNavActive();
    render(true);
    cmd("nav", { page: "engines" });
  }
  requestAnimationFrame(() => openEngineConfig(name));
}

export function commands() {
  return [
    ...NAV_ITEMS.map((item) => ({
      label: `打开${item.label}`,
      detail: item.hint,
      icon: item.icon,
      shortcut: `⌘${item.shortcut}`,
      run: () => navigate(item.id),
    })),
    {
      label: state.engineRunning ? "停止推理引擎" : "启动推理引擎",
      detail: `${state.engine} · ${isRunning() ? "运行中" : "已停止"}`,
      icon: state.engineRunning ? "stop" : "play",
      shortcut: "",
      run: () => toggleEngine(),
    },
    {
      label: "新对话",
      detail: "开一段新的本地会话",
      icon: "messagePlus",
      shortcut: "⌘N",
      run: () => cmd("newChat"),
    },
    {
      label: "打开生成参数",
      detail: "温度、Top P 与最大输出",
      icon: "sliders",
      shortcut: "",
      run: () => openInspector(),
    },
    {
      label: "打开下载中心",
      detail: "查看模型下载进度",
      icon: "download",
      shortcut: "",
      run: () => openDownloads(),
    },
    {
      label: "模型广场",
      detail: "搜索 Hugging Face 并下载",
      icon: "search",
      shortcut: "",
      run: () => openHub(),
    },
    {
      label: "切换外观",
      detail: `当前：${resolvedTheme() === "dark" ? "深色" : "浅色"}`,
      icon: resolvedTheme() === "dark" ? "sun" : "moon",
      shortcut: "⌘⇧A",
      run: () => setTheme(resolvedTheme() === "dark" ? "light" : "dark"),
    },
    {
      label: "折叠边栏",
      detail: "切换图标导航模式",
      icon: "panelLeft",
      shortcut: "⌘\\",
      run: () => toggleSidebar(),
    },
  ];
}

// ---------- events ----------
export function handleLiveClick(event) {
  if (state.currentOverlay === "model" &&
      !event.target.closest("#modelPopover") &&
      !event.target.closest("[data-action='model-menu']") &&
      !event.target.closest("[data-model-more]") &&
      !event.target.closest("[data-select-model]")) {
    closeOverlays();
  }
  const thread = event.target.closest("[data-thread]");
  if (thread) {
    event.preventDefault();
    openThread(thread.dataset.thread);
    return;
  }

  const suggestion = event.target.closest("[data-suggest]");
  if (suggestion) {
    const input = q("#chatInput");
    if (input) {
      input.value = suggestion.dataset.suggest;
      autosize(input);
      input.focus();
    }
    return;
  }

  const pending = event.target.closest("[data-pending]");
  if (pending) {
    event.preventDefault();
    const map = {
      "cancel-use": "cancelLibraryUse",
      "confirm-use": "confirmLibraryUse",
      "cancel-switch": "cancelModelSwitch",
      "confirm-switch": "confirmModelSwitch",
      "cancel-install": "cancelEngineInstall",
      "confirm-install": "confirmEngineInstall",
    };
    const type = map[pending.dataset.pending];
    if (type) cmd(type);
    return;
  }

  const download = event.target.closest("[data-dl]");
  if (download) {
    event.preventDefault();
    const action = download.dataset.dl;
    const payload = { engine: download.dataset.engine, model: download.dataset.model };
    if (action === "pause") cmd("pauseDownload");
    else if (action === "resume") cmd("resumeDownload", payload);
    else if (action === "cancel") cmd("cancelDownload", payload);
    return;
  }

  const modelMore = event.target.closest("[data-model-more]");
  if (modelMore) {
    event.preventDefault();
    event.stopPropagation();
    openModelMoreMenu(modelMore, modelMore.dataset.modelMore);
    return;
  }

  const menuModel = event.target.closest("[data-menu-model]");
  if (menuModel) {
    event.preventDefault();
    cmd("useModel", { engine: menuModel.dataset.menuEngine, id: menuModel.dataset.menuModel });
    closeOverlays();
    return;
  }

  const menuAction = event.target.closest("[data-menu-action]");
  if (menuAction) {
    event.preventDefault();
    const items = q("#modelPopover").__items || [];
    const item = items[Number(menuAction.dataset.menuAction)];
    closeOverlays();
    if (item && item.run) setTimeout(item.run, 40);
    return;
  }

  if (event.target.closest("[data-hub-close]")) {
    event.preventDefault();
    closeHub();
    return;
  }

  const finder = event.target.closest("[data-finder]");
  if (finder) {
    event.preventDefault();
    event.stopPropagation();
    const [kind, id] = String(finder.dataset.finder || "").split("|");
    cmd("openFinder", { kind, engine: id ? rawEngineOf(id) : activeEngineRaw() });
    return;
  }

  const thinking = event.target.closest("[data-thinking]");
  if (thinking) {
    event.preventDefault();
    event.stopPropagation();
    const label = thinking.dataset.thinking;
    const token = tokenForThinking(label);
    state.settings.thinking = label;
    state.settings.thinkingMode = token;
    state.params.thinking = label;
    cmd("saveSettings", { thinking: token });
    updateChoiceUI();
    return;
  }

  const effort = event.target.closest("[data-effort]");
  if (effort) {
    event.preventDefault();
    event.stopPropagation();
    const value = effort.dataset.effort;
    state.settings.reasoningEffort = value;
    cmd("setEffort", { effort: value });
    updateChoiceUI();
    return;
  }

  const thinkingChoice = event.target.closest("[data-fc-thinking-kind]");
  if (thinkingChoice) {
    event.preventDefault();
    event.stopPropagation();
    const kind = thinkingChoice.dataset.fcThinkingKind;
    const value = thinkingChoice.dataset.fcThinkingValue;
    if (kind === "mode") {
      state.settings.thinkingMode = value;
      state.settings.thinking = value === "on" ? "开启" : value === "off" ? "关闭" : "自动";
      cmd("saveSettings", { thinking: value });
    } else if (kind === "effort") {
      state.settings.reasoningEffort = value;
      cmd("setEffort", { effort: value });
    }
    if (FCChatThinking) {
      FCChatThinking.update(state);
      if (!(kind === "mode" && value === "on")) FCChatThinking.close();
    }
    updateChoiceUI();
    return;
  }
}

export function handleLiveInput(event) {
  if (event.target.id === "hubQuery") {
    S.hubState.query = event.target.value;
    return;
  }
  if (event.target.id === "chatInput") {
    autosize(event.target);
    const button = q("#sendButton");
    if (button) button.disabled = !event.target.value.trim() && !state.chatStreaming;
  }
}

export function handleLiveChange(event) {
  const target = event.target;
  if (target.matches("[data-gateway-port]")) {
    const port = parseInt(target.value, 10);
    if (Number.isFinite(port) && port >= 1024 && port <= 65535) {
      cmd("setGatewayPort", { port });
    } else {
      target.value = String(state.settings.gatewayPort || "");
      showToast("端口需在 1024–65535 之间", "error");
    }
    return;
  }
  if (target.matches("[data-port-engine]")) {
    const raw = target.dataset.portEngine;
    const port = parseInt(target.value, 10);
    if (Number.isFinite(port) && port >= 1024 && port <= 65535) {
      cmd("saveSettings", { ports: { [raw]: String(port) } });
    } else {
      target.value = String((state.settings.ports || {})[raw] || "");
      showToast("端口需在 1024–65535 之间", "error");
    }
    return;
  }
  if (target.matches("[data-hf-cache]")) {
    cmd("saveSettings", { hfCache: target.value.trim() });
  }
}

export function handleLiveKeydown(event) {
  const meta = event.metaKey || event.ctrlKey;
  if (meta && event.key.toLowerCase() === "k") {
    event.preventDefault();
    openCommand();
    return;
  }
  if (meta && event.key.toLowerCase() === "n") {
    event.preventDefault();
    cmd("newChat");
    return;
  }
  if (event.key === "Escape" && S.hubState.open) {
    event.preventDefault();
    if (S.hubState.view === "detail") closeHubDetail();
    else closeHub();
    return;
  }
  if (event.target.id === "hubQuery" && event.key === "Enter") {
    event.preventDefault();
    hubSearch(event.target.value);
    return;
  }
  if (event.target.id === "chatInput" && event.key === "Enter" && !event.shiftKey) {
    event.preventDefault();
    event.stopPropagation();
    sendChat();
    return;
  }
  // 合成键盘事件可能派发到 document（target 不是 Element），先验类型再查选择器。
  if (event.target instanceof Element && event.target.matches("[data-gateway-port], [data-port-engine], [data-hf-cache]") && event.key === "Enter") {
    event.preventDefault();
    event.target.blur();
  }
}


// ---------- app.js 的活体实现（经 import 暴露，不再走 window）----------
export function renderCommandResults(query) {
  const all = commands();
  const text = query.trim().toLowerCase();
  state.commandItems = all.filter((item) => !text || `${item.label} ${item.detail}`.toLowerCase().includes(text));
  state.commandIndex = Math.min(state.commandIndex, Math.max(0, state.commandItems.length - 1));
  q("#commandResults").innerHTML = state.commandItems.length ? state.commandItems.map((item, index) => `
    <button class="command-item ${index === state.commandIndex ? "selected" : ""}" type="button" data-command-index="${index}">
      <span class="command-item-icon">${icon(item.icon, 13)}</span>
      <span class="command-item-copy"><strong>${esc(item.label)}</strong><span>${esc(item.detail || "")}</span></span>
      ${item.shortcut ? `<kbd>${esc(item.shortcut)}</kbd>` : ""}
    </button>`).join("") : `<div class="fc-command-empty">没有匹配的命令</div>`;
  q("#commandHint").textContent = `${state.commandItems.length} 个命令`;
}


// WKWebView on file:// is not a secure context, so the preview's clipboard
// helper can silently fail there. Route copies through Swift's NSPasteboard.
export function copyText(text) {
  cmd("copyText", { text: String(text == null ? "" : text), label: "已复制到剪贴板" });
}
