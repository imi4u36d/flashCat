/* flashCat WebUI · 渲染引擎与桥接客户端
   Swift 侧把全量状态快照推给 window.__fc__.push(state)；
   本侧只做渲染与命令回传（webkit.messageHandlers.bridge）。 */

"use strict";

// ---------- 桥 ----------
function cmd(type, payload) {
  const message = Object.assign({ type }, payload || {});
  if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridge) {
    window.webkit.messageHandlers.bridge.postMessage(message);
  } else {
    console.log("[cmd]", message);
  }
}

// ---------- 本地 UI 状态 ----------
const UI = {
  chartRange: 45,           // 45 / 300 / 0（全部）
  modelsFilter: "all",      // all / local / remote
  modelsSearch: "",
  logFilter: "all",         // all / info / warning / error
  logSearch: "",
  logPaused: false,
  logSnapshot: null,
  thinkOpen: {},            // messageId -> bool
  settingsDraft: null,      // 设置页草稿
  menuOpen: null,           // 打开的浮层 id
  chatParamsOpen: false,    // 对话参数弹层
  chatParamsDraft: null,
  downloadsOpen: false,     // 下载中心弹层
  configEngine: null,       // 引擎配置弹层（engine id）
  configDraft: null,        // 配置草稿 {tuning, port}
  pendingRender: false,     // 交互期间（菜单打开/输入中）挂起的重绘
  streamStart: {},          // 生成中消息 id -> 本地起始时刻（livestrip 计时用）
  composing: false,         // IME 组合输入中（挂起重绘防打断）
};
let S = null; // 最近一次 Swift 快照
let lastPushJSON = null;   // 内容未变化的推送不再整页重绘

// ---------- 快照入口 ----------
window.__fc__ = {
  push(state) {
    const prev = S;
    const json = JSON.stringify(state);
    S = state;
    // 换页才重置草稿；同页推送（心跳/去抖）不能把用户正在编辑的草稿吹掉。
    if (!prev || prev.page !== state.page) {
      UI.settingsDraft = null;
      UI.configDraft = null;
    }
    applyAppearance();
    if (prev && state.toast && state.toast !== prev.toast) toast(state.toast);
    // 菜单开着或正在输入设置项时不整页重绘，交互结束后补一次。
    if (interactionHold()) { UI.pendingRender = true; lastPushJSON = json; return; }
    // 快照与上次完全一致（心跳空转）时只补走本地时钟，不整页重绘。
    if (prev && prev.page === state.page && lastPushJSON === json) { tickLive(); return; }
    lastPushJSON = json;
    render();
  },
};

// 快照未变时的本地时钟补走：概览 UP 计时、日志跟随时间戳。
function tickLive() {
  if (!S) return;
  if (S.page === "overview") {
    const el = document.getElementById("uptime");
    if (el) el.textContent = "UP " + fmtUptime(S.stats && S.stats.startedAt);
  } else if (S.page === "logs" && !UI.logPaused) {
    const f = document.getElementById("followLine");
    if (f) f.textContent = "█ 实时跟随中 · " + new Date().toTimeString().slice(0, 8);
  }
}
window.__fcToast = function (message) { toast(message); };

function interactionHold() {
  if (UI.menuOpen || UI.composing) return true;
  const key = document.activeElement && document.activeElement.dataset ? document.activeElement.dataset.key : null;
  // chatInput 除外：生成中的心跳推送要保持消息区实时刷新。
  return !!key && key !== "chatInput";
}

function flushPendingRender() {
  if (UI.pendingRender && !interactionHold()) {
    UI.pendingRender = false;
    render();
  }
}

function toast(message) {
  const el = document.getElementById("toast");
  el.textContent = message;
  el.classList.add("show");
  clearTimeout(el.__t);
  el.__t = setTimeout(() => el.classList.remove("show"), 2200);
}

// ---------- 外观 ----------
const darkQuery = window.matchMedia("(prefers-color-scheme: dark)");
darkQuery.addEventListener("change", () => { if (S && S.appearance === "system") render(); });
function applyAppearance() {
  const mode = !S || S.appearance === "system" ? (darkQuery.matches ? "dark" : "light")
             : S.appearance;
  document.body.dataset.mode = mode;
}

// ---------- 工具 ----------
const esc = (s) => String(s == null ? "" : s)
  .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
  .replace(/"/g, "&quot;");

function fmtBytes(n) {
  if (!n || n <= 0) return "—";
  const units = ["B", "KB", "MB", "GB", "TB"];
  let v = n, i = 0;
  while (v >= 1024 && i < units.length - 1) { v /= 1024; i++; }
  return `${v >= 100 ? Math.round(v) : v.toFixed(1)} ${units[i]}`;
}
function fmtRate(v) {
  if (!v || v <= 0) return "";
  return fmtBytes(v) + "/s";
}
function fmtUptime(startedAt) {
  if (!startedAt) return "—";
  const s = Math.max(0, Math.floor(Date.now() / 1000 - startedAt));
  const h = String(Math.floor(s / 3600)).padStart(2, "0");
  const m = String(Math.floor(s % 3600 / 60)).padStart(2, "0");
  return `${h}:${m}:${String(s % 60).padStart(2, "0")}`;
}
function fmtClock(ms) {
  if (!ms) return "";
  const d = new Date(ms);
  const p = (x) => String(x).padStart(2, "0");
  return `${p(d.getHours())}:${p(d.getMinutes())}`;
}
function relTime(ms) {
  if (!ms) return "";
  const diff = Date.now() - ms;
  if (diff < 60000) return "刚刚";
  if (diff < 3600000) return `${Math.floor(diff / 60000)}m`;
  if (diff < 86400000) return `${Math.floor(diff / 3600000)}h`;
  return "昨天";
}
// 进度环（安装进度用）
function ringSVG(fraction, size, label) {
  const p = Math.min(Math.max(fraction || 0, 0), 1);
  const r = (size - 7) / 2, c = 2 * Math.PI * r;
  return `<svg width="${size}" height="${size}" viewBox="0 0 ${size} ${size}" class="ring">
    <circle cx="${size / 2}" cy="${size / 2}" r="${r}" fill="none" stroke="var(--w-line)" stroke-width="3.5"/>
    <circle cx="${size / 2}" cy="${size / 2}" r="${r}" fill="none" stroke="var(--w-accent)" stroke-width="3.5"
      stroke-linecap="round" stroke-dasharray="${(c * p).toFixed(1)} ${c.toFixed(1)}" transform="rotate(-90 ${size / 2} ${size / 2})"/>
    <text x="50%" y="54%" dominant-baseline="middle" text-anchor="middle" font-size="${size >= 40 ? 11 : 9.5}" fill="var(--w-ink)">${label != null ? label : Math.round(p * 100) + "%"}</text>
  </svg>`;
}

// 极简 markdown：段落 / 标题 / 代码块 / 引用 / 列表 / 行内代码与加粗
function md(text) {
  const src = String(text == null ? "" : text);
  const blocks = [];
  const lines = src.replace(/\r\n/g, "\n").split("\n");
  let i = 0, para = [];
  const flush = () => { if (para.length) { blocks.push(["p", para.join("\n")]); para = []; } };
  while (i < lines.length) {
    const t = lines[i].trim();
    if (!t) { flush(); i++; continue; }
    if (t.startsWith("```") || t.startsWith("~~~")) {
      flush();
      const mark = t.slice(0, 3);
      const lang = esc(t.slice(3).trim() || "CODE");
      i++;
      const code = [];
      while (i < lines.length && !lines[i].trim().startsWith(mark)) { code.push(lines[i]); i++; }
      i++;
      blocks.push(["code", `<pre><code>${esc(code.join("\n"))}</code></pre>`, lang]);
      continue;
    }
    if (/^#{1,4}\s/.test(t)) { flush(); blocks.push(["h", esc(t.replace(/^#+\s*/, "")), t.match(/^#+/)[0].length]); i++; continue; }
    if (t.startsWith(">")) { flush(); const q = []; while (i < lines.length && lines[i].trim().startsWith(">")) { q.push(lines[i].trim().slice(1).trim()); i++; } blocks.push(["q", esc(q.join("\n"))]); continue; }
    if (/^[-*+•]\s/.test(t) || /^\d+[.)]\s/.test(t)) {
      flush();
      const items = [];
      while (i < lines.length && (/^[-*+•]\s/.test(lines[i].trim()) || /^\d+[.)]\s/.test(lines[i].trim()))) {
        items.push(lines[i].trim().replace(/^([-*+•]|\d+[.)])\s*/, "")); i++;
      }
      blocks.push(["ul", items.map((x) => `<li>${inline(x)}</li>`).join("")]);
      continue;
    }
    if (t === "---" || t === "***") { flush(); blocks.push(["hr"]); i++; continue; }
    para.push(lines[i]); i++;
  }
  flush();
  if (!blocks.length) blocks.push(["p", ""]);
  return blocks.map(([k, a, b]) => {
    switch (k) {
      case "p": return `<p>${inline(a)}</p>`;
      case "h": return `<p style="font-weight:700;font-size:${b <= 2 ? 14.5 : 13.5}px">${inline(a)}</p>`;
      case "code": return a;
      case "q": return `<p style="border-left:3px solid var(--w-line-strong);padding-left:10px;color:var(--w-ink-2)">${inline(a)}</p>`;
      case "ul": return `<ul style="margin:0;padding-left:18px">${a}</ul>`;
      default: return "<hr>";
    }
  }).join("");

  function inline(s) {
    return esc(s)
      .replace(/`([^`]+)`/g, "<code>$1</code>")
      .replace(/\*\*([^*]+)\*\*/g, "<b>$1</b>");
  }
}

// ---------- 渲染骨架 ----------
let renderQueued = false;
let pageChangedQueued = false;
function render(pageChanged) {
  if (pageChanged) pageChangedQueued = true;
  if (renderQueued) return;
  renderQueued = true;
  requestAnimationFrame(() => {
    renderQueued = false;
    const pc = pageChangedQueued;
    pageChangedQueued = false;
    renderNow(pc);
  });
}

function renderNow(pageChanged) {
  if (!S) return;
  closeMenus();
  const focusKey = document.activeElement && document.activeElement.dataset ? document.activeElement.dataset.key : null;
  const launch = !!S.launchPage;
  document.body.classList.toggle("launch-mode", launch);
  document.getElementById("side").style.display = launch ? "none" : "";
  const main = document.getElementById("main");
  main.className = "main" + (launch ? " launch-main" : (S.page === "chat" ? " chat-main" : ""));
  if (launch) {
    main.innerHTML = pageLaunch();
    bindActs(main);
    restoreFocus(focusKey);
    return;
  }
  // 页面切换：轻量淡入，弱化整页 innerHTML 替换的闪烁感。
  if (pageChanged) {
    main.classList.remove("page-in");
    void main.offsetWidth;
    main.classList.add("page-in");
  }
  renderSide();
  switch (S.page) {
    case "overview": main.innerHTML = pageOverview(); break;
    case "chat": main.innerHTML = pageChat(); afterChatRender(pageChanged); break;
    case "models": main.innerHTML = pageModels(); break;
    case "engines": main.innerHTML = pageEngines(); break;
    case "logs": main.innerHTML = pageLogs(); afterLogsRender(); break;
    case "settings": main.innerHTML = pageSettings(); afterSettingsRender(); break;
  }
  // 每页统一绑定 data-act；这是此前多页按钮失灵的根因（只绑定过对话/日志两页）。
  bindActs(main);
  renderOverlays();
  restoreFocus(focusKey);
}

// 近底才吸底：流式输出/新日志到达时跟随滚动，用户上翻阅读时不拽回底部。
function stickScroll(el, force) {
  if (!el) return;
  const nearBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 140;
  if (force || nearBottom) el.scrollTop = el.scrollHeight;
}

function restoreFocus(key) {
  if (!key) return;
  const el = document.querySelector(`[data-key="${key}"]`);
  if (el && el.focus) el.focus();
}

function closeMenus() {
  document.querySelectorAll(".popover").forEach((p) => p.remove());
  UI.menuOpen = null;
  flushPendingRender();
}

document.addEventListener("click", (e) => {
  UI.lastClickEl = e.target;
  const menuBtn = e.target.closest && e.target.closest("[data-menu]");
  const modelMenuBtn = e.target.closest && e.target.closest("[data-act='modelMenu']");
  if (!menuBtn && !modelMenuBtn) {
    if (UI.menuOpen && !e.target.closest(".popover")) { closeMenus(); UI.menuOpen = null; }
    return;
  }
  // 菜单按钮：捕获阶段统一处理并拦截，避免 bubble 侧重复触发。
  e.stopPropagation();
  e.preventDefault();
  if (menuBtn) {
    switch (menuBtn.dataset.menu) {
      case "modelSwitcher": modelSwitcherMenu(); return;
      case "chatMore": chatMoreMenu(); return;
      case "engineMenu": engineMenu(menuBtn.dataset.arg); return;
      case "logMenu": logMenu(); return;
    }
  }
  if (modelMenuBtn) modelMenu(modelMenuBtn.dataset.arg);
}, true);

function popover(anchorId, items) {
  if (UI.menuOpen === anchorId) { closeMenus(); return; }
  closeMenus();
  const anchor = document.getElementById(anchorId) || UI.lastClickEl;
  if (!anchor) return;
  const box = document.createElement("div");
  box.className = "popover";
  box.innerHTML = items.map((it) => it === "-" ? '<div class="sep"></div>'
    : `<div class="item ${it.on ? "on" : ""}" data-act="${esc(it.act)}" data-arg="${esc(it.arg || "")}">${it.label}${it.on ? '<span class="check">✓</span>' : ""}</div>`).join("");
  box.addEventListener("click", (e) => {
    const item = e.target.closest(".item");
    if (!item) return;
    closeMenus();
    handleAction(item.dataset.act, item.dataset.arg);
  });
  document.getElementById("main").appendChild(box);
  const r = anchor.getBoundingClientRect();
  const host = document.getElementById("main").getBoundingClientRect();
  box.style.top = Math.min(r.bottom - host.top + 4, host.height - box.offsetHeight - 8) + "px";
  box.style.left = Math.max(8, Math.min(r.left - host.left, host.width - box.offsetWidth - 8)) + "px";
  UI.menuOpen = anchorId;
}

function handleAction(act, arg) {
  switch (act) {
    case "nav": nav(arg); break;
    case "openThread": cmd("openThread", { id: arg }); break;
    case "newChat": cmd("newChat"); break;
    case "copyConversation": cmd("copyConversation"); break;
    case "clearChat": cmd("clearChat"); break;
    case "clearThreads": cmd("clearThreads"); break;
    case "chatParams": UI.chatParamsOpen = true; UI.chatParamsDraft = null; render(); break;
    case "browseEngine": cmd("browseEngine", { engine: arg }); break;
    case "useModel": { const [engine, id] = arg.split("|"); cmd("useModel", { engine, id }); break; }
    case "downloadModel": { const [engine, id] = arg.split("|"); cmd("downloadModel", { engine, id }); break; }
    case "revealModel": { const [engine, id] = arg.split("|"); cmd("revealModel", { engine, id }); break; }
    case "removeModel": { const [engine, id] = arg.split("|"); cmd("removeModel", { engine, id }); break; }
    case "engineMenu": engineMenu(arg); break;
    case "engineConfig": UI.configEngine = arg; UI.configDraft = null; render(); break;
    case "openFinder": cmd("openFinder", { kind: arg, engine: UI.configEngine || undefined }); break;
    case "openFinderEngine": { const [kind, eng] = arg.split("|"); cmd("openFinder", { kind, engine: eng }); break; }
    case "installEngine": cmd("installEngine", { engine: arg }); break;
    case "installEngineLaunch": cmd("installEngine", { engine: arg, launch: true }); break;
    case "openLaunchPage": cmd("openLaunchPage"); break;
    case "finishLaunch": cmd("finishLaunch"); break;
    case "start": cmd("startService"); break;
    case "stop": cmd("stopService"); break;
    case "restart": cmd("restartService"); break;
    case "confirmUse": cmd("confirmLibraryUse"); break;
    case "cancelUse": cmd("cancelLibraryUse"); break;
    case "confirmSwitch": cmd("confirmModelSwitch"); break;
    case "cancelSwitch": cmd("cancelModelSwitch"); break;
    case "confirmInstall": cmd("confirmEngineInstall"); break;
    case "cancelInstall": cmd("cancelEngineInstall"); break;
    case "chartRange": UI.chartRange = Number(arg); render(); break;
    case "copyGateway": cmd("copyGateway"); break;
    case "openDownloadCenter": UI.downloadsOpen = true; render(); break;
    case "closeDownloads": UI.downloadsOpen = false; render(); break;
    case "closeConfig": UI.configEngine = null; UI.configDraft = null; render(); break;
    case "closeChatParams": UI.chatParamsOpen = false; UI.chatParamsDraft = null; render(); break;
    case "pauseDownload": { const t = taskArg(arg); cmd("pauseDownload", t); break; }
    case "resumeDownload": { const t = taskArg(arg); cmd("resumeDownload", t); break; }
    case "cancelDownload": { const t = taskArg(arg); cmd("cancelDownload", t); break; }
    case "removeTask": { const t = taskArg(arg); cmd("removeTask", t); break; }
    case "saveEngineConfig": saveEngineConfig(); break;
    case "saveChatParams": saveChatParams(); break;
    case "logMenu": logMenu(); break;
    case "clearLogs": cmd("clearLogs"); break;
    case "importModels": cmd("importModels", { engine: arg }); break;
    case "rescan": cmd("rescan", { engine: arg }); break;
    case "copyLog": copyVisibleLogText(); break;
  }
}

function taskArg(arg) {
  const [engine, model] = String(arg || "").split("|");
  return { engine, model };
}

// 乐观导航：本地先切页渲染（快照数据已在手），再通知 Swift。
// 原实现只发命令等 Swift 回推，固定叠加 100ms 去抖 + 100ms 排队，菜单切换必然发黏。
function nav(page) {
  if (S && S.page !== page) {
    S.page = page;
    UI.settingsDraft = null;
    UI.configDraft = null;
    UI.menuOpen = null;
    lastPushJSON = null; // Swift 确认推送（同页）时仍正常走一次渲染兜底
    render(true);
  }
  cmd("nav", { page });
}

// ---------- 侧栏 ----------
const NAV_ICONS = { overview: "◧", chat: "❝", models: "◫", engines: "⚙", logs: "≣", settings: "✳" };
const NAV_NAMES = { overview: "概览", chat: "对话", models: "模型", engines: "引擎", logs: "日志", settings: "设置" };

function renderSide() {
  const st = S.engine || {};
  const localCount = (S.library && S.library.entries || []).filter((x) => x.installed).length;
  const running = st.running;
  const statusText = st.switching ? "切换中" : (running ? "运行中" : (st.state === "starting" ? "启动中" : (st.state === "failed" ? "异常" : "已停止")));
  const dotCls = st.switching || st.state === "starting" ? "warn pulse" : (running ? "ok" : (st.state === "failed" ? "err" : ""));
  const act = running ? `<span class="act" data-a="stop">停止</span>`
    : (st.state === "starting" || st.switching ? `<span class="act busy">…</span>`
    : `<span class="act" data-a="start">启动</span>`);
  const threads = (S.threads || []).map((t) =>
    `<div class="recent" data-act="openThread" data-arg="${esc(t.id)}">${esc(t.title)}<span class="tm">${relTime(t.updatedAt)}</span></div>`).join("");
  const dlCount = (S.downloads && S.downloads.tasks || []).length;

  document.getElementById("side").innerHTML = `
    <div class="brand"><div class="logo"></div><div><div class="t">flashCat</div><div class="s">本地推理控制台</div></div></div>
    <div class="group">工作区</div>
    ${["overview", "chat", "models", "engines", "logs", "settings"].map((p) => `
      <div class="nav-item ${S.page === p ? "active" : ""}" data-act="nav" data-arg="${p}">
        <span class="ico">${NAV_ICONS[p]}</span>${NAV_NAMES[p]}
        ${p === "models" && localCount ? `<span class="badge">${localCount}</span>` : ""}
      </div>`).join("")}
    <div class="group">最近对话</div>
    ${threads || '<div class="recent" style="color:var(--w-ink-3)">暂无对话</div>'}
    <div class="engine-card" id="engineCard">
      <div class="row1"><span class="dot ${dotCls}"></span><span class="st">${statusText}</span>${act}</div>
      <div class="model">${esc(S.selectedModel || "未选择模型")}</div>
      <div class="chips">${["splash", "omlx", "mtplx"].map((e) =>
        `<span class="echip ${S.engine.id === e ? "on" : ""}" data-engine="${e}">${e === "splash" ? "Splash" : e === "omlx" ? "oMLX" : "MTPLX"}</span>`).join("")}</div>
      <div class="foot"><span>${esc((st.id || "").toUpperCase())} ${esc(st.version || "")}</span><span>:${S.port}</span></div>
    </div>
    ${dlCount ? `<div class="side-dl" data-act="openDownloadCenter">↓ ${dlCount} 个下载任务</div>` : ""}`;

  const card = document.getElementById("engineCard");
  card.querySelectorAll("[data-a]").forEach((el) => {
    el.addEventListener("click", (e) => { e.stopPropagation(); handleAction(el.dataset.a); });
  });
  // 引擎 chip：点当前引擎跳引擎页，点其他引擎直接切换（一键 switchEngine）。
  card.querySelectorAll(".echip").forEach((el) => {
    el.addEventListener("click", (e) => {
      e.stopPropagation();
      const eng = el.dataset.engine;
      if (eng === S.engine.id) nav("engines");
      else cmd("switchEngine", { engine: eng });
    });
  });
  bindActs(document.getElementById("side"));
}

function bindActs(root) {
  root.querySelectorAll("[data-act]").forEach((el) => {
    if (el.__bound) return;
    el.__bound = true;
    el.addEventListener("click", (e) => {
      e.stopPropagation();
      handleAction(el.dataset.act, el.dataset.arg);
    });
  });
  // data-menu（⋯/模型切换）统一由 document 捕获阶段监听处理，这里不重复绑定。
}

// ---------- 概览 ----------
function sparkSVG(samples) {
  if (!samples || samples.length < 2) return '<div class="empty" style="padding:24px">启动并生成一次回复后，这里会显示吞吐曲线</div>';
  const W = 800, H = 88;
  const max = Math.max(...samples.map((s) => s.v), 10) * 1.15;
  const t0 = samples[0].t, t1 = Math.max(samples[samples.length - 1].t, t0 + 1);
  const pts = samples.map((s) => [((s.t - t0) / (t1 - t0)) * (W - 4), H - (s.v / max) * (H - 6) - 3]);
  const line = pts.map((p, i) => `${i ? "L" : "M"}${p[0].toFixed(1)},${p[1].toFixed(1)}`).join(" ");
  const area = `${line} L${pts[pts.length - 1][0].toFixed(1)},${H} L${pts[0][0].toFixed(1)},${H} Z`;
  const last = pts[pts.length - 1];
  return `<svg class="spark" viewBox="0 0 ${W} ${H}" preserveAspectRatio="none">
    <defs><linearGradient id="g1" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#FF7A45" stop-opacity=".28"/><stop offset="1" stop-color="#FF7A45" stop-opacity="0"/>
    </linearGradient></defs>
    <path d="${area}" fill="url(#g1)"/>
    <path d="${line}" fill="none" stroke="#FF7A45" stroke-width="2" stroke-linejoin="round"/>
    <circle cx="${last[0].toFixed(1)}" cy="${last[1].toFixed(1)}" r="3.5" fill="#FF7A45"/>
  </svg>`;
}

function metricCard(label, tag, value, unit, hint, hero, loading) {
  const val = loading
    ? `<div class="skeleton" style="width:96px;height:30px;margin:6px 0 4px"></div>`
    : `<div class="val">${esc(value)}<small>${esc(unit)}</small></div>`;
  return `<div class="metric ${hero ? "hero-m" : ""}">
    <div class="lb"><span>${esc(label)}</span><span class="tag">${esc(tag)}</span></div>
    ${val}<div class="hint">${esc(hint)}</div>
  </div>`;
}

function pageOverview() {
  const st = S.engine || {};
  const stats = S.stats;
  const loading = st.switching || st.state === "starting" || (st.ready && !stats);
  const statusText = st.switching ? `切换中${st.switchStage ? " · " + st.switchStage : ""}`
    : (st.state === "starting" ? `启动中${st.startupStage && st.startupStage !== "就绪" ? " · " + st.startupStage : ""}`
    : (running() ? "运行中" : (st.state === "failed" ? "启动失败" : "已停止")));
  const dotCls = st.switching || st.state === "starting" ? "warn pulse" : (running() ? "ok" : (st.state === "failed" ? "err" : ""));

  const samples = (S.throughput || []).filter((s) => !UI.chartRange || (Date.now() - s.t) <= UI.chartRange * 1000);
  const mem = stats && stats.memoryBytes && stats.physicalMemoryBytes;
  const kv = [
    ["设备", stats ? `${stats.deviceName || "—"}${stats.gpuCores ? " · " + stats.gpuCores + "C" : ""}` : "—"],
    ["进程", stats && stats.instancePid ? `PID ${stats.instancePid}` : "未运行"],
    ["热状态", stats ? (stats.thermalText || "—") : "—", stats && stats.thermal && stats.thermal !== "nominal"],
    ["请求统计", stats ? `${stats.requestsCompleted} 完成 · ${stats.requestsFailed} 失败` : "—"],
    [stats && stats.dflashLabel ? stats.dflashLabel : "草稿接受率", stats && stats.draftAcceptance != null ? Math.round(stats.draftAcceptance * 100) + "%" : (stats ? "未启用" : "—")],
    ["上下文窗口", stats && stats.maximumContextTokens ? (stats.maximumContextTokens >= 1000 ? Math.round(stats.maximumContextTokens / 1000) + "K tok" : stats.maximumContextTokens + " tok") : "—"],
  ].map(([k, v, warn]) => `<div class="r"><span class="k">${esc(k)}</span><span class="v" ${warn ? 'style="color:var(--w-warn)"' : ""}>${esc(v)}</span></div>`).join("");

  return `
    <div class="crumb">控制台 / 概览</div>
    <h2 class="pg">概览</h2>
    <div class="sub">本地推理引擎状态与实时指标</div>
    ${st.failure ? `<div class="confirm-strip" style="border-color:color-mix(in srgb, var(--w-err) 40%,transparent);color:var(--w-err);background:color-mix(in srgb, var(--w-err) 9%,transparent)">${esc(st.failure)}</div>` : ""}
    <div class="statusbar">
      <span class="lead"><span class="dot ${dotCls}"></span>${esc(statusText)}</span>
      <span class="meta"><span>ENGINE ${esc(st.id || "")} ${esc(st.version || "")}</span>
        ${running() ? `<span>PORT :${S.port}</span><span id="uptime">UP ${esc(fmtUptime(stats && stats.startedAt))}</span>${stats && stats.thermal && stats.thermal !== "nominal" ? `<span>TEMP ${esc(stats.thermalText)}</span>` : ""}` : ""}</span>
      <span class="hint">启停入口：侧栏引擎卡</span>
    </div>
    <div class="metrics">
      ${metricCard("解码速度", loading ? "SYNC" : "LIVE", stats && stats.decodeTokensPerSecond ? stats.decodeTokensPerSecond.toFixed(1) : "—", "tok/s", "实时采样 · 1s 刷新", true, loading)}
      ${metricCard("首字延迟", "TTFT", stats && stats.ttftMilliseconds != null ? Math.round(stats.ttftMilliseconds) : "—", "ms", "最近请求", false, loading)}
      ${metricCard("预填充", "PREFILL", stats && stats.prefillTokensPerSecond ? fmtK(stats.prefillTokensPerSecond) : "—", "tok/s", "引擎 prefill 采样", false, loading)}
      ${metricCard("内存压力", "MEM", stats && mem ? Math.round(stats.memoryBytes / stats.physicalMemoryBytes * 100) : "—", "%", mem ? `${fmtBytes(stats.memoryBytes)} / ${fmtBytes(stats.physicalMemoryBytes)}` : "引擎运行后显示", false, loading)}
    </div>
    <div class="chart-card">
      <div class="hd"><span class="t">解码吞吐</span>
        <span class="range"><span class="${UI.chartRange === 45 ? "on" : ""}" data-act="chartRange" data-arg="45">45 秒</span><span class="${UI.chartRange === 300 ? "on" : ""}" data-act="chartRange" data-arg="300">5 分钟</span><span class="${UI.chartRange === 0 ? "on" : ""}" data-act="chartRange" data-arg="0">全部</span></span>
      </div>
      ${loading ? '<div class="skeleton" style="height:88px"></div>' : sparkSVG(samples)}
    </div>
    <div class="cols">
      <div class="panel"><div class="t">运行详情</div><div class="kv">${kv}</div></div>
      <div class="panel"><div class="t">API 网关</div>
        <div class="endpoint"><span class="url">${esc(S.gatewayURL)}</span><span class="copy" data-act="copyGateway">复制</span></div>
        <div class="fmt-badges"><span class="fmt o">OpenAI · chat/completions</span><span class="fmt c">Claude · messages</span></div>
      </div>
    </div>`;
}

function fmtK(v) { return v >= 1000 ? (v / 1000).toFixed(1) + "k" : Math.round(v); }
function running() { return S.engine && S.engine.running; }

// ---------- 对话 ----------
function pageChat() {
  const msgs = S.messages || [];
  const body = msgs.length ? msgs.map((m, i) => msgRow(m, i)).join("")
    : `<div class="empty">
        <div class="t">开始一次本地对话</div>
        <div>所有推理都在这台设备上完成。没有账号，没有云端，也没有内容上传。</div>
        <div class="suggestions">
          <span class="cap click" data-say="帮我用一句话解释 GGUF 量化档位怎么选？">GGUF 量化档位怎么选？</span>
          <span class="cap click" data-say="DFlash2 草稿模型是怎么加速解码的？">DFlash2 如何加速？</span>
          <span class="cap click" data-say="64GB 内存的 Mac 跑 35B 模型该选什么量化？">64GB 跑 35B 选什么量化？</span>
        </div>
      </div>`;
  const live = S.generating ? `<div class="livestrip"><span class="spinner"></span>${esc(S.generationStatus || "生成中")}
    <span class="chips"><span class="mchip" id="liveRate">— tok/s</span><span class="mchip" id="liveElapsed">0.0s</span></span></div>` : "";
  const temp = S.settings ? S.settings.temperature : 0.7;
  const thinkLabel = S.settings ? S.settings.thinkingModeLabel : "自动";
  return `
    <div class="chat-head">
      <span class="dot ${running() ? "ok" : ""}"></span>
      <div class="mdl" id="modelSwitcher" data-menu="modelSwitcher">${esc(shortModel(S.selectedModel))}<small>点击切换模型</small></div>
      <div class="right">
        <span class="cap">温度 ${Number(temp).toFixed(1)}</span>
        <span class="cap">思考 · ${esc(thinkLabel)}</span>
        <span class="icon-btn" id="chatMore" data-menu="chatMore">⋯</span>
        <span class="cap on click" data-act="newChat">＋ 新对话</span>
      </div>
    </div>
    <div class="msgs" id="msgs">${body}</div>
    ${live}
    <div class="inputbar"><div class="inputbox">
      <textarea id="chatInput" rows="1" data-key="chatInput" placeholder="输入消息…（⏎ 发送 · ⇧⏎ 换行）${running() ? "" : " · 启动本地服务后可发送"}"></textarea>
      <div class="row">
        <span class="cap">${esc(shortModel(S.selectedModel))}</span>
        <span class="cap">温度 ${Number(temp).toFixed(1)}</span>
        <span class="cap">思考 · ${esc(thinkLabel)}</span>
        <button class="send ${S.generating ? "stop" : ""}" id="sendBtn" ${!S.generating && (!running() || !(UI.chatDraft || "").trim()) ? "disabled" : ""}>${S.generating ? "停止" : "发送"}</button>
      </div>
    </div></div>`;
}

function shortModel(id) {
  if (!id) return "模型";
  return id.split("/").pop();
}

function msgRow(m, index) {
  const isUser = m.role === "user";
  const av = isUser ? `<div class="av">你</div>` : `<div class="av"></div>`;
  const open = UI.thinkOpen[m.id];
  const think = !isUser && m.reasoning ? `
    <div class="think ${open ? "open" : ""}" data-think="${esc(m.id)}">
      <div class="th">思考过程${m.thinkSeconds ? " · " + m.thinkSeconds.toFixed(1) + "s" : ""} ${open ? "▲" : "▼"}</div>
      <div class="tb">${esc(m.reasoning)}</div>
    </div>` : "";
  const failed = m.content && m.content.startsWith("出错：");
  const bubble = failed
    ? `<div class="bubble" style="background:color-mix(in srgb, var(--w-err) 9%,transparent);border-color:color-mix(in srgb, var(--w-err) 30%,transparent);color:var(--w-err)">${esc(m.content)}</div>`
    : (m.streaming && !m.content ? `<div class="bubble" style="display:flex;gap:8px;align-items:center"><span class="spinner"></span>${esc(S.generationStatus || "正在生成…")}</div>`
    : `<div class="bubble">${m.streaming ? mdStream(m.content) : md(m.content)}</div>`);
  const meta = !isUser && !m.streaming && !failed && (m.rate || m.tokens) ? `
    <div class="msg-meta">${m.rate ? `<span>${m.rate.toFixed ? m.rate.toFixed(1) : m.rate} tok/s</span>` : ""}${m.ttft ? `<span>首字 ${Math.round(m.ttft * 1000)}ms</span>` : ""}${m.tokens ? `<span>${m.tokens} tokens</span>` : ""}<span class="lnk" data-copy="${esc(m.id)}">复制</span></div>` : "";
  return `<div class="msg ${isUser ? "user" : "ai"}">${av}<div>${think}${bubble}${meta}</div></div>`;
}

// 流式期间同一渲染管线（md 每帧全量重算对小消息足够快）
const mdStream = md;

function afterChatRender(pageChanged) {
  const input = document.getElementById("chatInput");
  const send = document.getElementById("sendBtn");
  const msgs = document.getElementById("msgs");
  if (input) {
    input.value = UI.chatDraft || "";
    input.addEventListener("input", () => {
      UI.chatDraft = input.value;
      input.style.height = "auto";
      input.style.height = Math.min(input.scrollHeight, 160) + "px";
      const btn = document.getElementById("sendBtn");
      if (btn && !S.generating) btn.disabled = !(UI.chatDraft || "").trim() || !running();
    });
    input.addEventListener("keydown", (e) => {
      if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); if (UI.chatDraft && UI.chatDraft.trim() && running() && !S.generating) doSend(); }
    });
  }
  if (send) send.addEventListener("click", () => { if (S.generating) cmd("stopGeneration"); else if (UI.chatDraft && UI.chatDraft.trim()) doSend(); });
  document.querySelectorAll("[data-think]").forEach((el) => {
    el.addEventListener("click", () => {
      const id = el.dataset.think;
      UI.thinkOpen[id] = !UI.thinkOpen[id];
      el.classList.toggle("open", UI.thinkOpen[id]);
      const tb = el.querySelector(".tb");
      tb.style.webkitLineClamp = UI.thinkOpen[id] ? "none" : "";
    });
  });
  document.querySelectorAll("[data-copy]").forEach((el) => {
    el.addEventListener("click", () => {
      const m = (S.messages || []).find((x) => x.id === el.dataset.copy);
      if (m) cmd("copyText", { text: m.content, label: "已复制消息" });
    });
  });
  document.querySelectorAll("[data-say]").forEach((el) => {
    el.addEventListener("click", () => { UI.chatDraft = el.dataset.say; doSend(); });
  });
  // livestrip 实时值：速率用消息自带统计，耗时用本地锚点计时
  // （此前这两个 chip 永远显示 "— tok/s / 0.0s"，从未被更新）。
  if (S.generating) {
    const cur = (S.messages || []).filter((m) => m.streaming && m.role !== "user").pop();
    if (cur) {
      if (!UI.streamStart[cur.id]) UI.streamStart[cur.id] = Date.now();
      const rate = document.getElementById("liveRate");
      const elapsed = document.getElementById("liveElapsed");
      if (rate) rate.textContent = cur.rate ? cur.rate.toFixed(1) + " tok/s"
        : (cur.tokens ? cur.tokens + " tokens" : "— tok/s");
      if (elapsed) elapsed.textContent = ((Date.now() - UI.streamStart[cur.id]) / 1000).toFixed(1) + "s";
    }
  } else if (Object.keys(UI.streamStart).length) {
    UI.streamStart = {};
  }
  // 跟随底部：切页强制吸底，流式期间仅当用户本就接近底部时跟随
  if (msgs) stickScroll(msgs, pageChanged);
  if (input && UI.chatDraft) { input.style.height = "auto"; input.style.height = Math.min(input.scrollHeight, 160) + "px"; }
}

function doSend() {
  const text = (UI.chatDraft || "").trim();
  if (!text) return;
  UI.chatDraft = "";
  cmd("sendChat", { text });
  render();
}

function modelSwitcherMenu() {
  const models = (S.modelsMenu || []);
  popover("modelSwitcher", models.map((m) => ({
    label: esc(shortModel(m.id)), act: "useModel", arg: `${S.engine.id}|${m.id}`, on: m.id === S.selectedModel,
  })).concat([{ label: "在模型页浏览全部…", act: "nav", arg: "models" }]));
}

function chatMoreMenu() {
  const threads = (S.threads || []).map((t) => ({ label: esc(t.title) + " · " + relTime(t.updatedAt), act: "openThread", arg: t.id }));
  popover("chatMore", threads.concat("-", [
    { label: "对话参数…", act: "chatParams" },
    { label: "复制整段对话", act: "copyConversation" },
    { label: "清空当前对话…", act: "clearChat" },
    "-", { label: "清空最近对话…", act: "clearThreads" },
  ]));
}

// ---------- 对话参数弹层 ----------
function chatParamsDraft() {
  if (!UI.chatParamsDraft) {
    const s = S.settings || {};
    UI.chatParamsDraft = {
      temperature: s.temperature != null ? s.temperature : 0.7,
      topP: s.topP != null ? s.topP : 0.95,
      maxTokens: s.maxTokens || 4096,
      systemPrompt: s.systemPrompt || "",
    };
  }
  return UI.chatParamsDraft;
}

function chatParamsBody() {
  const d = chatParamsDraft();
  return `
    <div class="modal-body">
      <div class="set-row"><div class="lab"><b>温度</b><small>越高越有创造性，越低越确定</small></div>
        <div class="ctl"><input type="range" min="0" max="2" step="0.05" value="${d.temperature}" data-cprange="temperature" style="width:150px">
        <span class="field" style="min-width:52px" id="cpv-temperature">${Number(d.temperature).toFixed(2)}</span></div></div>
      <div class="set-row"><div class="lab"><b>Top P</b><small>核采样概率质量上限</small></div>
        <div class="ctl"><input type="range" min="0" max="1" step="0.05" value="${d.topP}" data-cprange="topP" style="width:150px">
        <span class="field" style="min-width:52px" id="cpv-topP">${Number(d.topP).toFixed(2)}</span></div></div>
      <div class="set-row"><div class="lab"><b>最大生成 tokens</b><small>单次回复的长度上限</small></div>
        <div class="ctl"><input class="field" data-key="cpMaxTokens" data-cpnum="maxTokens" value="${esc(d.maxTokens)}"></div></div>
      <div class="set-row" style="align-items:flex-start"><div class="lab"><b>系统提示词</b><small>对每次请求生效，留空则不发送</small></div>
        <div class="ctl"><textarea class="cp-sys" data-key="cpSystem" data-cptext="systemPrompt" rows="4" placeholder="例如：你是一个简洁的本地助手。">${esc(d.systemPrompt)}</textarea></div></div>
    </div>
    <div class="modal-foot">
      <button class="btn-quiet" data-act="closeChatParams">取消</button>
      <button class="btn-main" data-act="saveChatParams">应用</button>
    </div>`;
}

function saveChatParams() {
  const d = UI.chatParamsDraft;
  if (!d) { UI.chatParamsOpen = false; render(); return; }
  const maxTokens = parseInt(d.maxTokens, 10);
  cmd("saveSettings", {
    temperature: Math.min(Math.max(Number(d.temperature) || 0, 0), 2),
    topP: Math.min(Math.max(Number(d.topP) || 0, 0), 1),
    maxTokens: maxTokens >= 16 ? maxTokens : 4096,
    systemPrompt: d.systemPrompt || "",
  });
  UI.chatParamsOpen = false;
  UI.chatParamsDraft = null;
  render();
}

// ---------- 模型 ----------
function filteredModelEntries() {
  const lib = S.library || { engine: "splash", entries: [] };
  const q = UI.modelsSearch.trim().toLowerCase();
  return lib.entries.filter((e) => {
    const passF = UI.modelsFilter === "all" || (UI.modelsFilter === "local" ? e.installed : !e.installed);
    const passQ = !q || e.id.toLowerCase().includes(q) || (e.display || "").toLowerCase().includes(q);
    return passF && passQ;
  });
}

// 网格独立成块：搜索输入时只重绘这块，不碰搜索框本身（否则每敲一个字焦点就丢）。
function modelsGridHTML() {
  const entries = filteredModelEntries();
  return entries.length ? `<div class="model-grid">${entries.map(modelCard).join("")}</div>`
    : `<div class="panel"><div class="empty" style="padding:36px"><div class="t">没有符合条件的模型</div><div>从「可下载」里挑一个，或点上方重新扫描 / 导入本地目录</div></div></div>`;
}

function pageModels() {
  const lib = S.library || { engine: "splash", entries: [] };
  const chips = [["splash", "Splash"], ["omlx", "oMLX"], ["mtplx", "MTPLX"]];
  const dn = S.downloads && S.downloads.active;
  const importText = dn
    ? `<span style="color:var(--w-accent);font-weight:600">下载中 ${Math.round((dn.fraction || 0) * 100)}%</span>`
    : `拖入模型目录，或点击选择本地权重（oMLX 支持 GGUF 与 safetensors，只建软链不搬家）`;
  return `
    <div class="crumb">控制台 / 模型</div>
    <h2 class="pg">模型</h2>
    <div class="sub">chip 只决定看哪个引擎的库，不改变运行状态；未安装的引擎也能浏览</div>
    <div class="chipbar">
      ${chips.map(([id, name]) => `<span class="echip ${lib.engine === id ? "on" : ""}" data-act="browseEngine" data-arg="${id}">${name}</span>`).join(" ")}
      <span class="search"><input data-key="modelsSearch" placeholder="⌕ 搜索模型…" value="${esc(UI.modelsSearch)}"></span>
      ${[["all", "全部"], ["local", "本机"], ["remote", "可下载"]].map(([v, n]) =>
        `<span class="filter ${UI.modelsFilter === v ? "on" : ""}" data-f="${v}">${n}</span>`).join("")}
      <span class="filter" style="margin-left:auto" data-act="rescan" data-arg="${esc(lib.engine)}">↻ 重新扫描</span>
      <span class="filter" data-act="openDownloadCenter">下载中心${S.downloads && S.downloads.tasks.length ? " · " + S.downloads.tasks.length : ""}</span>
    </div>
    <div class="import-bar" data-act="importModels" data-arg="${esc(lib.engine)}"><span class="plus">＋</span>${importText}</div>
    <div id="modelsGrid">${modelsGridHTML()}</div>`;
}

function modelCard(e) {
  const inUse = e.installed && e.engine === S.engine.id && e.id === S.selectedModel;
  const tags = [];
  if (inUse) tags.push(`<span class="mtag ok">使用中</span>`);
  if (e.bytes) tags.push(`<span class="mtag">${fmtBytes(e.bytes)}</span>`);
  if (e.draftTag) tags.push(`<span class="mtag">DFlash2 加速</span>`);
  (e.tags || []).forEach((t) => tags.push(`<span class="mtag">${esc(t)}</span>`));
  if (e.minMemory) tags.push(`<span class="mtag">内存下限 ${e.minMemory} GB</span>`);
  const actions = e.installed
    ? (e.isDraft ? "" : `<button class="btn-p" data-act="useModel" data-arg="${esc(e.engine)}|${esc(e.id)}">使用</button>`)
    : `<button class="btn-p dl" data-act="downloadModel" data-arg="${esc(e.engine)}|${esc(e.id)}">下载</button>`;
  return `<div class="model-card ${inUse ? "inuse" : ""}">
    <div class="nm" title="${esc(e.id)}">${esc(e.display || e.id)}</div>
    <div class="mtags">${tags.join("")}</div>
    <div class="ft"><span class="sz">${esc(e.originText)}${e.repo ? " · " + esc(e.repo) : ""}</span>
      ${actions}<button class="btn-p ghost" data-act="modelMenu" data-arg="${esc(e.engine)}|${esc(e.id)}">⋯</button></div>
  </div>`;
}

function modelMenu(arg) {
  const [engine, id] = arg.split("|");
  const entry = (S.library.entries || []).find((x) => x.engine === engine && x.id === id);
  const items = [];
  if (entry && entry.installed) {
    items.push({ label: "在 Finder 中显示", act: "revealModel", arg });
    items.push({ label: "删除模型…", act: "removeModel", arg });
  } else {
    items.push({ label: "下载", act: "downloadModel", arg });
  }
  popover("modelMenuBtn", items);
}

// ---------- 引擎 ----------
const ENGINE_META = {
  splash: { name: "Splash", sub: "单模型 · DFlash2 草稿加速 · 重启切模型", grad: "linear-gradient(135deg,#FF9F0A,#FF375F)" },
  omlx: { name: "oMLX", sub: "多模型常驻 · 热加载 / 热卸载 · 不停进程热切换", grad: "linear-gradient(135deg,#2AA8A0,#1F5FBF)" },
  mtplx: { name: "MTPLX", sub: "MTP 路径 · 长上下文 · 重启切模型", grad: "linear-gradient(135deg,#5E5CE6,#7B2CBF)" },
};
const ENGINE_CAPS = {
  splash: ["DFlash2 投机解码", "视觉多模态"],
  omlx: ["多模型热切换", "热加载"],
  mtplx: ["MTP 投机解码", "长上下文"],
};
const ENGINE_BLURB = {
  splash: "Apple Silicon 上的自管运行时，专注单模型：DFlash2 投机解码、KV 缓存与视觉多模态都在同一个包里。",
  omlx: "多模型热切换：常驻多个模型，按请求路由，MTP / DFlash2 按模型开关。",
  mtplx: "以 MTP 投机解码为主的引擎，量化与草稿参数通过命令行开关控制。",
};

function pageEngines() {
  const cards = ["splash", "omlx", "mtplx"].map((id) => {
    const meta = ENGINE_META[id];
    const info = (S.enginesInstall && S.enginesInstall[id]) || {};
    const versions = info.versions || [];
    const installed = versions.length > 0;
    const isActive = S.engine.id === id;
    const isRun = isActive && running();
    const busy = info.progress != null;
    const dot = isRun ? "ok" : (info.phase === "failed" ? "err" : "");
    const stTag = isRun ? `<span class="mtag ok">运行中</span>`
      : (info.phase === "failed" ? `<span class="mtag" style="color:var(--w-err)">失败</span>`
      : (installed ? `<span class="mtag">已停止</span>` : `<span class="mtag" style="color:var(--w-info)">未安装</span>`));
    const kv = [`<span>端口 <b>:${info.port}</b></span>`];
    if (installed) kv.push(`<span>已装 <b>${esc(versions[versions.length - 1])}</b></span>`);
    else kv.push(`<span>运行时 <b>未安装</b></span>`);
    const up = info.upstream;
    if (up && up.status === "update") kv.push(`<span>上游 <b>${esc(up.version)}</b> <span class="upd">可更新${up.prerelease ? " · 预发布" : ""}</span></span>`);
    else if (up && up.status === "current") kv.push(`<span>上游 <b>${esc(up.version)}</b> 一致</span>`);
    else if (up && up.status === "unavailable") kv.push(`<span>上游 <b>未知</b></span>`);
    if (info.params) kv.push(`<span>参数 <b>${esc(info.params)}</b></span>`);

    let ft = "";
    if (busy) {
      ft = `<div class="ft"><span class="btn-p ghost" style="pointer-events:none">安装 ${Math.round((info.progress || 0) * 100)}%</span><span style="font-size:11px;color:var(--w-ink-3)">${esc(info.step || "")}</span></div>`;
    } else {
      const btns = [];
      if (up && up.status === "update") btns.push(`<button class="btn-p ghost" data-act="installEngine" data-arg="${id}">${installed ? "更新到 " + esc(up.version) : "安装 " + esc(up.version)}</button>`);
      if (!installed) btns.push(`<button class="btn-p dl" data-act="installEngine" data-arg="${id}">安装运行时</button>`);
      btns.push(`<button class="btn-p ghost" data-act="nav" data-arg="logs">查看日志</button>`);
      btns.push(`<button class="btn-p ghost" data-act="engineConfig" data-arg="${id}" ${installed ? "" : "disabled"}>配置…</button>`);
      btns.push(`<button class="btn-p ghost right" data-menu="engineMenu" data-arg="${id}">⋯</button>`);
      ft = `<div class="ft">${btns.join("")}</div>`;
    }
    return `<div class="eng-card">
      <div class="hd">
        <span class="eng-ico" style="background:${meta.grad}">${meta.name[0]}</span>
        <div class="nm">${meta.name}<small>${meta.sub}</small></div>
        <div class="right"><span class="dot ${dot}"></span>${stTag}</div>
      </div>
      <div class="kvrow">${kv.join("")}</div>
      ${ft}
    </div>`;
  }).join("");
  return `
    <div class="crumb">控制台 / 引擎</div>
    <h2 class="pg">引擎</h2>
    <div class="sub">安装与维护 —— 启停唯一入口仍在侧栏引擎卡，这里只做配置、更新与卸载</div>
    <div class="eng-list">${cards}</div>`;
}

function engineMenu(id) {
  popover("engineMenuBtn", [
    { label: "配置…", act: "engineConfig", arg: id },
    { label: "在 Finder 中显示引擎目录", act: "openFinder", arg: "engines" },
    { label: "打开该引擎的模型目录", act: "openFinderEngine", arg: `engineModels|${id}` },
    { label: "打开该引擎的日志", act: "openFinderEngine", arg: `engineLogs|${id}` },
    "-", { label: "添加 / 安装新引擎…", act: "openLaunchPage" },
  ]);
}

// ---------- 引擎配置弹层 ----------
function cfgModel() {
  if (!UI.configDraft) {
    const info = (S.enginesInstall && S.enginesInstall[UI.configEngine]) || {};
    UI.configDraft = {
      tuning: JSON.parse(JSON.stringify(info.tuning || {})),
      port: String(info.port || ""),
    };
  }
  return UI.configDraft;
}
function tget(key, dflt) {
  const v = cfgModel().tuning[key];
  return v == null ? dflt : v;
}

function cfgToggle(label, small, key, dflt, disabled) {
  const on = tget(key, dflt);
  return `<div class="set-row"><div class="lab"><b>${label}</b><small>${small}</small></div>
    <div class="ctl"><span class="tgl ${on ? "" : "off"} ${disabled ? "disabled" : ""}" data-cfgtgl="${key}" data-d="${dflt ? 1 : 0}"></span></div></div>`;
}
function cfgField(label, small, key, placeholder, width, disabled) {
  const v = cfgModel().tuning[key];
  return `<div class="set-row"><div class="lab"><b>${label}</b><small>${small}</small></div>
    <div class="ctl"><input class="field" style="${width ? "width:" + width : ""}" ${disabled ? "disabled" : ""} data-cfg="${key}" placeholder="${esc(placeholder || "")}" value="${esc(v == null ? "" : v)}"></div></div>`;
}

function configBody() {
  const id = UI.configEngine;
  const info = (S.enginesInstall && S.enginesInstall[id]) || {};
  const versions = info.versions || [];
  const installed = versions.length > 0;
  const isActive = S.engine.id === id;
  const portDisabled = isActive && running();
  const T = () => cfgModel().tuning;
  let engineCards = "";

  if (id === "splash") {
    engineCards = `
      <div class="set-card">
        <div class="card-hd">DFlash2 <small>投机解码 draft 模型与资源上限</small></div>
        ${cfgToggle("启用 DFlash2", "用 draft 模型并行草稿，显著提升解码速度", "dflash", false)}
        ${cfgField("draft 目录", "留空则自动选择与主模型匹配的 draft", "draftModel", "自动", "240px", T().dflash === false)}
        ${cfgField("内存上限", "--max-memory，例如 24G；留空自动", "maxMemory", "自动", "96px")}
        ${cfgField("上下文长度", "--max-context，留空使用模型默认", "maxContext", "默认", "96px")}
        ${cfgToggle("仅语言模型", "跳过视觉与多模态部分，加载更快", "languageOnly", false)}
        ${cfgToggle("空闲时保留权重", "关闭空闲释放，响应更快但常驻内存", "idleReleaseOff", false)}
        ${cfgField("n-gram 表缓存", "--ple-memory，如 2G；off 整表载入；留空自动", "pleMemory", "自动", "96px")}
        ${cfgToggle("n-gram 表固定放 SSD", T().pleMemory ? "已被上面的缓存大小覆盖" : "开启 = --ple-memory auto，关闭 = off（整表载入内存）", "pleSSDOffload", true, !!T().pleMemory)}
      </div>`;
  } else if (id === "mtplx") {
    engineCards = `
      <div class="set-card">
        <div class="card-hd">MTP <small>多 token 预测</small></div>
        ${cfgToggle("启用 MTP", "--mtp / --no-mtp；关闭时不做投机解码", "mtp", true)}
        ${cfgToggle("启动即加载 MTP 权重", "--load-mtp，避免首个请求才付出加载开销", "loadMtp", false)}
        ${cfgField("量化位数", "--mtp-quant-bits，留空使用引擎默认", "mtpQuantBits", "默认", "72px")}
      </div>`;
  } else if (id === "omlx") {
    engineCards = `
      <div class="set-card">
        <div class="card-hd">MTP / DFlash2 <small>按模型生效，两者互斥</small></div>
        ${cfgToggle("启用 MTP", "开启后关闭 DFlash2（oMLX 不允许同时开）", "mtp", false)}
        ${cfgField("MTP 深度", "留空为自适应；固定值优先", "mtpDepth", "自适应", "72px", T().mtp !== true)}
        ${cfgToggle("启用 DFlash2", "开启后关闭 MTP", "dflash", false)}
        ${cfgToggle("PLE n-gram 表卸载到 SSD", "n-gram 表留在 SSD 走 mmap；显存装不下时 oMLX 会自动开启，代价约 2.5× 解码变慢", "pleSSDOffload", true)}
        <div class="set-note">这些开关由 oMLX 的设置接口保存，对每个模型独立生效；保存后会重新加载当前模型，未加载的模型在下一次加载时应用。</div>
      </div>`;
  }

  return `
    <div class="modal-body">
      <div class="set-card">
        <div class="card-hd">基础 <small>端口与模型目录${installed ? " · 已装 v" + esc(versions[versions.length - 1]) : " · 未安装"}</small></div>
        <div class="set-row"><div class="lab"><b>端口</b><small>默认 ${info.port || "—"}，可顺延</small></div>
          <div class="ctl"><input class="field" style="width:96px" ${portDisabled ? "disabled" : ""} data-cfgport value="${esc(cfgModel().port)}"></div></div>
        <div class="set-row"><div class="lab"><b>模型目录</b><small>${esc(info.modelsDir || "")}</small></div>
          <div class="ctl"><button class="btn-quiet" data-finder="engineModels|${id}">打开</button></div></div>
        <div class="set-row"><div class="lab"><b>引擎日志</b><small>启动命令行与引擎输出</small></div>
          <div class="ctl"><button class="btn-quiet" data-finder="engineLogs|${id}">查看</button></div></div>
      </div>
      ${engineCards}
      <div class="set-card">
        <div class="card-hd">高级 <small>原样追加的启动参数</small></div>
        ${cfgField("额外参数", "仅对该引擎生效，按空格切分并支持引号分组", "extraArguments", "例如 --no-webui --queue-size 8", "100%")}
        <div class="set-note">${id === "omlx" ? "" : "启动参数在下次启动时生效；保存后如需立即应用，请在引擎页重启。"}</div>
      </div>
    </div>
    <div class="modal-foot">
      <button class="btn-quiet" data-act="closeConfig">取消</button>
      <button class="btn-main" data-act="saveEngineConfig">保存</button>
    </div>`;
}

function saveEngineConfig() {
  if (!UI.configEngine || !UI.configDraft) { UI.configEngine = null; UI.configDraft = null; render(); return; }
  cmd("saveEngineConfig", {
    engine: UI.configEngine,
    tuning: UI.configDraft.tuning,
    port: UI.configDraft.port,
  });
  UI.configEngine = null;
  UI.configDraft = null;
  render();
}

// ---------- 日志 ----------
// console 区块独立成块：搜索输入时只重绘这块，不碰搜索框本身。
function logsConsoleHTML() {
  const source = UI.logPaused && UI.logSnapshot ? UI.logSnapshot : (S.logs || []);
  const needle = UI.logSearch.trim().toLowerCase();
  const visible = source.filter((l) => {
    const passF = UI.logFilter === "all" || l.level === UI.logFilter;
    const passQ = !needle || l.text.toLowerCase().includes(needle);
    return passF && passQ;
  });
  const lines = visible.map((l) => `<div class="log-line ${l.level === "error" ? "err" : ""}"><span class="ts">${esc(l.time)}</span><span class="lv ${l.level[0]}">${l.level.toUpperCase()}</span>${hl(esc(l.text), needle)}</div>`).join("");
  const follow = UI.logPaused
    ? `<div class="follow">‖ 已暂停 · 显示快照</div>`
    : `<div class="follow" id="followLine">█ 实时跟随中 · ${new Date().toTimeString().slice(0, 8)}</div>`;
  return (lines || '<div class="follow">暂无日志输出</div>') + follow;
}

function pageLogs() {
  const source = UI.logPaused && UI.logSnapshot ? UI.logSnapshot : (S.logs || []);
  const needle = UI.logSearch.trim().toLowerCase();
  const visibleCount = source.filter((l) => {
    const passF = UI.logFilter === "all" || l.level === UI.logFilter;
    const passQ = !needle || l.text.toLowerCase().includes(needle);
    return passF && passQ;
  }).length;
  const counts = { all: source.length, info: 0, warning: 0, error: 0 };
  source.forEach((l) => { if (counts[l.level] != null) counts[l.level]++; });
  return `
    <div class="crumb">控制台 / 日志</div>
    <h2 class="pg">日志</h2>
    <div class="sub">当前引擎（${esc(ENGINE_META[S.engine.id] ? ENGINE_META[S.engine.id].name : S.engine.id)}）的实时 stderr 输出${needle || UI.logFilter !== "all" ? ` · 命中 ${visibleCount} / ${source.length} 行` : ""}</div>
    <div class="chipbar">
      ${[["all", "全部"], ["info", "提示"], ["warning", "警告"], ["error", "错误"]].map(([v, n]) =>
        `<span class="filter ${UI.logFilter === v ? "on" : ""}" data-lf="${v}">${n}${v !== "all" ? " " + counts[v] : ""}</span>`).join("")}
      <span class="search"><input data-key="logSearch" placeholder="⌕ 搜索关键词…" value="${esc(UI.logSearch)}"></span>
      <span class="filter ${UI.logPaused ? "on" : ""}" style="margin-left:auto" id="pauseBtn">⏸ ${UI.logPaused ? "继续" : "暂停滚动"}</span>
      <span class="icon-btn" id="logMenuBtn" data-menu="logMenu">⋯</span>
    </div>
    <div class="log-console" id="logConsole">${logsConsoleHTML()}</div>`;
}

function hl(text, needle) {
  if (!needle) return text;
  const lower = text.toLowerCase(), n = needle.toLowerCase();
  let out = "", cursor = 0;
  let hit = lower.indexOf(n, cursor);
  while (hit !== -1) {
    out += text.slice(cursor, hit) + `<mark style="background:color-mix(in srgb, var(--w-warn) 32%,transparent);color:var(--w-ink);border-radius:3px">${text.slice(hit, hit + needle.length)}</mark>`;
    cursor = hit + needle.length;
    hit = lower.indexOf(n, cursor);
  }
  return out + text.slice(cursor);
}

function afterLogsRender() {
  const consoleEl = document.getElementById("logConsole");
  if (consoleEl) stickScroll(consoleEl, false);
  bindPageExtras();
}

function bindPageExtras() {
  bindActs(document.getElementById("main"));
  const pause = document.getElementById("pauseBtn");
  if (pause) pause.addEventListener("click", () => {
    if (!UI.logPaused) { UI.logPaused = true; UI.logSnapshot = (S.logs || []).slice(); }
    else { UI.logPaused = false; UI.logSnapshot = null; }
    render();
  });
  const search = document.querySelector('[data-key="logSearch"]');
  if (search) search.addEventListener("input", () => { UI.logSearch = search.value; renderLogConsoleOnly(); });
  const msearch = document.querySelector('[data-key="modelsSearch"]');
  if (msearch) msearch.addEventListener("input", () => { UI.modelsSearch = msearch.value; renderModelsGridOnly(); });
  document.querySelectorAll("[data-lf]").forEach((el) => el.addEventListener("click", () => { UI.logFilter = el.dataset.lf; render(); }));
  document.querySelectorAll("[data-f]").forEach((el) => el.addEventListener("click", () => { UI.modelsFilter = el.dataset.f; render(); }));
  // 输入框失焦时补做挂起的重绘（快照推送在输入期间被挂起）。
  document.querySelectorAll(".search input, .field").forEach((el) =>
    el.addEventListener("blur", flushPendingRender));
}

// 搜索过滤只更新对应区块（不滚屏、不动输入框），整页重绘留给换页/快照变化。
function renderLogConsoleOnly() {
  const consoleEl = document.getElementById("logConsole");
  if (!consoleEl) { render(); return; }
  consoleEl.innerHTML = logsConsoleHTML();
}
function renderModelsGridOnly() {
  const grid = document.getElementById("modelsGrid");
  if (!grid) { render(); return; }
  grid.innerHTML = modelsGridHTML();
  bindActs(grid);
}

function logMenu() {
  popover("logMenuBtn", [
    { label: "复制当前筛选结果", act: "copyLog" },
    { label: "打开日志文件", act: "openFinder", arg: "logs" },
    "-", { label: "清空日志…", act: "clearLogs" },
  ]);
}

function copyVisibleLogText() {
  const source = UI.logPaused && UI.logSnapshot ? UI.logSnapshot : (S.logs || []);
  const needle = UI.logSearch.trim().toLowerCase();
  const text = source
    .filter((l) => (UI.logFilter === "all" || l.level === UI.logFilter)
      && (!needle || l.text.toLowerCase().includes(needle)))
    .map((l) => `${l.time} ${l.level.toUpperCase()} ${l.text}`)
    .join("\n");
  if (text) cmd("copyLogText", { text });
}

// ---------- 设置 ----------
function settingsModel() {
  if (!UI.settingsDraft) {
    const s = S.settings;
    UI.settingsDraft = JSON.parse(JSON.stringify(s));
    // 端口在草稿里用字符串承载（输入框语义），比较时归一化。
    for (const k of Object.keys(UI.settingsDraft.ports || {})) {
      UI.settingsDraft.ports[k] = String(UI.settingsDraft.ports[k]);
    }
  }
  return UI.settingsDraft;
}

function settingsStored() {
  const s = JSON.parse(JSON.stringify(S.settings));
  for (const k of Object.keys(s.ports || {})) s.ports[k] = String(s.ports[k]);
  return s;
}

function savebarState(d) {
  const engines = ["splash", "omlx", "mtplx"];
  const dirty = JSON.stringify(d) !== JSON.stringify(settingsStored());
  const activePortChanged = d.ports[S.engine.id] !== S.settings.ports[S.engine.id];
  const otherChanged = ["thinking", "effort", "model", "autoStart", "launchAtLogin", "hfCache"].some((k) => JSON.stringify(d[k]) !== JSON.stringify(S.settings[k]));
  const restartHint = dirty && (activePortChanged || otherChanged) && running();
  const portInvalid = engines.some((e) => { const v = parseInt(d.ports[e], 10); return !v || v < 1024 || v > 65535; });
  const headline = !dirty ? "所有改动已保存"
    : restartHint ? `改动将重启 ${ENGINE_META[S.engine.id].name} 以生效`
    : "有未保存的更改";
  return { dirty, restartHint, portInvalid, headline };
}

function savebarHTML(d) {
  const st = savebarState(d);
  return `<div class="savebar ${st.dirty ? "" : "quiet"}" id="savebar">${esc(st.headline)}
    ${st.dirty ? `<button class="btn-quiet" id="discardBtn">放弃更改</button><button class="btn-main" id="saveBtn" ${st.portInvalid ? "disabled" : ""}>${st.restartHint ? "保存并重启" : "保存"}</button>` : ""}
  </div>`;
}

function pageSettings() {
  const d = settingsModel();

  const row = (label, small, ctl) => `<div class="set-row"><div class="lab"><b>${label}</b><small>${small}</small></div><div class="ctl">${ctl}</div></div>`;
  const seg = (opts, current, act) => `<div class="seg">${opts.map(([v, n]) => `<span class="${current === v ? "on" : ""}" data-setseg="${act}" data-arg="${v}">${n}</span>`).join("")}</div>`;
  const tgl = (on, act) => `<span class="tgl ${on ? "" : "off"}" data-settgl="${act}"></span>`;
  const field = (key, value, wide, invalid) => `<input class="field ${wide ? "wide" : ""} ${invalid ? "invalid" : ""}" data-key="set_${key}" data-setfield="${key}" value="${esc(value)}" spellcheck="false">`;

  return `
    <div class="crumb">控制台 / 设置</div>
    <h2 class="pg">设置</h2>
    <div class="sub">外观类改动立即生效；影响引擎的改动在保存后自动重启对应服务</div>
    <div class="set-card">
      ${row("外观", "跟随系统 / 浅色 / 深色，选中立即生效，无需保存",
        seg([["system", "跟随系统"], ["light", "浅色"], ["dark", "深色"]], S.appearance, "appearance"))}
      ${row("随 flashCat 启动引擎", "打开应用时自动把默认引擎拉起来", tgl(d.autoStart, "autoStart"))}
      ${row("登录时启动", "把 flashCat 加入 macOS 登录项", tgl(d.launchAtLogin, "launchAtLogin"))}
    </div>
    <div class="set-card">
      ${row("API 网关", "OpenAI + Claude 双格式 · 统一入口 · 端口改完按回车生效",
        tgl(S.settings.gatewayEnabled, "gateway") + field("gatewayPort", S.settings.gatewayPort, false))}
      ${row("Splash / oMLX / MTPLX 端口", "各引擎固定段起始端口，互相不抢",
        engines3().map((e) => field("port_" + e, d.ports[e], false, (() => { const v = parseInt(d.ports[e], 10); return v && !(v >= 1024 && v <= 65535); })())).join(""))}
    </div>
    <div class="set-card">
      ${row("思考模式", "推理模型是否先输出思考过程",
        seg([["automatic", "自动"], ["off", "关闭"], ["on", "开启"]], d.thinking, "thinking"))}
      ${d.thinking === "on" ? row("推理等级", "仅在思考模式为「开启」时生效",
        seg([["minimal", "最小"], ["low", "低"], ["medium", "中"], ["high", "高"], ["xhigh", "超高"], ["max", "最大"]], d.effort, "effort")) : ""}
      ${row("默认模型", "引擎启动时自动加载，也可手填自定义 ID",
        field("model", d.model, true))}
      ${row("下载缓存目录", "默认沿用 HF_HUB_CACHE", field("hfCache", d.hfCache, true))}
    </div>
    ${savebarHTML(d)}`;
}

function engines3() { return ["splash", "omlx", "mtplx"]; }

function refreshSettingsChrome() {
  const d = UI.settingsDraft;
  if (!d || S.page !== "settings") return;
  const bar = document.getElementById("savebar");
  if (bar) {
    bar.outerHTML = savebarHTML(d);
    bindSavebarButtons();
  }
  document.querySelectorAll('[data-setfield^="port_"]').forEach((el) => {
    const v = parseInt(el.value, 10);
    el.classList.toggle("invalid", !(v >= 1024 && v <= 65535));
  });
}

function bindSavebarButtons() {
  const discard = document.getElementById("discardBtn");
  if (discard) discard.addEventListener("click", () => { UI.settingsDraft = null; render(); });
  const save = document.getElementById("saveBtn");
  if (save) save.addEventListener("click", () => {
    const d = UI.settingsDraft;
    if (!d) return;
    cmd("saveSettings", {
      ports: d.ports, thinking: d.thinking, effort: d.effort,
      model: (d.model || "").trim(), autoStart: !!d.autoStart,
      launchAtLogin: !!d.launchAtLogin, hfCache: (d.hfCache || "").trim(),
    });
    UI.settingsDraft = null;
  });
}

function afterSettingsRender() {
  document.querySelectorAll("[data-setseg]").forEach((el) => el.addEventListener("click", () => {
    const act = el.dataset.setseg, arg = el.dataset.arg;
    if (act === "appearance") { cmd("appearance", { mode: arg }); return; }
    const d = settingsModel();
    d[act] = arg;
    render();
  }));
  document.querySelectorAll("[data-settgl]").forEach((el) => el.addEventListener("click", () => {
    const key = el.dataset.settgl;
    if (key === "gateway") { cmd("setGatewayEnabled", { on: S.settings.gatewayEnabled ? false : true }); return; }
    const d = settingsModel();
    d[key] = !d[key];
    render();
  }));
  document.querySelectorAll("[data-setfield]").forEach((el) => {
    el.addEventListener("click", (e) => e.stopPropagation());
    el.addEventListener("input", () => {
      const key = el.dataset.setfield;
      const d = settingsModel();
      if (key.startsWith("port_")) d.ports[key.slice(5)] = el.value.replace(/[^0-9]/g, "").slice(0, 5);
      else if (key === "gatewayPort") { /* 网关端口即时生效，回车提交 */ }
      else d[key] = el.value;
      refreshSettingsChrome();
    });
    el.addEventListener("blur", flushPendingRender);
  });
  document.querySelectorAll('[data-setfield="gatewayPort"]').forEach((el) => el.addEventListener("keydown", (e) => {
    if (e.key === "Enter") { const v = parseInt(el.value, 10); if (v >= 1024 && v <= 65535) { cmd("setGatewayPort", { port: v }); toast("网关已切换到端口 " + v); } }
  }));
  bindSavebarButtons();
}

// ---------- 启动页 ----------
function pageLaunch() {
  const idx = S.packIndex || {};
  const rows = ["splash", "omlx", "mtplx"].map((id) => {
    const meta = ENGINE_META[id];
    const info = (S.enginesInstall && S.enginesInstall[id]) || {};
    const versions = info.versions || [];
    const newestInstalled = versions.length ? versions[versions.length - 1] : null;
    const rel = info.latestRelease;
    const busy = info.progress != null;
    const failed = info.phase === "failed";
    let latestVersion = rel ? rel.version : (newestInstalled || null);
    const latestInstalled = latestVersion ? versions.includes(latestVersion) : false;

    let action = "";
    if (busy) {
      action = "";
    } else if (latestVersion && !latestInstalled) {
      action = `<button class="btn-p dl" data-act="installEngineLaunch" data-arg="${id}">安装</button>`;
    } else if (latestVersion && latestInstalled) {
      action = `<button class="btn-p ghost" disabled>已安装</button>`;
    } else {
      action = `<span class="mtag" style="color:var(--w-info)">暂无可用版本</span>`;
    }

    const progressLine = busy
      ? `<div class="launch-progress">${ringSVG(info.progress || 0, 30)}<span>${esc(info.step || "准备安装")}</span></div>`
      : (failed ? `<div class="launch-progress" style="color:var(--w-err)">上次安装失败，可重试</div>` : "");

    return `<div class="launch-card">
      <div class="lc-head">
        <span class="eng-ico" style="background:${meta.grad}">${meta.name[0]}</span>
        <div class="lc-name"><b>${meta.name}</b>
          <span class="mtags">${(ENGINE_CAPS[id] || []).map((t) => `<span class="mtag">${esc(t)}</span>`).join("")}
          ${newestInstalled ? (S.engine.id === id ? `<span class="mtag ok">当前引擎</span>` : `<span class="mtag">已安装 v${esc(newestInstalled)}</span>`) : ""}</span></div>
        <div class="lc-side">
          ${latestVersion ? `<span class="lc-ver ${latestInstalled ? "dim" : ""}">最新 v${esc(latestVersion)}${rel && rel.bytes ? " · " + fmtBytes(rel.bytes) : ""}</span>` : ""}
          ${action}
        </div>
      </div>
      <div class="lc-blurb">${esc(ENGINE_BLURB[id] || "")}</div>
      ${progressLine}
    </div>`;
  }).join("");

  const installedSummary = ["splash", "omlx", "mtplx"]
    .map((id) => ({ id, versions: (S.enginesInstall && S.enginesInstall[id] && S.enginesInstall[id].versions) || [] }))
    .filter((x) => x.versions.length)
    .map((x) => `${ENGINE_META[x.id].name} v${x.versions[x.versions.length - 1]}`)
    .join(" · ");

  return `
    <div class="launch-wrap">
      <div class="brand" style="padding-left:0"><div class="logo"></div><div><div class="t">flashCat</div><div class="s">本地推理控制台</div></div></div>
      <h2 class="launch-title">选择你的推理引擎</h2>
      <p class="launch-sub">引擎不再随应用打包，也不再有隐含的默认项。选一个下载安装，它就是你的默认引擎；之后可以随时从引擎页回到这里添加或切换到别的引擎。</p>
      ${installedSummary ? `<p class="launch-found">检测到本机已安装：${esc(installedSummary)}</p>`
        : (idx.loaded ? `<p class="launch-found dim">尚未检测到已安装的引擎，选择下面任意一个下载安装即可。</p>` : "")}
      ${idx.error ? `<div class="confirm-strip" style="border-color:color-mix(in srgb, var(--w-warn) 40%,transparent)">无法读取发布索引：${esc(idx.error)}</div>` : ""}
      ${rows}
      <p class="launch-note">安装包来自发布索引（<span class="mono">FLASHCAT_PACK_INDEX_URL</span>，或应用内置的 pack-index.json）。已在本机构建好的安装包也会直接被识别：把它们放进 <span class="mono">~/Library/Application Support/flashCat/engines/&lt;引擎&gt;/&lt;版本&gt;</span> 即可。</p>
      <div class="launch-start">
        <button class="btn-p dl" data-act="finishLaunch" ${S.launchNeedsSetup ? "disabled" : ""}>开始使用</button>
      </div>
    </div>`;
}

// ---------- 弹层（确认 / 下载中心 / 引擎配置 / 对话参数） ----------
function renderOverlays() {
  const host = document.getElementById("overlays");
  if (!host) return;
  const parts = [];
  // 待确认（使用模型 / 切换模型）
  if (S.pending && !UI.configEngine && !UI.downloadsOpen) {
    const p = S.pending;
    if (p.kind === "use") {
      parts.push(modal(`
        <div class="modal-title">${p.needsDownload ? "下载并使用模型" : "切换模型"}</div>
        <div class="modal-text">${p.needsDownload
          ? `「${esc(shortModel(p.model))}」尚未下载（${esc(p.engine.toUpperCase())} 引擎），确认后将开始下载，完成后自动启用。`
          : `切换到 ${esc(p.engine.toUpperCase())} 引擎的「${esc(shortModel(p.model))}」？`}</div>
        <div class="modal-foot">
          <button class="btn-quiet" data-act="cancelUse">取消</button>
          <button class="btn-main" data-act="confirmUse">${p.needsDownload ? "下载并使用" : "确认使用"}</button>
        </div>`, "cancelUse"));
    } else if (p.kind === "switch") {
      parts.push(modal(`
        <div class="modal-title">切换模型</div>
        <div class="modal-text">切换到「${esc(shortModel(p.model))}」？正在运行的服务将重启以加载新模型。</div>
        <div class="modal-foot">
          <button class="btn-quiet" data-act="cancelSwitch">取消</button>
          <button class="btn-main" data-act="confirmSwitch">确认切换</button>
        </div>`, "cancelSwitch"));
    }
  }
  // 引擎未安装确认（模型由未安装引擎驱动）
  if (S.pendingInstall) {
    const name = ENGINE_META[S.pendingInstall] ? ENGINE_META[S.pendingInstall].name : S.pendingInstall;
    parts.push(modal(`
      <div class="modal-title">${esc(name)} 还没安装</div>
      <div class="modal-text">这个模型由 ${esc(name)} 引擎驱动，先安装 ${esc(name)} 才能切换到它。</div>
      <div class="modal-foot">
        <button class="btn-quiet" data-act="cancelInstall">取消</button>
        <button class="btn-main" data-act="confirmInstall">去安装</button>
      </div>`, "cancelInstall"));
  }
  // 对话参数
  if (UI.chatParamsOpen) {
    parts.push(modal(`
      <div class="modal-title">对话参数</div>
      ${chatParamsBody()}`, "closeChatParams"));
  }
  // 引擎配置
  if (UI.configEngine) {
    const name = ENGINE_META[UI.configEngine] ? ENGINE_META[UI.configEngine].name : UI.configEngine;
    parts.push(modal(`
      <div class="modal-title">${esc(name)} 配置</div>
      ${configBody()}`, "closeConfig", true));
  }
  // 下载中心
  if (UI.downloadsOpen) {
    parts.push(modal(`
      <div class="modal-title">下载中心 <small>同时只进行一个下载，其余任务可暂停后排队</small></div>
      ${downloadsBody()}`, "closeDownloads", true));
  }
  host.innerHTML = parts.join("");
  bindOverlays(host);
}

function modal(inner, cancelAct, wide) {
  return `<div class="mask" data-cancel="${esc(cancelAct || "")}"><div class="modal ${wide ? "wide" : ""}">${inner}</div></div>`;
}

function bindOverlays(host) {
  host.querySelectorAll(".mask").forEach((mask) => {
    mask.addEventListener("click", (e) => {
      if (e.target === mask && mask.dataset.cancel) handleAction(mask.dataset.cancel);
    });
  });
  host.querySelectorAll("[data-act]").forEach((el) => {
    el.addEventListener("click", (e) => { e.stopPropagation(); handleAction(el.dataset.act, el.dataset.arg); });
  });
  // 引擎配置草稿
  host.querySelectorAll("[data-cfgtgl]").forEach((el) => el.addEventListener("click", (e) => {
    e.stopPropagation();
    if (el.classList.contains("disabled")) return;
    const key = el.dataset.cfgtgl;
    const t = cfgModel().tuning;
    const value = !(t[key] != null ? t[key] : el.dataset.d === "1");
    t[key] = value;
    // oMLX 的 MTP 与 DFlash 互斥：开一个关另一个。
    if (UI.configEngine === "omlx") {
      if (key === "mtp" && value) t.dflash = false;
      if (key === "dflash" && value) t.mtp = false;
    }
    renderOverlays();
  }));
  host.querySelectorAll("[data-cfg]").forEach((el) => el.addEventListener("input", () => {
    const key = el.dataset.cfg;
    const v = el.value.trim();
    cfgModel().tuning[key] = v === "" ? null : v;
  }));
  host.querySelectorAll("[data-cfgport]").forEach((el) => el.addEventListener("input", () => {
    el.value = el.value.replace(/[^0-9]/g, "").slice(0, 5);
    cfgModel().port = el.value;
  }));
  host.querySelectorAll("[data-finder]").forEach((el) => el.addEventListener("click", (e) => {
    e.stopPropagation();
    const [kind, eng] = el.dataset.finder.split("|");
    cmd("openFinder", { kind, engine: eng });
  }));
  // 对话参数控件
  host.querySelectorAll("[data-cprange]").forEach((el) => el.addEventListener("input", () => {
    const d = chatParamsDraft();
    d[el.dataset.cprange] = Number(el.value);
    const out = document.getElementById("cpv-" + el.dataset.cprange);
    if (out) out.textContent = Number(el.value).toFixed(2);
  }));
  host.querySelectorAll("[data-cpnum]").forEach((el) => el.addEventListener("input", () => {
    chatParamsDraft()[el.dataset.cpnum] = el.value.replace(/[^0-9]/g, "");
  }));
  host.querySelectorAll("[data-cptext]").forEach((el) => el.addEventListener("input", () => {
    chatParamsDraft()[el.dataset.cptext] = el.value;
  }));
}

function downloadsBody() {
  const tasks = (S.downloads && S.downloads.tasks) || [];
  const active = S.downloads && S.downloads.active;
  if (!tasks.length) {
    return `<div class="empty" style="padding:44px 20px"><div class="t">没有下载任务</div><div>在模型卡片或「可下载」里点下载，进度会显示在这里</div></div>`;
  }
  const rows = tasks.map((t) => {
    const isRun = active && active.engine === t.engine && active.model === t.model;
    const fraction = isRun ? (active.fraction || 0) : (t.fraction || 0);
    const total = t.totalBytes || 0;
    const done = isRun ? Math.round(fraction * total) : (t.downloadedBytes || 0);
    let status = "";
    if (isRun) status = `<span class="mtag" style="color:var(--w-accent)">下载中</span>`;
    else if (t.status === "paused") status = `<span class="mtag" style="color:var(--w-warn)">已暂停</span>`;
    else if (t.status === "failed") status = `<span class="mtag" style="color:var(--w-err)">失败</span>`;
    else status = `<span class="mtag">排队</span>`;
    let detail;
    if (total > 0) detail = `${fmtBytes(done)} / ${fmtBytes(total)}${isRun ? " · " + (fmtRate(active.speed) || "等待下载器报告进度…") : ""}`;
    else detail = isRun ? "已启动，等待下载器报告进度…"
      : (t.status === "paused" ? "已暂停，继续后从断点接着下"
      : (t.status === "failed" ? "上次下载失败，可重试" : "等待当前下载结束"));
    let btns = "";
    if (isRun) {
      btns = `<button class="btn-p ghost" data-act="pauseDownload" data-arg="${esc(t.engine)}|${esc(t.model)}">暂停</button>
              <button class="btn-p ghost" data-act="cancelDownload" data-arg="${esc(t.engine)}|${esc(t.model)}">取消</button>`;
    } else if (t.status === "paused") {
      btns = `<button class="btn-p ghost" data-act="resumeDownload" data-arg="${esc(t.engine)}|${esc(t.model)}">继续</button>
              <button class="btn-p ghost" data-act="cancelDownload" data-arg="${esc(t.engine)}|${esc(t.model)}">移除</button>`;
    } else if (t.status === "failed") {
      btns = `<button class="btn-p ghost" data-act="resumeDownload" data-arg="${esc(t.engine)}|${esc(t.model)}">重试</button>
              <button class="btn-p ghost" data-act="removeTask" data-arg="${esc(t.engine)}|${esc(t.model)}">移除</button>`;
    }
    return `<div class="dl-row">
      <div class="dl-main">
        <div class="dl-name">${esc(shortModel(t.model))}<span class="mtag">${esc(t.engine.toUpperCase())}</span>${status}</div>
        ${total > 0 ? `<div class="dl-meter"><div class="dl-fill ${t.status === "failed" && !isRun ? "err" : ""}" style="width:${Math.round(fraction * 100)}%"></div></div>` : ""}
        <div class="dl-detail">${esc(detail)}</div>
      </div>
      <div class="dl-btns">${btns}</div>
    </div>`;
  }).join("");
  return `<div class="dl-list">${rows}</div>`;
}

// ---------- 顶层绑定 ----------
// 菜单触发统一走 data-menu（document 级监听处理）

// IME 组合输入期间挂起快照重绘（否则生成中打中文会被整页重绘打断），结束后补一次。
document.addEventListener("compositionstart", () => { UI.composing = true; });
document.addEventListener("compositionend", () => {
  UI.composing = false;
  flushPendingRender();
});

window.addEventListener("keydown", (e) => {
  if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "n") { e.preventDefault(); handleAction("newChat"); }
});
