/* flashCat WebUI · live bridge adapter
 *
 * The visual layer is the liquid-glass preview (index.html + styles.css + the
 * component modules copied from preview/liquid-glass). This file is the only
 * app-specific part: it turns the Swift snapshot into the view state those
 * components render, and turns clicks back into bridge commands.
 *
 * preview/liquid-glass is the design source of truth. When it changes, the
 * copied files are refreshed and this adapter is re-checked against the new
 * component signatures.
 */
"use strict";

(function () {
  // The host may pre-create this array; when it does not, the error handler
  // below must still be able to record the first failure.
  window.__fcErrors = window.__fcErrors || [];

  // ---------- error surface (a broken render must not leave a blank window) ----------
  function surfaceError(title, detail) {
    // Never wipe a page that already rendered: animation-frame errors are
    // usually cosmetic, and replacing the DOM would hide the app. Keep the
    // message visible in a small bar and in the window title so it can be
    // reported without opening a web inspector.
    document.title = `flashCat · ${String(title || "error")}`.slice(0, 120);
    console.error("[flashCat]", title, detail);
    try {
      let bar = document.getElementById("fcErrorBar");
      if (!bar) {
        bar = document.createElement("div");
        bar.id = "fcErrorBar";
        bar.style.cssText = "position:fixed;left:12px;right:12px;bottom:12px;z-index:9999;max-height:140px;overflow:auto;padding:10px 12px;border-radius:10px;background:rgba(180,30,50,.92);color:#fff;font:10px/1.5 ui-monospace,monospace;white-space:pre-wrap;pointer-events:auto";
        document.body.appendChild(bar);
      }
      bar.textContent = `${title}\n${detail || ""}`;
      clearTimeout(bar.__timer);
      bar.__timer = setTimeout(() => { if (bar && bar.isConnected) bar.remove(); }, 8000);
    } catch (error) { /* last resort */ }
  }
  window.addEventListener("error", (event) => {
    window.__fcErrors.push([event.message, event.filename, event.lineno, event.colno].join(":"));
    surfaceError(event.message, `${event.filename}:${event.lineno}:${event.colno}`);
  });
  window.addEventListener("unhandledrejection", (event) => {
    window.__fcErrors.push(String(event.reason && (event.reason.stack || event.reason.message || event.reason)));
    surfaceError("Promise rejected", event.reason && (event.reason.stack || event.reason.message || event.reason));
  });
  const rawRAF = window.requestAnimationFrame.bind(window);
  window.requestAnimationFrame = function (callback) {
    return rawRAF(function (time) {
      try { callback(time); } catch (error) { surfaceError(error && error.message, error && error.stack); }
    });
  };

  // ---------- small helpers ----------
  const q = (selector, root = document) => root.querySelector(selector);
  const qa = (selector, root = document) => Array.from(root.querySelectorAll(selector));
  const S = { snap: null };
  let lastKey = "";
  let lastToast = null;
  let toastShownAt = 0;
  let rendered = false;
  let pendingDraft = null;
  // Model plaza view state. The search itself lives in Swift (`snap.hub`), so
  // everything here is presentation only: which result is open as a model card,
  // which tab of that card, and what the search box currently holds.
  let hubState = { open: false, query: "", view: "list", tab: "card", detailRepo: "" };
  let hubSignature = "";
  let liveNavIntent = null;
  let threadHint = "";
  // Message ids already painted in this thread. Only unseen ones get the
  // entrance animation, so a same-thread repaint (model switch, a streaming
  // token, a parameter change) does not replay every bubble.
  let seenThread = "";
  const seenMessages = new Set();
  let recentsKey = null;
  // The overview chart is a real timeline: each point keeps the timestamp the
  // engine (or the local stream meter) sampled it. Nothing is generated here —
  // when there is no decode history the timeline stays empty and the chart says
  // so instead of drawing invented motion.
  const FLOW_WINDOW_MS = 60_000;
  const FLOW_GAP_MS = 3_000;
  let flowTimeline = [];
  let flowDomainMax = 10;
  let snapshotAt = 0;
  let flowKey = "";
  let flowSince = 0;

  const engineCatalog = () => (S.snap && S.snap.engineCatalog) || [];
  const rawEngineOf = (name) => {
    const hit = engineCatalog().find((item) => item.name === name || item.id === name);
    return hit ? hit.id : name;
  };
  const nameEngineOf = (raw) => {
    const hit = engineCatalog().find((item) => item.id === raw || item.name === raw);
    return hit ? hit.name : raw;
  };
  const engineMeta = (name) => {
    const raw = rawEngineOf(name);
    const hit = engineCatalog().find((item) => item.id === raw);
    return hit || { id: raw, name: nameEngineOf(raw), accent: "#8d78e8", summary: "", adapter: raw };
  };
  const engineInstall = (name) => {
    const raw = rawEngineOf(name);
    const map = (S.snap && S.snap.enginesInstall) || {};
    return map[raw] || map[name] || {};
  };
  const activeEngineName = () => (S.snap && S.snap.engine && S.snap.engine.name) || nameEngineOf(S.snap?.engine?.id) || "Splash";
  const activeEngineRaw = () => (S.snap && S.snap.engine && S.snap.engine.id) || rawEngineOf(activeEngineName());
  const isRunning = () => !!(S.snap && S.snap.engine && S.snap.engine.running);
  const isBusy = () => {
    const engine = S.snap && S.snap.engine;
    return !!(engine && (engine.switching || engine.state === "starting" || engine.state === "stopping"));
  };
  const rateValue = () => {
    const stats = S.snap && S.snap.stats;
    if (!stats || !isRunning()) return 0;
    const live = Number(stats.liveDecodeRate);
    if (Number.isFinite(live) && live > 0) return live;
    const decode = Number(stats.decodeTokensPerSecond);
    return Number.isFinite(decode) ? decode : 0;
  };

  function cmd(type, payload) {
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
  const canonicalModel = (value) => String(value == null ? "" : value).trim().replace(/--/g, "/");
  const shortModel = (value) => {
    const canonical = canonicalModel(value);
    if (!canonical) return "未选择模型";
    return canonical.split("/").pop() || canonical;
  };
  const displayModel = shortModel;
  const fullModelName = (value) => canonicalModel(value) || "未选择模型";
  const modelOwner = (value) => {
    const parts = canonicalModel(value).split("/");
    return parts.length > 1 ? parts[0] : "";
  };
  const sameModel = (a, b) => canonicalModel(a).toLowerCase() === canonicalModel(b).toLowerCase();

  function fmtBytes(n) {
    const value = Number(n);
    if (!Number.isFinite(value) || value <= 0) return "—";
    const units = ["B", "KB", "MB", "GB", "TB"];
    let index = 0;
    let size = value;
    while (size >= 1024 && index < units.length - 1) { size /= 1024; index += 1; }
    return `${size >= 100 ? size.toFixed(0) : size.toFixed(1)} ${units[index]}`;
  }

  function fmtRate(value) {
    const n = Number(value);
    return Number.isFinite(n) && n > 0 ? `${n >= 100 ? n.toFixed(0) : n.toFixed(1)} tok/s` : "—";
  }

  function fmtUptime(startedAt) {
    const start = Number(startedAt || 0);
    if (!start) return "—";
    let seconds = Math.max(0, Math.floor(Date.now() / 1000 - start));
    const h = Math.floor(seconds / 3600);
    seconds -= h * 3600;
    const m = Math.floor(seconds / 60);
    const s = seconds - m * 60;
    return `${String(h).padStart(2, "0")}:${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`;
  }

  function fmtClock(ms) {
    if (!ms) return "";
    const date = new Date(Number(ms));
    const now = new Date();
    const sameDay = date.toDateString() === now.toDateString();
    return sameDay ? date.toTimeString().slice(0, 5) : `${date.getMonth() + 1}/${date.getDate()}`;
  }

  function engineGlyph(name) {
    const raw = rawEngineOf(name);
    if (raw === "mlx-serve") return "MLX";
    if (raw === "strata") return "ST";
    return String(name || "?").slice(0, 1).toUpperCase();
  }

  function modelFormat(entry) {
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

  function modelFlags(entry) {
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

  function modelMemory(entry) {
    if (entry.minMemory) return `${entry.minMemory} GB 内存起`;
    return entry.installed ? "本机权重" : "内存未标注";
  }

  // ---------- snapshot → view state ----------
  function adapt(snap) {
    const engine = snap.engine || {};
    const stats = snap.stats || null;
    const settings = snap.settings || {};
    const lib = snap.library || { engine: "splash", entries: [] };
    const engineName = nameEngineOf(engine.id) || "Splash";

    const intent = liveNavIntent;
    if (intent) {
      if (snap.page === intent.page) liveNavIntent = null;
      else if (Date.now() - intent.at < 1200) snap = { ...snap, page: intent.page };
      else liveNavIntent = null;
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
    if (!flowKey) {
      flowKey = flowIdentity;
    } else if (flowKey !== flowIdentity) {
      flowKey = flowIdentity;
      flowSince = Date.now();
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
    if (threadID !== seenThread) {
      seenThread = threadID;
      seenMessages.clear();
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
    snapshotAt = Date.now();
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
  function downloadShape(downloads) {
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
  function libraryShape(library) {
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
  function engineInstallShape(install) {
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

  function fingerprint() {
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

  // ---------- page rendering ----------
  function pageHTML() {
    if (S.snap.launchPage || (S.snap.recommendation && S.snap.recommendation.show)) return launchPageHTML();
    const rate = rateValue();
    switch (state.page) {
      case "overview": return window.FCWidgets.overview(state, rate);
      case "chat": return chatPageHTML();
      case "models": return modelsPageHTML();
      case "engines": return window.FCEngineWorkspace.render(state);
      case "logs": return logsPageHTML();
      case "settings": return settingsPageHTML();
      default: return window.FCWidgets.overview(state, rate);
    }
  }

  function render(animate = false) {
    if (!S.snap) return;
    const frame = q("#pageFrame");
    const main = q("#mainContent");
    if (!frame) return;
    const focus = captureFocus(frame);
    const scroll = main.scrollTop;
    const chatScroll = captureChatScroll();
    const html = pageHTML();
    if (animate && document.startViewTransition && !window.matchMedia("(prefers-reduced-motion: reduce)").matches && rendered) {
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
    rendered = true;
  }

  function afterRender(root) {
    if (!root) return;
    // 离开模型页就不再记悬停：键盘切页时指针没动，回来不该凭空带一张彩色
    // 描边的卡片。
    if (state.page !== "models") modelHoverName = "";
    if (state.page === "overview") {
      requestAnimationFrame(() => {
        if (window.inspectChartSegment) window.inspectChartSegment();
        if (window.startFlowVisualization) window.startFlowVisualization();
        if (window.updateSlidingSegments) window.updateSlidingSegments();
      });
    }
    if (state.page === "models") {
      // 重建前指针停在哪张卡，新节点首帧就带上悬停态：描边不闪。
      restoreModelHover();
      requestAnimationFrame(() => window.updateSlidingSegments && window.updateSlidingSegments());
    }
    if (state.page === "chat") {
      const input = q("#chatInput");
      if (input && pendingDraft != null) { input.value = pendingDraft; pendingDraft = null; }
      if (input) autosize(input);
      settleMessageEntrances(root);
      // A page paint during a live reply (opening the thread mid-stream, a
      // settings change) rebuilds the markup, so the new node needs its reveal
      // engine. It continues from the static prefix instead of retyping it.
      const messages = state.chatMessages || [];
      const last = messages[messages.length - 1];
      if (last && last.role === "assistant" && last.streaming && window.FCChatStream) {
        const node = q("#messagesInner .message:last-child");
        if (node) window.FCChatStream.push(node, last);
      }
    }
    if (state.page === "settings" || state.page === "logs") {
      requestAnimationFrame(() => window.updateSlidingSegments && window.updateSlidingSegments());
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
        if (window.syncEngineConfigControls) window.syncEngineConfigControls();
      });
    }
    requestAnimationFrame(() => {
      if (window.updateSlidingSegments) window.updateSlidingSegments();
      if (window.syncThinkingTriggerLabel) window.syncThinkingTriggerLabel();
    });
    tick();
  }

  function captureFocus(root) {
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

  function restoreFocus(focus) {
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

  function captureChatScroll() {
    const messages = q("#chatMessages");
    if (!messages) return null;
    return { top: messages.scrollTop, nearBottom: messages.scrollHeight - messages.scrollTop - messages.clientHeight < 60 };
  }

  function restoreChatScroll(saved) {
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

  function autosize(input) {
    input.style.height = "46px";
    input.style.height = `${Math.min(130, input.scrollHeight)}px`;
  }

  // ---------- chrome ----------
  function updateChrome() {
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
    if (label) label.textContent = busy ? (S.snap.engine.switching ? "切换中" : "启动中") : running ? "运行中" : "已停止";
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

  function applyShell() {
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
  function renderRecents() {
    const host = q("#recentList");
    if (!host) return;
    const threads = (S.snap && S.snap.threads) || [];
    // Every snapshot used to rebuild this list even when nothing had changed,
    // which made the glass sidebar repaint on each push. Keyed by content, the
    // list only touches the DOM when a thread row really differs.
    const key = threads.slice(0, 12)
      .map((thread) => `${thread.id}|${thread.title}|${thread.updatedAt}|${thread.id === state.threadID ? "1" : "0"}`).join("~");
    if (key === recentsKey) return;
    recentsKey = key;
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

  function navigate(page, options = {}) {
    if (!NAV_ITEMS.some((item) => item.id === page)) return;
    if (!options.force && state.page === page && !S.snap.launchPage) {
      const main = q("#mainContent");
      if (main) main.scrollTop = 0;
      return;
    }
    closeOverlays();
    if (hubState.open) closeHub();
    liveNavIntent = { page, at: Date.now() };
    state.page = page;
    state.engineConfigOpen = null;
    state.engineConfigDraft = null;
    syncNavActive();
    render(!!options.animate);
    lastKey = fingerprint();
    cmd("nav", { page });
  }

  function openThread(id) {
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
  function setTheme(theme) {
    state.theme = theme;
    state.settings.appearance = theme;
    document.documentElement.dataset.theme = resolvedTheme();
    updateThemeIcon();
    if (window.drawAmbient) window.drawAmbient(performance.now());
    cmd("appearance", { mode: theme });
    if (state.page === "settings") {
      qa("[data-appearance]").forEach((button) => button.classList.toggle("active", button.dataset.appearance === theme));
      if (window.updateSlidingSegments) window.updateSlidingSegments();
    }
  }

  function toggleSidebar() {
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
      if (window.updateNavIndicator) window.updateNavIndicator();
    }, 340);
    cmd("toggleSidebar");
  }

  const baseCloseOverlays = window.closeOverlays;
  window.closeOverlays = function closeOverlaysLive(options) {
    baseCloseOverlays(options);
    refreshOverlayLayer();
  };
  const baseOpenOverlay = window.openOverlay;
  window.openOverlay = function openOverlayLive(kind) {
    if (hubState.open && kind !== "hub") closeHub();
    baseOpenOverlay(kind);
  };
  const baseOpenCommand = window.openCommand;
  window.openCommand = function openCommandLive() {
    if (hubState.open) closeHub();
    baseOpenCommand();
  };

  window.FC_LIVE = {
    init, push: pushSnapshot, render, adapt,
    get snapshot() { return S.snap; },
  };
  // Swift's WebBridge talks to these two entry points.
  // Swift's token pipe arrives as a frame-sized batch. Deltas are applied
  // straight to the live turn; the snapshot watermark tells the renderer which
  // of those tokens it already has, so the two channels cannot double-paint.
  function pushStreamEvents(events) {
    if (!window.FCChatStream) return;
    window.FCChatStream.ingest(events);
  }

  window.__fc__ = {
    push: pushSnapshot,
    stream: pushStreamEvents,
    setSidebar: (visible) => { state.sidebarCollapsed = !visible; applyShell(); },
  };
  window.__fcToast = (message) => showToast(String(message || ""));

  // The app file (app.js) calls these bare globals at runtime, so replacing the
  // window properties is enough to route them into the bridge.
  window.navigate = navigate;
  window.setTheme = setTheme;
  window.toggleSidebar = toggleSidebar;
  window.renderRecents = renderRecents;

  // ---------- boot ----------
  function init() {
    document.documentElement.dataset.theme = resolvedTheme();
    document.documentElement.style.setProperty("--sidebar-width", `${state.sidebarWidth}px`);
    window.renderToolbarIcons();
    window.renderNav();
    renderRecents();
    if (window.bindGlobalEvents) window.bindGlobalEvents();
    if (window.startClock) window.startClock();
    if (window.startAmbient) window.startAmbient();
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
      overlayLayer.addEventListener("click", (event) => {
        if (event.target !== overlayLayer && !event.target.classList.contains("command-backdrop")) return;
        if (hubState.open) closeHub();
        if (state.currentOverlay) closeOverlays();
      });
    }
    document.addEventListener("click", handleLiveClick, true);
    document.addEventListener("input", handleLiveInput);
    document.addEventListener("change", handleLiveChange);
    document.addEventListener("keydown", handleLiveKeydown);
    document.addEventListener("mousedown", handleTitlebarDrag);
    document.addEventListener("pointerover", trackModelHover, true);
    document.addEventListener("pointerout", trackModelHover, true);
    document.addEventListener("pointermove", trackModelHoverMove, true);
    document.addEventListener("contextmenu", (event) => {
      if (!event.target.closest("input, textarea, [contenteditable='true'], [data-selectable]")) event.preventDefault();
    });
    document.addEventListener("selectstart", (event) => {
      if (!event.target.closest("input, textarea, [contenteditable='true'], [data-selectable]")) event.preventDefault();
    });
  }

  function handleTitlebarDrag(event) {
    if (event.button !== 0) return;
    if (!event.target.closest(".titlebar")) return;
    if (event.target.closest("button, input, a")) return;
    cmd("dragWindow");
  }

  function pushSnapshot(snap) {
    if (window.FCChatStream && Number.isFinite(Number(snap && snap.streamSeq))) {
      window.FCChatStream.setWatermark(snap.streamSeq);
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
    if (snap.toast && snap.toast !== lastToast && Date.now() - toastShownAt > 700) {
      lastToast = snap.toast;
      toastShownAt = Date.now();
      showToast(snap.toast);
    }
    renderPending();
    refreshOverlayLayer();
    if (hubState.open) renderHub();
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
    const shapeChanged = first || key !== lastKey || pageChanged;
    if (shapeChanged || threadChanged) {
      try {
        lastKey = key;
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
        if (pageChanged && !first) lastKey = fingerprint();
      } catch (error) {
        surfaceError(error && error.message, error && error.stack);
        throw error;
      }
    } else {
      // 指纹没变：进度这类纯数字的变化就停在这里，只补卡片上的百分比，
      // 不重建页面（否则悬停中的卡片会跟着每半秒闪一次）。
      patchModelProgress();
      tick();
    }
  }

  // ---------- model cards ----------
  // 悬停中的卡片一旦被整块重建，新节点在插入那一帧还没有 :hover：描边会先
  // 从玻璃白画一帧，再过渡回引擎色。下载中每 500ms 的推送只要触发一次重建，
  // 指针下就会看到边框反复闪。这里记住指针停在哪张卡上，渲染完立刻把
  // `is-hovered` 补到新节点，首帧就是悬停色，没有「基础态 → 悬停态」的过渡
  // 可重播。
  let modelHoverName = "";

  function clearModelHover() {
    if (!modelHoverName) return;
    modelHoverName = "";
    qa(".fc-model-card.is-hovered").forEach((card) => card.classList.remove("is-hovered"));
  }

  function trackModelHover(event) {
    const target = event.target;
    const card = target && typeof target.closest === "function"
      ? target.closest(".fc-model-card[data-model-name]")
      : null;
    if (!card) return;
    if (event.type === "pointerout") {
      const next = event.relatedTarget;
      if (next && card.contains(next)) return;
      if (modelHoverName !== card.dataset.modelName) return;
      modelHoverName = "";
      card.classList.remove("is-hovered");
      return;
    }
    const name = card.dataset.modelName || "";
    if (!name || name === modelHoverName) return;
    modelHoverName = name;
    qa(".fc-model-card.is-hovered").forEach((node) => {
      if (node !== card) node.classList.remove("is-hovered");
    });
    card.classList.add("is-hovered");
  }

  // 指针换了地方就清掉：卡片被移除时不会补发 pointerout，键盘切页也会留下
  // 一个「其实没在悬停」的旧名字。指针每次移动都校验一次最便宜。
  function trackModelHoverMove(event) {
    if (!modelHoverName) return;
    const target = event.target;
    const card = target && typeof target.closest === "function"
      ? target.closest(".fc-model-card[data-model-name]")
      : null;
    if (card && card.dataset.modelName === modelHoverName) return;
    clearModelHover();
  }

  function restoreModelHover() {
    const cards = qa("#modelsGrid .fc-model-card.is-hovered");
    const node = modelHoverName
      ? q(`#modelsGrid .fc-model-card[data-model-name="${CSS.escape(modelHoverName)}"]`)
      : null;
    cards.forEach((card) => { if (card !== node) card.classList.remove("is-hovered"); });
    if (node && !node.classList.contains("is-hovered")) node.classList.add("is-hovered");
  }

  // 只有模型页挂载着、并且网格里已经有卡片时才补。卡片集合变了（筛选、
  // 搜索、库更新）指纹会变，走整页渲染，这里不负责新增/删除节点。
  function patchModelProgress() {
    if (state.page !== "models" || !S.snap) return;
    if (S.snap.launchPage || (S.snap.recommendation && S.snap.recommendation.show)) return;
    const grid = q("#modelsGrid");
    if (!grid || !window.FCModelWorkspace || typeof window.FCModelWorkspace.patchProgress !== "function") return;
    window.FCModelWorkspace.patchProgress(grid, MODELS, state);
  }

  // 切换模型只会移动「使用中」：补两张卡的描边、状态胶囊和操作按钮，
  // 其它卡片保持原节点。整页 render 会把所有卡片重建一遍，读者会看到
  // 一整个网格同时重排/重放描边过渡。
  function patchModelSelection() {
    if (state.page !== "models" || !S.snap) return;
    if (S.snap.launchPage || (S.snap.recommendation && S.snap.recommendation.show)) return;
    const grid = q("#modelsGrid");
    if (!grid || !window.FCModelWorkspace || typeof window.FCModelWorkspace.patchSelection !== "function") return;
    window.FCModelWorkspace.patchSelection(grid, MODELS, state);
  }

  // ---------- logs (append only) ----------
  // 日志每来一行就整页重建，等于让 `.log-line` 的 0.36s 入场动画在屏幕上
  // 已有的每一行上重播一次：引擎一开口，整个控制台就在闪。这里记住上次画
  // 出来的行 id，只在尾部追加新增的行；清空、截断、换筛选/搜索才整页重来。
  let logsRendered = { ids: [], filter: "", search: "" };

  function markLogsRendered() {
    const lines = (S.snap && S.snap.logs) || [];
    logsRendered = {
      ids: lines.map((line) => String(line.id)),
      filter: state.logFilter,
      search: state.logSearch,
    };
  }

  function patchLogs() {
    if (!S.snap || state.page !== "logs") return false;
    const body = q("#consoleBody");
    if (!body) return false;
    if (logsRendered.filter !== state.logFilter || logsRendered.search !== state.logSearch) return false;
    const lines = LOG_SEED;
    const ids = lines.map((line) => String(line.id));
    const previous = logsRendered.ids;
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
    if (added.length) body.insertAdjacentHTML("beforeend", window.logLinesHtml(added));
    logsRendered.ids = ids;
    refreshLogCounters(lines);
    if (nearBottom) body.scrollTop = body.scrollHeight;
    return true;
  }

  function refreshLogCounters(lines) {
    qa(".filter-pill[data-log-filter]").forEach((pill) => {
      const badge = q("b", pill);
      if (badge) setNodeText(badge, String(window.logCount(pill.dataset.logFilter, lines)));
    });
    const head = q(".console-head");
    const counter = head && qa("span", head).pop();
    if (counter && /\d+\s*行/.test(counter.textContent)) setNodeText(counter, `${lines.length} 行`);
  }

  // ---------- engine install progress (in place) ----------
  // 安装进度只值一条宽度和两个数字。整页重建会把卡片、按钮和进度条一起换掉，
  // 宽度上没有过渡可播，所以看着就是一格一格地跳；卡片一重建，`fc-engine-signal`
  // 那排呼吸条也会从头开始。这里按卡片原地补，只有阶段变化才走整页。
  function patchEngineProgress() {
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

  function updateNavBadge() {
    const badge = q('.nav-item[data-page="models"] .nav-badge');
    if (!badge) return;
    const count = state.loadedModels || 0;
    badge.textContent = String(count);
    badge.style.display = count > 0 ? "" : "none";
  }

  function updateLaunchMode() {
    const standalone = !!(S.snap.launchPage || (S.snap.recommendation && S.snap.recommendation.show));
    document.body.classList.toggle("launch-mode", standalone);
  }

  // Live numbers that change every second without changing the page's shape.
  function tick() {
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
      const newest = newestFlowPoint();
      setText("[data-live='rate']", running && rate > 0 ? rate.toFixed(1) : "—");
      setText("[data-live='flowRate']", running && newest ? newest.v.toFixed(1) : "—");
      setText("[data-live='context']", running ? String(context.used || 0) : "—");
      setText("[data-live='ctx-label']", running ? `${Number(context.used || 0)} tokens` : "等待运行");
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

  function redrawFlowFrame() {
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
  function updateRhythm() {
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
    const values = flowTimeline
      .filter((point) => point.t >= now - 20_000 && point.t <= now + 1_000)
      .slice(-bars.length)
      .map((point) => point.v);
    const peak = values.reduce((max, value) => Math.max(max, value), 0);
    host.classList.toggle("is-empty", !values.length);
    const offset = bars.length - values.length;
    bars.forEach((bar, index) => {
      const value = index >= offset ? values[index - offset] : null;
      const height = value == null || !peak ? "6%" : `${Math.round(12 + (value / peak) * 88)}%`;
      if (bar.style.height !== height) bar.style.height = height;
    });
  }

  function updateRequestRows(sessions) {
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

  function formatThousands(value) {
    return Number(value).toLocaleString("en-US");
  }

  function setText(selector, text) {
    qa(selector).forEach((node) => {
      if (node.textContent !== text) node.textContent = text;
    });
  }

  /// 原地改一个已经挂着的节点。整页重建才会让动画重来，改文本不会。
  function setNodeText(node, text) {
    if (node && node.textContent !== text) node.textContent = text;
  }

  function memoryPercent() {
    const stats = S.snap.stats || {};
    const used = Number(stats.memoryBytes || 0);
    const total = Number(stats.physicalMemoryBytes || 0);
    if (!used || !total) return "—";
    return String(Math.round((used / total) * 100));
  }

  function memoryHint() {
    const stats = S.snap.stats || {};
    const used = Number(stats.memoryBytes || 0);
    const total = Number(stats.physicalMemoryBytes || 0);
    if (!used || !total) return "引擎未上报内存";
    return `${fmtBytes(used)} / ${fmtBytes(total)}`;
  }

  // ---------- overview data ----------
  // Keep the sampled throughput series as timestamped points. The chart and the
  // engine rhythm both read this; no clock tick invents values between samples.
  function updateFlowTimeline(raw) {
    const now = Date.now();
    const from = now - FLOW_WINDOW_MS - 5_000;
    const points = [];
    const seen = new Map();
    (Array.isArray(raw) ? raw : []).forEach((sample) => {
      const t = Number(sample && sample.t);
      const v = Number(sample && sample.v);
      if (!Number.isFinite(t) || !Number.isFinite(v) || v <= 0) return;
      if (t < Math.max(from, flowSince) || t > now + 2_000) return;
      const key = Math.round(t / 50);
      const previous = seen.get(key);
      if (previous == null || v > previous.v) seen.set(key, { t, v });
    });
    seen.forEach((point) => points.push(point));
    points.sort((a, b) => a.t - b.t);
    flowTimeline = points;
    const peak = points.reduce((max, point) => Math.max(max, point.v), 0);
    flowDomainMax = Math.max(10, Math.ceil((peak * 1.12) / 10) * 10);
    // app.js still keeps a numeric array for the probe and for compatibility;
    // it mirrors the real series, it is never seeded with a mock curve.
    flowHistory = points.map((point) => point.v);
  }

  function flowPoints(now = Date.now()) {
    return flowTimeline.filter((point) => point.t >= now - FLOW_WINDOW_MS && point.t <= now + 1_000);
  }

  function newestFlowPoint(maxAge = 5_000) {
    const point = flowTimeline[flowTimeline.length - 1];
    return point && Date.now() - point.t <= maxAge ? point : null;
  }

  // Only fresh samples count as a current decode rate. An engine that stopped
  // decoding keeps reporting its last value; showing that as "LIVE" is exactly
  // the kind of stale number this page used to fake.
  function currentDecodeRate() {
    if (!isRunning()) return 0;
    const point = newestFlowPoint();
    return point ? point.v : 0;
  }

  function flowPillText() {
    if (state.engineBusy) return "SYNC";
    if (!isRunning()) return "IDLE";
    return newestFlowPoint() ? "LIVE" : "WAITING";
  }

  function flowPillClass() {
    const text = flowPillText();
    return text === "LIVE" ? "" : text === "WAITING" ? "is-wait" : "is-off";
  }

  function clamp(value, min, max) {
    return Math.max(min, Math.min(max, value));
  }

  // TTFT is drawn on a 0–2000 ms track. The dot is a real position, not a
  // drifting decoration: 131 ms sits near the left, 1.5 s near the right.
  function ttftPercent() {
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
  function prefillSteps() {
    if (!isRunning()) return 0;
    const rate = Number((S.snap.stats || {}).prefillTokensPerSecond);
    if (!Number.isFinite(rate) || rate <= 0) return 0;
    if (rate >= 4800) return 5;
    if (rate >= 2400) return 4;
    if (rate >= 1200) return 3;
    if (rate >= 600) return 2;
    return 1;
  }

  function memoryBlocks() {
    if (!isRunning()) return 0;
    const percent = Number(memoryPercent());
    if (!Number.isFinite(percent) || percent <= 0) return 0;
    return clamp(Math.round((percent / 100) * 22), 0, 22);
  }

  // ---------- overview ----------
  function rollingText(text) {
    return Array.from(String(text)).map((char, index) =>
      `<span class="model-char" style="--i:${index}">${char === " " ? "&nbsp;" : esc(char)}</span>`).join("");
  }

  function engineStatusText() {
    const engine = (S.snap && S.snap.engine) || {};
    const busy = state.engineBusy;
    const running = isRunning();
    return busy
      ? (engine.switching ? "正在切换" : engine.state === "stopping" ? "正在停止" : "正在启动")
      : running ? "运行中" : engine.state === "failed" ? "启动失败" : "已停止";
  }

  function overviewHTML() {
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
                <strong data-live="rate">${currentDecodeRate() ? currentDecodeRate().toFixed(1) : "—"}</strong><span>tok/s</span>
              </div>
              <div class="engine-live-rhythm ${running && flowTimeline.length ? "" : "is-empty"}" data-live="rhythm" aria-hidden="true">
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
          ${metricWidget("context", "layers", "当前上下文", "CTX", running ? String(context.used || 0) : "—", context.total ? `/ ${Math.round(context.total / 1000)}K` : "", running ? "当前会话" : "引擎未运行")}
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
            <strong data-live="flowRate">${running && newestFlowPoint() ? newestFlowPoint().v.toFixed(1) : "—"}</strong>
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
  function syncOverviewChrome() {
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

  function formatElapsed(seconds) {
    const value = Number(seconds || 0);
    if (value < 1) return `${Math.round(value * 1000)}ms`;
    if (value < 60) return `${value.toFixed(1)}s`;
    return `${Math.floor(value / 60)}m ${Math.round(value % 60)}s`;
  }

  function gatewayAddress(label, address, kind) {
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

  function metricWidget(key, iconName, label, tag, value, unit, hint) {
    return `
      <section class="widget metric-widget metric-${key}" data-widget="metric-${key}">
        <div class="metric-widget-head">
          <span class="metric-widget-icon">${icon(iconName, 14)}</span>
          <span>${esc(label)}</span>
          <span class="metric-widget-tag">${esc(tag)}</span>
        </div>
        <div class="metric-widget-value">
          <strong data-live="${key}">${esc(value)}</strong><span>${esc(unit)}</span>
        </div>
        <div class="metric-widget-hint" data-live="${key}-hint">${esc(hint)}</div>
        ${metricVisual(key)}
      </section>`;
  }

  function requestStateClass(request) {
    return request.state === "failed" ? "err"
      : request.state === "decode" ? "warn"
        : request.state === "prefill" ? "wait" : "ok";
  }

  function requestRate(request) {
    const rate = Number(request && request.decodeRate);
    return request && Number.isFinite(rate) && rate > 0 ? rate.toFixed(1) : "—";
  }

  function requestMeta(request) {
    const stateText = request.state === "decode" ? "解码中"
      : request.state === "prefill" ? "预填充"
        : request.state === "failed" ? "失败" : "完成";
    const elapsed = requestElapsed(request);
    return `${stateText} · ${formatElapsed(elapsed)} · ${displayModel(request.model)}`;
  }

  function requestElapsed(request) {
    const base = Number(request && request.elapsed) || 0;
    const active = request && (request.state === "prefill" || request.state === "decode");
    return active ? base + Math.max(0, (Date.now() - snapshotAt) / 1000) : base;
  }

  function metricVisual(kind) {
    const context = S.snap.context || { used: 0, total: 0 };
    const percent = context.total ? Math.min(100, (context.used / context.total) * 100) : 0;
    if (kind === "context") {
      return `<div class="metric-context-meter ${isRunning() && context.total ? "" : "is-empty"}" aria-hidden="true">
        <i data-live="ctx-meter" style="width:${isRunning() ? percent : 0}%"></i><span data-live="ctx-label">${esc(String(context.used || 0))} tokens</span>
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

  window.FCWidgets.overview = function liveOverview() { return overviewHTML(); };

  // The preview's draw function renders a fabricated 60-point wave. This one
  // renders the real sampled timeline: x comes from each sample's timestamp,
  // the y domain from the current peak, and gaps longer than 3 s break the line
  // instead of pretending the engine was decoding through them.
  function setFlowReadout(value) {
    const text = value == null ? "—" : value.toFixed(1);
    qa("[data-live='flowRate'], #flowLiveValue").forEach((node) => {
      if (node.textContent !== text) node.textContent = text;
    });
  }

  function drawFlowFieldLive(ctx, width, height, time) {
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
      if (!flowState || time - flowState.lastReadout > 240) {
        if (flowState) flowState.lastReadout = time;
        setFlowReadout(null);
      }
      return;
    }

    const xOf = (t) => padX + ((t - (now - FLOW_WINDOW_MS)) / FLOW_WINDOW_MS) * (width - padX * 2);
    const yOf = (v) => bottom - (clamp(v, 0, flowDomainMax) / flowDomainMax) * (bottom - top);
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

    if (!flowState || time - flowState.lastReadout > 240) {
      if (flowState) flowState.lastReadout = time;
      setFlowReadout(fresh && isRunning() ? latest.v : null);
    }
  }

  function updateFlowProbeLive(width, height) {
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
  function chatModelGlyph(model, size) {
    return window.FCModelBrand ? window.FCModelBrand.inline(model, size) : icon("layers", size);
  }

  function chatPageHTML() {
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
          <span class="chat-context" title="当前会话上下文">${esc(String(context.used || 0))} / ${context.total ? `${Math.round(context.total / 1000)}K` : "—"}</span>
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
              ${window.FCChatThinking ? window.FCChatThinking.trigger(state) : ""}
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

  function chatBodyHTML() {
    const messages = state.chatMessages || [];
    return messages.length
      ? messages.map((message, index) => messageHTML(message, index === messages.length - 1)).join("")
      : chatEmptyHTML();
  }

  /// Keep the chat shell in place while only its live values move. Called on
  /// every snapshot (and from `tick()`), so switching models never has to
  /// rebuild the page just to relabel the model chip.
  function syncChatChrome() {
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
      if (window.fcMorphModelButton && line.querySelector("[data-model-label]")) {
        window.fcMorphModelButton(line, { label: modelLabel, glyph });
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
      if (window.fcMorphModelButton && chip.querySelector("[data-model-label]")) {
        window.fcMorphModelButton(chip, { label: modelLabel, glyph });
      } else {
        chip.innerHTML = `<span class="model-glyph" data-model-glyph>${glyph}</span>` +
          `<span class="model-label" data-model-label>${esc(modelLabel)}</span>`;
      }
    }

    const context = S.snap.context || { used: 0, total: 0 };
    setText(".chat-context", `${Number(context.used || 0)} / ${context.total ? `${Math.round(context.total / 1000)}K` : "—"}`);

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
    if (window.syncThinkingTriggerLabel) window.syncThinkingTriggerLabel();
  }

  /// Same-page chat update: refresh the message body in place instead of
  /// replacing the whole page. The sidebar and titlebar never repaint, and the
  /// composer keeps focus while a reply streams.
  /// `resetThread` is set when Swift reports a different threadID (new chat or
  /// reopening a history thread): the composer and the stream engine then belong
  /// to the previous conversation, so the message list is swapped wholesale but
  /// the chat shell itself still stays mounted.
  function updateChatPage(options = {}) {
    const resetThread = !!(options && options.resetThread);
    const saved = captureChatScroll();
    if (resetThread) {
      releaseChatMessages();
      resetChatComposer();
      // A thread swap replaces the whole list at once. Mark its messages as
      // already seen so a long history does not replay .4s of rise-and-blur on
      // every bubble — that reads as another full-screen flash.
      (state.chatMessages || []).forEach((message) => seenMessages.add(message.id));
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
  function releaseChatMessages() {
    const host = q("#messagesInner");
    if (host && window.FCChatStream) {
      qa(".message[data-msg-id]", host).forEach((node) => window.FCChatStream.release(node));
    }
    qa(".fc-jump").forEach((node) => node.remove());
  }

  /// The composer used to be recreated by the full-page render on a new chat,
  /// which dropped the draft. Keep that behaviour now that it stays mounted.
  function resetChatComposer() {
    const input = q("#chatInput");
    if (!input) return;
    input.value = "";
    input.style.height = "46px";
  }

  /// 流式回复只改最后一条气泡的正文文本，不动 `#messagesInner` 里的其它节点：
  /// 整段替换会把光标和「正在思考」的三点一起重建，动画每来一个 token 就重启
  /// 一次（看起来像卡住），长对话里还要重排整串气泡。结构真的变了（新消息、
  /// 换行、回复结束）就返回 false，让调用方走整段重绘。
  function patchStreamingMessage() {
    const messages = state.chatMessages || [];
    const last = messages[messages.length - 1];
    const host = q("#messagesInner");
    if (!last || last.role !== "assistant" || !host) return false;
    const articles = qa(".message[data-msg-id]", host);
    if (articles.length !== messages.length) return false;
    const node = articles[articles.length - 1];
    if (node.dataset.msgId !== String(last.id)) return false;

    if (!window.FCChatStream) return false;

    if (last.streaming) {
      // Every snapshot is just a new target; the reveal engine decides how the
      // text reaches the screen. Nothing here rebuilds the DOM, so the caret,
      // the thinking fold and the markdown blocks keep their state.
      window.FCChatStream.push(node, last);
      return true;
    }

    // The final snapshot arrives while the reader is still watching the last
    // characters land. Hand the finished text over with the meta row, but only
    // after the reveal has drained and the caret has retired — otherwise the
    // reply would jump to full height the instant generation stops.
    if (window.FCChatStream.isAnimating(node)) {
      window.FCChatStream.push(node, last, {
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
  function settleMessageEntrances(root) {
    qa(".message.is-new", root || document).forEach((node) => {
      if (node.dataset.entranceBound) return;
      node.dataset.entranceBound = "1";
      node.addEventListener("animationend", () => {
        node.classList.remove("is-new");
        delete node.dataset.entranceBound;
      }, { once: true });
    });
  }

  function chatEmptyHTML() {
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
  function messageAvatar(message) {
    const model = message.model || state.model;
    if (window.FCModelBrand && typeof window.FCModelBrand.tile === "function") {
      return window.FCModelBrand.tile(model, { size: 15, className: "avatar ai-icon model-avatar" });
    }
    return `<div class="avatar ai-icon">${icon("brain", 14)}</div>`;
  }

  function messageHTML(message, isLast) {
    // Only a message that has not been painted in this thread enters with the
    // rise-and-blur animation. Repaints caused by a switch or a streaming
    // token must leave the bubbles visually still.
    const isNew = !seenMessages.has(message.id);
    if (isNew) seenMessages.add(message.id);
    const entering = isNew ? " is-new" : "";
    if (message.role === "user") {
      return `<article class="message user${entering}" data-msg-id="${esc(message.id)}">
        <div class="message-body"><div class="user-bubble">${esc(message.content)}</div></div>
      </article>`;
    }
    const answer = window.FCChatStream
      ? window.FCChatStream.answerHTML(message)
      : `<div class="md-body">${window.FCChatMarkdown ? window.FCChatMarkdown.render(message.content) : esc(message.content)}</div>`;
    const thinking = window.FCChatStream ? window.FCChatStream.thinkingHTML(message) : "";
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
  function modelsPageHTML() {
    return window.FCModelWorkspace.render(state, MODELS);
  }

  // ---------- logs ----------
  function logsPageHTML() {
    const lines = LOG_SEED;
    const counts = {};
    ["全部", "提示", "警告", "错误"].forEach((filter) => { counts[filter] = window.logCount(filter, lines); });
    const html = window.logLinesHtml(lines);
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
  function settingsPageHTML() {
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
  function launchPageHTML() {
    const rec = S.snap.recommendation || {};
    if (rec.show) return recommendPageHTML(rec);
    return firstRunPageHTML();
  }

  function launchShell(inner) {
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

  function recommendPageHTML(rec) {
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

  function firstRunPageHTML() {
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
  function refreshOverlayLayer() {
    const layer = q("#overlayLayer");
    if (!layer) return;
    const needed = Boolean(state.currentOverlay) || Boolean(q("#fcPending"));
    layer.classList.toggle("is-open", needed);
    layer.setAttribute("aria-hidden", String(!needed));
  }

  let pendingSignature = "";
  function renderPending() {
    const pending = S.snap && S.snap.pending;
    const pendingInstall = S.snap && S.snap.pendingInstall;
    const host = q("#overlayLayer");
    let node = q("#fcPending");
    if (!pending && !pendingInstall) {
      if (node) node.remove();
      pendingSignature = "";
      refreshOverlayLayer();
      return;
    }
    if (!host) return;
    const signature = JSON.stringify([pending, pendingInstall]);
    if (signature === pendingSignature) return;
    pendingSignature = signature;
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
  }

  // ---------- model plaza (Hugging Face) ----------
  // Everything the plaza shows comes from Swift's `hub` snapshot; the page
  // never talks to the Hub, never filters by engine and never decides whether
  // a repository is downloadable. Commands: searchHub / hubDetail / downloadRepo.
  const hubSnapshot = () => (S.snap && S.snap.hub) || {};
  const hubCanonical = (id) => String(id || "").split(":")[0].replace(/--/g, "/").trim();

  /// Whether this repository is already on disk. `hub.local` is the judgement
  /// made by Swift (shared folder + every engine's model folder), so the page
  /// only mirrors it; matching canonicalises flat `owner--repo` names.
  function hubLocally(repo) {
    const canon = hubCanonical(repo);
    if (!canon) return false;
    const hub = hubSnapshot();
    return (hub.local || []).concat(hub.shared || []).some((id) => hubCanonical(id) === canon);
  }

  function openHub() {
    closeOverlays({ immediate: true, restoreFocus: false });
    hubState.open = true;
    hubState.view = "list";
    hubState.tab = "card";
    hubState.detailRepo = "";
    const hub = hubSnapshot();
    hubState.query = String(hub.query || "");
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
    hubSignature = "";
    renderHub(true);
    // The plaza opens on the Hub's trending list, like the README promises.
    // An empty sheet waiting for a keyword is a dead end, and the last query
    // is kept when the user reopens it.
    if (!hub.query && !(hub.results || []).length && !hub.loading) {
      hubSearch("", "trending", "all", 0);
    }
    requestAnimationFrame(() => q("#hubQuery")?.focus());
  }

  function closeHub() {
    hubState.open = false;
    hubState.view = "list";
    hubState.tab = "card";
    hubState.detailRepo = "";
    const node = q("#fcHub");
    if (node) node.classList.remove("is-open");
    q("#fcHubDim")?.remove();
    refreshOverlayLayer();
    // The card is a transient lookup; the list survives so reopening the plaza
    // is instant, and the query stays in the box.
    cmd("closeHubDetail");
    requestAnimationFrame(() => q('[data-action="open-hub"]')?.focus());
  }

  function closeHubDetail() {
    hubState.view = "list";
    hubState.tab = "card";
    hubState.detailRepo = "";
    cmd("closeHubDetail");
    renderHub(true);
    requestAnimationFrame(() => q("#hubQuery")?.focus());
  }

  /// Send one search to Swift. `query` left undefined means "what is in the
  /// box right now"; sort/filter/page left undefined keep the current ones.
  function hubSearch(query, sort, filter, page) {
    const hub = hubSnapshot();
    const input = q("#hubQuery");
    const value = query == null
      ? (input ? input.value : (hubState.query || ""))
      : String(query);
    hubState.query = String(value || "").trim();
    hubState.view = "list";
    hubState.tab = "card";
    hubState.detailRepo = "";
    cmd("searchHub", {
      query: hubState.query,
      sort: sort || hub.sort || "trending",
      filter: filter || hub.filter || "all",
      page: Math.max(0, Number(page) || 0),
    });
  }

  function openHubDetail(repo) {
    if (!repo) return;
    hubState.view = "detail";
    hubState.tab = "card";
    hubState.detailRepo = repo;
    renderHub(true);
    cmd("hubDetail", { repo });
  }

  function downloadHubModel(element) {
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

  function renderHub(force) {
    const node = q("#fcHub");
    if (!node || !hubState.open) return;
    const hub = hubSnapshot();
    const signature = JSON.stringify({
      view: hubState.view,
      tab: hubState.tab,
      detailRepo: hubState.detailRepo,
      hub: [hub.query, hub.sort, hub.filter, hub.page, hub.hasMore, hub.loading,
            hub.detailLoading, hub.error, hub.results, hub.detail, hub.local, hub.shared],
    });
    if (!force && signature === hubSignature) return;
    hubSignature = signature;
    const active = document.activeElement;
    const keepFocus = active && active.id === "hubQuery"
      ? { start: active.selectionStart, end: active.selectionEnd }
      : null;
    node.innerHTML = hubState.view === "detail" ? hubDetailHTML(hub) : hubListHTML(hub);
    if (keepFocus) {
      const input = q("#hubQuery");
      if (input) {
        input.focus({ preventScroll: true });
        try { input.setSelectionRange(keepFocus.start, keepFocus.end); } catch (error) { /* search input */ }
      }
    }
  }

  function hubCloseButton() {
    return `<button class="glass-icon-btn small" type="button" data-hub-close aria-label="关闭模型广场"><span class="sr-only">关闭</span>${icon("x", 14)}</button>`;
  }

  function hubChip(label, action, dataKey, value, active) {
    return `<button class="fc-hub-chip ${active ? "is-on" : ""}" type="button"
      data-action="${action}" data-${dataKey}="${esc(value)}" aria-pressed="${active}">${esc(label)}</button>`;
  }

  function hubKindLabel(model) {
    if (model.mtplx) return "MTP";
    if (model.gguf) return "GGUF";
    if (model.mlx) return "MLX";
    return "MODEL";
  }

  function hubCount(value) {
    const count = Number(value) || 0;
    if (count >= 1e9) return `${(count / 1e9).toFixed(1)}B`;
    if (count >= 1e6) return `${(count / 1e6).toFixed(count >= 1e7 ? 0 : 1)}M`;
    if (count >= 1e3) return `${(count / 1e3).toFixed(count >= 1e4 ? 0 : 1)}k`;
    return String(count);
  }

  function hubParams(value) {
    const count = Number(value) || 0;
    if (count >= 1e12) return `${(count / 1e12).toFixed(1)}T`;
    if (count >= 1e9) return `${(count / 1e9).toFixed(1)}B`;
    if (count >= 1e6) return `${(count / 1e6).toFixed(0)}M`;
    return hubCount(count);
  }

  function hubMemoryText(model) {
    const low = Number(model.memoryMin) || 0;
    const high = Number(model.memoryMax) || 0;
    if (!low) return "";
    if (high && high !== low) return `≈${low}–${high} GB`;
    return `≈${low} GB`;
  }

  function hubEngineLabel(model) {
    const id = model.engineID || "none";
    return id === "none" ? "无推荐引擎" : nameEngineOf(id);
  }

  function hubRowHTML(model) {
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
    const series = window.FCModelBrand && typeof window.FCModelBrand.seriesOf === "function"
      ? window.FCModelBrand.seriesOf(model)
      : null;
    const mark = series && typeof window.FCModelBrand.glyph === "function"
      ? `<span class="fc-hub-mark" style="--fc-series:${esc(series.color)}"
             title="${esc(series.label)} · ${esc(kind)}">${window.FCModelBrand.glyph(series, 17)}</span>`
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

  function hubListHTML(hub) {
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
          <input id="hubQuery" type="search" value="${esc(hubState.query || hub.query || "")}"
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
  function hubCardText(text) {
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

  function hubDetailHTML(hub) {
    // A card only belongs to the row that asked for it: while the next one is
    // in flight the previous card must not flash under the new title.
    const wanted = hubState.detailRepo || "";
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
    const tab = hubState.tab || "card";
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

  // ---------- downloads ----------
  function openDownloads() {
    closeOverlays({ immediate: true, restoreFocus: false });
    openOverlay("downloads");
    renderDownloads(true);
  }

  // 一行里的纯数字（百分比、已下/总量、速度）。渲染和原地补丁共用，两处
  // 措辞不会各写一套。
  function downloadRowText(task, downloads) {
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

  function downloadRows(downloads) {
    const tasks = Array.isArray(downloads.tasks) ? downloads.tasks.slice() : [];
    if (downloads.active && downloads.active.model && !tasks.some((task) => task.model === downloads.active.model)) {
      tasks.unshift({ ...downloads.active, status: "downloading" });
    }
    return tasks;
  }

  // 下载中心开着的时候，进度每 500ms 推一次。整表 innerHTML 会把行和按钮一起
  // 换掉 —— 指针停在某一行上时，行和按钮的悬停态就得重新命中一次，看起来是
  // 闪。所以只有「有哪些行、各自什么状态」变了才重建，数字走 patchDownloadRows。
  let downloadsShape = "";

  function renderDownloads(force) {
    const sheet = q("#downloadSheet");
    const list = q("#downloadList");
    if (!sheet || !list) return;
    const downloads = state.downloads || {};
    const tasks = downloadRows(downloads);
    const shape = downloadShape(downloads);
    if (!force && shape === downloadsShape && list.querySelector(".download-item")) {
      patchDownloadRows(list, downloads);
      return;
    }
    downloadsShape = shape;
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
  function patchDownloadRows(list, downloads) {
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

  // ---------- inspector ----------
  function openInspector() {
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
      qa(".range-input", q("#inspector")).forEach(window.updateRangeVisual);
      if (window.updateSlidingSegments) window.updateSlidingSegments();
    });
  }

  function applyChatParams() {
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

  function tokenForThinking(label) {
    return label === "开启" ? "on" : label === "关闭" ? "off" : "automatic";
  }

  // ---------- model switcher ----------
  function openModelPopover(anchor) {
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
              ${window.FCModelBrand
                ? window.FCModelBrand.tile(id, { size: 15, className: "model-option-icon fc-series-tile" })
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
    if (window.FCOverlayBounds) {
      window.FCOverlayBounds.place(anchor || document.body, popover, {
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

  function openChatMenu(anchor) {
    openActionMenu(anchor, [
      { label: "新对话", detail: "保留当前历史，开一段新的", icon: "messagePlus", run: () => cmd("newChat") },
      { label: "复制整段对话", detail: "按「你 / AI」分段复制", icon: "copy", run: () => cmd("copyConversation") },
      { label: "清空当前对话", detail: "历史里仍保留这一条", icon: "trash", run: () => cmd("clearChat") },
      { label: "下载中心", detail: "查看模型下载进度", icon: "download", run: () => openDownloads() },
    ]);
  }

  function openModelMoreMenu(anchor, name) {
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

  function openShareEngines(model) {
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
    node.addEventListener("click", (event) => {
      const toggle = event.target.closest("[data-share-engine]");
      if (toggle) {
        toggle.classList.toggle("on");
        toggle.innerHTML = `${icon(toggle.classList.contains("on") ? "check" : "cpu", 12)}<span>${esc(nameEngineOf(toggle.dataset.shareEngine))}</span>`;
        return;
      }
      if (event.target.closest("[data-share-cancel]")) {
        node.remove();
        return;
      }
      const save = event.target.closest("[data-share-save]");
      if (save) {
        const chosen = qa("[data-share-engine].on", node).map((item) => item.dataset.shareEngine);
        cmd("setModelEngines", { repo: save.dataset.shareSave, engines: chosen });
        node.remove();
      }
    });
  }

  function rawEngineIds() {
    return (S.snap && S.snap.engineCatalog ? S.snap.engineCatalog.map((item) => item.id) : []);
  }

  function openActionMenu(anchor, items) {
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
    if (window.FCOverlayBounds) {
      window.FCOverlayBounds.place(anchor || document.body, popover, {
        boundary: ".window", preferredSide: "bottom", align: "start", gap: 8, padding: 14,
        width: 300, maxHeight: 400, scroll: true, flip: true, clamp: true,
      });
    }
  }

  // ---------- actions ----------
  function liveHandleAction(action, element) {
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
        if (window.FCChatStream) window.FCChatStream.toggleThinking(block);
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
        hubSearch(hubState.query, element.dataset.hubSort, undefined, 0);
        break;
      case "hub-filter":
        hubSearch(hubState.query, undefined, element.dataset.hubFilter, 0);
        break;
      case "hub-page":
        hubSearch(hubState.query, undefined, undefined, Number(element.dataset.hubPage));
        break;
      case "hub-open":
        openHubDetail(element.dataset.hubRepo);
        break;
      case "hub-back":
        closeHubDetail();
        break;
      case "hub-tab":
        hubState.tab = element.dataset.hubTab || "card";
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
        lastKey = fingerprint();
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

  function toggleEngine(engineId) {
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

  function sendChat() {
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

  function stopChatStream() {
    cmd("stopGeneration");
  }

  function startChatDownload(name) {
    const model = state.modelIndex && state.modelIndex.get(name);
    const engine = model ? model.engineId : activeEngineRaw();
    cmd("downloadModel", { engine, id: name });
    showToast(`开始下载 ${displayModel(name)}`);
  }

  function selectModel(name) {
    const model = state.modelIndex && state.modelIndex.get(name);
    if (model) {
      cmd("useModel", { engine: model.engineId, id: name });
    } else {
      cmd("useModel", { engine: activeEngineRaw(), id: name });
    }
    closeOverlays();
  }

  function toggleSetting(key) {
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

  function cycleThinking() {
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

  function saveEngineConfig() {
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
    window.closeEngineConfig();
  }

  function runEngineInstall(id, kind) {
    cmd("installEngine", { engine: rawEngineOf(id), launch: false });
    showToast(kind === "update" ? `正在更新 ${id}` : `正在下载 ${id}`);
  }

  function removeEngineRuntime(id) {
    cmd("removeEngine", { engine: rawEngineOf(id) });
  }

  function resetSettings() {
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

  function copyVisibleLogs() {
    const text = qa(".log-line:not(.hidden) .msg").map((node) => node.textContent).join("\n");
    if (text) cmd("copyLogText", { text });
  }

  function openEngineConfigFromAnywhere(element) {
    const name = (element && element.dataset && (element.dataset.engineConfig || element.dataset.engineView)) || state.engine;
    if (state.page !== "engines") {
      state.page = "engines";
      state.activeEngineView = name;
      syncNavActive();
      render(true);
      cmd("nav", { page: "engines" });
    }
    requestAnimationFrame(() => window.openEngineConfig(name));
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
  function handleLiveClick(event) {
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
      if (window.FCChatThinking) {
        window.FCChatThinking.update(state);
        if (!(kind === "mode" && value === "on")) window.FCChatThinking.close();
      }
      updateChoiceUI();
      return;
    }
  }

  function updateChoiceUI() {
    const settings = state.settings;
    qa("[data-thinking]").forEach((button) => {
      button.classList.toggle("active", button.dataset.thinking === settings.thinking);
    });
    qa("[data-effort]").forEach((button) => {
      button.classList.toggle("active", button.dataset.effort === settings.reasoningEffort);
    });
    if (window.updateSlidingSegments) requestAnimationFrame(() => window.updateSlidingSegments());
    if (window.syncThinkingTriggerLabel) window.syncThinkingTriggerLabel();
  }

  function handleLiveInput(event) {
    if (event.target.id === "hubQuery") {
      hubState.query = event.target.value;
      return;
    }
    if (event.target.id === "chatInput") {
      autosize(event.target);
      const button = q("#sendButton");
      if (button) button.disabled = !event.target.value.trim() && !state.chatStreaming;
    }
  }

  function handleLiveChange(event) {
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

  function handleLiveKeydown(event) {
    const meta = event.metaKey || event.ctrlKey;
    if (meta && event.key.toLowerCase() === "k") {
      event.preventDefault();
      window.openCommand();
      return;
    }
    if (meta && event.key.toLowerCase() === "n") {
      event.preventDefault();
      cmd("newChat");
      return;
    }
    if (event.key === "Escape" && hubState.open) {
      event.preventDefault();
      if (hubState.view === "detail") closeHubDetail();
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
    if (event.target.matches("[data-gateway-port], [data-port-engine], [data-hf-cache]") && event.key === "Enter") {
      event.preventDefault();
      event.target.blur();
    }
  }

  // ---------- overrides of the preview's mock shell ----------
  window.renderCommandResults = function renderCommandResults(query) {
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
  };

  // WKWebView on file:// is not a secure context, so the preview's clipboard
  // helper can silently fail there. Route copies through Swift's NSPasteboard.
  window.copyText = function copyTextLive(text) {
    cmd("copyText", { text: String(text == null ? "" : text), label: "已复制到剪贴板" });
  };

  window.handleAction = liveHandleAction;
  window.toggleEngine = toggleEngine;
  window.sendChat = sendChat;
  window.stopChatStream = stopChatStream;
  window.startChatDownload = startChatDownload;
  window.selectModel = selectModel;
  window.toggleSetting = toggleSetting;
  window.cycleThinking = cycleThinking;
  window.saveEngineConfig = saveEngineConfig;
  window.runEngineInstall = runEngineInstall;
  window.removeEngineRuntime = removeEngineRuntime;
  window.resetSettings = resetSettings;
  window.openDownloads = openDownloads;
  window.openInspector = openInspector;
  window.openModelPopover = openModelPopover;
  window.commands = commands;
  window.updateEngineChrome = updateChrome;
  window.renderPage = function (animate, options) {
    render(Boolean(animate) && !(options && options.instant));
  };

  // The chart belongs to the app, not to the preview's mock telemetry: replace
  // the two entry points app.js calls while drawing and probing it, and keep
  // the mock seed/telemetry from ever running inside the app.
  window.drawFlowField = drawFlowFieldLive;
  window.updateFlowProbe = updateFlowProbeLive;
  window.initFlowHistory = function initFlowHistoryLive() {
    flowTimeline = [];
    flowHistory = [];
    flowDomainMax = 10;
  };
  window.startLiveTelemetry = function startLiveTelemetryLive() {};
})();
