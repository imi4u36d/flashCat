"use strict";

const $ = (selector, root = document) => root.querySelector(selector);
const $$ = (selector, root = document) => Array.from(root.querySelectorAll(selector));
const icon = (name, size = 16, cls = "") => window.FCIcons.svg(name, cls, size);
const esc = (value) => String(value == null ? "" : value)
  .replace(/&/g, "&amp;")
  .replace(/</g, "&lt;")
  .replace(/>/g, "&gt;")
  .replace(/"/g, "&quot;");

const NAV_ITEMS = [
  { id: "overview", label: "概览", hint: "状态与性能", icon: "dashboard", shortcut: "1" },
  { id: "chat", label: "对话", hint: "本地推理会话", icon: "message", shortcut: "2" },
  { id: "models", label: "模型", hint: "模型库与推荐", icon: "layers", shortcut: "3", badge: "3" },
  { id: "engines", label: "引擎", hint: "运行时管理", icon: "cpu", shortcut: "4" },
  { id: "logs", label: "日志", hint: "实时运行输出", icon: "scrollText", shortcut: "5" },
  { id: "settings", label: "设置", hint: "系统与外观", icon: "settings", shortcut: "6" },
];

const MODELS = [
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
    content: "本地大模型把推理留在你的设备上，数据不必离开这台 Mac，隐私边界更清楚。它不依赖云端网络，在离线或弱网环境里依然能工作，首字响应也更稳定。部署之后没有按 token 计费，长期高频使用时更容易控制成本，也方便围绕自己的资料做定制。",
    reasoning: "用户要求用三句话介绍优势。回答应覆盖隐私、离线与响应、长期成本。保持精炼，不引入不相关的对比。",
    rate: "87.4",
    ttft: "601",
    tokens: "120",
  },
  {
    id: "m3",
    role: "user",
    content: "那它在隐私和成本上分别怎么权衡？分点说。",
  },
  {
    id: "m4",
    role: "assistant",
    content: "隐私上：数据可以在本地处理，适合敏感资料；代价是磁盘、权限与日志仍要自己管理。\n成本上：高频、离线、批量处理更划算；代价是前期硬件投入和后续维护。\n结论：数据敏感且调用量大时更适合本地，低频或需要持续跟随新模型时云端仍更经济。",
    reasoning: "需要分别讨论隐私与成本，并给出平衡结论。保留短句和清晰分点。",
    rate: "100.6",
    ttft: "1688",
    tokens: "356",
  },
];

const state = {
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
let chatTimer = 0;
let chartRangeTimer = 0;
let flowAnimation = 0;
let flowState = null;
let flowHistory = [];
let sidebarAnimTimer = 0;
let modelListAnimationToken = 0;
let hasRenderedPage = false;
let overlayCloseToken = 0;
let overlayTrigger = null;

const LOG_SEED = [
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

function init() {
  const hashPage = location.hash.replace(/^#/, "");
  if (NAV_ITEMS.some((item) => item.id === hashPage)) state.page = hashPage;
  document.documentElement.dataset.theme = resolvedTheme();
  document.documentElement.style.setProperty("--sidebar-width", `${state.sidebarWidth}px`);
  document.body.classList.toggle("sidebar-collapsed", state.sidebarCollapsed);
  renderToolbarIcons();
  renderNav();
  renderPage(false);
  updateEngineChrome();
  bindGlobalEvents();
  startClock();
  startAmbient();
  initFlowHistory();
  startLiveTelemetry();
  if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
    document.documentElement.classList.add("reduce-motion");
  }
}

function resolvedTheme() {
  if (state.theme === "system") {
    return window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
  }
  return state.theme;
}

function renderToolbarIcons() {
  $("#downloadIcon").innerHTML = icon("download", 15);
  $("#commandIcon").innerHTML = icon("search", 18);
  updateThemeIcon();
}

function updateThemeIcon() {
  $("#themeIcon").innerHTML = icon(resolvedTheme() === "dark" ? "sun" : "moon", 15);
  $("#themeToggle").setAttribute("aria-label", resolvedTheme() === "dark" ? "切换到浅色外观" : "切换到深色外观");
}

function renderNav() {
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

function updateNavIndicator() {
  const indicator = $(".nav-indicator");
  const active = $(".nav-item.active");
  if (!indicator || !active) return;
  const y = active.offsetTop;
  indicator.style.setProperty("--nav-y", `${y}px`);
  indicator.style.height = `${active.offsetHeight}px`;
}

function navigate(page, options = {}) {
  if (!NAV_ITEMS.some((item) => item.id === page)) return;
  if (!options.force && state.page === page) {
    $("#mainContent").scrollTo({ top: 0, behavior: "smooth" });
    return;
  }
  closeOverlays();
  state.page = page;
  syncNavActive();
  $("#mainContent").scrollTop = 0;
  renderPage(!options.immediate);
  history.replaceState(null, "", `#${page}`);
}

function syncNavActive() {
  $$(".nav-item").forEach((item) => {
    const active = item.dataset.page === state.page;
    item.classList.toggle("active", active);
    item.setAttribute("aria-current", active ? "page" : "false");
  });
  requestAnimationFrame(updateNavIndicator);
}

function renderPage(animate = true) {
  const frame = $("#pageFrame");
  if (!frame) return;
  const firstRender = !hasRenderedPage;
  const previousView = frame.dataset.view;
  const scrollTop = $("#mainContent").scrollTop;
  const focusState = captureFocusState(frame);
  const commit = () => {
    if (window.FCChatThinking) window.FCChatThinking.close({ restoreFocus: false });
    stopFlowVisualization();
    frame.classList.remove("is-leaving");
    frame.dataset.view = state.page;
    $("#mainContent").dataset.view = state.page;
    const renderers = {
      overview: renderOverview,
      chat: () => window.FCPages.chat(state),
      models: () => window.FCModelWorkspace.render(state, MODELS),
      engines: () => window.FCEngineWorkspace.render(state),
      logs: () => {
        const lines = LOG_SEED.concat(generatedLogs());
        const counts = Object.fromEntries(["全部", "提示", "警告", "错误"].map((filter) => [filter, logCount(filter, lines)]));
        return window.FCPages.logs(state, logLinesHtml(lines), counts);
      },
      settings: () => window.FCPages.settings(state),
    };
    frame.innerHTML = (renderers[state.page] || renderOverview)();
    if (state.page === "chat") scrollChatToBottom(false);
    if (state.page === "overview") {
      requestAnimationFrame(() => {
        inspectChartSegment();
        startFlowVisualization();
      });
    }
    if (state.page === "models") {
      requestAnimationFrame(updateEngineTabIndicator);
    }
    requestAnimationFrame(updateSlidingSegments);
    if (previousView === state.page) {
      $("#mainContent").scrollTop = scrollTop;
    }
    restoreFocusState(focusState);
    hasRenderedPage = true;
  };
  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  if (animate && !reduceMotion && document.startViewTransition) {
    document.startViewTransition(commit);
  } else if (!animate && !firstRender && !reduceMotion && window.FCMotionGuard) {
    window.FCMotionGuard.fadeSwap(frame, commit, {
      durationOut: 70,
      durationIn: 150,
      distance: 2,
    });
  } else {
    commit();
    if (!firstRender && !reduceMotion) {
      frame.animate(
        [{ opacity: .82, transform: "translateY(2px)" }, { opacity: 1, transform: "none" }],
        { duration: animate ? 220 : 160, easing: "cubic-bezier(.2,.8,.2,1)" }
      );
    }
  }
}

function captureFocusState(root) {
  const active = document.activeElement;
  if (!active || active === document.body || !root.contains(active)) return null;
  const attributes = [
    "data-setting-toggle",
    "data-engine-toggle",
    "data-appearance",
    "data-model-filter",
    "data-page",
    "data-action",
    "id",
  ];
  for (const attribute of attributes) {
    const value = active.getAttribute(attribute);
    if (!value) continue;
    return {
      selector: `[${attribute}="${cssEscape(value)}"]`,
      start: active.selectionStart,
      end: active.selectionEnd,
    };
  }
  return null;
}

function restoreFocusState(focusState) {
  if (!focusState) return;
  requestAnimationFrame(() => {
    const target = $(focusState.selector);
    if (!target || target.disabled) return;
    target.focus({ preventScroll: true });
    if (
      typeof focusState.start === "number" &&
      typeof target.setSelectionRange === "function"
    ) {
      target.setSelectionRange(focusState.start, focusState.end);
    }
  });
}

function pageHeader(title, subtitle, actions = "") {
  return `
    <header class="page-header">
      <div>
        <h1 class="page-title">${esc(title)}</h1>
        <p class="page-subtitle">${esc(subtitle)}</p>
      </div>
      <div class="page-actions">${actions}</div>
    </header>`;
}

function renderOverviewLegacy() {
  const rate = state.engineRunning ? 104.0 + Math.sin(state.metricTick / 7) * 2.8 : 0;
  return `
    ${pageHeader("概览", "本地推理状态、性能与接口，在一个视图中保持同步。", `
      <button class="button" type="button" data-action="refresh-overview">${icon("refresh", 14)}<span>刷新状态</span></button>
      <button class="button" type="button" data-action="open-inspector">${icon("sliders", 14)}<span>运行参数</span></button>
    `)}
    <div class="overview-grid">
      <section class="engine-hero">
        <div class="engine-hero-main">
          <div class="engine-kicker">
            <span class="status-pill ${state.engineRunning ? "" : "stopped"}">
              <i></i>${state.engineBusy ? "正在切换" : state.engineRunning ? "运行中" : "已停止"}
            </span>
            <span>${esc(state.engine)}</span>
            <span class="engine-port">PORT :8000</span>
          </div>
          <div class="hero-model-row">
            <button class="model-orb" type="button" data-action="model-menu" aria-label="切换模型">
              ${icon("brain", 21)}
            </button>
            <div class="hero-model-copy">
              <h2>${esc(shortModel(state.model))}</h2>
              <p><b>${state.engineRunning ? "DFlash2 已加速" : "等待启动"}</b> · ${state.engineRunning ? "上下文 430 / 262K tokens" : "引擎未运行"}</p>
            </div>
          </div>
          <div class="hero-actions">
            <button class="button primary" type="button" data-action="model-menu">${icon("layers", 14)}<span>切换模型</span></button>
            <button class="button ${state.engineRunning ? "danger" : ""}" type="button" data-action="toggle-engine">
              ${icon(state.engineBusy ? "loader" : state.engineRunning ? "stop" : "play", 14)}
              <span>${state.engineBusy ? "处理中" : state.engineRunning ? "停止引擎" : "启动引擎"}</span>
            </button>
            <div class="live-spark" data-live-spark aria-hidden="true">
              ${Array.from({ length: 18 }, (_, i) => `<i style="height:${state.engineRunning ? 5 + ((i * 11) % 29) : 3}px; animation-delay:${i * 35}ms"></i>`).join("")}
            </div>
          </div>
        </div>
        <div class="engine-actions">
          <div class="engine-actions-top">
            <button class="glass-icon-btn" type="button" data-action="refresh-overview" aria-label="重启引擎" title="重启引擎">${icon("refresh", 15)}</button>
            <button class="glass-icon-btn" type="button" data-action="engine-config" aria-label="引擎配置" title="引擎配置">${icon("sliders", 15)}</button>
          </div>
          <button class="engine-dial" type="button" data-action="toggle-engine" aria-label="${state.engineRunning ? "停止" : "启动"}引擎">
            <span class="engine-dial-inner">
              <strong>${state.engineRunning ? rate.toFixed(1) : "—"}</strong>
              <span>TOK / SEC</span>
            </span>
          </button>
        </div>
      </section>

      <div class="metrics-grid">
        ${metricCard("gauge", "解码速度", "LIVE", state.engineRunning ? rate.toFixed(1) : "—", "tok/s", state.engineRunning ? "均值 98.7 tok/s · 最近 45 秒" : "启动引擎后显示")}
        ${metricCard("timer", "首字延迟", "TTFT", state.engineRunning ? "131" : "—", "ms", "最近请求 · 正常")}
        ${metricCard("arrowUp", "预填充", "PREFILL", state.engineRunning ? "1,370" : "—", "tok/s", "引擎采样值")}
        ${metricCard("hardDrive", "内存压力", "MEM", state.engineRunning ? "51" : "—", "%", state.engineRunning ? "65.5 GB / 128 GB" : "空闲")}
      </div>

      <section class="panel throughput-card">
        <header class="panel-head">
          <div>
            <div class="panel-title">Token 流</div>
            <div class="panel-caption">5 条实时请求流 · 每颗粒子是一次解码</div>
          </div>
          <div class="spacer"></div>
          <span class="flow-live-readout"><b id="flowLiveValue">${state.engineRunning ? rate.toFixed(1) : "—"}</b><small>tok/s</small></span>
          <div class="segmented" data-chart-range>
            <span class="segment-indicator"></span>
            ${["45 秒", "5 分钟", "全部"].map((range) => `<button type="button" class="${state.chartRange === range ? "active" : ""}" data-range="${range}">${range}</button>`).join("")}
          </div>
        </header>
        <div class="flow-stage" id="flowStage">
          <canvas id="flowCanvas" aria-label="实时 Token 流可视化"></canvas>
          <div class="flow-stage-label">
            <span class="flow-live-dot"></span>
            <span id="flowStateLabel">LIVE · ${state.engineRunning ? "DECODE" : "IDLE"}</span>
          </div>
          <button class="flow-freeze" type="button" data-flow-freeze title="冻结画面以检查瞬时值">
            ${icon("pause", 11)}<span>冻结</span>
          </button>
          <div class="flow-cursor" id="flowCursor" aria-hidden="true"></div>
          <div class="flow-tooltip" id="flowTooltip" aria-hidden="true">
            <span>PROBE</span>
            <strong>— tok/s</strong>
            <small>— tokens</small>
          </div>
          <div class="flow-axis" aria-hidden="true">
            <span>-45s</span><span>-30s</span><span>-15s</span><span>NOW</span>
          </div>
        </div>
        <footer class="chart-foot">
          <span>${state.engineRunning ? "流宽表示瞬时解码速度，亮度表示最近活动" : "启动引擎后，请求会从左侧涌入"}</span>
          <span class="chart-legend"><span><i></i>Splash</span><span><i class="node"></i>外部网关</span></span>
        </footer>
      </section>

      <section class="panel api-panel">
        <header class="panel-head">
          <div>
            <div class="panel-title">API 网关</div>
            <div class="panel-caption">固定地址 · 双协议同时提供</div>
          </div>
          <div class="spacer"></div>
          <span class="status-pill" style="height:21px;padding:0 7px;font-size:8px"><i></i>ONLINE</span>
        </header>
        <div class="api-body">
          ${endpoint("openai", "OpenAI", "http://127.0.0.1:9000/v1")}
          ${endpoint("claude", "Claude", "http://127.0.0.1:9000")}
          <p class="api-note">${icon("network", 14)}<span>客户端只需固定这个地址。切换引擎、修改端口都不会影响外部配置。</span></p>
        </div>
      </section>

      <div class="request-strip">
        ${requestPill("完成", "#1842 · OpenAI", "刚刚 · Qwen3.8 27B", "87.4")}
        ${requestPill("解码", "#1843 · Claude", "0.8s · Qwen3.8 27B", "104.0")}
        ${requestPill("完成", "#1841 · OpenAI", "32s · Qwen3.8 27B", "96.2")}
      </div>
    </div>`;
}

function renderOverview() {
  const rate = state.engineRunning ? 104.0 + Math.sin(state.metricTick / 7) * 2.8 : 0;
  return window.FCWidgets.overview(state, rate);
}

function metricCard(iconName, label, tag, value, unit, hint) {
  const visual = label === "解码速度" ? speedMatrix() : miniLineSvg();
  return `
    <article class="metric-card">
      <div class="metric-top">
        <span class="metric-label"><span class="metric-icon">${icon(iconName, 13)}</span>${esc(label)}</span>
        <span class="metric-tag">${esc(tag)}</span>
      </div>
      <div class="metric-value"><span data-count="${esc(value)}">${esc(value)}</span><small>${esc(unit)}</small></div>
      <div class="metric-hint">${esc(hint)}</div>
      <div class="${label === "解码速度" ? "speed-matrix" : "metric-mini-line"}" aria-hidden="true">${visual}</div>
    </article>`;
}

function speedMatrix() {
  return Array.from({ length: 96 }, (_, index) => {
    const height = 20 + ((index * 37) % 68);
    return `<i style="--h:${height}%;--d:${-((index % 17) * .11).toFixed(2)}s;--x:${(index % 8) * .015}s"></i>`;
  }).join("");
}

function miniLineSvg() {
  return `<svg viewBox="0 0 220 30" preserveAspectRatio="none">
    <path d="M0 24 C18 22 25 15 43 18 S73 25 92 14 S124 20 143 11 S174 17 192 8 S208 7 220 5"
      fill="none" stroke="var(--accent)" stroke-width="1.3"/>
    <path d="M0 24 C18 22 25 15 43 18 S73 25 92 14 S124 20 143 11 S174 17 192 8 S208 7 220 5 L220 30 L0 30 Z"
      fill="var(--accent)" opacity=".14"/>
  </svg>`;
}

function chartSvg() {
  const points = Array.from({ length: 55 }, (_, i) => {
    const y = 50
      + Math.sin(i * .31) * 9
      + Math.sin(i * .12 + .4) * 15
      - i * .25;
    return [i / 54 * 800, y];
  });
  const line = points.map(([x, y], i) => `${i ? "L" : "M"}${x.toFixed(1)},${y.toFixed(1)}`).join(" ");
  const area = `${line} L800,132 L0,132 Z`;
  return `<svg viewBox="0 0 800 132" preserveAspectRatio="none" aria-label="解码吞吐图">
    <defs>
      <linearGradient id="chartStroke" x1="0" y1="0" x2="1" y2="0">
        <stop offset="0" stop-color="var(--accent-3)"/>
        <stop offset=".58" stop-color="var(--accent)"/>
        <stop offset="1" stop-color="var(--accent-2)"/>
      </linearGradient>
      <linearGradient id="chartFill" x1="0" y1="0" x2="0" y2="1">
        <stop offset="0" stop-color="var(--accent)" stop-opacity=".22"/>
        <stop offset="1" stop-color="var(--accent)" stop-opacity="0"/>
      </linearGradient>
      <linearGradient id="chartGlow" x1="0" y1="0" x2="0" y2="1">
        <stop offset="0" stop-color="var(--accent)"/>
        <stop offset="1" stop-color="var(--accent)" stop-opacity="0"/>
      </linearGradient>
    </defs>
    <g class="chart-grid">
      <line x1="0" y1="28" x2="800" y2="28"/>
      <line x1="0" y1="65" x2="800" y2="65"/>
      <line x1="0" y1="102" x2="800" y2="102"/>
    </g>
    <path class="chart-area" d="${area}"/>
    <path class="chart-glow" d="${area}"/>
    <path class="chart-line" d="${line}" pathLength="1"/>
    <circle class="chart-dot" cx="800" cy="${points[points.length - 1][1].toFixed(1)}" r="3.5"/>
  </svg>`;
}

function endpoint(kind, label, address) {
  return `<div class="endpoint">
    <span class="endpoint-type ${kind}">${esc(label)}</span>
    <span class="endpoint-copy"><strong>BASE URL</strong><span>${esc(address)}</span></span>
    <button class="copy-btn" type="button" data-copy="${esc(address)}" aria-label="复制 ${esc(label)} 地址">${icon("copy", 13)}</button>
  </div>`;
}

function requestPill(status, label, meta, rate) {
  return `<div class="request-pill">
    <span class="dot" style="${status === "解码" ? "background:var(--warn);box-shadow:0 0 0 3px color-mix(in srgb,var(--warn) 10%,transparent)" : ""}"></span>
    <div><strong>${esc(label)}</strong><span>${esc(meta)}</span></div>
    <b>${esc(rate)}</b>
  </div>`;
}

function renderChat() {
  return `
    <section class="chat-page">
      <header class="chat-head">
        <button class="chat-model" type="button" data-action="model-menu">
          <span class="chat-model-orb">${icon("brain", 14)}</span>
          <span class="chat-model-copy">
            <strong>${esc(shortModel(state.model))}</strong>
            <span>${state.engineRunning ? "本地推理 · 上下文 430 / 262K" : "引擎已停止"}</span>
          </span>
        </button>
        <span class="spacer"></span>
        <button class="button icon-only quiet" type="button" data-action="chat-more" aria-label="更多对话操作" title="更多对话操作">${icon("ellipsis", 15)}</button>
        <button class="button" type="button" data-action="new-chat">${icon("messagePlus", 14)}<span>新对话</span></button>
      </header>
      <div class="chat-messages" id="chatMessages">
        <div class="messages-inner" id="messagesInner">${chatMessagesHtml()}</div>
      </div>
      <div class="chat-composer-wrap">
        <div class="chat-composer">
          <label class="visually-hidden" for="chatInput">消息</label>
          <textarea id="chatInput" rows="1" placeholder="输入消息…  ⏎ 发送 · ⇧⏎ 换行"></textarea>
          <div class="composer-row">
            <button class="composer-chip" type="button" data-action="model-menu">${icon("layers", 12)}<span>${esc(shortModel(state.model))}</span></button>
            <button class="composer-chip" type="button" data-action="open-inspector">${icon("sliders", 12)}<span>参数</span></button>
            <button class="composer-chip" type="button" data-action="thinking-cycle">${icon("brain", 12)}<span>思考 · ${esc(state.params.thinking)}</span></button>
            <span class="spacer"></span>
            <button class="send-button" id="sendButton" type="button" data-action="send-chat" aria-label="发送消息">
              ${icon(state.chatStreaming ? "stop" : "arrowUp", 14)}
            </button>
          </div>
        </div>
      </div>
    </section>`;
}

function chatMessagesHtml() {
  return state.chatMessages.map((message) => {
    if (message.role === "user") {
      return `<article class="message user">
        <div class="message-body"><div class="user-bubble">${esc(message.content)}</div></div>
      </article>`;
    }
    const lines = (message.content || "").split("\n").filter(Boolean);
    const text = message.streaming && !message.content
      ? `<span class="typing-dots" aria-label="正在思考"><i></i><i></i><i></i></span>`
      : `${lines.map((line) => `<p>${esc(line)}${message.streaming && line === lines[lines.length - 1] ? '<span class="stream-caret"></span>' : ""}</p>`).join("")}`;
    return `<article class="message ai">
      <div class="avatar">${icon("message", 14)}</div>
      <div class="message-body">
        <div class="reasoning" data-reasoning>
          <button class="reasoning-toggle" type="button" data-action="toggle-reasoning" aria-expanded="false">
            ${icon("brain", 11)}<span>思考过程</span><span style="margin-left:auto">${icon("chevronDown", 11)}</span>
          </button>
          <div class="reasoning-copy"><div><p>${esc(message.reasoning || "正在整理回答策略。")}</p></div></div>
        </div>
        <div class="assistant-card ${message.streaming ? "is-streaming" : ""}" id="${message.id === "stream" ? "streamingAnswer" : ""}">
          <div class="assistant-text">${text}</div>
        </div>
        ${message.streaming ? "" : `<div class="message-meta">
          <span>${esc(message.rate || "—")} tok/s</span>
          <span>首字 ${esc(message.ttft || "—")} ms</span>
          <span>${esc(message.tokens || "—")} tokens</span>
          <button type="button" data-copy="${esc(message.content)}">复制</button>
        </div>`}
      </div>
    </article>`;
  }).join("");
}

function renderModels() {
  const filtered = filteredModels();
  return `
    ${pageHeader("模型", "本机权重、引擎推荐与 Hugging Face 模型库。", `
      <button class="button" type="button" data-action="search-hub">${icon("search", 14)}<span>模型广场</span></button>
      <button class="button" type="button" data-action="downloads">${icon("download", 14)}<span>下载中心</span></button>
    `)}
    <div class="models-toolbar">
      <div class="engine-tabs" aria-label="按引擎筛选">
        ${["全部", "Splash", "oMLX", "MTPLX"].map((engine) => `<button type="button" class="${state.modelFilter === engine ? "active" : ""}" data-model-filter="${engine}">${engine}</button>`).join("")}
      </div>
      <label class="search-field">
        ${icon("search", 14)}
        <input id="modelSearch" type="search" placeholder="搜索模型…" value="${esc(state.modelSearch)}" autocomplete="off">
      </label>
      <span class="spacer"></span>
      <button class="button icon-only" type="button" data-action="refresh-models" aria-label="刷新模型状态" title="刷新模型状态">${icon("refresh", 14)}</button>
    </div>
    <section class="featured-model">
      <div class="featured-main">
        <div class="featured-badges">
          <span class="mini-badge hot">本机模型</span>
          <span class="mini-badge">GGUF</span>
          <span class="mini-badge">DFlash2 加速</span>
          <span class="mini-badge">256K</span>
        </div>
        <h2>${esc(shortModel(state.model))}</h2>
        <p>当前默认权重已加载到 Splash。视觉、思考与草稿加速同时启用，通过 API 网关对所有客户端可见。</p>
        <div class="featured-actions">
          <button class="button primary" type="button" data-action="use-model">${icon("play", 14)}<span>正在使用</span></button>
          <button class="button" type="button" data-action="model-detail">${icon("fileText", 14)}<span>模型详情</span></button>
          <button class="button icon-only quiet" type="button" data-action="model-more" aria-label="更多操作">${icon("ellipsis", 15)}</button>
        </div>
      </div>
      <div class="featured-visual" aria-hidden="true">
        <div class="model-stack">
          <div class="model-layer"></div>
          <div class="model-layer"></div>
          <div class="model-layer"></div>
        </div>
      </div>
    </section>
    <div class="models-grid" id="modelsGrid">
      ${filtered.length ? filtered.map(modelCard).join("") : `<div class="panel" style="grid-column:1/-1;padding:34px;text-align:center;color:var(--text-3);font-size:11px">没有匹配的模型</div>`}
    </div>`;
}

function filteredModels() {
  return window.FCModelWorkspace.filterModels(MODELS, state);
}

function modelCard(model) {
  const busy = state.downloadsInFlight.has(model.name);
  const done = state.downloaded.has(model.name);
  return `<article class="model-card" data-model-name="${esc(model.name)}">
    <div class="model-card-head">
      <span class="model-type-icon">${icon("database", 14)}</span>
      <div style="min-width:0;flex:1">
        <h3>${esc(model.name)}</h3>
        <div class="model-repo">${esc(model.repo)}</div>
      </div>
    </div>
    <div class="model-flags">
      <span class="model-flag">${esc(model.format)}</span>
      ${model.flags.map((flag) => `<span class="model-flag">${esc(flag)}</span>`).join("")}
    </div>
    <div class="model-card-foot">
      <span class="model-size">${esc(model.size)}</span>
      <span class="model-flag">${esc(model.memory)}</span>
      <span class="spacer"></span>
      <button class="model-download ${busy ? "downloading" : ""}" type="button"
              data-download-model="${esc(model.name)}" ${busy ? "disabled" : ""}>
        ${icon(busy ? "loader" : done ? "check" : "download", 11)}
        <span>${done ? "已下载" : busy ? "下载中" : "下载"}</span>
      </button>
    </div>
  </article>`;
}

function renderEngines() {
  return `
    ${pageHeader("引擎", "三个运行时共享同一套控制面，但保留各自的端口与日志。", `
      <button class="button" type="button" data-action="check-updates">${icon("refresh", 14)}<span>检查更新</span></button>
    `)}
    <div class="engines-list">
      ${state.engines.map(engineCard).join("")}
    </div>`;
}

function engineCard(engine) {
  const running = engine.state === "running";
  const busy = engine.state === "starting";
  return `<article class="engine-card ${running ? "active" : ""}" style="--engine-color:${engine.color}" data-engine-card="${esc(engine.id)}">
    <div class="engine-logo">${esc(engine.glyph)}</div>
    <div class="engine-info">
      <div class="engine-name-row">
        <span class="engine-name">${esc(engine.id)}</span>
        <span class="engine-version">v${esc(engine.version)}</span>
      </div>
      <div class="engine-description">${esc(engine.description)}</div>
    </div>
    <div class="engine-facts">
      <div class="engine-fact"><span>端口</span><strong>:${esc(engine.port)}</strong></div>
      <div class="engine-fact"><span>运行时间</span><strong>${esc(engine.uptime)}</strong></div>
      <div class="engine-fact"><span>进程</span><strong>${esc(engine.pid)}</strong></div>
    </div>
    <div class="engine-controls">
      <span class="engine-state ${busy ? "starting" : running ? "running" : ""}">
        ${busy ? `<span class="spin">${icon("loader", 10)}</span>` : "<i></i>"}
        ${busy ? "启动中" : running ? "运行中" : "已停止"}
      </span>
      <button class="button ${running ? "" : "primary"}" type="button" data-engine-toggle="${esc(engine.id)}" ${busy ? "disabled" : ""}>
        ${icon(busy ? "loader" : running ? "stop" : "play", 13)}
        <span>${busy ? "等待" : running ? "停止" : "启动"}</span>
      </button>
      <button class="button icon-only quiet" type="button" data-action="engine-config" aria-label="${esc(engine.id)} 配置">${icon("sliders", 14)}</button>
    </div>
  </article>`;
}

function renderLogs() {
  const lines = LOG_SEED.concat(generatedLogs());
  return `
    ${pageHeader("日志", "当前引擎的实时输出，按级别过滤并保持可检索。", `
      <button class="button" type="button" data-action="log-copy">${icon("copy", 14)}<span>复制可见日志</span></button>
      <button class="button icon-only quiet" type="button" data-action="clear-logs" aria-label="清空日志">${icon("trash", 14)}</button>
    `)}
    <div class="log-toolbar">
      <div class="filter-pills" id="logFilters">
        ${["全部", "提示", "警告", "错误"].map((filter) => `<button class="filter-pill ${state.logFilter === filter ? "active" : ""}" type="button" data-log-filter="${filter}">${filter}<b>${logCount(filter, lines)}</b></button>`).join("")}
      </div>
      <label class="search-field" style="min-width:220px">
        ${icon("search", 14)}
        <input id="logSearch" type="search" placeholder="搜索关键词…" value="${esc(state.logSearch)}" autocomplete="off">
      </label>
      <span class="spacer"></span>
      <button class="button" type="button" data-action="toggle-log-pause">${icon(state.logPaused ? "play" : "pause", 13)}<span>${state.logPaused ? "继续跟随" : "暂停滚动"}</span></button>
    </div>
    <section class="console">
      <header class="console-head">
        <span class="live-toggle"><i></i>${state.logPaused ? "PAUSED" : "LIVE FOLLOW"}</span>
        <span>splash.log</span>
        <span class="spacer"></span>
        <span>${lines.length} lines</span>
      </header>
      <div class="console-body" id="consoleBody">${logLinesHtml(lines)}</div>
    </section>`;
}

function generatedLogs() {
  const lines = [];
  for (let i = 0; i < logSequence; i++) {
    const rate = (88 + Math.sin(i * 1.1) * 15).toFixed(1);
    const messages = [
      `Gateway stream completed · output 128 · ${rate} tok/s · finish_reason=stop`,
      `Kernel scheduling pass ${12 + i} · 40 GPU cores · thermal nominal`,
      `KV cache hit · 18432 tokens reused · resident window 262144`,
      `Decode verify budget auto · accepted 3 of 5 draft tokens · ${rate} tok/s`,
    ];
    lines.push({
      time: logTime(i),
      level: i % 9 === 6 ? "WARN" : "INFO",
      msg: messages[i % messages.length],
    });
  }
  return lines;
}

function logTime(offset = 0) {
  const now = new Date(Date.now() - (logSequence - offset) * 1600);
  return now.toTimeString().slice(0, 8);
}

function logCount(filter, lines) {
  if (filter === "全部") return lines.length;
  const target = filter === "提示" ? "INFO" : filter === "警告" ? "WARN" : "ERROR";
  return lines.filter((line) => line.level === target).length;
}

function logLinesHtml(lines) {
  const filterLevel = state.logFilter === "提示" ? "INFO" : state.logFilter === "警告" ? "WARN" : state.logFilter === "错误" ? "ERROR" : "";
  const query = state.logSearch.toLowerCase();
  return lines.map((line, index) => {
    const matchesFilter = !filterLevel || line.level === filterLevel;
    const matchesSearch = !query || line.msg.toLowerCase().includes(query);
    const hidden = !matchesFilter || !matchesSearch;
    return `<div class="log-line ${hidden ? "hidden" : ""}" data-log-level="${line.level}" data-log-text="${esc(line.msg.toLowerCase())}">
      <span class="time">${esc(line.time || logTime(index))}</span>
      <span class="level ${line.level.toLowerCase()}">${esc(line.level)}</span>
      <span class="msg">${esc(line.msg)}</span>
    </div>`;
  }).join("");
}

function renderSettings() {
  return `
    ${pageHeader("设置", "外观、服务与系统集成。更改即时生效。", `
      <button class="button" type="button" data-action="reset-settings">${icon("refresh", 14)}<span>恢复默认</span></button>
    `)}
    <div class="settings-layout">
      <div style="display:flex;flex-direction:column;gap:14px">
        <section class="settings-group">
          <div class="settings-row">
            <div class="settings-copy"><strong>外观</strong><span>跟随系统，或固定使用浅色 / 深色外观</span></div>
            <div class="settings-segmented" data-appearance-choice>
              ${["system", "light", "dark"].map((choice) => `<button type="button" class="${state.theme === choice ? "active" : ""}" data-appearance="${choice}">${choice === "system" ? "跟随系统" : choice === "light" ? "浅色" : "深色"}</button>`).join("")}
            </div>
          </div>
          <div class="settings-row">
            <div class="settings-copy"><strong>随 flashCat 启动引擎</strong><span>打开应用时自动把默认引擎拉起来</span></div>
            <button class="toggle ${state.settings.launchEngine ? "on" : ""}" type="button" data-setting-toggle="launchEngine" role="switch" aria-checked="${state.settings.launchEngine}"></button>
          </div>
          <div class="settings-row">
            <div class="settings-copy"><strong>登录时启动</strong><span>把 flashCat 加进 macOS 登录项</span></div>
            <button class="toggle ${state.settings.login ? "on" : ""}" type="button" data-setting-toggle="login" role="switch" aria-checked="${state.settings.login}"></button>
          </div>
        </section>

        <section class="settings-group">
          <div class="settings-row">
            <div class="settings-copy"><strong>API 网关</strong><span>OpenAI 与 Claude 双格式 · 统一入口</span></div>
            <button class="toggle ${state.settings.gateway ? "on" : ""}" type="button" data-setting-toggle="gateway" role="switch" aria-checked="${state.settings.gateway}"></button>
          </div>
          <div class="settings-row">
            <div class="settings-copy"><strong>引擎端口</strong><span>各引擎固定起始端口，互不抢占</span></div>
            <div class="port-row">
              <label class="port-input"><span>:</span><input value="8000" inputmode="numeric" aria-label="Splash 端口"></label>
              <label class="port-input"><span>:</span><input value="8100" inputmode="numeric" aria-label="oMLX 端口"></label>
              <label class="port-input"><span>:</span><input value="8200" inputmode="numeric" aria-label="MTPLX 端口"></label>
            </div>
          </div>
        </section>

        <section class="settings-group">
          <div class="settings-row">
            <div class="settings-copy"><strong>思考模式</strong><span>思考模型是否在回答前输出推理过程</span></div>
            <div class="settings-segmented" data-thinking-choice>
              ${["自动", "关闭", "开启"].map((choice) => `<button type="button" class="${state.settings.thinking === choice ? "active" : ""}" data-thinking="${choice}">${choice}</button>`).join("")}
            </div>
          </div>
          <div class="settings-row">
            <div class="settings-copy"><strong>默认模型</strong><span>${esc(shortModel(state.model))}</span></div>
            <button class="button" type="button" data-action="model-menu">${icon("layers", 14)}<span>更改</span></button>
          </div>
        </section>
      </div>

      <aside class="system-profile">
        <div class="profile-head">
          <div class="profile-icon">${icon("monitor", 19)}</div>
          <div><strong>MacBook Pro</strong><span>Apple M5 Max · macOS 26.4</span></div>
        </div>
        <div class="profile-stats">
          <div class="profile-stat"><span>统一内存</span><strong>128 GB</strong></div>
          <div class="profile-stat"><span>GPU 核心</span><strong>40</strong></div>
          <div class="profile-stat"><span>模型磁盘</span><strong>61 GB</strong></div>
        </div>
        <div class="profile-meter"><i></i></div>
        <div class="profile-foot"><span>内存压力 51%</span><span>可用 62.5 GB</span></div>
      </aside>
    </div>`;
}

function shortModel(model) {
  return String(model || "未选择模型").split("/").pop();
}

function setTheme(theme) {
  const previous = resolvedTheme();
  state.theme = theme;
  state.settings.appearance = theme;
  localStorage.setItem("fc-preview-theme", theme);
  const next = resolvedTheme();
  document.documentElement.dataset.theme = next;
  updateThemeIcon();
  drawAmbient(performance.now());
  if (state.page === "settings") {
    $$("[data-appearance]").forEach((button) => button.classList.toggle("active", button.dataset.appearance === theme));
    updateSlidingSegments();
  }
  if (previous !== next) showToast(next === "dark" ? "已切换到深色外观" : "已切换到浅色外观");
}

function toggleSidebar() {
  state.sidebarCollapsed = !state.sidebarCollapsed;
  document.body.classList.add("sidebar-animating");
  clearTimeout(sidebarAnimTimer);
  document.body.classList.toggle("sidebar-collapsed", state.sidebarCollapsed);
  localStorage.setItem("fc-preview-sidebar", state.sidebarCollapsed ? "rail" : "full");
  $("#sidebarToggle").setAttribute("aria-expanded", String(!state.sidebarCollapsed));
  $("#sidebarToggle").setAttribute("aria-label", state.sidebarCollapsed ? "展开边栏" : "折叠边栏");
  $("#sidebarToggle").title = `${state.sidebarCollapsed ? "展开" : "折叠"}边栏（⌘\\）`;
  sidebarAnimTimer = setTimeout(() => {
    document.body.classList.remove("sidebar-animating");
    updateNavIndicator();
  }, 360);
}

function toggleEngine(engineId = state.engine) {
  if (engineId === state.engine && state.engineBusy) return;
  if (engineId === state.engine) {
    state.engineBusy = true;
    const mainEngine = state.engines.find((engine) => engine.id === "Splash");
    if (mainEngine) mainEngine.state = "starting";
    updateEngineChrome();
    renderPage(false);
    setTimeout(() => {
      state.engineRunning = !state.engineRunning;
      state.engineBusy = false;
      if (mainEngine) {
        mainEngine.state = state.engineRunning ? "running" : "stopped";
        mainEngine.uptime = state.engineRunning ? "00:54:18" : "—";
        mainEngine.pid = state.engineRunning ? "95976" : "—";
      }
      if (!state.engineRunning) {
        showToast("引擎已安全停止");
      } else {
        showToast("引擎已就绪 · Qwen3.8 已加载");
      }
      updateEngineChrome();
      if (state.page === "overview" || state.page === "engines") renderPage(false);
      pulseHaptic();
    }, 1250);
    return;
  }
  const target = state.engines.find((engine) => engine.id === engineId);
  if (!target || target.state === "starting") return;
  if (target.installed === false) {
    showToast(`请先下载 ${engineId} 运行时`, "error");
    return;
  }
  if (target.state === "running") {
    target.state = "stopped";
    target.uptime = "—";
    target.pid = "—";
    showToast(`${engineId} 已停止`);
    renderPage(false);
    return;
  }
  target.state = "starting";
  target.uptime = "加载中";
  target.pid = "—";
  renderPage(true);
  setTimeout(() => {
    target.state = "running";
    target.uptime = "00:00:01";
    target.pid = String(100000 + Math.floor(Math.random() * 80000));
    showToast(`${engineId} 已启动`);
    renderPage(true);
    pulseHaptic();
  }, 1500);
}

function defaultEngineTuning(id) {
  if (id === "Splash") return { dflash: true, pleSSDOffload: true };
  if (id === "oMLX") return { mtp: true, dflash: false, pleSSDOffload: true };
  if (id === "MTPLX") return { loadMtp: true, mtp: true };
  return {};
}

function openEngineConfig(id) {
  const engine = state.engines.find((item) => item.id === id);
  if (!engine || engine.installed === false) return;
  state.activeEngineView = id;
  state.engineConfigOpen = id;
  state.engineConfigDraft = {
    engine: id,
    port: String(engine.port || ""),
    tuning: Object.assign(defaultEngineTuning(id), engine.tuning || {}),
  };
  renderPage(true);
  pulseHaptic();
}

function closeEngineConfig() {
  const panel = $(".fc-engine-panel");
  const finish = () => {
    state.engineConfigOpen = null;
    state.engineConfigDraft = null;
    renderPage(true);
  };
  if (!panel || window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
    finish();
    return;
  }
  panel.animate(
    [{ opacity: 1, transform: "none" }, { opacity: 0, transform: "translateX(18px)" }],
    { duration: 170, easing: "cubic-bezier(.4,0,.2,1)", fill: "forwards" }
  ).finished.then(finish).catch(finish);
}

function saveEngineConfig() {
  const id = state.engineConfigOpen;
  if (!id || !state.engineConfigDraft) return;
  const engine = state.engines.find((item) => item.id === id);
  if (engine) {
    engine.tuning = { ...(state.engineConfigDraft.tuning || {}) };
    engine.port = String(state.engineConfigDraft.port || engine.port);
  }
  showToast(`${id} 配置已保存`);
  closeEngineConfig();
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

function syncEngineConfigControls() {
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

function runEngineInstall(id, kind) {
  const engine = state.engines.find((item) => item.id === id);
  if (!engine) return;
  engine.busy = true;
  engine.progress = 12;
  renderPage(false);
  showToast(kind === "update" ? `正在更新 ${id}` : `正在下载 ${id}`);
  setTimeout(() => {
    engine.busy = false;
    engine.progress = 100;
    engine.installed = true;
    engine.version = engine.latest || engine.version;
    engine.state = engine.state === "not-installed" ? "stopped" : engine.state;
    showToast(kind === "update" ? `${id} 已更新到 v${engine.version}` : `${id} 运行时已安装`);
    renderPage(false);
    pulseHaptic();
  }, 1200);
}

function removeEngineRuntime(id) {
  const engine = state.engines.find((item) => item.id === id);
  if (!engine) return;
  const running = id === "Splash" ? state.engineRunning : engine.state === "running";
  if (running) {
    showToast("请先停止引擎再删除运行时", "error");
    return;
  }
  engine.installed = false;
  engine.state = "not-installed";
  if (state.engineConfigOpen === id) {
    state.engineConfigOpen = null;
    state.engineConfigDraft = null;
  }
  showToast(`${id} 运行时已删除`);
  renderPage(false);
}

function updateEngineChrome() {
  const dot = $("#topEngineDot");
  const label = $("#topEngineState");
  const rate = $("#topEngineRate");
  const action = $("#topEngineAction");
  const control = $("#topEngineControl");
  if (!dot || !label || !rate || !action || !control) return;
  dot.classList.toggle("is-stopped", !state.engineRunning && !state.engineBusy);
  dot.classList.toggle("is-busy", state.engineBusy);
  label.textContent = state.engineBusy ? "切换中" : state.engineRunning ? "运行中" : "已停止";
  rate.textContent = state.engineRunning ? `${(104 + Math.sin(state.metricTick / 7) * 2.8).toFixed(0)} tok/s` : "—";
  action.innerHTML = icon(state.engineRunning ? "stop" : "play", 11);
  control.setAttribute("aria-label", state.engineRunning ? "停止引擎" : "启动引擎");
}

function sendChat() {
  if (state.chatStreaming) {
    stopChatStream();
    return;
  }
  const input = $("#chatInput");
  if (!input || !input.value.trim() || !state.engineRunning) {
    if (!state.engineRunning) showToast("请先启动推理引擎");
    return;
  }
  const text = input.value.trim();
  input.value = "";
  state.chatStreaming = true;
  state.chatMessages.push({ id: `u${Date.now()}`, role: "user", content: text });
  const assistant = {
    id: "stream",
    role: "assistant",
    content: "",
    reasoning: "用户希望得到一个直接、可执行的回答。先确认上下文，再组织为简洁的结论。",
    streaming: true,
  };
  state.chatMessages.push(assistant);
  renderPage(false);
  setTimeout(() => {
    const full = "可以。基于当前上下文，我建议先把数据和模型都留在本地，再通过固定网关接入现有工具。这样切换引擎时不需要改任何客户端配置，性能数据也能在同一个控制台里持续观察。";
    let index = 0;
    chatTimer = setInterval(() => {
      if (!state.chatStreaming) return;
      index += 2 + Math.floor(Math.random() * 4);
      assistant.content = full.slice(0, index);
      updateStreamingMessage(assistant);
      if (index >= full.length) {
        clearInterval(chatTimer);
        assistant.streaming = false;
        assistant.rate = "103.8";
        assistant.ttft = "208";
        assistant.tokens = "196";
        state.chatStreaming = false;
        renderPage(false);
      }
    }, 55);
  }, 650);
}

function updateStreamingMessage(assistant) {
  const answer = $("#streamingAnswer .assistant-text");
  if (!answer) return;
  answer.innerHTML = assistant.content.split("\n").map((line) => `<p>${esc(line)}</p>`).join("") + `<span class="stream-caret"></span>`;
  scrollChatToBottom(true);
}

function stopChatStream() {
  clearInterval(chatTimer);
  state.chatStreaming = false;
  const last = state.chatMessages[state.chatMessages.length - 1];
  if (last && last.streaming) {
    last.streaming = false;
    last.content = last.content || "已停止生成。";
    last.rate = "—";
    last.ttft = "—";
    last.tokens = "—";
  }
  showToast("已停止生成");
  renderPage(false);
}

function scrollChatToBottom(smooth = true) {
  const messages = $("#chatMessages");
  if (!messages) return;
  messages.scrollTo({ top: messages.scrollHeight, behavior: smooth ? "smooth" : "auto" });
}

function cycleThinking() {
  const choices = ["自动", "开启", "关闭"];
  const next = choices[(choices.indexOf(state.params.thinking) + 1) % choices.length];
  state.params.thinking = next;
  state.settings.thinking = next;
  showToast(`思考模式 · ${next}`);
  if (state.page === "chat") renderPage(false);
  if (state.page === "settings") renderPage(false);
}

function startChatDownload(name) {
  if (state.downloadsInFlight.has(name) || state.downloaded.has(name)) return;
  state.downloadsInFlight.set(name, 0);
  renderPage(false);
  showToast(`开始下载 ${shortModel(name)}`);
  let progress = 0;
  const timer = setInterval(() => {
    progress += 7 + Math.random() * 11;
    if (progress >= 100) {
      clearInterval(timer);
      state.downloadsInFlight.delete(name);
      state.downloaded.add(name);
      showToast(`${shortModel(name)} 已下载完成`);
      pulseHaptic();
    } else {
      state.downloadsInFlight.set(name, progress);
    }
    if (state.page === "models") {
      const card = $(`[data-model-name="${cssEscape(name)}"]`);
      if (card) {
        const button = $("[data-download-model]", card);
        if (button) {
          button.querySelector("span").textContent = progress >= 100 ? "已下载" : `${Math.round(progress)}%`;
        }
      }
    }
  }, 380);
}

function cssEscape(value) {
  if (window.CSS && CSS.escape) return CSS.escape(value);
  return String(value).replace(/"/g, '\\"');
}

function toggleSetting(key) {
  state.settings[key] = !state.settings[key];
  const button = $(`[data-setting-toggle="${key}"]`);
  if (button) {
    button.classList.toggle("on", state.settings[key]);
    button.setAttribute("aria-checked", String(state.settings[key]));
  }
  showToast(key === "gateway" ? `API 网关已${state.settings.gateway ? "开启" : "关闭"}` : "设置已更新");
}

function openOverlay(kind) {
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

function closeOverlays(options = {}) {
  const layer = $("#overlayLayer");
  const kind = state.currentOverlay;
  if (!layer || (!kind && !layer.classList.contains("is-open"))) return;
  const panel = overlayPanel(kind);
  const trigger = overlayTrigger;
  const token = ++overlayCloseToken;
  overlayTrigger = null;
  if (window.FCOverlayBounds && $("#modelPopover")) {
    window.FCOverlayBounds.clear($("#modelPopover"), { restore: true });
  }
  const finish = () => {
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
  Promise.all(exits.map((element) => (
    window.FCMotionGuard
      ? window.FCMotionGuard.exit(element, { duration: 150, distance: 6 })
      : Promise.resolve()
  ))).then(finish, finish);
}

function openCommand() {
  closeOverlays({ immediate: true, restoreFocus: false });
  openOverlay("command");
  $("#commandPalette").setAttribute("aria-modal", "true");
  const input = $("#commandInput");
  input.value = "";
  state.commandIndex = 0;
  renderCommandResults("");
  requestAnimationFrame(() => input.focus());
}

function commands() {
  return [
    ...NAV_ITEMS.map((item) => ({
      label: `打开${item.label}`,
      detail: item.hint,
      icon: item.icon,
      shortcut: `⌘${item.shortcut}`,
      run: () => navigate(item.id),
    })),
    {
      label: "切换外观",
      detail: `当前：${resolvedTheme() === "dark" ? "深色" : "浅色"}`,
      icon: resolvedTheme() === "dark" ? "sun" : "moon",
      shortcut: "⌘⇧A",
      run: () => setTheme(resolvedTheme() === "dark" ? "light" : "dark"),
    },
    {
      label: state.engineRunning ? "停止推理引擎" : "启动推理引擎",
      detail: `${state.engine} · 端口 8000`,
      icon: state.engineRunning ? "stop" : "play",
      shortcut: "",
      run: () => toggleEngine(),
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
      detail: "2 个下载任务",
      icon: "download",
      shortcut: "",
      run: () => openDownloads(),
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

function renderCommandResults(query) {
  const all = commands();
  const q = query.trim().toLowerCase();
  state.commandItems = all.filter((item) => !q || `${item.label} ${item.detail}`.toLowerCase().includes(q));
  state.commandIndex = Math.min(state.commandIndex, Math.max(0, state.commandItems.length - 1));
  const navResults = state.commandItems.slice(0, 6);
  $("#commandResults").innerHTML = navResults.length ? `
    ${navResults.map((item, index) => `
      <button class="command-item ${index === state.commandIndex ? "selected" : ""}" type="button" data-command-index="${index}">
        <span class="command-item-icon">${icon(item.icon, 13)}</span>
        <span class="command-item-copy"><strong>${esc(item.label)}</strong></span>
        ${item.shortcut ? `<kbd>${esc(item.shortcut)}</kbd>` : ""}
      </button>`).join("")}
  ` : `<div style="padding:34px;text-align:center;color:var(--text-3);font-size:10.5px">没有匹配的命令</div>`;
  $("#commandHint").textContent = `${state.commandItems.length} 个命令`;
}

function runCommand(index) {
  const item = state.commandItems[index];
  if (!item) return;
  closeOverlays();
  setTimeout(() => item.run(), 80);
}

function openInspector() {
  closeOverlays({ immediate: true, restoreFocus: false });
  openOverlay("inspector");
  const p = state.params;
  $("#inspector").innerHTML = `
    <div class="inspector-grabber" aria-hidden="true"></div>
    <header class="inspector-head">
      <div><span class="eyebrow">CHAT PARAMETERS</span><h2 id="inspectorTitle">生成参数</h2></div>
      <button class="glass-icon-btn small" type="button" data-close-inspector aria-label="关闭参数面板">${icon("x", 14)}</button>
    </header>
    <div class="inspector-body">
      ${rangeRow("temperature", "温度", p.temperature, 0, 1.5, .05, "精确", "发散")}
      ${rangeRow("topP", "Top P", p.topP, 0, 1, .01, "聚焦", "多样")}
      ${rangeRow("tokens", "最大输出", p.tokens, 512, 8192, 256, "512", "8192")}
      <div class="param-row">
        <div class="param-head"><span>思考模式</span><b>${esc(p.thinking)}</b></div>
        <div class="settings-segmented think-segment" data-thinking-choice>
          ${["自动", "关闭", "开启"].map((choice) => `<button type="button" class="${p.thinking === choice ? "active" : ""}" data-thinking="${choice}">${choice}</button>`).join("")}
        </div>
      </div>
    </div>
    <footer class="inspector-foot">
      <button class="button" type="button" data-action="reset-params">重置</button>
      <button class="button primary" type="button" data-action="save-params">应用</button>
    </footer>`;
  requestAnimationFrame(() => {
    $$(".range-input", $("#inspector")).forEach(updateRangeVisual);
  });
}

function rangeRow(key, label, value, min, max, step, low, high) {
  return `<div class="param-row">
    <div class="param-head"><span>${esc(label)}</span><b data-range-value="${key}">${esc(value)}</b></div>
    <input class="range-input" type="range" min="${min}" max="${max}" step="${step}"
           value="${value}" data-param="${key}" aria-label="${esc(label)}">
    <div class="param-hint"><span>${esc(low)}</span><span>${esc(high)}</span></div>
  </div>`;
}

function updateRangeVisual(input) {
  const min = Number(input.min || 0);
  const max = Number(input.max || 100);
  const value = Number(input.value);
  input.style.setProperty("--v", `${((value - min) / (max - min)) * 100}%`);
  const key = input.dataset.param;
  const label = $(`[data-range-value="${key}"]`);
  if (label) label.textContent = String(value);
}

function openDownloads() {
  closeOverlays({ immediate: true, restoreFocus: false });
  openOverlay("downloads");
  const sheet = $("#downloadSheet");
  sheet.innerHTML = `
    <header class="sheet-head">
      <div><span class="eyebrow">MODEL DOWNLOADS</span><h2 id="downloadTitle">下载中心</h2></div>
      <button class="glass-icon-btn small" type="button" data-close-downloads aria-label="关闭下载中心">${icon("x", 14)}</button>
    </header>
    <div class="download-list">
      <article class="download-item">
        <div class="download-type">MLX</div>
        <div class="download-copy"><strong>Qwen3.8-27B-4bit</strong><span>13.8 / 20.2 GB · 48 MB/s</span><div class="progress-track"><i style="width:68%"></i></div></div>
        <span class="download-percent">68%</span>
      </article>
      <article class="download-item">
        <div class="download-type gguf">GGUF</div>
        <div class="download-copy"><strong>Qwen3.5-4B-Q4_K_M</strong><span>1.7 / 2.6 GB · 等待中</span><div class="progress-track queued"><i style="width:64%"></i></div></div>
        <span class="download-percent muted">暂停</span>
      </article>
    </div>`;
}

function openModelPopover(anchor) {
  if ($("#overlayLayer").classList.contains("model-open")) {
    closeOverlays();
    return;
  }
  closeOverlays({ immediate: true, restoreFocus: false });
  openOverlay("model");
  const popover = $("#modelPopover");
  popover.innerHTML = MODELS.slice(0, 4).map((model, index) => `
    <button class="model-option" style="--i:${index}" type="button" data-select-model="${esc(model.name)}">
      <span class="model-option-icon">${icon("brain", 14)}</span>
      <span class="model-option-copy"><strong>${esc(shortModel(model.name))}</strong><span>${esc(model.engine)} · ${esc(model.size)} · ${esc(model.format)}</span></span>
      ${model.name === state.model ? `<span class="model-option-check">${icon("check", 14)}</span>` : ""}
    </button>`).join("");
  const rect = anchor.getBoundingClientRect();
  const width = 318;
  const left = Math.max(14, Math.min(window.innerWidth - width - 14, rect.left));
  if (window.FCOverlayBounds) {
    window.FCOverlayBounds.place(anchor, popover, {
      boundary: ".window",
      preferredSide: "bottom",
      align: "start",
      gap: 8,
      padding: 14,
      width,
      maxHeight: 420,
      scroll: true,
      flip: true,
      clamp: true,
    });
  } else {
    popover.style.left = `${left}px`;
    popover.style.top = `${rect.bottom + 8}px`;
  }
}

function selectModel(name) {
  state.model = name;
  closeOverlays();
  showToast(`已切换到 ${shortModel(name)}`);
  updateEngineChrome();
  renderPage(false);
  requestAnimationFrame(() => {
    const title = $("[data-model-title]");
    if (!title) return;
    title.classList.add("is-switching");
    setTimeout(() => title.classList.remove("is-switching"), 860);
  });
  pulseHaptic();
}

function showToast(message, tone = "ok") {
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

function copyText(text) {
  const value = String(text || "");
  const done = () => showToast("已复制到剪贴板");
  if (navigator.clipboard && window.isSecureContext) {
    navigator.clipboard.writeText(value).then(done).catch(() => fallbackCopy(value, done));
  } else {
    fallbackCopy(value, done);
  }
}

function fallbackCopy(value, done) {
  const area = document.createElement("textarea");
  area.value = value;
  area.style.cssText = "position:fixed;opacity:0";
  document.body.appendChild(area);
  area.select();
  try { document.execCommand("copy"); done(); } catch { showToast("无法访问剪贴板", "error"); }
  area.remove();
}

function inspectChartSegment() {
  const segmented = $("[data-chart-range]");
  if (!segmented) return;
  const active = $("button.active", segmented);
  const indicator = $(".segment-indicator", segmented);
  if (!active || !indicator) return;
  indicator.style.width = `${active.offsetWidth}px`;
  indicator.style.transform = `translateX(${active.offsetLeft - 2}px)`;
}

function startClock() {
  const clock = $("#systemClock");
  const tick = () => {
    const now = new Date();
    clock.textContent = `${String(now.getHours()).padStart(2, "0")}:${String(now.getMinutes()).padStart(2, "0")}`;
  };
  tick();
  setInterval(tick, 30000);
}

function startLiveTelemetry() {
  setInterval(() => {
    if (!flowHistory.length) return;
    flowHistory.shift();
    const last = flowHistory[flowHistory.length - 1] || 100;
    const next = state.engineRunning
      ? Math.max(76, Math.min(124, last + (Math.random() - .48) * 10 + Math.sin(Date.now() / 3200) * 2.2))
      : 0;
    flowHistory.push(next);
  }, 1000);

  setInterval(() => {
    state.metricTick += 1;
    updateEngineChrome();
    const spark = $("[data-live-spark]");
    if (spark && state.engineRunning) {
      $$("i", spark).forEach((bar, index) => {
        if ((index + state.metricTick) % 4 === 0) {
          bar.style.height = `${6 + Math.random() * 29}px`;
        }
      });
    }
    if (state.page === "logs" && !state.logPaused && state.engineRunning && logSequence < 20) {
      logSequence += 1;
      appendLiveLog();
    }
  }, 2300);

  setInterval(() => {
    if (state.page !== "models") return;
    state.downloadsInFlight.forEach((progress, name) => {
      const next = Math.min(99, progress + 2 + Math.random() * 4);
      state.downloadsInFlight.set(name, next);
      const card = $(`[data-model-name="${cssEscape(name)}"]`);
      const button = card ? $("[data-download-model]", card) : null;
      if (button) button.querySelector("span").textContent = `${Math.round(next)}%`;
    });
  }, 1800);
}

function initFlowHistory() {
  flowHistory = Array.from({ length: 60 }, (_, index) =>
    96 + Math.sin(index * .42) * 7 + Math.sin(index * .13 + .8) * 5 + (Math.random() - .5) * 3.5);
}

function appendLiveLog() {
  const body = $("#consoleBody");
  if (!body) return;
  const nearBottom = body.scrollHeight - body.scrollTop - body.clientHeight < 40;
  const line = document.createElement("div");
  const isWarning = logSequence % 7 === 0;
  line.className = "log-line";
  line.dataset.logLevel = isWarning ? "WARN" : "INFO";
  line.dataset.logText = "gateway stream activity";
  line.innerHTML = `<span class="time">${logTime()}</span><span class="level ${isWarning ? "warn" : ""}">${isWarning ? "WARN" : "INFO"}</span><span class="msg">Gateway stream active · output ${128 + logSequence} · ${(94 + Math.random() * 13).toFixed(1)} tok/s · finish_reason=stop</span>`;
  body.appendChild(line);
  if (nearBottom) body.scrollTop = body.scrollHeight;
}

function startFlowVisualization() {
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

function drawFlowFieldLegacy(ctx, width, height, time) {
  const dark = resolvedTheme() === "dark";
  const accent = computedColor("--accent");
  const accent2 = computedColor("--accent-2");
  const accent3 = computedColor("--accent-3");
  const info = computedColor("--info");
  const ok = computedColor("--ok");
  const colors = [accent, info, accent3, accent2, ok];
  const t = time / 1000;
  const laneCount = 5;
  const top = 34;
  const bottom = height - 28;
  const gap = (bottom - top) / (laneCount - 1);
  const baseRates = [104, 88, 119, 76, 96];
  ctx.clearRect(0, 0, width, height);
  ctx.save();
  ctx.globalCompositeOperation = dark ? "lighter" : "source-over";

  const pulseX = ((t * 58) % (width + 180)) - 80;
  const pulseGradient = ctx.createLinearGradient(pulseX - 90, 0, pulseX + 90, 0);
  pulseGradient.addColorStop(0, colorWithAlpha(accent, 0));
  pulseGradient.addColorStop(.5, colorWithAlpha(accent, dark ? .055 : .04));
  pulseGradient.addColorStop(1, colorWithAlpha(accent, 0));
  ctx.fillStyle = pulseGradient;
  ctx.fillRect(pulseX - 90, 0, 180, height);

  for (let lane = 0; lane < laneCount; lane++) {
    const laneY = top + lane * gap;
    const color = colors[lane % colors.length];
    const activeRate = state.engineRunning ? baseRates[lane] : 0;
    const wave = Math.min(6.5, 2.5 + activeRate / 34);
    const laneGradient = ctx.createLinearGradient(0, 0, width, 0);
    laneGradient.addColorStop(0, colorWithAlpha(color, 0));
    laneGradient.addColorStop(.1, colorWithAlpha(color, dark ? .035 : .025));
    laneGradient.addColorStop(.55, colorWithAlpha(color, dark ? .075 : .05));
    laneGradient.addColorStop(.97, colorWithAlpha(color, 0));
    ctx.fillStyle = laneGradient;
    ctx.fillRect(0, laneY - 7, width, 14);

    const hoveredLane = flowState.hoverY != null && Math.abs(flowState.hoverY - laneY) < gap * .36;
    if (hoveredLane) {
      ctx.fillStyle = colorWithAlpha(color, dark ? .075 : .05);
      ctx.fillRect(0, laneY - 12, width, 24);
    }

    const lanePath = () => {
      ctx.beginPath();
      for (let x = -4; x <= width + 4; x += 5) {
        const y = laneY
          + Math.sin(x * .021 + t * (.7 + lane * .028) + lane * 1.13) * wave
          + Math.sin(x * .008 - t * .23 + lane * .7) * 1.2;
        if (x === -4) ctx.moveTo(x, y);
        else ctx.lineTo(x, y);
      }
    };
    const lineGradient = ctx.createLinearGradient(0, 0, width, 0);
    lineGradient.addColorStop(0, colorWithAlpha(color, 0));
    lineGradient.addColorStop(.08, colorWithAlpha(color, state.engineRunning ? .32 : .09));
    lineGradient.addColorStop(.52, colorWithAlpha(color, state.engineRunning ? .54 : .13));
    lineGradient.addColorStop(.93, colorWithAlpha(color, state.engineRunning ? .38 : .09));
    lineGradient.addColorStop(1, colorWithAlpha(color, 0));
    lanePath();
    ctx.strokeStyle = lineGradient;
    ctx.lineWidth = state.engineRunning ? 1.35 : .7;
    ctx.stroke();

    if (state.engineRunning) {
      lanePath();
      ctx.save();
      ctx.setLineDash([8, 19]);
      ctx.lineDashOffset = -(t * (17 + activeRate * .24) + lane * 11);
      ctx.strokeStyle = colorWithAlpha(color, hoveredLane ? .94 : .72);
      ctx.lineWidth = hoveredLane ? 2.1 : 1.45;
      ctx.shadowColor = colorWithAlpha(color, .8);
      ctx.shadowBlur = hoveredLane ? 12 : 7;
      ctx.stroke();
      ctx.restore();

      const headX = ((t * activeRate * 1.28 + lane * 89) % (width + 20)) - 10;
      const headY = laneY
        + Math.sin(headX * .021 + t * (.7 + lane * .028) + lane * 1.13) * wave
        + Math.sin(headX * .008 - t * .23 + lane * .7) * 1.2;
      const headFade = Math.sin(Math.min(1, Math.max(0, headX / width)) * Math.PI);
      ctx.save();
      ctx.shadowColor = colorWithAlpha(color, .9);
      ctx.shadowBlur = 12;
      ctx.fillStyle = colorWithAlpha(color, .95 * Math.max(.08, headFade));
      ctx.beginPath();
      ctx.arc(headX, headY, hoveredLane ? 2.5 : 2, 0, Math.PI * 2);
      ctx.fill();
      ctx.restore();
    }

    ctx.font = "7.5px SFMono-Regular, Menlo, monospace";
    ctx.textAlign = "left";
    ctx.fillStyle = colorWithAlpha(color, .72);
    ctx.fillText(`R${lane + 1}`, 13, laneY - 7);
    ctx.textAlign = "right";
    ctx.fillStyle = colorWithAlpha(computedColor("--text-3"), .76);
    ctx.fillText(state.engineRunning ? activeRate.toFixed(1) : "idle", width - 13, laneY - 7);
  }

  const events = [
    { x: .33, label: "#1840" },
    { x: .56, label: "#1841" },
    { x: .77, label: "#1842" },
  ];
  events.forEach((event) => {
    const x = width * event.x;
    ctx.strokeStyle = colorWithAlpha(accent, .22);
    ctx.lineWidth = 1;
    ctx.setLineDash([2, 5]);
    ctx.beginPath();
    ctx.moveTo(x, top - 9);
    ctx.lineTo(x, bottom + 8);
    ctx.stroke();
    ctx.setLineDash([]);
    ctx.fillStyle = colorWithAlpha(accent, .68);
    ctx.beginPath();
    ctx.arc(x, bottom + 8, 1.7, 0, Math.PI * 2);
    ctx.fill();
    ctx.font = "7px SFMono-Regular, Menlo, monospace";
    ctx.textAlign = "center";
    ctx.fillStyle = colorWithAlpha(computedColor("--text-3"), .82);
    ctx.fillText(event.label, x, height - 7);
  });
  ctx.restore();

  if (!state.engineRunning) {
    $("#flowStateLabel") && ($("#flowStateLabel").textContent = "IDLE · ENGINE STOPPED");
  } else if ($("#flowStateLabel")) {
    $("#flowStateLabel").textContent = "LIVE · DECODE";
  }
  if (time - flowState.lastReadout > 240) {
    flowState.lastReadout = time;
    const live = $("#flowLiveValue");
    if (live) live.textContent = state.engineRunning ? (101 + Math.sin(t * 1.7) * 3.2).toFixed(1) : "—";
  }
}

function drawFlowField(ctx, width, height, time) {
  const dark = resolvedTheme() === "dark";
  const accent = computedColor("--accent");
  const accent2 = computedColor("--accent-2");
  const accent3 = computedColor("--accent-3");
  ctx.clearRect(0, 0, width, height);
  ctx.save();
  ctx.globalCompositeOperation = dark ? "lighter" : "source-over";

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

  const samples = flowHistory.length ? flowHistory.slice(-60) : Array(60).fill(0);
  const padX = 16;
  const top = 24;
  const bottom = height - 18;
  const valueFloor = 60;
  const valueCeiling = 140;
  const points = samples.map((value, index) => ({
    x: padX + (index / (samples.length - 1)) * (width - padX * 2),
    y: bottom - ((Math.max(valueFloor, Math.min(valueCeiling, value)) - valueFloor) / (valueCeiling - valueFloor)) * (bottom - top),
  }));
  const path = () => {
    ctx.beginPath();
    ctx.moveTo(points[0].x, points[0].y);
    for (let index = 1; index < points.length - 1; index++) {
      const next = points[index + 1];
      const midX = (points[index].x + next.x) / 2;
      const midY = (points[index].y + next.y) / 2;
      ctx.quadraticCurveTo(points[index].x, points[index].y, midX, midY);
    }
    ctx.lineTo(points[points.length - 1].x, points[points.length - 1].y);
  };

  const area = ctx.createLinearGradient(0, 0, 0, height);
  area.addColorStop(0, colorWithAlpha(accent, dark ? .14 : .12));
  area.addColorStop(.72, colorWithAlpha(accent3, dark ? .045 : .04));
  area.addColorStop(1, colorWithAlpha(accent, 0));
  path();
  ctx.lineTo(points[points.length - 1].x, height);
  ctx.lineTo(points[0].x, height);
  ctx.closePath();
  ctx.fillStyle = area;
  ctx.fill();

  const stroke = ctx.createLinearGradient(0, 0, width, 0);
  stroke.addColorStop(0, colorWithAlpha(accent3, 0));
  stroke.addColorStop(.12, colorWithAlpha(accent3, .7));
  stroke.addColorStop(.5, colorWithAlpha(accent, .84));
  stroke.addColorStop(.85, colorWithAlpha(accent2, .8));
  stroke.addColorStop(1, colorWithAlpha(accent2, 0));

  path();
  ctx.save();
  ctx.shadowColor = colorWithAlpha(accent, .28);
  ctx.shadowBlur = 18;
  ctx.strokeStyle = stroke;
  ctx.lineWidth = state.engineRunning ? 2 : 1;
  ctx.stroke();
  ctx.restore();

  const head = points[points.length - 1];
  ctx.save();
  ctx.shadowColor = colorWithAlpha(accent2, .9);
  ctx.shadowBlur = 18;
  ctx.fillStyle = colorWithAlpha(accent2, state.engineRunning ? .95 : .28);
  ctx.beginPath();
  ctx.arc(head.x, head.y, state.engineRunning ? 3.2 : 2, 0, Math.PI * 2);
  ctx.fill();
  ctx.restore();
  ctx.restore();

  if (time - flowState.lastReadout > 240) {
    flowState.lastReadout = time;
    const live = $("#flowLiveValue");
    if (live) live.textContent = state.engineRunning ? samples[samples.length - 1].toFixed(1) : "—";
  }
}

function updateFlowProbe(width, height) {
  if (!flowState || flowState.hoverX == null) return;
  const cursor = $("#flowCursor");
  const tooltip = $("#flowTooltip");
  const x = Math.max(12, Math.min(width - 12, flowState.hoverX));
  const progress = Math.max(0, Math.min(1, (x - 16) / Math.max(1, width - 32)));
  const index = Math.max(0, Math.min(flowHistory.length - 1, Math.round(progress * (flowHistory.length - 1))));
  const rate = flowHistory[index] || 0;
  const tokens = Math.round(rate * (1.8 + progress * 2.2));
  const secondsAgo = Math.round((1 - progress) * 60);
  if (cursor) {
    cursor.style.left = `${x}px`;
    cursor.style.opacity = "1";
  }
  if (tooltip) {
    tooltip.innerHTML = `<span>${secondsAgo === 0 ? "NOW" : `${secondsAgo} 秒前`}</span><strong>${state.engineRunning ? rate.toFixed(1) : "—"} tok/s</strong><small>${state.engineRunning ? `${tokens} tokens` : "等待解码"}</small>`;
    const left = x > width - 130 ? x - 126 : x + 12;
    const top = Math.max(36, Math.min(height - 87, (flowState.hoverY || 58) + 16));
    tooltip.style.left = `${left}px`;
    tooltip.style.top = `${top}px`;
    tooltip.style.opacity = "1";
  }
}

function computedColor(variable) {
  const value = getComputedStyle(document.documentElement).getPropertyValue(variable).trim();
  return value || "#d94d78";
}

function colorWithAlpha(color, alpha) {
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

function startAmbient() {
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

function drawAmbient(time = 0) {
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

function bindGlobalEvents() {
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
  if ($("#commandTrigger")) $("#commandTrigger").addEventListener("click", openCommand);
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
    if (window.FCChatThinking?.isOpen()) window.FCChatThinking.close();
    else window.FCChatThinking?.open(thinkingTrigger, state, {
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
      state.settings.reasoningEffortLabel = window.FCChatThinking.EFFORTS.find((item) => item.value === value)?.label || value;
    }
    if (kind === "mode" && value === "on") {
      requestAnimationFrame(() => window.FCChatThinking?.update(state));
    } else {
      window.FCChatThinking?.update(state);
      window.FCChatThinking?.close();
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

function handleAction(action, element) {
  switch (action) {
    case "refresh-overview":
      showToast("状态已刷新");
      pulseHaptic();
      break;
    case "request-detail":
      showToast("请求详情已在实时流中定位");
      break;
    case "toggle-engine":
      toggleEngine();
      break;
    case "model-menu":
      openModelPopover(element);
      break;
    case "open-inspector":
      openInspector();
      break;
    case "engine-config":
      showToast("引擎配置已打开");
      break;
    case "downloads":
      openDownloads();
      break;
    case "send-chat":
      sendChat();
      break;
    case "toggle-reasoning": {
      const reasoning = element.closest(".reasoning");
      const open = reasoning.classList.toggle("open");
      element.setAttribute("aria-expanded", String(open));
      break;
    }
    case "chat-more":
      showToast("对话已保存到本地");
      break;
    case "new-chat":
      state.chatMessages = [];
      state.chatStreaming = false;
      renderPage(false);
      showToast("已新建对话");
      break;
    case "recent-chat":
      navigate("chat");
      break;
    case "thinking-cycle":
      cycleThinking();
      break;
    case "search-hub":
      closeOverlays();
      showToast("模型广场已准备就绪");
      break;
    case "refresh-models":
      showToast("模型状态已刷新");
      break;
    case "refresh-engines":
      showToast("引擎状态已刷新");
      break;
    case "use-model":
      showToast("当前权重已在使用");
      break;
    case "model-detail":
    case "model-more":
      showToast("模型详情已展开");
      break;
    case "check-updates":
      showToast("三个引擎均为最新版本");
      break;
    case "toggle-log-pause":
      state.logPaused = !state.logPaused;
      renderPage(false);
      showToast(state.logPaused ? "日志已暂停跟随" : "日志已恢复实时跟随");
      break;
    case "clear-logs":
      logSequence = 0;
      renderPage(false);
      showToast("已清空当前视图日志");
      break;
    case "log-copy":
      copyText($$(".log-line:not(.hidden) .msg").map((node) => node.textContent).join("\n"));
      break;
    case "reset-settings":
      resetSettings();
      break;
    case "reset-params":
      state.params = { temperature: .7, topP: .92, tokens: 4096, thinking: "自动" };
      openInspector();
      break;
    case "save-params":
      closeOverlays();
      showToast("生成参数已应用");
      break;
  }
}

function resetSettings() {
  state.settings = { launchEngine: true, login: true, gateway: true, thinking: "自动" };
  state.theme = "system";
  state.settings.appearance = "system";
  localStorage.removeItem("fc-preview-theme");
  document.documentElement.dataset.theme = resolvedTheme();
  updateThemeIcon();
  renderPage(false);
  showToast("设置已恢复为默认值");
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
    grid.innerHTML = window.FCModelWorkspace.cards(filtered, state);
  };
  if (window.FCMotionGuard) {
    window.FCMotionGuard.fadeSwap(grid, commit, {
      durationOut: 70,
      durationIn: 150,
      distance: 3,
    });
  } else {
    commit();
  }
}

function updateEngineTabIndicator(prepare = true) {
  const tabs = $("[data-engine-tabs]");
  if (!tabs) return;
  if (tabs.classList.contains("fc-model-engine-switch")) {
    const engines = ["全部", "Splash", "oMLX", "MTPLX"];
    tabs.style.setProperty("--fc-filter-index", String(Math.max(0, engines.indexOf(state.modelFilter))));
    return;
  }
  const active = $("button.active", tabs);
  const indicator = tabs ? $(".engine-tab-indicator", tabs) : null;
  if (!tabs || !active || !indicator) return;
  indicator.style.width = `${active.offsetWidth}px`;
  indicator.style.transform = `translateX(${active.offsetLeft - 3}px)`;
  if (prepare) requestAnimationFrame(() => tabs.classList.add("is-ready"));
}

function updateSlidingSegments() {
  $$("[data-sliding-segments]").forEach(updateSlidingSegment);
}

function syncThinkingTriggerLabel() {
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
  if (!container) return;
  const active = $("button.active", container);
  const slider = $(".segment-slider", container);
  if (!active || !slider) return;
  slider.style.width = `${active.offsetWidth}px`;
  slider.style.left = `${active.offsetLeft}px`;
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
    grid.innerHTML = window.FCModelWorkspace.cards(filtered, state);
    grid.classList.remove("is-leaving");
    grid.classList.add("is-entering");
    setTimeout(() => {
      if (token === modelListAnimationToken) grid.classList.remove("is-entering");
    }, 520);
  }, 110);
}

function filterLogRows() {
  const query = state.logSearch.toLowerCase();
  const level = state.logFilter === "提示" ? "INFO" : state.logFilter === "警告" ? "WARN" : state.logFilter === "错误" ? "ERROR" : "";
  $$(".log-line").forEach((line) => {
    const matchesLevel = !level || line.dataset.logLevel === level;
    const matchesSearch = !query || line.dataset.logText.includes(query);
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
      line.animate(
        [{ opacity: 0, transform: "translateY(-3px)" }, { opacity: 1, transform: "none" }],
        { duration: 180, easing: "cubic-bezier(.16,1,.3,1)" }
      );
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
  if (state.page === "chat" && event.key === "Enter" && !event.shiftKey && event.target.id === "chatInput") {
    event.preventDefault();
    sendChat();
  }
  if (event.target.matches(".reasoning-toggle") && (event.key === "Enter" || event.key === " ")) {
    event.preventDefault();
    event.target.click();
  }
}

document.addEventListener("DOMContentLoaded", init);
window.addEventListener("beforeunload", () => {
  if (ambientAnimation) cancelAnimationFrame(ambientAnimation);
});
