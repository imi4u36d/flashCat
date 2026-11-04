/* flashCat · overview component library
   Every region on the overview page is rendered as an independent widget.
   Components only receive view state and return markup; interaction stays in app.js. */
(function () {
  "use strict";

  const icon = (name, size = 16) => window.FCIcons.svg(name, "", size);
  const esc = (value) => String(value == null ? "" : value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
  const shortModel = (model) => {
    const canonical = String(model || "").trim().replace(/--/g, "/");
    return canonical ? canonical.split("/").pop() : "未选择模型";
  };
  const displayModel = shortModel;
  const rollingText = (text) => Array.from(text).map((char, index) =>
    `<span class="model-char" style="--i:${index}">${char === " " ? "&nbsp;" : esc(char)}</span>`).join("");

  function pageHeader() {
    return `
      <header class="page-header overview-heading">
        <div>
          <span class="eyebrow">FLASHCAT / OVERVIEW</span>
          <h1 class="page-title">概览</h1>
          <p class="page-subtitle">本地推理、接口与设备状态，组合成一个持续更新的控制面。</p>
        </div>
        <div class="page-actions">
          <button class="button" type="button" data-action="refresh-overview">
            ${icon("refresh", 14)}<span>刷新</span>
          </button>
          <button class="button" type="button" data-action="open-inspector">
            ${icon("sliders", 14)}<span>运行参数</span>
          </button>
        </div>
      </header>`;
  }

  function engineWidget(state, rate) {
    const running = state.engineRunning;
    const busy = state.engineBusy;
    const status = busy ? "正在切换" : running ? "运行中" : "已停止";
    return `
      <section class="widget engine-widget widget-span-8" data-widget="engine">
        <div class="engine-widget-main">
          <div class="engine-widget-copy">
            <span class="status-pill ${running ? "" : "stopped"}"><i></i>Splash · ${status}</span>
            <h2 class="model-title" data-model-title title="${esc(shortModel(state.model))}">${rollingText(displayModel(state.model))}</h2>
            <div class="engine-actions">
              <button class="button primary" type="button" data-action="model-menu">
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
              <span><i></i>${busy ? "SWITCHING" : running ? "LIVE DECODE" : "ENGINE IDLE"}</span>
              <b>${running ? "2 SESSIONS" : "QUEUE 0"}</b>
            </div>
            <div class="engine-live-rate">
              <strong>${running ? rate.toFixed(1) : "—"}</strong><span>tok/s</span>
            </div>
            <div class="engine-live-rhythm" aria-hidden="true">
              ${Array.from({ length: 20 }, (_, index) => `<i style="--h:${24 + ((index * 31) % 68)}%;--d:${index * 52}ms"></i>`).join("")}
            </div>
          </div>
        </div>
      </section>`;
  }

  function gatewayWidget() {
    return `
      <section class="widget gateway-widget widget-span-4" data-widget="gateway">
        <div class="widget-topline">
          <div class="widget-identity">
            <span class="widget-symbol gateway-symbol">${icon("network", 16)}</span>
            <div><strong>API 网关</strong><span>OpenAI + Claude</span></div>
          </div>
          <span class="online-pill"><i></i>ONLINE</span>
        </div>
        <div class="gateway-addresses">
          ${gatewayAddress("OpenAI", "http://127.0.0.1:9000/v1", "openai")}
          ${gatewayAddress("Claude", "http://127.0.0.1:9000", "claude")}
        </div>
      </section>`;
  }

  // 两个协议各自的「产品图标」：OpenAI 的结、Claude 的放射星。
  // 都是白色单色字形（brand-*.png），底色由 .provider-mark 的品牌色给。
  function gatewayAddress(label, address, kind) {
    return `
      <div class="gateway-address">
        <span class="provider-mark ${kind}"><img class="provider-glyph" src="brand-${esc(kind)}.png" alt=""></span>
        <div>
          <span>${esc(label)}</span>
          <code>${esc(address)}</code>
        </div>
        <button class="copy-btn" type="button" data-copy="${esc(address)}"
                aria-label="复制 ${esc(label)} 地址">${icon("copy", 13)}</button>
      </div>`;
  }

  const METRICS = [
    { key: "context", icon: "layers", label: "当前上下文", tag: "CTX", unit: "/ 262K", hint: "当前会话" },
    { key: "ttft", icon: "timer", label: "首字延迟", tag: "TTFT", unit: "ms", hint: "最近请求 · 正常" },
    { key: "prefill", icon: "arrowUp", label: "预填充", tag: "PREFILL", unit: "tok/s", hint: "引擎采样值" },
    { key: "memory", icon: "hardDrive", label: "内存压力", tag: "MEM", unit: "%", hint: "65.5 GB / 128 GB" },
  ];

  function metricsWidget(state, rate) {
    const values = {
      context: state.engineRunning ? "430" : "—",
      ttft: state.engineRunning ? "131" : "—",
      prefill: state.engineRunning ? "1,370" : "—",
      memory: state.engineRunning ? "51" : "—",
    };
    return `
      <div class="metric-widget-row widget-span-12">
        ${METRICS.map((metric) => metricWidget(metric, values[metric.key])).join("")}
      </div>`;
  }

  function metricWidget(metric, value) {
    return `
      <section class="widget metric-widget metric-${metric.key}" data-widget="metric-${metric.key}">
        <div class="metric-widget-head">
          <span class="metric-widget-icon">${icon(metric.icon, 14)}</span>
          <span>${esc(metric.label)}</span>
          <span class="metric-widget-tag">${esc(metric.tag)}</span>
        </div>
        <div class="metric-widget-value">
          <strong>${esc(value)}</strong><span>${esc(metric.unit)}</span>
        </div>
        <div class="metric-widget-hint">${esc(metric.hint)}</div>
        ${metricVisual(metric.key)}
      </section>`;
  }

  function metricVisual(kind) {
    if (kind === "context") {
      return `<div class="metric-context-meter" aria-hidden="true">
        <i style="width:1.4%"></i><span>430 tokens</span>
      </div>`;
    }
    if (kind === "ttft") {
      return `<div class="metric-latency" aria-hidden="true">
        <span></span><span></span><span></span><span></span><span></span><span></span><span></span>
        <i></i>
      </div>`;
    }
    if (kind === "prefill") {
      return `<div class="metric-burst" aria-hidden="true">
        <i></i><i></i><i></i><i></i><i></i>
      </div>`;
    }
    return `<div class="metric-capacity" aria-hidden="true">${Array.from({ length: 22 }, (_, index) =>
      `<i class="${index < 11 ? "filled" : ""}" style="--d:${index * 22}ms"></i>`).join("")}</div>`;
  }

  function tokenFlowWidget(state, rate) {
    return `
      <section class="widget token-widget widget-span-8" data-widget="token-flow">
        <div class="flow-minimal-head">
          <span>总解码 · 最近 60 秒</span>
          <span class="online-pill"><i></i>LIVE</span>
        </div>
        <div class="flow-total">
          <strong id="flowLiveValue">${state.engineRunning ? rate.toFixed(1) : "—"}</strong>
          <span>tok/s</span>
        </div>
        <div class="flow-stage" id="flowStage">
          <canvas id="flowCanvas" aria-label="实时 Token 流可视化"></canvas>
          <div class="flow-cursor" id="flowCursor" aria-hidden="true"></div>
          <div class="flow-tooltip" id="flowTooltip" aria-hidden="true">
            <span>PROBE</span><strong>— tok/s</strong><small>— tokens</small>
          </div>
        </div>
      </section>`;
  }

  function requestWidgets() {
    const requests = [
      { id: "#1844", kind: "OpenAI", state: "解码", meta: "0.8s · Qwen3.8", rate: "104.0", color: "warn" },
      { id: "#1843", kind: "Claude", state: "完成", meta: "刚刚 · Qwen3.8", rate: "87.4", color: "ok" },
      { id: "#1842", kind: "OpenAI", state: "完成", meta: "12s · Qwen3.8", rate: "96.2", color: "ok" },
      { id: "#1841", kind: "Claude", state: "完成", meta: "32s · Qwen3.6", rate: "91.7", color: "ok" },
      { id: "#1840", kind: "OpenAI", state: "完成", meta: "48s · Qwen3.8", rate: "102.4", color: "ok" },
    ];
    return `
      <section class="widget requests-widget widget-span-4" data-widget="requests">
        <div class="requests-head">
          <span>最近请求</span>
          <span>${requests.length} 条</span>
        </div>
        <div class="request-list">
          ${requests.map((request) => `
            <button class="request-row" type="button" data-action="request-detail">
              <span class="request-state ${request.color}"><i></i></span>
              <span class="request-row-main">
                <strong>${esc(request.kind)} <small>${esc(request.id)}</small></strong>
                <span>${esc(request.meta)}</span>
              </span>
              <span class="request-row-rate">${esc(request.rate)}<small>tok/s</small></span>
            </button>`).join("")}
        </div>
        <div class="requests-foot"><span>全部请求</span><strong>42</strong><span>失败</span><strong>0</strong></div>
      </section>`;
  }

  window.FCWidgets = {
    overview(state, rate) {
      return `
        <div class="overview-widget-grid">
          ${engineWidget(state, rate)}
          ${gatewayWidget()}
          ${metricsWidget(state, rate)}
          ${tokenFlowWidget(state, rate)}
          ${requestWidgets()}
        </div>`;
    },
  };
}());
