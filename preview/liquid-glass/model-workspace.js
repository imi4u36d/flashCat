/* flashCat · model workspace
   Pure render API for the model library. Interaction stays in the host shell. */
(function () {
  "use strict";

  const ENGINES = ["全部", "Splash", "oMLX", "MTPLX"];
  const ENGINE_COLORS = {
    Splash: "#ff7a59",
    oMLX: "#5caeff",
    MTPLX: "#9a7cff",
  };

  const esc = (value) => String(value == null ? "" : value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");

  const icon = (name, size) => {
    if (window.FCIcons && typeof window.FCIcons.svg === "function") {
      return window.FCIcons.svg(name, "", size);
    }
    return "";
  };

  function shortName(value) {
    return String(value || "未命名模型").split("/").pop();
  }

  function friendlyName(model) {
    const raw = shortName(model && model.name);
    const knownNames = [
      ["Qwen3.8-Flash-Next", "Qwen3.8 Flash-Next"],
      ["Qwen3.8-27B", "Qwen3.8 27B"],
      ["Qwen3.6-35B", "Qwen3.6 35B"],
      ["Qwen3.5-4B", "Qwen3.5 4B"],
      ["MiMo-9B", "MiMo 9B"],
      ["Strata-Serve-8B", "Strata 8B"],
    ];
    const match = knownNames.find(([needle]) => raw.includes(needle));
    if (match) return match[1];

    return raw
      .replace(/(?:-GSQ|-RCO|-GGUF|-MLX|-MTPLX|-4bit|-Q4_K_M)+$/gi, "")
      .replace(/[-_]+/g, " ")
      .replace(/\s+/g, " ")
      .trim();
  }

  function modelState(model, state) {
    const current = model.name === state.model;
    const inFlight = state.downloadsInFlight instanceof Map
      ? state.downloadsInFlight.has(model.name)
      : false;
    const downloaded = model.installed ||
      (state.downloaded instanceof Set && state.downloaded.has(model.name));
    const progress = state.downloadsInFlight instanceof Map
      ? Math.max(0, Math.min(100, Number(state.downloadsInFlight.get(model.name)) || 0))
      : 0;
    return { current, inFlight, downloaded, progress };
  }

  function filterModels(models, state = {}) {
    const list = Array.isArray(models) ? models : [];
    const filter = ENGINES.includes(state.modelFilter) ? state.modelFilter : "全部";
    const search = String(state.modelSearch || "").trim().toLocaleLowerCase();

    return list.filter((model) => {
      const engineMatch = filter === "全部" || model.engine === filter;
      const haystack = [
        model.name,
        model.repo,
        model.engine,
        model.format,
        friendlyName(model),
        ...(Array.isArray(model.flags) ? model.flags : []),
      ].join(" ").toLocaleLowerCase();
      return engineMatch && (!search || haystack.includes(search));
    });
  }

  function statusMarkup(model, state) {
    const modelStatus = modelState(model, state);
    if (modelStatus.current) {
      return `<span class="fc-model-status fc-model-status-current"><i></i>使用中</span>`;
    }
    if (modelStatus.inFlight) {
      return `<span class="fc-model-status fc-model-status-downloading"><i></i>下载</span>`;
    }
    if (modelStatus.downloaded) {
      return `<span class="fc-model-status fc-model-status-downloaded">${icon("check", 10)}已下载</span>`;
    }
    return `<span class="fc-model-status"><i></i>下载</span>`;
  }

  function actionMarkup(model, state) {
    const modelStatus = modelState(model, state);
    if (modelStatus.current) {
      return `<span class="fc-model-action fc-model-action-static">${icon("activity", 12)}<span>使用中</span></span>`;
    }
    if (modelStatus.inFlight) {
      return `<button class="fc-model-action fc-model-action-progress" type="button" data-download-model="${esc(model.name)}" disabled>
        ${icon("loader", 12)}<span>${Math.round(modelStatus.progress)}%</span>
      </button>`;
    }
    if (modelStatus.downloaded) {
      return `<button class="fc-model-action fc-model-action-downloaded" type="button" data-select-model="${esc(model.name)}">
        ${icon("check", 12)}<span>已下载</span>
      </button>`;
    }
    return `<button class="fc-model-action" type="button" data-download-model="${esc(model.name)}">
      ${icon("download", 12)}<span>下载</span>
    </button>`;
  }

  function card(model, state, index) {
    const modelStatus = modelState(model, state);
    const engine = model.engine || "Unknown";
    const color = ENGINE_COLORS[engine] || "var(--fc-model-fallback)";
    const tags = (Array.isArray(model.flags) ? model.flags : []).slice(0, 3);
    const classes = [
      "widget",
      "fc-model-card",
      modelStatus.current ? "fc-model-card-current" : "",
      modelStatus.inFlight ? "fc-model-card-downloading" : "",
      modelStatus.downloaded && !modelStatus.current ? "fc-model-card-downloaded" : "",
    ].filter(Boolean).join(" ");

    return `<article class="${classes}" style="--fc-card-index:${index}; --fc-engine:${esc(color)}"
      data-model-name="${esc(model.name)}" ${modelStatus.current ? 'aria-current="true"' : ""}>
      <div class="fc-model-card-sheen" aria-hidden="true"></div>
      <header class="fc-model-card-head widget-topline">
        <div class="widget-identity">
          <span class="widget-symbol fc-model-engine-mark">${icon("cpu", 16)}</span>
          <div>
            <strong>${esc(engine)}</strong>
            <span>${esc(model.format || "LOCAL")}</span>
          </div>
        </div>
        ${statusMarkup(model, state)}
      </header>

      <div class="fc-model-card-body">
        <h2 title="${esc(shortName(model.name))}">${esc(friendlyName(model))}</h2>
        <p class="fc-model-repo" title="${esc(model.repo || "")}">${esc(model.repo || "本地模型")}</p>

        <div class="fc-model-specs" aria-label="模型规格">
          <span><small>ENGINE</small><strong>${esc(engine)}</strong></span>
          <span><small>FORMAT</small><strong>${esc(model.format || "—")}</strong></span>
          <span><small>SIZE</small><strong>${esc(model.size || "—")}</strong></span>
        </div>

        ${tags.length ? `<div class="fc-model-tags">${tags.map((tag) =>
          `<span>${esc(tag)}</span>`).join("")}</div>` : ""}
      </div>

      <footer class="fc-model-card-foot">
        <span class="fc-model-memory">${icon("hardDrive", 12)}<span>${esc(model.memory || "内存未标注")}</span></span>
        ${actionMarkup(model, state)}
      </footer>

      ${modelStatus.inFlight ? `<span class="fc-model-card-progress" aria-hidden="true">
        <i style="width:${modelStatus.progress}%"></i>
      </span>` : ""}
    </article>`;
  }

  function cards(models, state = {}) {
    const list = Array.isArray(models) ? models : [];
    if (!list.length) {
      return `<div class="fc-model-empty">
        <span>${icon("search", 18)}</span>
        <strong>没有匹配的模型</strong>
        <small>调整引擎筛选或搜索词</small>
      </div>`;
    }
    return list.map((model, index) => card(model, state, index)).join("");
  }

  function render(state = {}, models = []) {
    const filter = ENGINES.includes(state.modelFilter) ? state.modelFilter : "全部";
    const filterIndex = Math.max(0, ENGINES.indexOf(filter));
    const filtered = filterModels(models, state);

    return `<section class="fc-model-workspace" data-fc-model-workspace>
      <header class="fc-model-toolbar">
        <div class="fc-model-engine-switch" data-engine-tabs aria-label="按引擎筛选"
          style="--fc-filter-index:${filterIndex}">
          <span class="fc-model-filter-indicator" aria-hidden="true"></span>
          ${ENGINES.map((engine) => `<button type="button"
            class="${filter === engine ? "fc-model-filter-button-active" : ""}"
            data-model-filter="${esc(engine)}"
            aria-pressed="${filter === engine}">${esc(engine)}</button>`).join("")}
        </div>

        <label class="fc-model-search">
          ${icon("search", 14)}
          <input id="modelSearch" type="search" placeholder="搜索模型"
            value="${esc(state.modelSearch || "")}" autocomplete="off" spellcheck="false">
        </label>

        <span class="fc-model-toolbar-spacer"></span>

        <button class="fc-model-refresh" type="button" data-action="refresh-models"
          aria-label="刷新模型" title="刷新模型">
          ${icon("refresh", 14)}
        </button>
      </header>

      <div class="fc-model-grid" id="modelsGrid" data-fc-model-grid>
        ${cards(filtered, state)}
      </div>
    </section>`;
  }

  window.FCModelWorkspace = {
    render,
    cards,
    filterModels,
    modelTiles: cards,
  };
}());
