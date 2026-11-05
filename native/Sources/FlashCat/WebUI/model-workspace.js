/* flashCat · model workspace
   Pure render API for the model library. Interaction stays in the host shell. */
import { esc } from "./esc.js";
import { FCIcons } from "./icons.js";
import { FCModelBrand } from "./model-brand.js";


const DEFAULT_ENGINES = ["全部", "Splash", "oMLX", "MTPLX"];
function engineNames(state) {
  if (state && Array.isArray(state.engineCatalog) && state.engineCatalog.length) {
    return ["全部", ...state.engineCatalog.map((engine) => engine.id)];
  }
  if (state && Array.isArray(state.engines) && state.engines.length) {
    return ["全部", ...state.engines.map((engine) => engine.id)];
  }
  return DEFAULT_ENGINES;
}
const ENGINE_COLORS = {
  Splash: "#ff7a59",
  oMLX: "#5caeff",
  MTPLX: "#9a7cff",
};

const icon = (name, size) => {
  if (FCIcons && typeof FCIcons.svg === "function") {
    return FCIcons.svg(name, "", size);
  }
  return "";
};

function canonicalName(value) {
  return String(value == null ? "" : value).trim().replace(/--/g, "/");
}

function shortName(value) {
  const canonical = canonicalName(value);
  if (!canonical) return "未命名模型";
  return canonical.split("/").pop() || canonical;
}

function friendlyName(model) {
  return shortName(model && model.name);
}

// The download center and the model card must tell the same story. The host
// hands over one table keyed by `engine|repo` (and by repo alone), so a
// paused row, a failed row and a live transfer all land on the same card.
// Card ids may be flat (`owner--repo`) while the task is `owner/repo`, hence
// the canonical lookup; the old preview mock only fills downloadsInFlight.
function downloadState(model, state) {
  const id = canonicalName(model.name);
  const engine = String(model.engineId || (model.entry && model.entry.engine) || "");
  const table = state.downloadStates instanceof Map ? state.downloadStates : null;
  let task = null;
  if (table) {
    // Prefer the engine-specific row: a per-engine download for Splash must
    // not light up Strata's card for the same repository id. A shared task
    // is the exception — one copy in the common folder serves every engine
    // it was authorized for, so its progress belongs on each of their cards.
    task = engine ? (table.get(engine + "|" + id) || null) : null;
    const generic = table.get(id);
    if (!task && generic && (!engine || generic.shared)) task = generic;
  }
  if (!task && state.downloadsInFlight instanceof Map) {
    const value = state.downloadsInFlight.has(model.name)
      ? state.downloadsInFlight.get(model.name)
      : state.downloadsInFlight.has(id) ? state.downloadsInFlight.get(id) : null;
    if (value != null) {
      task = { status: "downloading", progress: value, indeterminate: false };
    }
  }
  if (!task) return null;
  const raw = Number(task.progress);
  return {
    status: String(task.status || "downloading"),
    progress: Number.isFinite(raw) ? Math.max(0, Math.min(100, raw)) : 0,
    indeterminate: !!task.indeterminate || !Number.isFinite(raw),
    // A shared task lives under the engine that started it, which may not be
    // the engine tab this card is shown in. The continue button has to address
    // the download-center row itself, so carry the row's own engine/model.
    engine: String(task.engine || engine || ""),
    model: String(task.model || model.name || ""),
  };
}

function modelState(model, state) {
  const current = canonicalName(model.name) === canonicalName(state.model);
  const task = downloadState(model, state);
  const downloading = !!task && (task.status === "downloading" || task.status === "queued");
  const paused = !!task && task.status === "paused";
  const failed = !!task && task.status === "failed";
  // A row in the download center means the weights are not finished. Never
  // fall back to the scanned folder in that state: half a snapshot already
  // has config.json and a tokenizer, which is enough for the scanner to call
  // it installed. The card stays on the progress action until the row goes.
  const downloaded = !task && (
    model.installed ||
    (state.downloaded instanceof Set && state.downloaded.has(model.name))
  );
  return {
    current,
    inFlight: downloading || paused || failed,
    downloading,
    paused,
    failed,
    busy: !!task,
    downloaded,
    progress: task ? task.progress : 0,
    indeterminate: !!task && task.indeterminate,
    // 继续按钮直接点名下载中心里的那一行；没有任务时退回卡片自己的引擎/id。
    downloadEngine: task ? task.engine : (model.engineId || ""),
    downloadModel: task ? task.model : model.name,
  };
}

// 只描述「卡片长什么样」的那几位状态。百分比不在这里：它每半秒变一次，
// 交给 patchProgress 原地改数字，卡片节点不动。
function selectionKey(modelStatus) {
  return [
    modelStatus.current ? "cur" : "-",
    modelStatus.downloaded ? "dl" : "-",
    modelStatus.downloading ? "ing" : modelStatus.paused ? "pause" : modelStatus.failed ? "fail" : "-",
  ].join("|");
}

function filterModels(models, state = {}) {
  const list = Array.isArray(models) ? models : [];
  const engines = engineNames(state);
  const filter = engines.includes(state.modelFilter) ? state.modelFilter : "全部";
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

// 卡片上带百分比的文案只在这里生成：整页渲染和下面的原地补丁共用一套
// 措辞，否则心跳补一次数字就会和刚渲染出来的文案对不上。
function actionLabel(modelStatus) {
  const percent = Math.round(modelStatus.progress);
  // 暂停卡片上的按钮本身就是「继续」：文案得说它会做什么，而不是再报一遍
  // 「已暂停」。「已下载 / 下载中」这类状态不再单独占一枚胶囊。
  if (modelStatus.paused) return modelStatus.indeterminate ? "继续" : `继续 ${percent}%`;
  return modelStatus.indeterminate ? "下载中" : `${percent}%`;
}

// 卡片右上角原来是一枚下载状态胶囊，胶囊删掉后这个位置交给「更多操作」
// 菜单：菜单里全是针对已落盘权重才有意义的条目（在 Finder 中显示、复制
// ID、删除），所以没下载完的卡片不开这枚按钮。
function menuMarkup(model, state) {
  const modelStatus = modelState(model, state);
  if (!modelStatus.downloaded) return "";
  return `<button class="fc-model-menu" type="button" data-model-more="${esc(model.name)}"
    aria-label="更多操作" title="更多操作">${icon("ellipsis", 14)}</button>`;
}

function actionMarkup(model, state) {
  const modelStatus = modelState(model, state);
  if (modelStatus.current) {
    return `<span class="fc-model-action fc-model-action-static">${icon("activity", 12)}<span>使用中</span></span>`;
  }
  // Paused rows keep the card out of the "使用" state. 继续 resumes the same
  // download-center row in place — that is the whole point of a paused card,
  // and opening the center first only adds a step. The running transfer still
  // opens the center (there is nothing to continue there).
  if (modelStatus.downloading) {
    return `<button class="fc-model-action fc-model-action-progress" type="button" data-action="downloads"
      aria-label="在下载中心查看下载进度" title="在下载中心查看">
      ${icon("loader", 12)}<span>${actionLabel(modelStatus)}</span>
    </button>`;
  }
  if (modelStatus.paused) {
    return `<button class="fc-model-action fc-model-action-paused" type="button"
      data-dl="resume" data-engine="${esc(modelStatus.downloadEngine)}" data-model="${esc(modelStatus.downloadModel)}"
      aria-label="继续下载" title="继续下载">
      ${icon("play", 12)}<span>${actionLabel(modelStatus)}</span>
    </button>`;
  }
  if (modelStatus.failed) {
    return `<button class="fc-model-action fc-model-action-failed" type="button" data-action="downloads"
      aria-label="在下载中心重试下载" title="在下载中心重试">
      ${icon("alert", 12)}<span>下载失败</span>
    </button>`;
  }
  if (modelStatus.downloaded) {
    return `<button class="fc-model-action fc-model-action-downloaded" type="button" data-select-model="${esc(model.name)}">
      ${icon("play", 12)}<span>使用</span>
    </button>`;
  }
  return `<button class="fc-model-action" type="button" data-download-model="${esc(model.name)}">
    ${icon("download", 12)}<span>下载</span>
  </button>`;
}

// 模型家族标记：看得懂「这是 Qwen 还是 MiMo」，而不是一排同样的 CPU 芯片。
// 认不出家族时退回首字母（Strata-Serve-8B 读作 S），仍比通用图标好认。
function modelSeries(model) {
  return FCModelBrand
    && typeof FCModelBrand.seriesOf === "function"
    && typeof FCModelBrand.tile === "function"
    ? FCModelBrand.seriesOf(model)
    : null;
}

function engineMark(model) {
  if (!modelSeries(model)) {
    return `<span class="widget-symbol fc-model-engine-mark">${icon("cpu", 16)}</span>`;
  }
  return FCModelBrand.tile(model, {
    size: 18,
    className: "widget-symbol fc-model-engine-mark fc-model-series-mark",
  });
}

function card(model, state, index) {
  const modelStatus = modelState(model, state);
  const engine = model.engine || "Unknown";
  const color = (state.engineAccents && state.engineAccents[engine]) || ENGINE_COLORS[engine] || "var(--fc-model-fallback)";
  const series = modelSeries(model);
  // 副标题跟图标说同一件事：先家族、后格式。引擎仍由加粗行和下方
  // ENGINE 规格承担，这样图标不会被误读成「引擎的徽标」。MTPLX 包
  // 的格式和引擎同名，只写一次。
  const format = model.format || "";
  const bits = [series && series.label, format && format !== engine ? format : ""].filter(Boolean);
  const meta = bits.length ? bits.join(" · ") : (format || "LOCAL");
  const tags = (Array.isArray(model.flags) ? model.flags : []).slice(0, 3);
  const classes = [
    "widget",
    "fc-model-card",
    modelStatus.current ? "fc-model-card-current" : "",
    modelStatus.inFlight ? "fc-model-card-downloading" : "",
    modelStatus.downloaded && !modelStatus.current ? "fc-model-card-downloaded" : "",
  ].filter(Boolean).join(" ");

  return `<article class="${classes}" style="--fc-card-index:${index}; --fc-engine:${esc(color)}"
    data-model-name="${esc(model.name)}" data-fc-selection="${selectionKey(modelStatus)}"
    ${modelStatus.current ? 'aria-current="true"' : ""}>
    <header class="fc-model-card-head widget-topline">
      <div class="widget-identity">
        ${engineMark(model)}
        <div>
          <strong>${esc(engine)}</strong>
          <span>${esc(meta)}</span>
        </div>
      </div>
      ${menuMarkup(model, state)}
    </header>

    <div class="fc-model-card-body">
      <h2 title="${esc(canonicalName(model.name) || "本地模型")}">${esc(friendlyName(model))}</h2>
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
      <div class="fc-model-card-actions">
        ${actionMarkup(model, state)}
      </div>
    </footer>

    ${(modelStatus.downloading || modelStatus.paused) ? `<span class="fc-model-card-progress ${modelStatus.paused ? "is-paused" : ""}" aria-hidden="true">
      <i style="width:${modelStatus.progress}%"></i>
    </span>` : ""}
  </article>`;
}

// 下载进度是唯一每半秒都在变的东西，但它只值一个数字和一条宽度。整页重渲染
// 会把卡片节点整批换掉：鼠标正停在卡片上时，那一帧里新节点还没有 :hover，
// 描边和投影的过渡于是一次次从基础态重放 —— 看起来就是卡片一直在闪。
// 所以进度走这里原地改写，卡片、图标、进度条都留在原来的节点上。
function patchProgress(root, models, state = {}) {
  if (!root || typeof root.querySelectorAll !== "function" || !Array.isArray(models)) return;
  const byName = new Map();
  models.forEach((model) => byName.set(model.name, model));

  root.querySelectorAll(".fc-model-card[data-model-name]").forEach((node) => {
    const model = byName.get(node.dataset.modelName);
    if (!model) return;
    const modelStatus = modelState(model, state);
    // 状态本身变了（下载中 → 已下载、暂停 → 继续）是要换结构的，交给整页
    // 渲染；这里只处理仍在进行中的百分比。
    if (!modelStatus.inFlight) return;

    // 只认和当前状态配套的那枚按钮：DOM 和状态对不上时留给整页渲染，
    // 不在这里猜。
    const action = node.querySelector(modelStatus.downloading
      ? ".fc-model-action-progress"
      : ".fc-model-action-paused");
    if (action) setLabelText(action, actionLabel(modelStatus));

    const bar = node.querySelector(".fc-model-card-progress > i");
    if (bar) {
      const width = `${modelStatus.progress}%`;
      if (bar.style.width !== width) bar.style.width = width;
    }
  });
}

// 状态胶囊是 <i></i>文字，按钮是 <svg/><span>文字</span>。只改文字节点：
// 图标（下载中那枚一直在转）保持同一个节点，动画不会被补丁打断。
function setLabelText(node, text) {
  const slot = node.querySelector("span") || node.lastChild;
  if (!slot) return;
  if (slot.nodeType === 3) {
    if (slot.nodeValue !== text) slot.nodeValue = text;
  } else if (slot.textContent !== text) {
    slot.textContent = text;
  }
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
  const engines = engineNames(state);
  const filter = engines.includes(state.modelFilter) ? state.modelFilter : "全部";
  const filtered = filterModels(models, state);

  return `<section class="fc-model-workspace" data-fc-model-workspace>
    <header class="fc-model-toolbar">
      <div class="fc-model-engine-switch" data-engine-tabs aria-label="按引擎筛选">
        <span class="fc-model-filter-indicator" aria-hidden="true"></span>
        ${engines.map((engine) => `<button type="button"
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

      <button class="fc-model-tools" type="button" data-action="open-hub"
        aria-label="模型广场" title="模型广场">
        ${icon("cloudDownload", 14)}<span>模型广场</span>
      </button>
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

// 「使用中」是换模型时唯一变的东西，但整页渲染会换掉所有卡片节点：
// 失去的那张瞬间掉回普通底，赢得的那张直接带着选中描边出现 —— 于是
// 选中变化看起来是「跳」的。这里只动相关的两张卡，并给它们一个落位动画。
function patchSelection(root, models, state = {}) {
  if (!root || typeof root.querySelectorAll !== "function" || !Array.isArray(models)) return;
  const byName = new Map();
  models.forEach((model) => byName.set(model.name, model));

  root.querySelectorAll(".fc-model-card[data-model-name]").forEach((node) => {
    const model = byName.get(node.dataset.modelName);
    if (!model) return;
    const modelStatus = modelState(model, state);
    const key = selectionKey(modelStatus);
    if (node.dataset.fcSelection === key) return;
    const wasCurrent = node.classList.contains("fc-model-card-current");
    node.dataset.fcSelection = key;
    node.classList.toggle("fc-model-card-current", modelStatus.current);
    node.classList.toggle("fc-model-card-downloading", modelStatus.inFlight);
    node.classList.toggle("fc-model-card-downloaded", modelStatus.downloaded && !modelStatus.current);
    if (modelStatus.current) node.setAttribute("aria-current", "true");
    else node.removeAttribute("aria-current");

    const actions = node.querySelector(".fc-model-card-actions");
    if (actions) {
      // 只换那枚「使用 / 使用中」按钮。右上角菜单按钮的增删跟着下载状态走，
      // 那种变化会让指纹失效、整页重绘，不在这个局部补丁里猜。
      const action = actions.querySelector(".fc-model-action");
      if (action) action.outerHTML = actionMarkup(model, state);
    }

    if (modelStatus.current && !wasCurrent) {
      node.classList.add("is-just-selected");
      clearTimeout(node.__selectionTimer);
      node.__selectionTimer = setTimeout(() => node.classList.remove("is-just-selected"), 640);
    } else if (!modelStatus.current && wasCurrent) {
      node.classList.add("is-just-released");
      clearTimeout(node.__selectionTimer);
      node.__selectionTimer = setTimeout(() => node.classList.remove("is-just-released"), 520);
    }
  });
}

export const FCModelWorkspace = {
  render,
  cards,
  patchProgress,
  patchSelection,
  filterModels,
  modelTiles: cards,
};
