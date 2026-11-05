/* flashCat WebUI · live store — 快照整形、状态容器、Swift 桥、错误上报与共享工具
 *
 * live 层的数据底座：把 Swift 快照整形进 app.js 的共享 state（adapt 家族，
 * 这是既有架构——app.js 拥有全局 state，依赖方向 store → app.js 与拆分前
 * app.js ↔ live.js 的循环同源，TDZ 安全已用分析器实证，见 docs/reviews 附录 C）；
 * live 界面自身的可变状态收在唯一的 S 容器里——ESM 的导入绑定是只读视图，
 * 裸 let 无法在模块间赋值，容器是唯一正确的跨模块可变状态形态。S.snap 是
 * Swift 推送的最新快照。本层不做 DOM patch、不发命令。
 */

import { LOG_SEED, MODELS, state } from "./app.js";
import { esc } from "./esc.js";

// WKWebView loads this page over file://, where every external script gets an
// opaque origin. WebKit scrubs uncaught exceptions to "Script error." with an
// empty filename and line 0 — exactly the "Script error. / :0:0" red bar that
// used to pop up at the bottom of a perfectly working window. That text has
// no actionable information, so it must not interrupt the UI.
// Errors are now recorded with their real stack whenever one is reachable,
// deduplicated, and forwarded to Swift so the 日志 page keeps a readable
// trace. The red bar survives only as a blank-window fallback: if the very
// first render fails there is nothing else on screen to tell the user.
window.__fcErrors = window.__fcErrors || [];

window.__fcErrorDetails = window.__fcErrorDetails || [];

export const FC_ERROR_LIMIT = 100;

export const FC_REPORT_GAP_MS = 60_000;

export function errorText(value) {
  if (value == null) return "";
  if (typeof value === "string") return value;
  return String(value.stack || value.message || value);
}

export function recordError(source, title, detail, report) {
  const entry = {
    at: new Date().toISOString(),
    source: source || "runtime",
    title: String(title || ""),
    detail: String(detail || ""),
  };
  window.__fcErrorDetails.push(entry);
  if (window.__fcErrorDetails.length > FC_ERROR_LIMIT) window.__fcErrorDetails.shift();
  window.__fcErrors.push(`${entry.at} [${entry.source}] ${entry.title} ${entry.detail}`.trim());
  if (window.__fcErrors.length > FC_ERROR_LIMIT) window.__fcErrors.shift();
  console.error("[flashCat]", entry.source, entry.title, entry.detail);
  if (report === false) return entry;

  // One line per distinct failure per minute, plus a hard floor so a looping
  // render cannot flood the native log with bridge messages.
  const signature = `${entry.title}|${entry.detail.split("\n")[0]}`;
  const now = Date.now();
  if (now - S.lastErrorReportAt < 2_000) return entry;
  if (signature === S.lastErrorSignature && now - S.lastErrorReportAt < FC_REPORT_GAP_MS) return entry;
  S.lastErrorSignature = signature;
  S.lastErrorReportAt = now;
  try {
    cmd("jsError", {
      message: entry.title.slice(0, 500),
      stack: entry.detail.slice(0, 2000),
      source: entry.source,
    });
  } catch (error) { /* bridge not ready yet */ }
  return entry;
}

export function surfaceError(title, detail, source) {
  const raw = String(title || "");
  const scrubbed = !raw || raw === "Script error." || raw === "undefined";
  const entry = recordError(source, raw || "Unknown error", errorText(detail), !scrubbed);
  if (scrubbed || S.pagePainted) return;
  document.title = `flashCat · ${entry.title}`.slice(0, 120);
  try {
    let bar = document.getElementById("fcErrorBar");
    if (!bar) {
      bar = document.createElement("div");
      bar.id = "fcErrorBar";
      bar.style.cssText = "position:fixed;left:12px;right:12px;bottom:12px;z-index:9999;max-height:140px;overflow:auto;padding:10px 12px;border-radius:10px;background:rgba(180,30,50,.92);color:#fff;font:10px/1.5 ui-monospace,monospace;white-space:pre-wrap;pointer-events:auto";
      document.body.appendChild(bar);
    }
    bar.textContent = `${entry.title}\n${entry.detail || ""}`;
    clearTimeout(bar.__timer);
    bar.__timer = setTimeout(() => { if (bar && bar.isConnected) bar.remove(); }, 8000);
  } catch (error) { /* last resort */ }
}

window.addEventListener("error", (event) => {
  // When WebKit hands us the Error object the real message and stack survive;
  // otherwise this is the scrubbed cross-origin form and stays off screen.
  const error = event.error;
  const stack = errorText(error);
  const title = (error && error.message) || event.message || "";
  const location = `${event.filename || ""}:${event.lineno || 0}:${event.colno || 0}`;
  surfaceError(title, stack || location, "window.error");
});

window.addEventListener("unhandledrejection", (event) => {
  surfaceError("Promise rejected", errorText(event.reason), "unhandledrejection");
});

export const rawRAF = window.requestAnimationFrame.bind(window);

window.requestAnimationFrame = function (callback) {
  return rawRAF(function (time) {
    try { callback(time); }
    catch (error) { surfaceError(error && error.message, errorText(error), "raf"); }
  });
};

// ---------- small helpers ----------
export const q = (selector, root = document) => root.querySelector(selector);

export const qa = (selector, root = document) => Array.from(root.querySelectorAll(selector));

// live 界面的全部可变状态（见文件头注释）。
export const S = {
  snap: null,
  pagePainted: false,
  lastErrorSignature: "",
  lastErrorReportAt: 0,
  lastKey: "",
  lastToast: null,
  toastShownAt: 0,
  rendered: false,
  pendingDraft: null,
  hubState: { open: false, query: "", view: "list", tab: "card", detailRepo: "" },
  hubSignature: "",
  liveNavIntent: null,
  threadHint: "",
  seenThread: "",
  seenMessages: new Set(),
  recentsKey: null,
  flowTimeline: [],
  flowDomainMax: 10,
  shownRate: 0,
  shownRateSampleT: 0,
  shownRateAt: 0,
  snapshotAt: 0,
  flowKey: "",
  flowSince: 0,
  modelHoverName: "",
  logsRendered: { ids: [], filter: "", search: "" },
  pendingSignature: "",
  downloadsShape: "",
};

// The overview chart is a real timeline: each point keeps the timestamp the
// engine (or the local stream meter) sampled it. Nothing is generated here —
// when there is no decode history the timeline stays empty and the chart says
// so instead of drawing invented motion.
export const FLOW_WINDOW_MS = 60_000;

export const FLOW_GAP_MS = 3_000;

export const engineCatalog = () => (S.snap && S.snap.engineCatalog) || [];

export const rawEngineOf = (name) => {
  const hit = engineCatalog().find((item) => item.name === name || item.id === name);
  return hit ? hit.id : name;
};

export const nameEngineOf = (raw) => {
  const hit = engineCatalog().find((item) => item.id === raw || item.name === raw);
  return hit ? hit.name : raw;
};

export const engineMeta = (name) => {
  const raw = rawEngineOf(name);
  const hit = engineCatalog().find((item) => item.id === raw);
  return hit || { id: raw, name: nameEngineOf(raw), accent: "#8d78e8", summary: "", adapter: raw };
};

export const engineInstall = (name) => {
  const raw = rawEngineOf(name);
  const map = (S.snap && S.snap.enginesInstall) || {};
  return map[raw] || map[name] || {};
};

export const activeEngineName = () => (S.snap && S.snap.engine && S.snap.engine.name) || nameEngineOf(S.snap?.engine?.id) || "Splash";

export const activeEngineRaw = () => (S.snap && S.snap.engine && S.snap.engine.id) || rawEngineOf(activeEngineName());

export const isRunning = () => !!(S.snap && S.snap.engine && S.snap.engine.running);

export const isBusy = () => {
  const engine = S.snap && S.snap.engine;
  return !!(engine && (engine.switching || engine.state === "starting" || engine.state === "stopping"));
};

// 全站只有一个实时速率口径：概览大数字、顶栏、聊天页都从
// currentDecodeRate() 取，避免同一时刻几处显示互相矛盾的读数。
export const rateValue = () => currentDecodeRate();

export function cmd(type, payload) {
  const message = Object.assign({ type }, payload || {});
  if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridge) {
    window.webkit.messageHandlers.bridge.postMessage(message);
  } else {
    console.log("[cmd]", message);
  }
}

// Model ids are the only truthful name we have. Engines that store weights as
// a flat folder (`owner--repo`) are canonicalised to `owner/repo`; the short
// repo name is what the UI labels, and the full id stays in the tooltip.
// Earlier this table rewrote ids into invented product names ("Qwen3.8
// Flash-Next"), which made two different repos look like the same model and
// hid the actual quantisation/engine variant the user had picked.
export const canonicalModel = (value) => String(value == null ? "" : value).trim().replace(/--/g, "/");

export const shortModel = (value) => {
  const canonical = canonicalModel(value);
  if (!canonical) return "未选择模型";
  return canonical.split("/").pop() || canonical;
};

export const displayModel = shortModel;

export const fullModelName = (value) => canonicalModel(value) || "未选择模型";

export const modelOwner = (value) => {
  const parts = canonicalModel(value).split("/");
  return parts.length > 1 ? parts[0] : "";
};

export const sameModel = (a, b) => canonicalModel(a).toLowerCase() === canonicalModel(b).toLowerCase();

export function fmtBytes(n) {
  const value = Number(n);
  if (!Number.isFinite(value) || value <= 0) return "—";
  const units = ["B", "KB", "MB", "GB", "TB"];
  let index = 0;
  let size = value;
  while (size >= 1024 && index < units.length - 1) { size /= 1024; index += 1; }
  return `${size >= 100 ? size.toFixed(0) : size.toFixed(1)} ${units[index]}`;
}

// 统一保留一位小数。旧版在 100 处把小数位从 1 位切成 0 位，数值只要
// 在 99.9 ↔ 100.1 之间晃一下，显示格式就跟着跳，看着像速度突变。
export function rateNumberText(value) {
  const n = Number(value);
  return Number.isFinite(n) && n > 0 ? n.toFixed(1) : "—";
}

export function fmtRate(value) {
  return rateNumberText(value) === "—" ? "—" : `${rateNumberText(value)} tok/s`;
}

export function fmtUptime(startedAt) {
  const start = Number(startedAt || 0);
  if (!start) return "—";
  let seconds = Math.max(0, Math.floor(Date.now() / 1000 - start));
  const h = Math.floor(seconds / 3600);
  seconds -= h * 3600;
  const m = Math.floor(seconds / 60);
  const s = seconds - m * 60;
  return `${String(h).padStart(2, "0")}:${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`;
}

export function fmtClock(ms) {
  if (!ms) return "";
  const date = new Date(Number(ms));
  const now = new Date();
  const sameDay = date.toDateString() === now.toDateString();
  return sameDay ? date.toTimeString().slice(0, 5) : `${date.getMonth() + 1}/${date.getDate()}`;
}

export function modelFormat(entry) {
  // Format comes from the repository or the engine that serves it, never from
  // a substring like "mtp": `Jundot--Qwen3.6-…-oQ4e-mtp` is MLX weights with
  // an MTP head, and used to be labelled MTPLX on oMLX/MLX-Serve because the
  // repo name happened to contain "mtp".
  const text = [entry.id, entry.repo, entry.display, ...(entry.tags || [])].join(" ").toLowerCase();
  if (text.includes("gguf")) return "GGUF";
  if (text.includes("mtplx")) return "MTPLX";
  if (text.includes("mlx")) return "MLX";
  const adapter = engineMeta(nameEngineOf(entry.engine)).adapter;
  // splash serves GGUF; Strata streams GGUF experts; MTPLX uses its own packs;
  // every other engine here is an MLX runtime.
  if (adapter === "splash" || adapter === "strata") return "GGUF";
  if (adapter === "mtplx") return "MTPLX";
  return "MLX";
}

export function modelFlags(entry) {
  const flags = [];
  const push = (value) => {
    const text = String(value || "").trim();
    if (text && !flags.includes(text)) flags.push(text);
  };
  (entry.tags || []).forEach(push);
  if (entry.recommendedTag) push(entry.recommendedTag);
  if (entry.draftTag) push(entry.installed ? "DFlash2 加速" : "含 DFlash2");
  if (entry.shared) push("共享");
  if (entry.uncatalogued) push("未收录");
  if (entry.isDraft) push("草稿");
  return flags.slice(0, 5);
}

export function modelMemory(entry) {
  if (entry.minMemory) return `${entry.minMemory} GB 内存起`;
  return entry.installed ? "本机权重" : "内存未标注";
}

// 引擎名 → 徽标字符（纯字符串逻辑；adapt 整形与视图都要用）。
export function engineGlyph(name) {
  const raw = rawEngineOf(name);
  if (raw === "mlx-serve") return "MLX";
  if (raw === "strata") return "ST";
  return String(name || "?").slice(0, 1).toUpperCase();
}

// ---------- snapshot → view state ----------
export function adapt(snap) {
  const engine = snap.engine || {};
  const stats = snap.stats || null;
  const settings = snap.settings || {};
  const lib = snap.library || { engine: "splash", entries: [] };
  const engineName = nameEngineOf(engine.id) || "Splash";

  const intent = S.liveNavIntent;
  if (intent) {
    if (snap.page === intent.page) S.liveNavIntent = null;
    else if (Date.now() - intent.at < 1200) snap = { ...snap, page: intent.page };
    else S.liveNavIntent = null;
  }
  state.page = snap.page || state.page || "overview";
  state.theme = snap.appearance || state.theme || "light";
  state.sidebarCollapsed = !snap.sidebar;
  state.engine = engineName;
  state.engineRunning = !!engine.running && engine.state === "running";
  state.engineBusy = isBusy();
  state.activeEngineView = state.activeEngineView && engineCatalog().some((item) => item.name === state.activeEngineView)
    ? state.activeEngineView
    : engineName;
  state.model = snap.selectedModel || "";
  state.engineSwitching = !!engine.switching;
  state.switchStage = String(engine.switchStage || "").trim();
  // Throughput samples survive a model switch in Swift (they live for 30
  // minutes), but a curve from the previous engine/model is not this engine's
  // history. Start a fresh timeline when the identity changes.
  const flowIdentity = `${engine.id || ""}|${snap.selectedModel || ""}`;
  if (!S.flowKey) {
    S.flowKey = flowIdentity;
  } else if (S.flowKey !== flowIdentity) {
    S.flowKey = flowIdentity;
    S.flowSince = Date.now();
    // 换了引擎/模型就别把上一台机器的读数带过来。
    S.shownRate = 0;
    S.shownRateSampleT = 0;
  }
  state.engineCatalog = engineCatalog().map((item) => ({ ...item, id: item.name, rawId: item.id }));
  state.engineAccents = Object.fromEntries(engineCatalog().map((item) => [item.name, item.accent]));
  state.enginesInstall = Object.fromEntries(
    Object.entries(snap.enginesInstall || {}).map(([raw, info]) => [nameEngineOf(raw), info])
  );
  state.engines = engineCatalog().map((item) => {
    const info = (snap.enginesInstall || {})[item.id] || {};
    const versions = Array.isArray(info.versions) ? info.versions : [];
    const isActive = item.id === engine.id;
    const running = isActive && !!engine.running;
    const upstream = info.upstream || {};
    const latest = upstream.version || (info.latestRelease && info.latestRelease.version) || "";
    const stateName = isActive ? engine.state : "stopped";
    return {
      id: item.name,
      rawId: item.id,
      glyph: engineGlyph(item.name),
      color: item.accent || "#8d78e8",
      version: versions[versions.length - 1] || "—",
      latest,
      installed: Boolean(item.installed) || versions.length > 0,
      port: String(info.port != null ? info.port : item.defaultPort || ""),
      state: running ? "running" : stateName === "starting" ? "starting" : stateName === "stopping" ? "stopping" : "stopped",
      description: item.summary || "",
      uptime: running ? fmtUptime(stats && stats.startedAt) : "—",
      pid: running && stats && stats.instancePid ? String(stats.instancePid) : "—",
      tuning: info.tuning || {},
      info,
      adapter: item.adapter,
      capabilities: item.capabilities || [],
      features: (item.capabilities || []).map((cap) => cap.label || cap.id).slice(0, 3),
      updateAvailable: upstream.status === "update",
      progress: info.progress != null ? Math.round(Number(info.progress) * 100) : null,
      busy: Boolean(info.phase),
      phase: info.phase || "",
      latestRelease: info.latestRelease || null,
    };
  });

  // models: prefer the flat all-engine list so the engine tabs actually have
  // something to filter; the per-engine library stays as a fallback for old
  // snapshots. A model shared by several engines appears once, owned by the
  // engine currently being browsed.
  const flat = Array.isArray(snap.modelsAll) && snap.modelsAll.length ? snap.modelsAll : null;
  const entries = [];
  if (flat) {
    const byId = new Map();
    flat.forEach((entry) => {
      const existing = byId.get(entry.id);
      if (!existing || entry.engine === lib.engine) byId.set(entry.id, entry);
    });
    byId.forEach((entry) => entries.push(entry));
  } else if (Array.isArray(lib.entries)) {
    entries.push(...lib.entries);
  }
  entries.sort((a, b) => {
    const browse = (b.engine === lib.engine ? 1 : 0) - (a.engine === lib.engine ? 1 : 0);
    if (browse) return browse;
    return (b.installed ? 1 : 0) - (a.installed ? 1 : 0);
  });
  MODELS.length = 0;
  entries.forEach((entry) => {
    MODELS.push({
      name: entry.id,
      id: entry.id,
      engine: nameEngineOf(entry.engine),
      engineId: entry.engine,
      repo: entry.repo || entry.display || entry.id,
      display: entry.display || entry.id,
      format: modelFormat(entry),
      size: fmtBytes(entry.bytes),
      memory: modelMemory(entry),
      flags: modelFlags(entry),
      installed: !!entry.installed,
      entry,
    });
  });
  state.modelIndex = new Map(MODELS.map((model) => [model.name, model]));

  // downloads: one table feeds both the sheet and the model cards. The card
  // must never say "使用" while a row is still in the center — a partial
  // snapshot already has config.json + tokenizer and the engine scan calls
  // it installed. Key by engine + canonical id so two engines that share a
  // repo do not borrow each other's progress, and accept the flat
  // `owner--repo` spelling the scanners return.
  const downloads = snap.downloads || {};
  const downloadStates = new Map();
  const rememberDownload = (engine, model, status, fraction, totalBytes, shared) => {
    const raw = String(model == null ? "" : model);
    if (!raw) return;
    const canonical = canonicalModel(raw);
    const value = Number(fraction);
    const known = fraction != null && Number.isFinite(value);
    // 公共目录里的权重只有一份：这条任务要同时点亮所有被授权引擎的卡片，
    // 否则浏览另一个引擎时卡片有进度、下载中心也有，模型页却停在「下载」。
    const engines = Array.from(new Set([engine, ...(Array.isArray(shared) ? shared : [])].filter(Boolean)));
    const info = {
      engine: engine || "",
      engines,
      shared: engines.length > 1,
      model: raw,
      canonical,
      status: String(status || "downloading"),
      progress: known ? Math.max(0, Math.min(100, value * 100)) : 0,
      indeterminate: !known,
      totalBytes: Number(totalBytes) || 0,
    };
    downloadStates.set(canonical, info);
    engines.forEach((id) => downloadStates.set(`${id}|${canonical}`, info));
  };
  const tasks = Array.isArray(downloads.tasks) ? downloads.tasks : [];
  tasks.forEach((task) => {
    rememberDownload(task.engine, task.model, task.status || "downloading",
      task.fraction, task.totalBytes, task.shared);
  });
  // The live child carries the freshest fraction; put it last so it wins over
  // the task row that shares the same model. It inherits the task's shared
  // engines so the freshest number reaches every card, too.
  if (downloads.active && downloads.active.model) {
    const activeTask = tasks.find((task) => task.model === downloads.active.model);
    rememberDownload(downloads.active.engine, downloads.active.model, "downloading",
      downloads.active.fraction, 0, activeTask && activeTask.shared);
  }
  state.downloadStates = downloadStates;

  state.downloadsInFlight = new Map();
  MODELS.forEach((model) => {
    const canonical = canonicalModel(model.name);
    const engine = model.engineId || "";
    const specific = engine ? downloadStates.get(`${engine}|${canonical}`) : null;
    const generic = downloadStates.get(canonical);
    const info = specific || (generic && (!engine || generic.shared) ? generic : null);
    if (!info) return;
    model.installed = false;
    // SIZE 不用下载任务总量改写：一次下载可能顺带抓草稿头、mmproj 和
    // 别的分片，任务总量不等于这张卡的权重大小。库条目里的体积若只是
    // 下载中的半截扫描值，也不会进指纹触发重建，卡上保留渲染时的值，
    // 下载结束（任务行消失）再刷新一次。
    const progress = Math.round(info.progress);
    state.downloadsInFlight.set(model.name, progress);
    state.downloadsInFlight.set(canonical, progress);
  });
  state.downloaded = new Set(MODELS
    .filter((model) => model.installed && !state.downloadsInFlight.has(model.name)
      && !state.downloadsInFlight.has(canonicalModel(model.name)))
    .map((model) => model.name));

  // chat
  const threadID = snap.threadID || "";
  if (threadID !== S.seenThread) {
    S.seenThread = threadID;
    S.seenMessages.clear();
  }
  state.chatMessages = (snap.messages || []).map((message) => ({
    id: message.id,
    role: message.role,
    content: message.content || "",
    reasoning: message.reasoning || "",
    // The model that produced this answer, kept per message so an older reply
    // keeps its family mark after the reader switches to another model.
    model: message.model || "",
    streaming: !!message.streaming || (!!snap.generating && message.role === "assistant" && message === (snap.messages || [])[snap.messages.length - 1]),
    rate: message.rate != null ? String(Math.round(Number(message.rate) * 10) / 10) : "",
    ttft: message.ttft != null ? String(Math.round(Number(message.ttft) * 1000)) : "",
    tokens: message.tokens != null ? String(message.tokens) : "",
    createdAt: message.createdAt || 0,
    // Wall-clock time the model spent thinking before its first answer token.
    // Persisted with the thread so an old reply keeps its "思考了 8.4 秒".
    thinkingSeconds: Number.isFinite(Number(message.thinkingSeconds)) && Number(message.thinkingSeconds) > 0
      ? Number(message.thinkingSeconds) : null,
  }));
  state.chatStreaming = !!snap.generating;

  // logs
  const logLines = (snap.logs || []).map((line) => ({
    time: line.time || "",
    level: String(line.level || "info").toUpperCase() === "WARNING" ? "WARN" : String(line.level || "info").toUpperCase(),
    msg: line.text || "",
    id: line.id,
  }));
  LOG_SEED.length = 0;
  logLines.forEach((line) => LOG_SEED.push(line));

  // settings
  const thinkingLabel = settings.thinkingMode === "on" ? "开启" : settings.thinkingMode === "off" ? "关闭" : "自动";
  state.settings = {
    launchEngine: !!settings.autoStart,
    login: !!settings.launchAtLogin,
    gateway: !!settings.gatewayEnabled,
    gatewayPort: settings.gatewayPort,
    thinking: thinkingLabel,
    thinkingMode: settings.thinkingMode || "automatic",
    reasoningEffort: settings.reasoningEffort || "medium",
    reasoningEffortLabel: settings.reasoningEffortLabel || "中",
    reasoningEfforts: settings.reasoningEfforts || [],
    appearance: snap.appearance || "system",
    temperature: Number(settings.temperature ?? 0.7),
    topP: Number(settings.topP ?? 0.92),
    maxTokens: Number(settings.maxTokens ?? 0),
    effectiveMaxTokens: Number(settings.effectiveMaxTokens ?? 0),
    systemPrompt: settings.systemPrompt || "",
    hfCache: settings.hfCache || "",
    defaultModel: settings.defaultModel || "",
    ports: settings.ports || {},
    autoStart: !!settings.autoStart,
    launchAtLogin: !!settings.launchAtLogin,
  };
  state.params = {
    temperature: state.settings.temperature,
    topP: state.settings.topP,
    tokens: state.settings.maxTokens || state.settings.effectiveMaxTokens || 0,
    thinking: thinkingLabel,
    effort: state.settings.reasoningEffort,
  };

  // shell chrome
  state.gatewayURL = snap.gatewayURL || "";
  state.gatewayClaudeURL = snap.gatewayClaudeURL || "";
  state.endpointURL = snap.endpointURL || "";
  state.context = snap.context || { used: 0, total: 0 };
  state.stats = stats;
  S.snapshotAt = Date.now();
  updateFlowTimeline(snap.throughput);
  state.threads = snap.threads || [];
  state.appVersion = snap.appVersion || "";
  state.threadID = snap.threadID || "";
  state.downloads = downloads;
  state.hub = snap.hub || null;
  state.pending = snap.pending || null;
  state.pendingInstall = snap.pendingInstall || null;
  state.recommendation = snap.recommendation || { show: false };
  state.launchPage = !!snap.launchPage;
  state.launchNeedsSetup = !!snap.launchNeedsSetup;
  state.packIndex = snap.packIndex || { loaded: false, error: "" };
  state.loadedModels = (snap.library && snap.library.entries || []).filter((entry) => entry.installed).length;

  state.sidebarWidth = Math.max(180, Math.min(320, Number(localStorage.getItem("fc-preview-sidebar-width")) || 200));
}

// ---------- fingerprint ----------
// 下载任务的「形状」：哪条任务、什么状态、共享给谁、有没有已知百分比。
// 刻意不含 fraction / downloadedBytes / speed —— 那三个数每 500ms 都会变，
// 进了指纹就等于让模型页每半秒重建一次。
export function downloadShape(downloads) {
  if (!downloads) return "";
  const parts = (Array.isArray(downloads.tasks) ? downloads.tasks : []).map((task) =>
    [task.engine, task.model, task.status, (task.shared || []).join("+"),
      task.fraction == null ? "?" : "n"].join("~"));
  const active = downloads.active;
  if (active && active.model) parts.push(["active", active.engine, active.model].join("~"));
  return parts.join("§");
}

// 库快照里会改变卡片结构 / 文案的字段。`bytes` 故意不在里面：它是磁盘上
// 的实际大小，下载时每写完一块就长一点，跟着扫描每 500ms 变一次。把它算进
// 指纹，模型页就会跟着半秒整页重建一次——鼠标停在卡片上时，悬停的描边和
// 投影过渡被反复从基础态重放，看起来就是边框一直在闪。下载中的卡片改由
// 任务总量显示 SIZE，进度数字走 patchProgress。
export function libraryShape(library) {
  if (!library) return "";
  const entries = Array.isArray(library.entries) ? library.entries : [];
  return [library.engine || "", entries.map((entry) => [
    entry.id, entry.engine, entry.installed, entry.source, entry.repo, entry.display,
    entry.minMemory, entry.recommendedTag, entry.draftTag, entry.isDraft,
    entry.shared, (entry.engines || []).join("+"), entry.uncatalogued,
    (entry.tags || []).join("+"), entry.fit, entry.rank,
  ].join("~")).join("§")].join("|");
}

// 引擎安装进度的「形状」：哪台引擎、装了什么版本、处在哪个阶段、配置是什么。
// 百分比和步骤文案每 100~500ms 都在变，进了指纹就等于让引擎页和首次安装页
// 整页重建（进度条被重建，宽度没有过渡可播，就一直跳）；数字交给
// patchEngineProgress 原地补，只有阶段/版本/配置变化才换结构。
export function engineInstallShape(install) {
  if (!install) return "";
  return Object.keys(install).sort().map((id) => {
    const info = install[id] || {};
    const upstream = info.upstream || {};
    return [
      id,
      (info.versions || []).join("+"),
      info.phase || "",
      upstream.status || "",
      upstream.version || "",
      info.port,
      (info.latestRelease && info.latestRelease.version) || "",
      JSON.stringify(info.tuning || {}),
    ].join("~");
  }).join("§");
}

export function fingerprint() {
  if (!S.snap) return "";
  if (S.snap.launchPage || (S.snap.recommendation && S.snap.recommendation.show)) {
    return ["launch", S.snap.launchPage, JSON.stringify(S.snap.recommendation || {}),
      engineInstallShape(S.snap.enginesInstall), S.snap.packIndex, S.snap.pending, S.snap.engine && S.snap.engine.state].join("|");
  }
  const page = state.page;
  if (page === "overview") {
    // Engine state, the selected model and the switch stage are patched into
    // the engine widget by `syncOverviewChrome()`; only the shape-changing
    // parts (gateway, request rows) may rebuild the page.
    return ["overview", state.gatewayURL, state.gatewayClaudeURL,
      S.snap.settings && S.snap.settings.gatewayEnabled,
      (S.snap.sessions || []).map((s) => `${s.id}:${s.state}`).join(",")].join("|");
  }
  if (page === "chat") {
    // The chat shell is patched in place for everything except the message
    // body: the model chip, engine pill and context meter follow `tick()`.
    // Keeping them out of the fingerprint is what stops a model switch (or a
    // streaming token) from replacing the whole page and replaying every
    // entrance animation.
    return ["chat", S.snap.generating,
      (S.snap.messages || []).map((m) => [m.id, m.role, m.model, m.content, m.reasoning, m.streaming, m.rate, m.ttft, m.tokens].join("~")).join("§"),
      JSON.stringify(S.snap.settings && { t: S.snap.settings.thinkingMode, e: S.snap.settings.reasoningEffort, l: S.snap.settings.reasoningEffortLabel })].join("|");
  }
  if (page === "models") {
    // 下载进度（字节数、百分比、速度）每 500ms 变一次。把它算进指纹，整页
    // 就会跟着半秒重建一次；鼠标正停在卡片上时，悬停的描边/投影过渡每次
    // 都得从基础态重放，看起来就是卡片在闪。这里只留会改变卡片结构的
    // 「形状」（谁在下载、什么状态、共享给哪些引擎），数字交给
    // patchModelProgress 原地补。选中模型也一样：它只影响两张卡的描边和
    // 「使用中」胶囊，整页重建会让所有卡片从基础态重来一遍。
    // 库快照同理：`bytes` 是扫描到的磁盘大小，下载中每块写入都在变，
    // 用 libraryShape 只留结构字段，避免同一张卡每半秒重建一次。
    return ["models", state.modelFilter, state.modelSearch, libraryShape(S.snap.library),
      downloadShape(S.snap.downloads)].join("|");
  }
  if (page === "engines") {
    return ["engines", state.activeEngineView, state.engineConfigOpen,
      JSON.stringify(S.snap.engineCatalog || []), engineInstallShape(S.snap.enginesInstall),
      S.snap.engine && S.snap.engine.state, S.snap.engine && S.snap.engine.running].join("|");
  }
  if (page === "logs") {
    if (state.logPaused) return ["logs", "paused", state.logFilter].join("|");
    return ["logs", (S.snap.logs || []).length, (S.snap.logs || [])[0]?.id || "", state.logFilter].join("|");
  }
  if (page === "settings") {
    return ["settings", JSON.stringify(S.snap.settings || {}), JSON.stringify(S.snap.recommendation || {}), S.snap.appearance].join("|");
  }
  return page;
}

export function formatThousands(value) {
  return Number(value).toLocaleString("en-US");
}

// 上下文窗口动辄几十万 tokens，概览卡片和聊天栏统一用 K 显示：
// 11894 → 11.9K、262144 → 262K。不足 1K 时保留原值，免得出现「0.4K」
// 这种比「430」更难读的写法；100K 以上取整，避免「262.1K」的假精度。
export function formatContextK(value) {
  const tokens = Number(value) || 0;
  if (tokens < 1000) return String(Math.round(tokens));
  const k = tokens / 1000;
  const text = k >= 100 ? String(Math.round(k)) : k.toFixed(1).replace(/\.0$/, "");
  return `${text}K`;
}

export function setText(selector, text) {
  qa(selector).forEach((node) => {
    if (node.textContent !== text) node.textContent = text;
  });
}

/// 原地改一个已经挂着的节点。整页重建才会让动画重来，改文本不会。
export function setNodeText(node, text) {
  if (node && node.textContent !== text) node.textContent = text;
}

export function memoryPercent() {
  const stats = S.snap.stats || {};
  const used = Number(stats.memoryBytes || 0);
  const total = Number(stats.physicalMemoryBytes || 0);
  if (!used || !total) return "—";
  return String(Math.round((used / total) * 100));
}

export function memoryHint() {
  const stats = S.snap.stats || {};
  const used = Number(stats.memoryBytes || 0);
  const total = Number(stats.physicalMemoryBytes || 0);
  if (!used || !total) return "引擎未上报内存";
  return `${fmtBytes(used)} / ${fmtBytes(total)}`;
}

// ---------- overview data ----------
// Keep the sampled throughput series as timestamped points. The chart and the
// engine rhythm both read this; no clock tick invents values between samples.
export function updateFlowTimeline(raw) {
  const now = Date.now();
  const from = now - FLOW_WINDOW_MS - 5_000;
  const points = [];
  const seen = new Map();
  (Array.isArray(raw) ? raw : []).forEach((sample) => {
    const t = Number(sample && sample.t);
    const v = Number(sample && sample.v);
    if (!Number.isFinite(t) || !Number.isFinite(v) || v <= 0) return;
    if (t < Math.max(from, S.flowSince) || t > now + 2_000) return;
    const key = Math.round(t / 50);
    const previous = seen.get(key);
    if (previous == null) {
      seen.set(key, { t, v, sum: v, n: 1 });
    } else {
      // 同一小格里取平均，不再只留最大值：旧逻辑等于系统性放大尖峰、
      // 丢掉低值，曲线和 LIVE 数字都被往上带。
      previous.sum += v;
      previous.n += 1;
      previous.v = previous.sum / previous.n;
    }
  });
  seen.forEach((point) => points.push(point));
  points.sort((a, b) => a.t - b.t);
  S.flowTimeline = points;
  // y 轴上限取 90 分位而不是窗口峰值：单个尖峰不该把整张图压扁，
  // 峰值滚出窗口时也不该让所有柱子和折线一起缩放跳动。
  const sorted = points.map((point) => point.v).sort((a, b) => a - b);
  const reference = sorted.length ? sorted[Math.floor((sorted.length - 1) * 0.9)] : 0;
  S.flowDomainMax = Math.max(10, Math.ceil((reference * 1.25) / 10) * 10);
}

export function flowPoints(now = Date.now()) {
  return S.flowTimeline.filter((point) => point.t >= now - FLOW_WINDOW_MS && point.t <= now + 1_000);
}

export function newestFlowPoint(maxAge = 4_000) {
  const point = S.flowTimeline[S.flowTimeline.length - 1];
  return point && Date.now() - point.t <= maxAge ? point : null;
}

// 一个样本只平滑一次：tick、updateChrome、模板渲染都会调这个函数，
// 所以用样本时间戳做幂等键，重复调用不会把 EMA 反复作用在同一个值上。
// 没有新样本时先保留上一个读数几秒，而不是立刻掉成「—」：快照约 1 秒
// 一推、采样 0.5 秒一次，旧版在两次推送的缝隙里就会闪一下空值。
export function currentDecodeRate() {
  if (!isRunning()) {
    S.shownRate = 0;
    S.shownRateSampleT = 0;
    return 0;
  }
  const point = newestFlowPoint();
  if (point && point.v > 0) {
    if (point.t !== S.shownRateSampleT) {
      S.shownRateSampleT = point.t;
      S.shownRate = S.shownRate > 0 ? S.shownRate * 0.7 + point.v * 0.3 : point.v;
    }
    S.shownRateAt = Date.now();
  } else if (Date.now() - S.shownRateAt > 3_000) {
    S.shownRate = 0;   // 引擎确实停了，别一直挂着一个 "LIVE" 的旧数字
  }
  if (S.shownRate <= 0) {
    // 生成刚开始、曲线还没落下第一个样本时，先用 Swift 侧同一个
    // 低通估计器的读数，避免数字从「—」突然跳出来。
    const live = Number((S.snap && S.snap.stats || {}).liveDecodeRate);
    return Number.isFinite(live) && live > 0 ? live : 0;
  }
  return S.shownRate;
}

export function flowPillText() {
  if (state.engineBusy) return "SYNC";
  if (!isRunning()) return "IDLE";
  return currentDecodeRate() > 0 ? "LIVE" : "WAITING";
}

export function flowPillClass() {
  const text = flowPillText();
  return text === "LIVE" ? "" : text === "WAITING" ? "is-wait" : "is-off";
}

export function clamp(value, min, max) {
  return Math.max(min, Math.min(max, value));
}

// TTFT is drawn on a 0–2000 ms track. The dot is a real position, not a
// drifting decoration: 131 ms sits near the left, 1.5 s near the right.
export function ttftPercent() {
  if (!isRunning()) return null;
  // JSON null for engines that never report TTFT must stay "no data" —
  // Number(null) is 0, which would otherwise draw a dot at 0 ms.
  const raw = (S.snap.stats || {}).ttftMilliseconds;
  if (raw == null || raw === "") return null;
  const ms = Number(raw);
  if (!Number.isFinite(ms) || ms < 0) return null;
  return clamp(4 + (ms / 2000) * 92, 4, 96);
}

// Prefill is a five-step gauge of the engine's own sample (tok/s). The bars
// only light up for the steps the real number has reached.
export function prefillSteps() {
  if (!isRunning()) return 0;
  const rate = Number((S.snap.stats || {}).prefillTokensPerSecond);
  if (!Number.isFinite(rate) || rate <= 0) return 0;
  if (rate >= 4800) return 5;
  if (rate >= 2400) return 4;
  if (rate >= 1200) return 3;
  if (rate >= 600) return 2;
  return 1;
}

export function memoryBlocks() {
  if (!isRunning()) return 0;
  const percent = Number(memoryPercent());
  if (!Number.isFinite(percent) || percent <= 0) return 0;
  return clamp(Math.round((percent / 100) * 22), 0, 22);
}

// ---------- overview ----------
export function rollingText(text) {
  return Array.from(String(text)).map((char, index) =>
    `<span class="model-char" style="--i:${index}">${char === " " ? "&nbsp;" : esc(char)}</span>`).join("");
}

export function engineStatusText() {
  const engine = (S.snap && S.snap.engine) || {};
  const busy = state.engineBusy;
  const running = isRunning();
  return busy
    ? (engine.switching ? "正在切换" : engine.state === "stopping" ? "正在停止" : "正在启动")
    : running ? "运行中" : engine.state === "failed" ? "启动失败" : "已停止";
}

export function formatElapsed(seconds) {
  const value = Number(seconds || 0);
  if (value < 1) return `${Math.round(value * 1000)}ms`;
  if (value < 60) return `${value.toFixed(1)}s`;
  return `${Math.floor(value / 60)}m ${Math.round(value % 60)}s`;
}

export function requestStateClass(request) {
  return request.state === "failed" ? "err"
    : request.state === "decode" ? "warn"
      : request.state === "prefill" ? "wait" : "ok";
}

export function requestRate(request) {
  // 网关侧已做过连续时间低通，这里直接显示，不再叠加瞬时窗口。
  return rateNumberText(request && request.decodeRate);
}

export function requestMeta(request) {
  const stateText = request.state === "decode" ? "解码中"
    : request.state === "prefill" ? "预填充"
      : request.state === "failed" ? "失败" : "完成";
  const elapsed = requestElapsed(request);
  return `${stateText} · ${formatElapsed(elapsed)} · ${displayModel(request.model)}`;
}

export function requestElapsed(request) {
  const base = Number(request && request.elapsed) || 0;
  const active = request && (request.state === "prefill" || request.state === "decode");
  return active ? base + Math.max(0, (Date.now() - S.snapshotAt) / 1000) : base;
}

// ---------- model plaza (Hugging Face) ----------
// Everything the plaza shows comes from Swift's `hub` snapshot; the page
// never talks to the Hub, never filters by engine and never decides whether
// a repository is downloadable. Commands: searchHub / hubDetail / downloadRepo.
export const hubSnapshot = () => (S.snap && S.snap.hub) || {};

export const hubCanonical = (id) => String(id || "").split(":")[0].replace(/--/g, "/").trim();

/// Whether this repository is already on disk. `hub.local` is the judgement
/// made by Swift (shared folder + every engine's model folder), so the page
/// only mirrors it; matching canonicalises flat `owner--repo` names.
export function hubLocally(repo) {
  const canon = hubCanonical(repo);
  if (!canon) return false;
  const hub = hubSnapshot();
  return (hub.local || []).concat(hub.shared || []).some((id) => hubCanonical(id) === canon);
}

// 一行里的纯数字（百分比、已下/总量、速度）。渲染和原地补丁共用，两处
// 措辞不会各写一套。
export function downloadRowText(task, downloads) {
  const active = downloads.active && downloads.active.model === task.model;
  // The live child and the task row can disagree by one 0.5s watch tick.
  // The card reads the live fraction first, so the sheet must do the same
  // or the two percentages visibly drift apart.
  const fraction = active
    ? Math.round(Number(downloads.active.fraction || 0) * 100)
    : task.fraction == null ? 0 : Math.round(Number(task.fraction) * 100);
  const total = Number(task.totalBytes || 0);
  const done = Number(task.downloadedBytes || 0);
  const speed = active ? Number(downloads.active.speed || 0) : 0;
  const status = task.status || "downloading";
  const statusText = status === "paused" ? "已暂停" : status === "failed" ? "失败" : active ? "下载中" : "等待中";
  return {
    status,
    fraction,
    meta: `${total ? `${fmtBytes(done)} / ${fmtBytes(total)}` : fmtBytes(done)}${speed ? ` · ${fmtBytes(speed)}/s` : ""} · ${statusText}`,
  };
}

export function tokenForThinking(label) {
  return label === "开启" ? "on" : label === "关闭" ? "off" : "automatic";
}

export function rawEngineIds() {
  return (S.snap && S.snap.engineCatalog ? S.snap.engineCatalog.map((item) => item.id) : []);
}

// ---------- a11y：aria-modal 对话框的焦点治理 ----------
// 三个 role="dialog" aria-modal="true"（#commandPalette 命令面板、#fcPending
// 确认弹窗、#fcShare 共享引擎）共用这套逻辑。用「每次按键即查 DOM」而不是
// 在各开合路径挂/摘监听——幂等，且面板结果区重渲染后无需重新登记。
const FOCUSABLE = 'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';

// 当前打开的模态对话框；scrim 类取 DOM 序最后一个（后进居上）。
export function activeModalDialog() {
  const palette = q("#commandPalette");
  if (palette && palette.getAttribute("aria-modal") === "true") return palette;
  const scrims = qa(".fc-scrim > .fc-modal[aria-modal='true']");
  return scrims.length ? scrims[scrims.length - 1] : null;
}

// Tab 循环约束在对话框内。返回 true 表示已消费（调用方不再处理）。
export function trapModalTab(event) {
  if (event.key !== "Tab" || event.metaKey || event.ctrlKey || event.altKey) return false;
  const dialog = activeModalDialog();
  if (!dialog) return false;
  const items = qa(FOCUSABLE, dialog);
  if (!items.length) return false;
  const first = items[0];
  const last = items[items.length - 1];
  const active = document.activeElement;
  const outside = !dialog.contains(active);
  if (event.shiftKey) {
    if (active === first || outside) {
      event.preventDefault();
      last.focus({ preventScroll: true });
      return true;
    }
  } else if (active === last || outside) {
    event.preventDefault();
    first.focus({ preventScroll: true });
    return true;
  }
  return false; // 中间元素间正常移动，放行浏览器默认
}

// scrim 类对话框（fcPending / fcShare）没有专属 Escape 处理，这里统一补上：
// 触发各自的取消按钮，走既有关闭路径（状态清理与焦点还原都保持单一来源）。
export function scrimCancelOnEscape(event) {
  if (event.key !== "Escape" || event.metaKey || event.ctrlKey || event.altKey) return false;
  const dialog = activeModalDialog();
  if (!dialog || dialog.id === "commandPalette") return false; // 面板由 app.js 的 Escape 关
  const cancel = dialog.querySelector("[data-share-cancel], [data-pending^='cancel']") || dialog.querySelector("button");
  if (!cancel) return false;
  event.preventDefault();
  cancel.click();
  return true;
}

// 弹窗打开前记住触发元素、关闭后还原——面板外的两个 scrim 对话框靠它把
// 焦点还给发起者。只记第一个（连续重渲染不覆盖）。
let modalReturnFocus = null;
export function stashModalFocus() {
  if (!modalReturnFocus && document.activeElement && document.activeElement !== document.body) {
    modalReturnFocus = document.activeElement;
  }
}
export function restoreModalFocus() {
  const back = modalReturnFocus;
  modalReturnFocus = null;
  if (back && back.isConnected) back.focus({ preventScroll: true });
}
