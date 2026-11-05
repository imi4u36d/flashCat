import { esc } from "./esc.js";
import { FCIcons } from "./icons.js";
import { FCModelWorkspace } from "./model-workspace.js";
import { FCSegments } from "./segments.js";
import { FCOverlayBounds } from "./overlay-bounds.js";
import { FCMotionGuard } from "./motion-guard.js";
import { FCChatThinking } from "./chat-thinking.js";
import {
  FC_LIVE, closeOverlays, openOverlay, openCommand, copyText, drawFlowField, handleAction,
  navigate, openDownloads, renderCommandResults, renderPage, runEngineInstall,
  removeEngineRuntime, saveEngineConfig,
  selectModel, sendChat, setTheme, startChatDownload, toggleEngine, toggleSetting, toggleSidebar,
  updateFlowProbe,
} from "./live.js";

const $ = (selector, root = document) => root.querySelector(selector);
const $$ = (selector, root = document) => Array.from(root.querySelectorAll(selector));
export const icon = (name, size = 16, cls = "") => FCIcons.svg(name, cls, size);
export const NAV_ITEMS = [
  { id: "overview", label: "概览", hint: "状态与性能", icon: "dashboard", shortcut: "1" },
  { id: "chat", label: "对话", hint: "本地推理会话", icon: "message", shortcut: "2" },
  { id: "models", label: "模型", hint: "模型库与推荐", icon: "layers", shortcut: "3", badge: "3" },
  { id: "engines", label: "引擎", hint: "运行时管理", icon: "cpu", shortcut: "4" },
  { id: "logs", label: "日志", hint: "实时运行输出", icon: "scrollText", shortcut: "5" },
  { id: "settings", label: "设置", hint: "系统与外观", icon: "settings", shortcut: "6" },
];

export const MODELS = [
  {
    name: "Qwen3.8-Flash-Next-GSQ-RCO-GGUF",
    repo: "ISTA-DASLab / Qwen3.8-Flash-Next",
    engine: "Splash",
    format: "GGUF",
    size: "63.8 GB",
    memory: "64 GB 内存起",
    flags: ["DFlash2 加速", "MoE", "视觉", "256K"],
    installed: true,
  },
  {
    name: "Qwen3.8-27B-4bit",
    repo: "mlx-community / Qwen3.8-27B-4bit",
    engine: "oMLX",
    format: "MLX",
    size: "14.5 GB",
    memory: "24 GB 内存起",
    flags: ["热切换", "MoE", "思考"],
    installed: false,
  },
  {
    name: "Qwen3.6-35B-A3B-4bit",
    repo: "mlx-community / Qwen3.6-35B-A3B-4bit",
    engine: "oMLX",
    format: "MLX",
    size: "19.0 GB",
    memory: "32 GB 内存起",
    flags: ["4bit", "MoE", "长上下文"],
    installed: false,
  },
  {
    name: "MiMo-9B-MTPLX",
    repo: "youssofal / MiMo-9B-MTPLX",
    engine: "MTPLX",
    format: "MTPLX",
    size: "5.4 GB",
    memory: "16 GB 内存起",
    flags: ["低内存兜底", "多 token"],
    installed: false,
  },
  {
    name: "Qwen3.5-4B-Q4_K_M",
    repo: "bartowski / Qwen3.5-4B-GGUF",
    engine: "Splash",
    format: "GGUF",
    size: "2.6 GB",
    memory: "8 GB 内存起",
    flags: ["Q4_K_M", "轻量"],
    installed: false,
  },
  {
    name: "Strata-Serve-8B-MLX",
    repo: "flashcat / strata-serve-8b",
    engine: "MTPLX",
    format: "MTPLX",
    size: "7.8 GB",
    memory: "18 GB 内存起",
    flags: ["长上下文", "工具调用"],
    installed: false,
  },
];

const ENGINES = [
  {
    id: "Splash",
    glyph: "S",
    color: "#ff8b63",
    version: "1.5.0",
    latest: "1.6.0",
    installed: true,
    port: "8000",
    state: "running",
    description: "单模型、最省事，DFlash2 草稿加速",
    uptime: "00:54:18",
    pid: "95976",
  },
  {
    id: "oMLX",
    glyph: "O",
    color: "#65b9ff",
    version: "0.7.3rc1",
    latest: "0.7.3rc1",
    installed: true,
    port: "8100",
    state: "stopped",
    description: "多模型常驻，模型热切换不停进程",
    uptime: "—",
    pid: "—",
  },
  {
    id: "MTPLX",
    glyph: "M",
    color: "#ad8cff",
    version: "2.12.2",
    latest: "2.12.2",
    installed: false,
    port: "8200",
    state: "not-installed",
    description: "长上下文与多 token 预测",
    uptime: "—",
    pid: "—",
  },
];

const INITIAL_MESSAGES = [
  {
    id: "m1",
    role: "user",
    content: "用三句话介绍本地大模型的优势。",
  },
  {
    id: "m2",
    role: "assistant",
    content: "本地大模型把推理留在你的设备上，**数据不必离开这台 Mac**，隐私边界更清楚。\n\n- 不依赖云端网络，离线或弱网环境里依然能工作，首字响应更稳定。\n- 没有按 token 计费，长期高频使用时更容易控制成本。\n- 可以围绕自己的资料做定制，`system prompt` 与检索都在本机。\n\n> 代价是硬件投入与运维要自己承担——这也是它更适合固定工作流的原因。",
    reasoning: "用户要求用三句话介绍优势。回答应覆盖隐私、离线与响应、长期成本。保持精炼，不引入不相关的对比。",
    rate: "87.4",
    ttft: "601",
    tokens: "120",
    thinkingSeconds: 4.2,
  },
  {
    id: "m3",
    role: "user",
    content: "那它在隐私和成本上分别怎么权衡？分点说。",
  },
  {
    id: "m4",
    role: "assistant",
    content: "**隐私**\n\n数据可以在本地处理，适合敏感资料；代价是磁盘、权限与日志仍要自己管理。\n\n**成本**\n\n高频、离线、批量处理更划算；代价是前期硬件投入和后续维护。\n\n**结论**\n\n数据敏感且调用量大时更适合本地，低频或需要持续跟随新模型时云端仍更经济。",
    reasoning: "需要分别讨论隐私与成本，并给出平衡结论。保留短句和清晰分点。",
    rate: "100.6",
    ttft: "1688",
    tokens: "356",
    thinkingSeconds: 6.8,
  },
];

export const state = {
  page: "overview",
  theme: localStorage.getItem("fc-preview-theme") || "light",
  sidebarCollapsed: localStorage.getItem("fc-preview-sidebar") === "rail",
  sidebarWidth: Math.max(180, Math.min(320, Number(localStorage.getItem("fc-preview-sidebar-width")) || 200)),
  engineRunning: true,
  engineBusy: false,
  engine: "Splash",
  activeEngineView: "Splash",
  engineConfigOpen: null,
  engineConfigDraft: null,
  model: MODELS[0].name,
  chartRange: "45 秒",
  metricTick: 0,
  modelFilter: "全部",
  modelSearch: "",
  downloaded: new Set(),
  downloadsInFlight: new Map(),
  settings: {
    launchEngine: true,
    login: true,
    gateway: true,
    thinking: "自动",
    reasoningEffort: "medium",
    reasoningEffortLabel: "中",
    reasoningEfforts: [
      { value: "minimal", label: "最少" },
      { value: "low", label: "低" },
      { value: "medium", label: "中" },
      { value: "high", label: "高" },
      { value: "xhigh", label: "极高" },
      { value: "max", label: "最大" },
    ],
    appearance: localStorage.getItem("fc-preview-theme") || "light",
  },
  engines: JSON.parse(JSON.stringify(ENGINES)),
  chatMessages: JSON.parse(JSON.stringify(INITIAL_MESSAGES)),
  chatStreaming: false,
  logPaused: false,
  logFilter: "全部",
  logSearch: "",
  commandIndex: 0,
  commandItems: [],
  currentOverlay: "",
  params: {
    temperature: 0.7,
    topP: 0.92,
    tokens: 4096,
    thinking: "自动",
  },
};

let ambientAnimation = 0;
let pointerX = window.innerWidth * 0.5;
let pointerY = window.innerHeight * 0.28;
let logSequence = 0;
let flowAnimation = 0;
export let flowState = null;
let modelListAnimationToken = 0;
let overlayCloseToken = 0;
let overlayTrigger = null;

export const LOG_SEED = [
  { level: "INFO", msg: "Ready · ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF · context 262K · http://127.0.0.1:8000" },
  { level: "INFO", msg: "Long requests keep their KV on the SSD cache: 262144 tokens of context (bound: model; window 262144, resident 262144)." },
  { level: "INFO", msg: "Kernel policy for GPU family 10 with 40 cores." },
  { level: "INFO", msg: "SSD cache: up to 32.0 GiB of temporary files in /var/folders/qk/vwmf128x2m9bt6rj_knt8604000gn/T/" },
  { level: "INFO", msg: "Decode cycles verify the rows the verify budget chooses (--verify-rows auto)." },
  { level: "INFO", msg: "Routed experts load with their layers: memory holds their 32402 MiB (--expert-memory auto)." },
  { level: "INFO", msg: "The PLE table loads with the weights: memory holds its 27465 MiB (--ple-memory auto)." },
  { level: "INFO", msg: "Weights loaded in 7.68 s." },
  { level: "WARN", msg: "Output truncated: request touched the 4096 token generation ceiling; reasoning and answer share this budget." },
  { level: "INFO", msg: "Started · input 63 · cached 0 · output 120 · TTFT 0.1s · 95.5 tok/s · 2.1 tok/cycle" },
  { level: "INFO", msg: "Done · input 63 · cached 0 · output 120 · TTFT 0.1s · 87.4 tok/s · 2.1 tok/cycle" },
  { level: "ERROR", msg: "oMLX probe skipped: runtime is installed but the service is not running on :8100." },
  { level: "INFO", msg: "Gateway accepted POST /v1/chat/completions · OpenAI dialect · stream=true" },
  { level: "INFO", msg: "Gateway route resolved · splash:8000 · model Qwen3.8-Flash-Next-GSQ-RCO-GGUF" },
  { level: "INFO", msg: "Chat template patched to render later system messages in place." },
];

export function resolvedTheme() {
  if (state.theme === "system") {
    return window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
  }
  return state.theme;
}

export function renderToolbarIcons() {
  $("#downloadIcon").innerHTML = icon("download", 15);
  $("#commandIcon").innerHTML = icon("search", 18);
  updateThemeIcon();
}

export function updateThemeIcon() {
  $("#themeIcon").innerHTML = icon(resolvedTheme() === "dark" ? "sun" : "moon", 15);
  $("#themeToggle").setAttribute("aria-label", resolvedTheme() === "dark" ? "切换到浅色外观" : "切换到深色外观");
}

export function renderNav() {
  const nav = $("#primaryNav");
  nav.innerHTML = `<span class="nav-indicator" aria-hidden="true"></span>${NAV_ITEMS.map((item) => `
    <button type="button" class="nav-item ${state.page === item.id ? "active" : ""}"
            data-page="${item.id}" aria-current="${state.page === item.id ? "page" : "false"}"
            title="${esc(item.label)}（⌘${item.shortcut}）">
      <span class="nav-icon">${icon(item.icon, 18)}</span>
      <span class="nav-label">${esc(item.label)}</span>
      ${item.badge ? `<span class="nav-badge">${esc(item.badge)}</span>` : ""}
    </button>`).join("")}`;
  requestAnimationFrame(updateNavIndicator);
}

export function updateNavIndicator() {
  const indicator = $(".nav-indicator");
  const active = $(".nav-item.active");
  if (!indicator || !active) return;
  const y = active.offsetTop;
  indicator.style.setProperty("--nav-y", `${y}px`);
  indicator.style.height = `${active.offsetHeight}px`;
}


export function syncNavActive() {
  $$(".nav-item").forEach((item) => {
    const active = item.dataset.page === state.page;
    item.classList.toggle("active", active);
    item.setAttribute("aria-current", active ? "page" : "false");
  });
  requestAnimationFrame(updateNavIndicator);
}


function filteredModels() {
  return FCModelWorkspace.filterModels(MODELS, state);
}


function logTime(offset = 0) {
  const now = new Date(Date.now() - (logSequence - offset) * 1600);
  return now.toTimeString().slice(0, 8);
}

export function logCount(filter, lines) {
  if (filter === "全部") return lines.length;
  const target = filter === "提示" ? "INFO" : filter === "警告" ? "WARN" : "ERROR";
  return lines.filter((line) => line.level === target).length;
}

export function logLinesHtml(lines) {
  const filterLevel = state.logFilter === "提示" ? "INFO" : state.logFilter === "警告" ? "WARN" : state.logFilter === "错误" ? "ERROR" : "";
  // A snapshot can arrive while the engine is switching and a field can be
  // missing for one frame. Log rows are display-only: render a blank instead
  // of letting the whole logs page throw (which used to surface as an opaque
  // "Script error." under file://).
  const query = String(state.logSearch || "").toLowerCase();
  return (lines || []).map((line, index) => {
    const level = String((line && line.level) || "INFO").toUpperCase();
    const msg = line && line.msg != null ? String(line.msg) : "";
    const time = (line && line.time) || logTime(index);
    const matchesFilter = !filterLevel || level === filterLevel;
    const matchesSearch = !query || msg.toLowerCase().includes(query);
    const hidden = !matchesFilter || !matchesSearch;
    return `<div class="log-line ${hidden ? "hidden" : ""}" data-log-level="${level}" data-log-text="${esc(msg.toLowerCase())}">
      <span class="time">${esc(time)}</span>
      <span class="level ${level.toLowerCase()}">${esc(level)}</span>
      <span class="msg">${esc(msg)}</span>
    </div>`;
  }).join("");
}


function defaultEngineTuning(id) {
  if (id === "Splash") return { dflash: true, pleSSDOffload: true };
  if (id === "oMLX") return { mtp: true, dflash: false, pleSSDOffload: true };
  if (id === "MTPLX") return { loadMtp: true, mtp: true };
  return {};
}

// 引擎配置：面板从右侧推入，左栏同步收窄，两者共用一条时间线和一条曲线。
// 不能用页面级 view transition —— 那会把「旧的宽卡片」和「新的窄卡片」叠成两层字。
const ENGINE_SPLIT_MS = 360;
const ENGINE_SPLIT_EASE = "cubic-bezier(.2, .82, .18, 1)";
let engineSplitToken = 0;

// 面板要让出的宽度：直接读变量，不用读当前 padding —— 动画跑到一半时
// getComputedStyle 给的是插值中的值，拿它当目标会让关闭动画从半路起跳。
function engineSplitWidth(ws) {
  const cs = getComputedStyle(ws);
  const width = parseFloat(cs.getPropertyValue("--fc-panel-width")) || 440;
  const gap = parseFloat(cs.getPropertyValue("--fc-panel-gap")) || 12;
  return width + gap;
}

function animateEngineSplit(open) {
  const ws = $("[data-fc-engine-workspace]");
  if (!ws) return null;
  const panel = $(".fc-engine-panel", ws);
  if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return null;

  const target = engineSplitWidth(ws);
  const from = open ? 0 : (parseFloat(getComputedStyle(ws).paddingRight) || 0);
  const to = open ? target : 0;
  const duration = open ? ENGINE_SPLIT_MS : 280;
  const token = ++engineSplitToken;

  if (open) {
    // 先把「关着」的几何量压回第 0 帧；和插入同一帧，首次绘制就是起点，不会先闪一下全展开。
    ws.style.paddingRight = "0px";
    if (panel) {
      panel.style.transform = `translateX(${target}px)`;
      panel.style.opacity = "0";
    }
  }

  // 面板的位移始终等于「让位宽度 - 当前 padding」，任何一帧都不会盖到卡片上。
  const split = ws.animate(
    [{ paddingRight: `${from}px` }, { paddingRight: `${to}px` }],
    { duration, easing: ENGINE_SPLIT_EASE, fill: "forwards" }
  );

  if (panel) {
    panel.animate(
      [
        { transform: `translateX(${target - from}px)`, opacity: open ? 0 : 1 },
        { transform: `translateX(${target - to}px)`, opacity: open ? 1 : 0 },
      ],
      { duration, easing: ENGINE_SPLIT_EASE, fill: "forwards" }
    );
  }

  split.finished.catch(() => {}).then(() => {
    // 动画结束后把内联值交还给 CSS：之后窗口缩放、换面板都不会被定格。
    // 半路被打断（比如动画还没完就关掉）时不要清，交给最新那次动画收尾。
    if (token !== engineSplitToken) return;
    ws.style.paddingRight = "";
    if (panel) {
      panel.style.transform = "";
      panel.style.opacity = "";
    }
  });
  return split;
}

export function openEngineConfig(id) {
  const engine = state.engines.find((item) => item.id === id);
  if (!engine || engine.installed === false) return;
  const alreadyOpen = Boolean(state.engineConfigOpen);
  state.activeEngineView = id;
  state.engineConfigOpen = id;
  state.engineConfigDraft = {
    engine: id,
    port: String(engine.port || ""),
    tuning: Object.assign(defaultEngineTuning(id), engine.tuning || {}),
  };
  renderPage(true, { instant: true });
  // 已经开着就只是换一个引擎的面板，不需要再演一遍「推开左栏」。
  // 同步起动画：和插入同一帧，浏览器第一次绘制就已经是「关着」的起点，不会先闪一下全展开。
  if (!alreadyOpen) animateEngineSplit(true);
  pulseHaptic();
}

export function closeEngineConfig() {
  const panel = $(".fc-engine-panel");
  const finish = () => {
    state.engineConfigOpen = null;
    state.engineConfigDraft = null;
    // 收尾也用 instant：面板已经退干净了，再来一次页面淡入会像闪一下。
    renderPage(true, { instant: true });
  };
  const animation = animateEngineSplit(false);
  if (!panel || !animation) {
    finish();
    return;
  }
  // 等左栏收到位、面板退干净，再把 DOM 换掉；提前换会看到面板「啪」地消失。
  animation.finished.then(finish).catch(finish);
}


function setEngineConfigToggle(key) {
  if (!state.engineConfigDraft) return;
  const id = state.engineConfigOpen;
  const tuning = state.engineConfigDraft.tuning;
  tuning[key] = !tuning[key];
  if (id === "oMLX") {
    if (key === "mtp" && tuning.mtp) tuning.dflash = false;
    if (key === "dflash" && tuning.dflash) tuning.mtp = false;
  }
  if (id === "MTPLX" && key === "mtp" && !tuning.mtp) tuning.loadMtp = false;
  syncEngineConfigControls();
}

export function syncEngineConfigControls() {
  const panel = $(".fc-engine-panel");
  const draft = state.engineConfigDraft;
  if (!panel || !draft) return;
  const tuning = draft.tuning || {};
  $$("[data-fc-engine-toggle]", panel).forEach((button) => {
    const key = button.dataset.fcEngineToggle;
    const on = Boolean(tuning[key]);
    button.classList.toggle("fc-engine-switch-on", on);
    button.setAttribute("aria-checked", String(on));
  });
  const setDisabled = (selector, disabled) => {
    $$(selector, panel).forEach((element) => {
      element.disabled = Boolean(disabled);
      element.classList.toggle("fc-engine-switch-disabled", Boolean(disabled) && element.classList.contains("fc-engine-switch"));
    });
  };
  if (state.engineConfigOpen === "Splash") {
    setDisabled('[data-fc-engine-field="draftModel"]', tuning.dflash === false);
    setDisabled('[data-fc-engine-toggle="pleSSDOffload"]', Boolean(tuning.pleMemory));
  } else if (state.engineConfigOpen === "oMLX") {
    setDisabled('[data-fc-engine-field="mtpDepth"]', !tuning.mtp);
  } else if (state.engineConfigOpen === "MTPLX") {
    setDisabled('[data-fc-engine-field="mtpQuantBits"]', !tuning.mtp);
    setDisabled('[data-fc-engine-toggle="loadMtp"]', !tuning.mtp);
  }
}


export function openOverlayBase(kind) {
  const layer = $("#overlayLayer");
  overlayCloseToken += 1;
  if (!state.currentOverlay) {
    overlayTrigger = document.activeElement instanceof HTMLElement
      ? document.activeElement
      : null;
  }
  const panel = overlayPanel(kind);
  if (panel) {
    panel.getAnimations().forEach((animation) => animation.cancel());
  }
  state.currentOverlay = kind;
  layer.classList.remove("command-open", "inspector-open", "downloads-open", "model-open");
  layer.classList.add("is-open", `${kind}-open`);
  layer.setAttribute("aria-hidden", "false");
}

function overlayPanel(kind) {
  return {
    command: $("#commandPalette"),
    inspector: $("#inspector"),
    downloads: $("#downloadSheet"),
    model: $("#modelPopover"),
  }[kind] || null;
}

export function closeOverlaysBase(options = {}) {
  const layer = $("#overlayLayer");
  const kind = state.currentOverlay;
  if (!layer || (!kind && !layer.classList.contains("is-open"))) return;
  const panel = overlayPanel(kind);
  const trigger = overlayTrigger;
  const token = ++overlayCloseToken;
  overlayTrigger = null;
  // 模型菜单是锚在按钮上的浮层。以前这里在退出动画开始前就把 FCOverlayBounds
  // 写下的 inline 几何量还了回去：left/top 一被移除，菜单第一帧就跳回 overlay
  // 层的 (0,0)，再在那个角落淡出 —— 看上去就是「收起时闪一下」。
  // 现在只冻结位置（摘掉跟随监听，不动 inline 样式和滚动条类），等真的
  // 收起来以后再还原。
  const popover = $("#modelPopover");
  const freezePopover = Boolean(FCOverlayBounds && popover && kind === "model");
  let releasePopover = null;
  if (freezePopover) {
    FCOverlayBounds.freeze(popover);
    popover.classList.add("is-closing");
    releasePopover = () => {
      // 幂等：同一帧里重开/重关会换掉这份 release，旧的那次直接作废。
      if (popover.__fcRelease !== releasePopover) return;
      popover.__fcRelease = null;
      popover.classList.remove("is-closing");
      FCOverlayBounds.clear(popover);
    };
    popover.__fcRelease = releasePopover;
  }
  const finish = () => {
    if (releasePopover) releasePopover();
    if (token !== overlayCloseToken) return;
    layer.classList.remove("is-open", "command-open", "inspector-open", "downloads-open", "model-open");
    layer.setAttribute("aria-hidden", "true");
    state.currentOverlay = "";
    $("#inspector").setAttribute("aria-modal", "false");
    $("#commandPalette").setAttribute("aria-modal", "false");
    if (panel) panel.getAnimations().forEach((animation) => animation.cancel());
    if (options.restoreFocus !== false && trigger?.isConnected) {
      trigger.focus({ preventScroll: true });
    } else if (state.chatStreaming && state.page === "chat") {
      $("#chatInput")?.focus();
    }
  };
  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  if (options.immediate || !panel || reduceMotion || typeof panel.animate !== "function") {
    finish();
    return;
  }
  const backdrop = $(".command-backdrop");
  const exits = [panel];
  if (kind === "command" && backdrop) exits.push(backdrop);
  // 模型菜单比其它浮层多留 20ms：列表逐行退场要时间，面板同帧消失会显得
  // 「被剪掉」。visibility 的延迟（.2s）也按这个时长留了余量。
  const exitOptions = kind === "model"
    ? { duration: 170, distance: 5 }
    : { duration: 150, distance: 6 };
  Promise.all(exits.map((element) => (
    FCMotionGuard
      ? FCMotionGuard.exit(element, exitOptions)
      : Promise.resolve()
  ))).then(finish, finish);
}

export function openCommandBase() {
  closeOverlays({ immediate: true, restoreFocus: false });
  openOverlay("command");
  $("#commandPalette").setAttribute("aria-modal", "true");
  const input = $("#commandInput");
  input.value = "";
  state.commandIndex = 0;
  renderCommandResults("");
  requestAnimationFrame(() => input.focus());
}


function runCommand(index) {
  const item = state.commandItems[index];
  if (!item) return;
  closeOverlays();
  setTimeout(() => item.run(), 80);
}


export function rangeRow(key, label, value, min, max, step, low, high) {
  return `<div class="param-row">
    <div class="param-head"><span>${esc(label)}</span><b data-range-value="${key}">${esc(value)}</b></div>
    <input class="range-input" type="range" min="${min}" max="${max}" step="${step}"
           value="${value}" data-param="${key}" aria-label="${esc(label)}">
    <div class="param-hint"><span>${esc(low)}</span><span>${esc(high)}</span></div>
  </div>`;
}

export function updateRangeVisual(input) {
  const min = Number(input.min || 0);
  const max = Number(input.max || 100);
  const value = Number(input.value);
  input.style.setProperty("--v", `${((value - min) / (max - min)) * 100}%`);
  const key = input.dataset.param;
  const label = $(`[data-range-value="${key}"]`);
  if (label) label.textContent = String(value);
}


// ---------- model label morph ----------
// 换模型只换一个名字，却会改变按钮宽度：直接写 textContent 的话，新名字是
// 「凭空出现」的，右边的上下文/参数按钮还会在一帧里横跳一百多像素。
// 这里把旧名字留成绝对定位的残影，让新旧两条文字交叉淡入淡出；同时按真实
// 宽度补一段 width 动画 —— 同一行里的其它 flex 元素会跟着一起滑过去。
const modelMorphTokens = new WeakMap();
const modelMorphAnims = new WeakMap();

function morphModelButton(button, next = {}) {
  if (!button) return false;
  const slot = button.querySelector("[data-model-label]");
  if (!slot) return false;
  const label = String(next.label == null ? "" : next.label);
  const glyph = button.querySelector("[data-model-glyph]");
  const glyphMarkup = next.glyph == null ? null : String(next.glyph);
  const glyphChanged = Boolean(glyph && glyphMarkup != null && glyph.innerHTML !== glyphMarkup);
  const current = slot.querySelector(".model-label-text");
  const oldLabel = current ? current.textContent : slot.textContent;
  if (oldLabel === label && !glyphChanged) {
    if (glyphChanged && glyph) glyph.innerHTML = glyphMarkup;
    return false;
  }

  // 先记下屏幕上的宽度，再取消上一次动画：中途再换一次时起点接着上一帧，
  // 不会缩回上一次的终点再重来。
  const startWidth = button.getBoundingClientRect().width;
  const previous = modelMorphAnims.get(button);
  if (previous) {
    previous.forEach((animation) => animation.cancel());
    modelMorphAnims.delete(button);
  }
  const token = (modelMorphTokens.get(button) || 0) + 1;
  modelMorphTokens.set(button, token);

  slot.querySelectorAll(".model-label-ghost").forEach((node) => node.remove());
  const ghost = document.createElement("span");
  ghost.className = "model-label-ghost";
  ghost.setAttribute("aria-hidden", "true");
  ghost.textContent = oldLabel;
  const fresh = document.createElement("span");
  fresh.className = "model-label-text";
  fresh.textContent = label;
  slot.textContent = "";
  slot.append(ghost, fresh);
  slot.dataset.label = label;
  if (glyph && glyphMarkup != null) glyph.innerHTML = glyphMarkup;

  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches
    || typeof button.animate !== "function";
  if (reduceMotion) {
    ghost.remove();
    return true;
  }

  button.classList.add("is-morphing");
  button.style.width = `${startWidth}px`;
  // 让旧宽度先落一帧，再量目标宽度；两次写入在同一帧里会被合并，
  // width 动画就会从一个已经变宽的布局起步。
  button.getBoundingClientRect();
  button.style.width = "auto";
  const targetWidth = button.getBoundingClientRect().width;
  button.style.width = `${startWidth}px`;
  button.getBoundingClientRect();

  const animations = [];
  if (Math.abs(targetWidth - startWidth) >= 0.5) {
    animations.push(button.animate(
      [{ width: `${startWidth}px` }, { width: `${targetWidth}px` }],
      { duration: 320, easing: "cubic-bezier(.2, .86, .18, 1)", fill: "both" }
    ));
  }
  animations.push(ghost.animate(
    [
      { opacity: 1, translate: "0 0", filter: "blur(0)" },
      { opacity: 0, translate: "0 -6px", filter: "blur(2px)" },
    ],
    { duration: 110, easing: "cubic-bezier(.4, 0, 1, 1)", fill: "both" }
  ));
  animations.push(fresh.animate(
    [
      { opacity: 0, translate: "0 6px", filter: "blur(2px)" },
      { opacity: 1, translate: "0 0", filter: "blur(0)" },
    ],
    { duration: 250, delay: 115, easing: "cubic-bezier(.16, 1, .3, 1)", fill: "both" }
  ));
  if (glyphChanged && glyph) {
    animations.push(glyph.animate(
      [{ opacity: .3, scale: .8 }, { opacity: 1, scale: 1 }],
      { duration: 280, delay: 40, easing: "cubic-bezier(.16, 1, .3, 1)", fill: "both" }
    ));
  }
  modelMorphAnims.set(button, animations);

  Promise.all(animations.map((animation) => animation.finished.catch(() => {}))).then(() => {
    if (modelMorphTokens.get(button) !== token) return;
    modelMorphTokens.delete(button);
    modelMorphAnims.delete(button);
    button.classList.remove("is-morphing");
    button.style.width = "";
    ghost.remove();
  });
  return true;
}

export const fcMorphModelButton = morphModelButton;


export function showToast(message, tone = "ok") {
  const stack = $("#toastStack");
  const toast = document.createElement("div");
  toast.className = "toast";
  toast.innerHTML = `<span class="toast-icon">${icon(tone === "error" ? "alert" : "circleCheck", 14)}</span><span>${esc(message)}</span>`;
  stack.appendChild(toast);
  setTimeout(() => {
    toast.classList.add("is-leaving");
    setTimeout(() => toast.remove(), 260);
  }, 2200);
}

function pulseHaptic() {
  if (navigator.vibrate) navigator.vibrate(8);
}


export function inspectChartSegment() {
  const segmented = $("[data-chart-range]");
  if (segmented) FCSegments?.paint(segmented);
}

export function startClock() {
  // The app has no fake system menu bar (the real one is native), so the
  // preview's clock element is absent. Skip instead of throwing during init:
  // an exception here would abort bindGlobalEvents and leave every custom
  // handler unbound.
  const clock = $("#systemClock");
  if (!clock) return;
  const tick = () => {
    const now = new Date();
    clock.textContent = `${String(now.getHours()).padStart(2, "0")}:${String(now.getMinutes()).padStart(2, "0")}`;
  };
  tick();
  setInterval(tick, 30000);
}


export function startFlowVisualization() {
  stopFlowVisualization();
  const canvas = $("#flowCanvas");
  if (!canvas) return;
  const ctx = canvas.getContext("2d");
  const stage = $("#flowStage");
  if (!ctx || !stage) return;
  flowState = {
    hoverX: null,
    hoverY: null,
    range: state.chartRange,
    lastReadout: 0,
  };
  const resize = () => {
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    const rect = stage.getBoundingClientRect();
    canvas.width = Math.max(1, rect.width * dpr);
    canvas.height = Math.max(1, rect.height * dpr);
    canvas.style.width = `${rect.width}px`;
    canvas.style.height = `${rect.height}px`;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  };
  resize();
  canvas.addEventListener("pointermove", (event) => {
    const rect = canvas.getBoundingClientRect();
    flowState.hoverX = event.clientX - rect.left;
    flowState.hoverY = event.clientY - rect.top;
    updateFlowProbe(rect.width, rect.height);
  });
  canvas.addEventListener("pointerleave", () => {
    if (!flowState) return;
    flowState.hoverX = null;
    flowState.hoverY = null;
    const cursor = $("#flowCursor");
    const tooltip = $("#flowTooltip");
    if (cursor) cursor.style.opacity = "0";
    if (tooltip) tooltip.style.opacity = "0";
  });
  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const draw = (now) => {
    if (!canvas.isConnected || state.page !== "overview") return;
    const rect = stage.getBoundingClientRect();
    if (document.body.classList.contains("sidebar-animating") ||
        document.body.classList.contains("sidebar-resizing")) {
      flowAnimation = requestAnimationFrame(draw);
      return;
    }
    if (Math.abs(canvas.clientWidth - rect.width) > 1 || Math.abs(canvas.clientHeight - rect.height) > 1) resize();
    drawFlowField(ctx, rect.width, rect.height, now);
    if (!reduceMotion) flowAnimation = requestAnimationFrame(draw);
  };
  flowAnimation = requestAnimationFrame(draw);
}

function stopFlowVisualization() {
  if (flowAnimation) cancelAnimationFrame(flowAnimation);
  flowAnimation = 0;
}


export function computedColor(variable) {
  const value = getComputedStyle(document.documentElement).getPropertyValue(variable).trim();
  return value || "#d94d78";
}

export function colorWithAlpha(color, alpha) {
  const value = String(color).trim();
  if (value.startsWith("#")) {
    const hex = value.length === 4
      ? value.slice(1).split("").map((char) => char + char).join("")
      : value.slice(1);
    const number = Number.parseInt(hex, 16);
    if (Number.isFinite(number)) {
      return `rgba(${(number >> 16) & 255}, ${(number >> 8) & 255}, ${number & 255}, ${alpha})`;
    }
  }
  const rgb = value.match(/rgba?\(([^)]+)\)/);
  if (rgb) {
    const channels = rgb[1].split(",").slice(0, 3).map((part) => part.trim()).join(", ");
    return `rgba(${channels}, ${alpha})`;
  }
  return `rgba(217, 77, 120, ${alpha})`;
}

export function startAmbient() {
  const canvas = $("#ambient");
  const ctx = canvas.getContext("2d");
  let width = 0;
  let height = 0;
  let dpr = 1;
  const resize = () => {
    dpr = Math.min(window.devicePixelRatio || 1, 2);
    width = window.innerWidth;
    height = window.innerHeight;
    canvas.width = width * dpr;
    canvas.height = height * dpr;
    canvas.style.width = `${width}px`;
    canvas.style.height = `${height}px`;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  };
  window.addEventListener("resize", resize, { passive: true });
  resize();
  const draw = (time) => {
    drawAmbient(time);
    ambientAnimation = requestAnimationFrame(draw);
  };
  if (!window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
    ambientAnimation = requestAnimationFrame(draw);
  } else {
    drawAmbient(0);
  }
}

export function drawAmbient(time = 0) {
  const canvas = $("#ambient");
  if (!canvas) return;
  const ctx = canvas.getContext("2d");
  const width = window.innerWidth;
  const height = window.innerHeight;
  const light = resolvedTheme() === "light";
  ctx.save();
  ctx.setTransform(Math.min(window.devicePixelRatio || 1, 2), 0, 0, Math.min(window.devicePixelRatio || 1, 2), 0, 0);
  ctx.clearRect(0, 0, width, height);
  const bg = ctx.createLinearGradient(0, 0, width, height);
  if (light) {
    bg.addColorStop(0, "#eef6ff");
    bg.addColorStop(.38, "#e4edfb");
    bg.addColorStop(.7, "#f4eaf3");
    bg.addColorStop(1, "#e8f5f0");
  } else {
    bg.addColorStop(0, "#090c13");
    bg.addColorStop(.55, "#111523");
    bg.addColorStop(1, "#14101a");
  }
  ctx.fillStyle = bg;
  ctx.fillRect(0, 0, width, height);

  const px = pointerX / width;
  const py = pointerY / height;
  ctx.globalCompositeOperation = light ? "source-over" : "screen";
  const baseY = height * (.18 + py * .12);
  const ribbonTints = light
    ? ["116, 159, 245", "240, 128, 172", "109, 207, 184", "154, 131, 236", "244, 159, 111"]
    : ["117, 162, 255", "255, 105, 164", "90, 222, 196", "154, 130, 255", "245, 153, 98"];
  for (let i = 0; i < 10; i++) {
    const depth = i / 9;
    ctx.beginPath();
    for (let x = -20; x <= width + 20; x += 12) {
      const t = time * .000035;
      const wave = Math.sin(x * .0022 + i * .51 + t * 1.4) * (32 + i * 2.8)
        + Math.sin(x * .00092 - i * .18 - t) * (44 + i * 1.5);
      const cursorPull = Math.exp(-Math.pow((x - pointerX) / (width * .4), 2)) * (py - .5) * 44;
      const y = baseY + i * 48 + depth * height * .54 + wave + cursorPull;
      if (x === -20) ctx.moveTo(x, y);
      else ctx.lineTo(x, y);
    }
    const tint = ribbonTints[i % ribbonTints.length];
    ctx.strokeStyle = `rgba(${tint}, ${light ? .045 + depth * .025 : .02 + depth * .018})`;
    ctx.lineWidth = 32 + i * 7;
    ctx.stroke();
  }

  for (let i = 0; i < 16; i++) {
    const depth = i / 15;
    ctx.beginPath();
    for (let x = -20; x <= width + 20; x += 14) {
      const t = time * .000042;
      const wave = Math.sin(x * .0031 + i * .38 + t * 1.6) * (16 + i * 1.8)
        + Math.sin(x * .0012 - i * .17 - t) * (24 + i * 1.2);
      const y = baseY + i * 36 + depth * height * .46 + wave + Math.exp(-Math.pow((x - pointerX) / (width * .34), 2)) * (py - .5) * 28;
      if (x === -20) ctx.moveTo(x, y);
      else ctx.lineTo(x, y);
    }
    ctx.strokeStyle = light
      ? `rgba(70, 84, 110, ${.016 + depth * .01})`
      : `rgba(176, 194, 232, ${.012 + depth * .012})`;
    ctx.lineWidth = .72;
    ctx.stroke();
  }
  ctx.globalCompositeOperation = "source-over";
  ctx.restore();
}

export function bindGlobalEvents() {
  document.addEventListener("click", handleClick);
  document.addEventListener("input", handleInput);
  document.addEventListener("pointermove", handlePointerMove, { passive: true });
  document.addEventListener("keydown", handleKeydown);
  window.addEventListener("resize", () => {
    updateNavIndicator();
    inspectChartSegment();
    if (state.currentOverlay === "model") closeOverlays();
  }, { passive: true });

  $("#sidebarToggle").addEventListener("click", toggleSidebar);
  $("#themeToggle").addEventListener("click", () => setTheme(resolvedTheme() === "dark" ? "light" : "dark"));
  $("#downloadShortcut").addEventListener("click", openDownloads);
  bindSidebarResize();
  bindWindowControls();
  const backdrop = $(".command-backdrop");
  backdrop.addEventListener("click", closeOverlays);
  $(".window").addEventListener("animationend", () => {
    $(".window").style.animation = "";
  }, { once: true });
}

function bindWindowControls() {
  $$("[data-window-action]").forEach((button) => {
    button.addEventListener("click", () => {
      const action = button.dataset.windowAction;
      const win = $("#window");
      if (action === "close") {
        showToast("预览模式中，窗口会保持打开");
        win.animate(
          [{ transform: "translateX(0)" }, { transform: "translateX(-5px)" }, { transform: "translateX(5px)" }, { transform: "translateX(0)" }],
          { duration: 180, easing: "ease-out" }
        );
      } else if (action === "minimize") {
        win.classList.toggle("is-minimized");
        if (win.classList.contains("is-minimized")) {
          setTimeout(() => {
            win.classList.remove("is-minimized");
            showToast("窗口已恢复");
          }, 900);
        }
      } else {
        win.classList.toggle("is-maximized");
        showToast(win.classList.contains("is-maximized") ? "窗口已缩放" : "窗口已还原");
      }
    });
  });
}

function bindSidebarResize() {
  const handle = $("#sidebarResize");
  if (!handle) return;
  let dragging = false;
  let dragWidth = state.sidebarWidth;
  let restoreWidth = state.sidebarWidth;

  const applyWidth = (width, persist = false, remember = true) => {
    const next = Math.round(Math.max(72, Math.min(320, width)));
    if (remember) state.sidebarWidth = next;
    document.documentElement.style.setProperty("--sidebar-width", `${next}px`);
    handle.setAttribute("aria-valuenow", String(next));
    if (persist) localStorage.setItem("fc-preview-sidebar-width", String(next));
  };

  handle.addEventListener("pointerdown", (event) => {
    event.preventDefault();
    dragging = true;
    document.body.classList.add("sidebar-resizing");
    if (state.sidebarCollapsed) {
      restoreWidth = state.sidebarWidth;
      state.sidebarCollapsed = false;
      document.body.classList.remove("sidebar-collapsed");
      localStorage.setItem("fc-preview-sidebar", "full");
      $("#sidebarToggle").setAttribute("aria-expanded", "true");
      applyWidth(180, false, false);
      dragWidth = 180;
    } else {
      restoreWidth = $("#sidebar").getBoundingClientRect().width;
      dragWidth = restoreWidth;
    }
    handle.setPointerCapture?.(event.pointerId);
  });

  handle.addEventListener("pointermove", (event) => {
    if (!dragging) return;
    const left = $("#sidebar").getBoundingClientRect().left;
    dragWidth = Math.round(Math.max(72, Math.min(320, event.clientX - left)));
    applyWidth(dragWidth, false, false);
  });

  const finish = () => {
    if (!dragging) return;
    dragging = false;
    document.body.classList.remove("sidebar-resizing");
    if (dragWidth <= 168) {
      state.sidebarCollapsed = true;
      document.body.classList.add("sidebar-collapsed");
      localStorage.setItem("fc-preview-sidebar", "rail");
      applyWidth(restoreWidth, true);
      $("#sidebarToggle").setAttribute("aria-expanded", "false");
    } else {
      state.sidebarCollapsed = false;
      document.body.classList.remove("sidebar-collapsed");
      localStorage.setItem("fc-preview-sidebar", "full");
      applyWidth(dragWidth, true);
      $("#sidebarToggle").setAttribute("aria-expanded", "true");
    }
    updateNavIndicator();
  };
  handle.addEventListener("pointerup", finish);
  handle.addEventListener("pointercancel", finish);

  handle.addEventListener("keydown", (event) => {
    if (event.key !== "ArrowLeft" && event.key !== "ArrowRight") return;
    event.preventDefault();
    if (state.sidebarCollapsed) {
      state.sidebarCollapsed = false;
      document.body.classList.remove("sidebar-collapsed");
      localStorage.setItem("fc-preview-sidebar", "full");
    }
    applyWidth(state.sidebarWidth + (event.key === "ArrowRight" ? 8 : -8), true);
    updateNavIndicator();
  });

  handle.addEventListener("dblclick", () => {
    applyWidth(200, true);
    updateNavIndicator();
  });
}

function handleClick(event) {
  const pageButton = event.target.closest("[data-page]");
  if (pageButton) {
    navigate(pageButton.dataset.page);
    return;
  }

  const command = event.target.closest("[data-command-index]");
  if (command) {
    runCommand(Number(command.dataset.commandIndex));
    return;
  }

  if (event.target.closest("[data-close-command], [data-close-inspector], [data-close-downloads]")) {
    closeOverlays();
    return;
  }

  const thinkingTrigger = event.target.closest("[data-fc-thinking-trigger]");
  if (thinkingTrigger) {
    if (FCChatThinking?.isOpen()) FCChatThinking.close();
    else FCChatThinking?.open(thinkingTrigger, state, {
      boundary: ".window",
      align: "start",
      gap: 9,
      padding: 12,
      width: 304,
      maxHeight: 520,
    });
    return;
  }

  const thinkingChoice = event.target.closest("[data-fc-thinking-kind]");
  if (thinkingChoice) {
    const kind = thinkingChoice.dataset.fcThinkingKind;
    const value = thinkingChoice.dataset.fcThinkingValue;
    if (kind === "mode") {
      state.settings.thinking = value === "automatic" ? "自动" : value === "off" ? "关闭" : "开启";
      state.params.thinking = state.settings.thinking;
      if (value === "on") {
        state.settings.reasoningEffort = state.settings.reasoningEffort || "medium";
      }
    } else if (kind === "effort") {
      state.settings.thinking = "开启";
      state.params.thinking = "开启";
      state.settings.reasoningEffort = value;
      state.settings.reasoningEffortLabel = FCChatThinking.EFFORTS.find((item) => item.value === value)?.label || value;
    }
    if (kind === "mode" && value === "on") {
      requestAnimationFrame(() => FCChatThinking?.update(state));
    } else {
      FCChatThinking?.update(state);
      FCChatThinking?.close();
    }
    syncThinkingTriggerLabel();
    return;
  }

  const copy = event.target.closest("[data-copy]");
  if (copy) {
    copyText(copy.dataset.copy);
    copy.animate(
      [{ transform: "scale(1)" }, { transform: "scale(.82)" }, { transform: "scale(1)" }],
      { duration: 250, easing: "cubic-bezier(.2,.9,.2,1)" }
    );
    return;
  }

  const range = event.target.closest("[data-range]");
  if (range) {
    state.chartRange = range.dataset.range;
    $$("[data-range]").forEach((item) => item.classList.toggle("active", item === range));
    inspectChartSegment();
    if (flowState) flowState.range = range.dataset.range;
    const stage = $("#flowStage");
    if (stage) stage.animate([{ opacity: .45 }, { opacity: 1 }], { duration: 380, easing: "ease-out" });
    return;
  }

  const filter = event.target.closest("[data-model-filter]");
  if (filter) {
    setModelFilter(filter.dataset.modelFilter);
    return;
  }

  const logFilter = event.target.closest("[data-log-filter]");
  if (logFilter) {
    state.logFilter = logFilter.dataset.logFilter;
    $$("[data-log-filter]").forEach((button) => button.classList.toggle("active", button === logFilter));
    updateSlidingSegment(logFilter.parentElement);
    filterLogRows();
    return;
  }

  const download = event.target.closest("[data-download-model]");
  if (download) {
    startChatDownload(download.dataset.downloadModel);
    return;
  }

  const selectModelButton = event.target.closest("[data-select-model]");
  if (selectModelButton) {
    selectModel(selectModelButton.dataset.selectModel);
    return;
  }

  const engineConfig = event.target.closest("[data-engine-config]");
  if (engineConfig) {
    openEngineConfig(engineConfig.dataset.engineConfig);
    return;
  }

  if (event.target.closest("[data-engine-config-close], [data-act='closeConfig']")) {
    closeEngineConfig();
    return;
  }

  if (event.target.closest("[data-act='saveEngineConfig']")) {
    saveEngineConfig();
    return;
  }

  const engineConfigToggle = event.target.closest("[data-fc-engine-toggle]");
  if (engineConfigToggle) {
    setEngineConfigToggle(engineConfigToggle.dataset.fcEngineToggle);
    return;
  }

  const engineDownload = event.target.closest("[data-engine-download]");
  if (engineDownload) {
    runEngineInstall(engineDownload.dataset.engineDownload, "download");
    return;
  }

  const engineUpdate = event.target.closest("[data-engine-update]");
  if (engineUpdate) {
    runEngineInstall(engineUpdate.dataset.engineUpdate, "update");
    return;
  }

  const engineRemove = event.target.closest("[data-engine-remove]");
  if (engineRemove) {
    removeEngineRuntime(engineRemove.dataset.engineRemove);
    return;
  }

  const finder = event.target.closest("[data-finder]");
  if (finder) {
    showToast("已在 Finder 中定位");
    return;
  }

  const engineView = event.target.closest("[data-engine-view]");
  if (engineView) {
    state.activeEngineView = engineView.dataset.engineView;
    renderPage(false);
    return;
  }

  const engineToggle = event.target.closest("[data-engine-toggle]");
  if (engineToggle) {
    toggleEngine(engineToggle.dataset.engineToggle);
    return;
  }

  const toggle = event.target.closest("[data-setting-toggle]");
  if (toggle) {
    toggleSetting(toggle.dataset.settingToggle);
    return;
  }

  const appearance = event.target.closest("[data-appearance]");
  if (appearance) {
    setTheme(appearance.dataset.appearance);
    return;
  }

  const thinking = event.target.closest("[data-thinking]");
  if (thinking) {
    const value = thinking.dataset.thinking;
    state.settings.thinking = value;
    state.params.thinking = value;
    if (state.currentOverlay === "inspector") {
      $$("[data-thinking]", $("#inspector")).forEach((button) => button.classList.toggle("active", button === thinking));
      updateSlidingSegment(thinking.parentElement);
    } else {
      $$("[data-thinking]", $("[data-thinking-choice]")).forEach((button) => button.classList.toggle("active", button.dataset.thinking === value));
      const group = $("[data-thinking-choice]");
      if (group) updateSlidingSegment(group);
    }
    showToast(`思考模式 · ${value}`);
    return;
  }

  const actionElement = event.target.closest("[data-action]");
  if (actionElement) {
    handleAction(actionElement.dataset.action, actionElement);
  }
}


function handleInput(event) {
  if (event.target.id === "modelSearch") {
    state.modelSearch = event.target.value;
    updateModelsGrid();
  } else if (event.target.id === "logSearch") {
    state.logSearch = event.target.value;
    filterLogRows();
  } else if (event.target.id === "chatInput") {
    const button = $("#sendButton");
    if (button) button.disabled = !event.target.value.trim() && !state.chatStreaming;
    event.target.style.height = "46px";
    event.target.style.height = `${Math.min(130, event.target.scrollHeight)}px`;
  } else if (event.target.id === "commandInput") {
    state.commandIndex = 0;
    renderCommandResults(event.target.value);
  } else if (event.target.matches("[data-param]")) {
    const key = event.target.dataset.param;
    state.params[key] = Number(event.target.value);
    updateRangeVisual(event.target);
  } else if (event.target.matches("[data-fc-engine-field]")) {
    if (!state.engineConfigDraft) return;
    const key = event.target.dataset.fcEngineField;
    if (key === "port") state.engineConfigDraft.port = event.target.value;
    else state.engineConfigDraft.tuning[key] = event.target.value;
  }
}

function updateModelsGrid() {
  const grid = $("#modelsGrid");
  if (!grid) return;
  modelListAnimationToken += 1;
  const filtered = filteredModels();
  const commit = () => {
    grid.innerHTML = FCModelWorkspace.cards(filtered, state);
  };
  if (FCMotionGuard) {
    FCMotionGuard.fadeSwap(grid, commit, {
      durationOut: 70,
      durationIn: 150,
      distance: 3,
    });
  } else {
    commit();
  }
}

// 滑块的定位统一交给 FCSegments：它按真实按钮量位置，并自己监听 active 变化。
// 下面几个旧入口保留名字，只是转发，免得调用点散落一地。
function updateEngineTabIndicator() {
  FCSegments?.paintAll();
}

export function updateSlidingSegments() {
  FCSegments?.paintAll();
}

export function syncThinkingTriggerLabel() {
  const trigger = $("[data-fc-thinking-trigger]");
  if (!trigger) return;
  const mode = state.settings.thinking;
  const label = mode === "开启"
    ? (state.settings.reasoningEffortLabel || "中")
    : mode;
  const value = $(".fc-thinking-trigger-value", trigger);
  if (value) value.textContent = label;
  trigger.dataset.fcThinkingMode = mode === "开启" ? "on" : mode === "关闭" ? "off" : "automatic";
}

function updateSlidingSegment(container) {
  if (container) FCSegments?.paint(container);
}

function setModelFilter(filter) {
  state.modelFilter = filter;
  $$("[data-model-filter]").forEach((button) => {
    const active = button.dataset.modelFilter === filter;
    button.classList.toggle("active", active);
    button.classList.toggle("fc-model-filter-button-active", active);
    button.setAttribute("aria-pressed", String(active));
  });
  updateEngineTabIndicator();
  const grid = $("#modelsGrid");
  if (!grid) return;
  const token = ++modelListAnimationToken;
  grid.classList.add("is-leaving");
  setTimeout(() => {
    if (token !== modelListAnimationToken) return;
    const filtered = filteredModels();
    grid.innerHTML = FCModelWorkspace.cards(filtered, state);
    grid.classList.remove("is-leaving");
    grid.classList.add("is-entering");
    setTimeout(() => {
      if (token === modelListAnimationToken) grid.classList.remove("is-entering");
    }, 520);
  }, 110);
}

function filterLogRows() {
  const query = String(state.logSearch || "").toLowerCase();
  const level = state.logFilter === "提示" ? "INFO" : state.logFilter === "警告" ? "WARN" : state.logFilter === "错误" ? "ERROR" : "";
  $$(".log-line").forEach((line) => {
    const matchesLevel = !level || line.dataset.logLevel === level;
    const matchesSearch = !query || (line.dataset.logText || "").includes(query);
    const hidden = !matchesLevel || !matchesSearch;
    if (hidden) {
      if (!line.classList.contains("hidden")) {
        line.classList.add("is-filtering-out");
        setTimeout(() => {
          if (line.classList.contains("is-filtering-out")) {
            line.classList.add("hidden");
            line.classList.remove("is-filtering-out");
          }
        }, 120);
      }
    } else {
      line.classList.remove("hidden", "is-filtering-out");
      if (typeof line.animate === "function") {
        line.animate(
          [{ opacity: 0, transform: "translateY(-3px)" }, { opacity: 1, transform: "none" }],
          { duration: 180, easing: "cubic-bezier(.16,1,.3,1)" }
        );
      }
    }
  });
}

function handlePointerMove(event) {
  pointerX = event.clientX;
  pointerY = event.clientY;
  const win = $("#window");
  if (win) {
    win.style.setProperty("--pointer-x", `${event.clientX}px`);
    win.style.setProperty("--pointer-y", `${event.clientY}px`);
  }
  const glass = event.target.closest(".glass-surface, .glass-sheet");
  if (glass) {
    const rect = glass.getBoundingClientRect();
    glass.style.setProperty("--local-x", `${event.clientX - rect.left}px`);
    glass.style.setProperty("--local-y", `${event.clientY - rect.top}px`);
  }
}

function handleKeydown(event) {
  const meta = event.metaKey || event.ctrlKey;
  if (meta && event.key === "\\") {
    event.preventDefault();
    toggleSidebar();
    return;
  }
  if (meta && /^[1-6]$/.test(event.key)) {
    event.preventDefault();
    navigate(NAV_ITEMS[Number(event.key) - 1].id);
    return;
  }
  if (meta && event.shiftKey && event.key.toLowerCase() === "a") {
    event.preventDefault();
    setTheme(resolvedTheme() === "dark" ? "light" : "dark");
    return;
  }
  if (event.key === "Escape") {
    if (state.currentOverlay) closeOverlays();
    return;
  }
  if (state.currentOverlay === "command") {
    if (event.key === "ArrowDown") {
      event.preventDefault();
      state.commandIndex = Math.min(state.commandItems.length - 1, state.commandIndex + 1);
      renderCommandResults($("#commandInput").value);
    } else if (event.key === "ArrowUp") {
      event.preventDefault();
      state.commandIndex = Math.max(0, state.commandIndex - 1);
      renderCommandResults($("#commandInput").value);
    } else if (event.key === "Enter") {
      event.preventDefault();
      runCommand(state.commandIndex);
    }
    return;
  }
  // 同上：实时壳自己监听 Enter，这里再发一次就是「发送+立即停止」。
  if (!FC_LIVE && state.page === "chat" && event.key === "Enter" && !event.shiftKey && event.target.id === "chatInput") {
    event.preventDefault();
    sendChat();
  }
  if (event.target.matches(".think-head") && (event.key === "Enter" || event.key === " ")) {
    event.preventDefault();
    event.target.click();
  }
}

// app.js is the shared shell: state, nav chrome and the interaction layer that
// live.js builds on. live.js owns rendering — if it is missing there is nothing
// to paint, so say so loudly instead of falling back to the old mock-data
// preview. The render harness asserts on console errors, so a broken load shows
// up in `make webui-check` instead of shipping a fake UI.
document.addEventListener("DOMContentLoaded", function () {
  if (!FC_LIVE) {
    console.error("[flashCat] live.js did not load — no UI to render.");
    return;
  }
  FC_LIVE.init();
});
window.addEventListener("beforeunload", () => {
  if (ambientAnimation) cancelAnimationFrame(ambientAnimation);
});
