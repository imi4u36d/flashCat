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
  logOpen: {},              // 日志行 id -> true（展开详情，跨重绘保持）
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
  navIntent: null,          // 本地刚切到的页 {page, at}：旧快照不许把它掀回去
  pointerDown: false,       // 指针按住期间不重建侧栏（重建会吞掉 click）
  sideDirty: false,         // 按住期间攒下的侧栏改动，抬手后补渲染
  chatScroll: null,         // 重绘前捕获的对话滚动位 {top, nearBottom}
  logScroll: null,          // 重绘前捕获的日志控制台滚动位 {top, h, nearTop}
};
let S = null; // 最近一次 Swift 快照
let lastPushJSON = null;   // 内容未变化的推送不再整页重绘
let lastSideHTML = null;   // 侧栏上次渲染的 HTML：内容没变就不重建 DOM

// ---------- 快照入口 ----------
window.__fc__ = {
  push(state) {
    const prev = S;
    // 快速连点时，Swift 侧还在路上的快照可能带着上一页的 page。本地刚切过的页
    // 不能被它掀回去（表现就是「点了没反应」），以本地意图为准，等对齐后清掉。
    const intent = UI.navIntent;
    if (intent) {
      if (state.page === intent.page) UI.navIntent = null;
      else if (Date.now() - intent.at < 1500) state.page = intent.page;
      else UI.navIntent = null;
    }
    S = state;
    // 换页才重置草稿；同页推送（心跳/去抖）不能把用户正在编辑的草稿吹掉。
    if (!prev || prev.page !== state.page) {
      UI.settingsDraft = null;
      UI.configDraft = null;
    } else if (state.page === "settings" && UI.settingsDraft && prev.settings &&
               comparableSettings(UI.settingsDraft) === comparableSettings(prev.settings)) {
      // 草稿还没被用户改过（仍与进入页面时的快照一致）就让它作废，
      // 下次按最新快照重建。否则保存竞态（保存推送在路上时心跳先渲染了一帧）
      // 或后台改写（安装完成改 defaultModel、端口被占改 ports）都会被
      // 旧草稿顶成凭空的「有未保存的更改」。
      UI.settingsDraft = null;
    }
    applyAppearance();
    applySidebar();
    if (prev && state.toast && state.toast !== prev.toast) toast(state.toast);
    // 侧栏折叠/展开动画进行中：快照照单全收（S 已更新、外观/侧栏已应用），
    // 但指纹与整页重绘推迟到动画收口——动画里每帧都在重排，此刻再同步串一遍
    // snapshotKey（对话页要 stringify 全部 messages）和 render，动画就被顶掉
    // 几帧。数据晚 0.26s 上屏看不出来；换页不在此列，点了导航就要立刻有反应。
    const pageChanged = !prev || prev.page !== state.page;
    if (!pageChanged && Date.now() < sideAnimUntil) {
      if (!sideAnimFlush) {
        sideAnimFlush = setTimeout(() => {
          sideAnimFlush = 0;
          // 动画期间的快照都没算过指纹：清掉，让收口这一次必重绘。
          lastPushJSON = null;
          if (interactionHold()) UI.pendingRender = true;
          else render();
        }, sideAnimUntil - Date.now() + 5);
      }
      return;
    }
    // 指纹只覆盖本页可见字段：折叠只改布局宽度，不该为它整页重绘（会丢对话滚动位）。
    const json = snapshotKey(state);
    // 菜单开着或正在输入设置项时不整页重绘，交互结束后补一次。
    if (interactionHold()) { UI.pendingRender = true; lastPushJSON = json; return; }
    // 快照与上次完全一致（心跳空转）时只补走本地时钟，不整页重绘。
    if (prev && prev.page === state.page && lastPushJSON === json) { tickLive(); return; }
    lastPushJSON = json;
    render();
  },
  // 侧栏折叠的轻量专线（⌘\ 菜单 / Swift 侧改动）：不推全量快照，立刻切档。
  // 点击手柄的路径不走这里——handleAction 已本地翻转过，这里只是校准兜底。
  setSidebar(visible) {
    if (S) S.sidebar = !!visible;
    applySidebar();
  },
};

// 快照指纹：只取「当前这一页真的会渲染」的字段，用于「内容没变就不重绘」的判断。
// 指纹不能再比整包快照：引擎运行时 stats 每秒变一次、日志尾巴每秒都在长，
// 于是任何页面（含设置页）都会被每秒一次的推送整页重绘——看上去就是
// 「没碰它，那个提示条却一直在闪」。sidebar 仍不进指纹：折叠只改布局宽度。
const SHELL_FIELDS = ["page", "appearance", "toast", "engine", "port",
                      "selectedModel", "threads", "pending", "pendingInstall"];
const PAGE_FIELDS = {
  overview: ["stats", "throughput", "acceptance", "draftLabel", "endpointURL",
             "gatewayURL", "gatewayClaudeURL", "modelsMenu", "context"],
  chat: ["messages", "generating", "generationStatus", "modelsMenu", "library", "settings"],
  models: ["library", "downloads", "modelsMenu"],
  engines: ["enginesInstall", "packIndex"],
  logs: ["logs"],
  settings: ["settings"],
};
const LAUNCH_FIELDS = ["launchPage", "launchNeedsSetup", "packIndex", "pending",
                       "pendingInstall", "enginesInstall", "downloads", "engine"];

function snapshotKey(state) {
  if (!state) return "";
  const keys = state.launchPage
    ? LAUNCH_FIELDS
    : SHELL_FIELDS.concat(PAGE_FIELDS[state.page] || []);
  const parts = keys.map((k) => (state[k] === undefined ? null : state[k]));
  // 侧栏徽标与「↓ N 个下载任务」只关心数量；下载中心开着时才需要完整进度。
  parts.push(((state.downloads && state.downloads.tasks) || []).length);
  parts.push(((state.library && state.library.entries) || []).filter((x) => x.installed).length);
  if (UI.downloadsOpen) parts.push(state.downloads);
  return JSON.stringify(parts);
}

// 侧边栏折叠：状态由 Swift 持有（菜单「折叠侧边栏 ⌘\」也在改它），
// 网页只负责把 body 切到 rail 一档，宽度过渡交给 CSS。
function applySidebar() {
  const rail = !!(S && S.sidebar === false);
  const next = rail ? "rail" : "full";
  // 真正切换那一档时开一个 300ms 的窗口（--side-t 是 .26s），期间的纯数据刷新延后重绘。
  // 同窗口给 body 挂 side-anim：.msg/.log-line 的 content-visibility 只在这一小段
  // 开（动画每帧重排的大头），平时必须关着——CV 下重绘恢复滚动位会被钳回 0。
  if (document.body.dataset.side !== next) {
    sideAnimUntil = Date.now() + 300;
    document.body.classList.add("side-anim");
    clearTimeout(sideAnimClassTimer);
    sideAnimClassTimer = setTimeout(() => document.body.classList.remove("side-anim"), 320);
  }
  document.body.dataset.side = next;
  // 手柄的文案跟着翻：本地先翻状态时快照还没回来，aria/title 不能停在旧值上。
  const btn = document.querySelector(".side-toggle");
  if (btn) {
    const label = rail ? "展开侧边栏" : "折叠侧边栏";
    btn.setAttribute("aria-expanded", rail ? "false" : "true");
    btn.setAttribute("aria-label", label);
    btn.title = label + "（⌘\\）";
  }
}

// 首帧之后跑一遍「假折叠」：rail 那一套样式、布局、合成层先在后台算过一遍，
// 真正点下去就不用现搭。不预热的话第一次折叠会卡 100ms 以上，之后才顺——
// 用户看到的就是「第一次点很顿，后面就好了」。整个过程在同一个任务里跑完，
// 中间不会落帧，所以看不出来。
let sideWarmed = false;
function warmSideTransition() {
  if (sideWarmed) return;
  sideWarmed = true;
  const root = document.documentElement;
  const prev = document.body.dataset.side || "full";
  root.style.setProperty("--side-t", "0s");
  document.body.dataset.side = prev === "rail" ? "full" : "rail";
  void document.body.offsetWidth;
  document.body.dataset.side = prev;
  void document.body.offsetWidth;
  root.style.removeProperty("--side-t");
}

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
// token 数按「千」收敛：概览里 262144 → 262K，四位数以下原样给。
function fmtTokens(n) {
  if (!n || n <= 0) return "—";
  return n >= 1000 ? Math.round(n / 1000) + "K" : String(n);
}
function fmtUptime(startedAt) {
  if (!startedAt) return "—";
  const s = Math.max(0, Math.floor(Date.now() / 1000 - startedAt));
  const h = String(Math.floor(s / 3600)).padStart(2, "0");
  const m = String(Math.floor(s % 3600 / 60)).padStart(2, "0");
  return `${h}:${m}:${String(s % 60).padStart(2, "0")}`;
}
// 启动已等待的秒数。引擎在「加载权重 → 预热」之间可能几分钟不吭声，
// 有这行数字，慢就是慢，而不是看起来卡死。
function fmtElapsed(sec) {
  const s = Math.max(0, Math.floor(sec || 0));
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
}
// 「就绪 / 启动中」是状态本身，不该再当阶段名重复一遍。
function stageLabel(st) {
  const stage = st && st.startupStage;
  if (!stage || stage === "就绪" || stage === "启动中") return "";
  return stage;
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
// 侧栏折叠动画的截止时刻。动画期间不让「纯数据刷新」重绘整页：
// 概览页的 stats 每秒变一次，1s 心跳有约 1/4 的概率正好落在 260ms 的过渡里，
// 那一下会把 main.innerHTML 整块换掉（几十个节点 + 折线图重画），
// 动画就被顶掉一拍——看上去就是「展开到一半卡一下」。让路即可，数据晚 0.26s 上屏看不出来。
// 换页不在此列：用户点了导航就要立刻有反应。
let sideAnimUntil = 0;
// side-anim 类的收口定时器：窗口过了就把 CV 关回去（见 applySidebar / app.css）。
let sideAnimClassTimer = 0;
// 动画期间的收口定时器：多个快照挤在动画里只排一次，收口时按最新 S 重绘。
let sideAnimFlush = 0;
function render(pageChanged) {
  if (pageChanged) pageChangedQueued = true;
  if (renderQueued) return;
  renderQueued = true;
  const run = () => {
    renderQueued = false;
    const pc = pageChangedQueued;
    pageChangedQueued = false;
    renderNow(pc);
  };
  const wait = sideAnimUntil - Date.now();
  if (wait > 0 && !pageChanged) setTimeout(run, wait);
  else requestAnimationFrame(run);
}

// ---------- 局部更新（DOM morph）----------
// 整页 innerHTML 替换的代价不只是那几毫秒：节点身份全换了，CSS 动画从 0% 重来
// （流式 spinner 6 秒内被重置 57 次）、滚动容器归零、输入框内容与选中态丢失、
// 展开态要靠 UI.* 手工抢救。这里改成「解析新 HTML → 与旧树逐节点对齐 → 只改真正
// 变了的文本和属性」，能复用的节点一律复用，动画/滚动/焦点/输入法组字自然保住。
function paint(el, html, reuse) {
  if (!reuse) { el.innerHTML = html; return; }
  const tpl = document.createElement("template");
  tpl.innerHTML = html;
  morphChildren(el, tpl.content);
}

// 节点能否就地打补丁：标签、id、data-key 都对得上才复用，否则整块换掉。
function sameNode(a, b) {
  if (a.nodeType !== b.nodeType) return false;
  if (a.nodeType === 3) return true;                 // 文本：直接改 nodeValue
  if (a.nodeType !== 1) return false;                // 注释等：整块换掉
  if (a.tagName !== b.tagName) return false;
  if (a.id !== b.id) return false;                   // id 变了说明角色变了
  return (a.getAttribute("data-key") || "") === (b.getAttribute("data-key") || "");
}

// 节点的稳定身份：优先 data-key（消息按 id），其次 data-log（日志行按 id）。
function nodeKey(el) {
  if (!el || el.nodeType !== 1 || !el.getAttribute) return null;
  const k = el.getAttribute("data-key") || el.getAttribute("data-log");
  return k ? el.tagName + "|" + k : null;
}

function morphChildren(parent, source) {
  // 必须先拍成数组再遍历！childNodes 是活集合，appendChild/replaceChild 会把节点
  // 从 source 里摘走，活集合当场左移 —— 按活集合走会每搬一个就跳过一个，页面直
  // 接被搬空（换页后整页空白就是这么来的）。
  const oldKids = Array.prototype.slice.call(parent.childNodes);
  const newKids = Array.prototype.slice.call(source.childNodes);
  // 旧节点按 key 建索引。日志/消息是从头部插入的：纯按下标对齐会让后面每一条
  // 都被当成"变了"重写一遍（800 行日志一次推送要写八百个节点）。有 key 的先按
  // key 配对，没 key 的再退回下标对齐。
  const oldByKey = new Map();
  oldKids.forEach((n) => { const k = nodeKey(n); if (k && !oldByKey.has(k)) oldByKey.set(k, n); });
  const used = new Set();
  const plan = new Array(newKids.length);
  for (let i = 0; i < newKids.length; i++) {
    const nk = newKids[i];
    const k = nodeKey(nk);
    let m = k ? oldByKey.get(k) : null;
    if (m && used.has(m)) m = null;
    if (!m) {
      const ok = oldKids[i];
      if (ok && !used.has(ok) && sameNode(ok, nk)) m = ok;
    }
    if (m) used.add(m);
    plan[i] = m;
  }
  for (let i = 0; i < newKids.length; i++) {
    const nk = newKids[i];
    const m = plan[i];
    const ref = parent.childNodes[i] || null;
    if (m) { morphNode(m, nk); if (m !== ref) parent.insertBefore(m, ref); }
    else parent.insertBefore(nk, ref);
  }
  for (let i = 0; i < oldKids.length; i++) if (!used.has(oldKids[i])) oldKids[i].remove();
}

function morphNode(a, b) {
  if (a.nodeType === 3) { if (a.nodeValue !== b.nodeValue) a.nodeValue = b.nodeValue; return; }
  morphAttrs(a, b);
  // data-managed：这块内容自己维护（日志控制台 800 行，每秒整段重拼 ≈ 24ms），
  // morph 只对齐属性、不碰子节点。
  if (b.getAttribute && b.getAttribute("data-managed") !== null) return;
  morphChildren(a, b);
}

function morphAttrs(a, b) {
  const want = b.attributes;
  for (let i = 0; i < want.length; i++) {
    const n = want[i].name;
    if (a.getAttribute(n) !== want[i].value) a.setAttribute(n, want[i].value);
  }
  const have = a.attributes;
  for (let i = have.length - 1; i >= 0; i--) {
    const n = have[i].name;
    if (!b.hasAttribute(n)) a.removeAttribute(n);
  }
  // 属性驱动不了的选中态单独对齐；输入框的 value 属性故意不碰，免得打断输入。
  if (a.tagName === "INPUT" && (b.type === "checkbox" || b.type === "radio")) a.checked = b.checked;
  if (a.tagName === "OPTION") a.selected = b.selected;
}

function renderNow(pageChanged) {
  if (!S) return;
  closeMenus();
  const focusKey = document.activeElement && document.activeElement.dataset ? document.activeElement.dataset.key : null;
  const launch = !!S.launchPage;
  document.body.classList.toggle("launch-mode", launch);
  document.getElementById("side").style.display = launch ? "none" : "";
  const main = document.getElementById("main");
  main.className = "main" + (launch ? " launch-main" : (S.page === "chat" ? " chat-main" : (S.page === "logs" ? " logs-main" : "")));
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
  // 整页 innerHTML 替换会连滚动容器（#msgs / #logConsole）一起重建，
  // scrollTop 归零——这就是流式输出时「对话看着看着被弹回顶部」的根因。
  // 重绘前记住滚动位与是否近底，渲染完成后由 afterXxxRender 恢复。
  UI.chatScroll = null;
  UI.logScroll = null;
  // 其余页没有内滚容器，.main 自己就是滚动条：引擎页的安装/下载进度每秒推一次、
  // 设置页点一个开关都会整页重绘，不记住 scrollTop 就是「看一半被弹回顶部」。
  // 换页（pageChanged）仍回顶部，符合直觉。
  let mainScroll = (!pageChanged && S.page !== "chat") ? main.scrollTop : null;
  if (!pageChanged) {
    const msgsEl = document.getElementById("msgs");
    if (S.page === "chat" && msgsEl)
      UI.chatScroll = { top: msgsEl.scrollTop, nearBottom: msgsEl.scrollHeight - msgsEl.scrollTop - msgsEl.clientHeight < 140 };
    const conEl = document.getElementById("logConsole");
    if (S.page === "logs" && conEl)
      // 倒序吸顶跟随：nearTop 记录是否在顶部附近；h 记录内容高度，
      // 恢复时用高度差 delta 补偿顶部插入的新日志（见 afterLogsRender）。
      UI.logScroll = { top: conEl.scrollTop, h: conEl.scrollHeight, nearTop: conEl.scrollTop < 140 };
  }
  renderSide();
  // 换页仍整块重建（保留 page-in 过渡语义）；同页刷新走 morph，节点和动画都留着。
  const reuse = !pageChanged;
  switch (S.page) {
    case "overview": paint(main, pageOverview(), reuse); break;
    // 流式期间每秒多次推送只改 livestrip 里的文本，spinner 的 CSS 动画不再被打回 0%。
    case "chat": paint(main, pageChat(), reuse); afterChatRender(pageChanged); break;
    case "models": paint(main, pageModels(), reuse); afterModelsRender(); break;
    case "engines": paint(main, pageEngines(), reuse); break;
    case "logs": paint(main, pageLogs(), reuse); afterLogsRender(); break;
    case "settings": paint(main, pageSettings(), reuse); afterSettingsRender(); break;
  }
  // 每页统一绑定 data-act；这是此前多页按钮失灵的根因（只绑定过对话/日志两页）。
  bindActs(main);
  renderOverlays();
  restoreFocus(focusKey);
  // 恢复非对话页的滚动位。放在 restoreFocus 之后：focus() 自带的 scrollIntoView
  // 语义不会再把位置拽走。内容高度变化（如设置页点开「推理等级」多出一行）时
  // 浏览器会自行夹到合法范围，不会滚过头。
  if (mainScroll != null) main.scrollTop = mainScroll;
  if (!sideWarmed) requestAnimationFrame(warmSideTransition);
}

// 近底才吸底：流式输出时跟随滚动，用户上翻阅读时不拽回底部。
// （日志页已改为倒序吸顶，不走这里；对话页恢复逻辑在 afterChatRender 内联。）
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
      case "sidebarModelSwitcher": sidebarModelMenu(); return;
      case "chatMore": chatMoreMenu(); return;
      case "thinkLevel": thinkLevelMenu(); return;
      case "engineMenu": engineMenu(menuBtn.dataset.arg); return;
      case "logMenu": logMenu(); return;
    }
  }
  if (modelMenuBtn) modelMenu(modelMenuBtn.dataset.arg);
}, true);

// ---------- 原生窗口手感：不选中、不拖拽、不弹浏览器的右键菜单 ----------
function isEditableTarget(el) {
  if (!el) return false;
  const tag = (el.tagName || "").toUpperCase();
  return tag === "INPUT" || tag === "TEXTAREA" || el.isContentEditable === true;
}

// 右键：网页是应用外壳，不该出现「重新载入 / 检查元素 / 前进后退」那套。
// 输入框里仍保留系统编辑菜单（粘贴 / 全选）。
window.addEventListener("contextmenu", (e) => {
  if (!isEditableTarget(e.target)) e.preventDefault();
}, true);

// 除表单控件外一律不可拖选（CSS 的 user-select 是主手段，这里兜住 WebKit 的边角）。
document.addEventListener("selectstart", (e) => {
  if (!isEditableTarget(e.target)) e.preventDefault();
}, true);
document.addEventListener("dragstart", (e) => e.preventDefault(), true);

// 按住指针期间不重建侧栏：mouseup 时目标若已被换掉，click 事件根本不会触发。
document.addEventListener("pointerdown", () => { UI.pointerDown = true; }, true);
document.addEventListener("pointerup", () => {
  UI.pointerDown = false;
  if (UI.sideDirty && S) { UI.sideDirty = false; renderSide(); }
}, true);
document.addEventListener("pointercancel", () => { UI.pointerDown = false; }, true);

function popover(anchorId, items) {
  if (UI.menuOpen === anchorId) { closeMenus(); return; }
  closeMenus();
  const anchor = document.getElementById(anchorId) || UI.lastClickEl;
  if (!anchor) return;
  const box = document.createElement("div");
  box.className = "popover";
  box.innerHTML = items.map((it) => it === "-" ? '<div class="sep"></div>'
    : it.header ? `<div class="menu-head">${it.label}</div>`
    : `<div class="item ${it.on ? "on" : ""}" data-act="${esc(it.act)}" data-arg="${esc(it.arg || "")}">${it.label}${it.on ? '<span class="check">✓</span>' : ""}</div>`).join("");
  box.addEventListener("click", (e) => {
    const item = e.target.closest(".item");
    if (!item) return;
    closeMenus();
    handleAction(item.dataset.act, item.dataset.arg);
  });
  // 挂到 body、按视口定位：侧栏引擎卡的锚点在 #main 外面，
  // 挂在 #main 里会算出负坐标被夹到左上角。
  document.body.appendChild(box);
  const r = anchor.getBoundingClientRect();
  box.style.top = Math.max(8, Math.min(r.bottom + 4, window.innerHeight - box.offsetHeight - 8)) + "px";
  box.style.left = Math.max(8, Math.min(r.left, window.innerWidth - box.offsetWidth - 8)) + "px";
  UI.menuOpen = anchorId;
}

function handleAction(act, arg) {
  switch (act) {
    case "nav": nav(arg); break;
    // 折叠/展开侧栏：先本地翻转（点击即出效果），再让 Swift 落盘并回推快照校准。
    case "toggleSidebar":
      if (S) { S.sidebar = S.sidebar === false; applySidebar(); }
      cmd("toggleSidebar");
      break;
    case "openThread": cmd("openThread", { id: arg }); break;
    case "newChat": cmd("newChat"); break;
    case "copyConversation": cmd("copyConversation"); break;
    case "clearChat": cmd("clearChat"); break;
    case "clearThreads": cmd("clearThreads"); break;
    case "chatParams": UI.chatParamsOpen = true; UI.chatParamsDraft = null; render(); break;
    case "setEffort": cmd("setEffort", { effort: arg }); break;
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
    case "copyGateway": cmd("copyGateway", { style: arg || "openai" }); break;
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
    case "resetChatParams": resetChatParams(); break;
    case "logMenu": logMenu(); break;
    case "clearLogs": cmd("clearLogs"); break;
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
  if (!S) { cmd("nav", { page }); return; }
  if (S.page === page) { cmd("nav", { page }); return; }
  S.page = page;
  UI.settingsDraft = null;
  UI.configDraft = null;
  UI.menuOpen = null;
  // 记下这次点击的意图：Swift 回推的旧快照不许把页面掀回上一页。
  UI.navIntent = { page, at: Date.now() };
  // 指纹跟上本地这一帧：Swift 的确认推送内容一致时不再二次整页重绘（否则每次
  // 切页都会渲两遍，第二遍还会把按下的元素换掉，连点就容易丢 click）。
  lastPushJSON = snapshotKey(S);
  render(true);
  cmd("nav", { page });
}

// ---------- 侧栏 ----------
// 实心矢量图标：统一 24 视窗、currentColor 填充，随 nav-item 的配色/悬停/选中状态走。
// 说明：文字符号（◧ ❝ ◫ ⚙）在不同字体下粗细与基线都不一致，缩小后尤其糊，故全部改 SVG。
function navIcon(paths) {
  return `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false">${paths}</svg>`;
}
const NAV_ICONS = {
  // 概览：四宫格仪表盘
  overview: navIcon(`<path d="M4 2.6h5.4a1.6 1.6 0 0 1 1.6 1.6v5.6a1.6 1.6 0 0 1-1.6 1.6H4a1.6 1.6 0 0 1-1.6-1.6V4.2A1.6 1.6 0 0 1 4 2.6Zm10 0h6a1.6 1.6 0 0 1 1.6 1.6v3.4a1.6 1.6 0 0 1-1.6 1.6h-6a1.6 1.6 0 0 1-1.6-1.6V4.2A1.6 1.6 0 0 1 14 2.6Zm0 9.2h6a1.6 1.6 0 0 1 1.6 1.6v6.4a1.6 1.6 0 0 1-1.6 1.6h-6a1.6 1.6 0 0 1-1.6-1.6v-6.4a1.6 1.6 0 0 1 1.6-1.6Zm-10 3.6h5.4a1.6 1.6 0 0 1 1.6 1.6v2.8a1.6 1.6 0 0 1-1.6 1.6H4a1.6 1.6 0 0 1-1.6-1.6v-2.8A1.6 1.6 0 0 1 4 15.4Z"/>`),
  // 对话：实心气泡
  chat: navIcon(`<path d="M5 2.8h14A3.7 3.7 0 0 1 22.7 6.5v7.6a3.7 3.7 0 0 1-3.7 3.7h-5.6l-4.6 3.6a1 1 0 0 1-1.6-.8v-2.8H5a3.7 3.7 0 0 1-3.7-3.7V6.5A3.7 3.7 0 0 1 5 2.8Z"/>`),
  // 模型：层叠权重
  models: navIcon(`<path d="M11.3 2.4a1.6 1.6 0 0 1 1.4 0l8.9 4.3a1 1 0 0 1 0 1.8l-8.9 4.3a1.6 1.6 0 0 1-1.4 0L2.4 8.5a1 1 0 0 1 0-1.8l8.9-4.3Z"/><path d="M2.6 12.2a1 1 0 0 1 1.4-.5l7.3 3.5a1.6 1.6 0 0 0 1.4 0l7.3-3.5a1 1 0 0 1 .9 1.8l-8.4 4a3.6 3.6 0 0 1-3.2 0l-8.2-4a1 1 0 0 1-.5-1.3Z"/><path d="M2.6 17.4a1 1 0 0 1 1.4-.5l7.3 3.5a1.6 1.6 0 0 0 1.4 0l7.3-3.5a1 1 0 0 1 .9 1.8l-8.4 4a3.6 3.6 0 0 1-3.2 0l-8.2-4a1 1 0 0 1-.5-1.3Z"/>`),
  // 引擎：推理芯片
  engines: navIcon(`<path fill-rule="evenodd" d="M6.8 4.6h10.4a2.2 2.2 0 0 1 2.2 2.2v10.4a2.2 2.2 0 0 1-2.2 2.2H6.8a2.2 2.2 0 0 1-2.2-2.2V6.8a2.2 2.2 0 0 1 2.2-2.2Zm1.6 4.4v6h7.2v-6H8.4Z"/><g stroke="currentColor" stroke-width="1.9" stroke-linecap="round"><path d="M8.6 1.5v3.1M12 1.5v3.1M15.4 1.5v3.1M8.6 19.4v3.1M12 19.4v3.1M15.4 19.4v3.1M1.5 8.6h3.1M1.5 12h3.1M1.5 15.4h3.1M19.4 8.6h3.1M19.4 12h3.1M19.4 15.4h3.1"/></g>`),
  // 日志：实心文档 + 镂空行
  logs: navIcon(`<path fill-rule="evenodd" d="M6.2 2.2h11.6A2.2 2.2 0 0 1 20 4.4v15.2a2.2 2.2 0 0 1-2.2 2.2H6.2A2.2 2.2 0 0 1 4 19.6V4.4a2.2 2.2 0 0 1 2.2-2.2Zm1.6 5a1.1 1.1 0 0 0 0 2.2h8.4a1.1 1.1 0 0 0 0-2.2H7.8Zm0 4.4a1.1 1.1 0 0 0 0 2.2h8.4a1.1 1.1 0 0 0 0-2.2H7.8Zm0 4.4a1.1 1.1 0 0 0 0 2.2h5a1.1 1.1 0 0 0 0-2.2h-5Z"/>`),
  // 设置：实心齿轮（描边同色 + round join，把小尺寸下的尖角磨圆）
  settings: navIcon(`<path fill-rule="evenodd" stroke="currentColor" stroke-width="1.3" stroke-linejoin="round" d="M22.14 10.21 L22.14 13.79 L19.1 13.7 L18.02 16.13 L20.44 17.91 L17.91 20.44 L15.81 18.22 L13.33 19.18 L13.79 22.14 L10.21 22.14 L10.3 19.1 L7.87 18.02 L6.09 20.44 L3.56 17.91 L5.78 15.81 L4.82 13.33 L1.86 13.79 L1.86 10.21 L4.9 10.3 L5.98 7.87 L3.56 6.09 L6.09 3.56 L8.19 5.78 L10.67 4.82 L10.21 1.86 L13.79 1.86 L13.7 4.9 L16.13 5.98 L17.91 3.56 L20.44 6.09 L18.22 8.19 L19.18 10.67 Z M8.2 12a3.8 3.8 0 1 0 7.6 0a3.8 3.8 0 1 0 -7.6 0Z"/>`),
};
const NAV_NAMES = { overview: "概览", chat: "对话", models: "模型", engines: "引擎", logs: "日志", settings: "设置" };

// 品牌猫头：与应用图标（scripts/cat_icon.py 画的扁平猫头）同一条轮廓曲线，
// 内联 SVG 而非 CSS 渐变方块，侧栏 / 会话页与 Dock 里的图标永远一致。
// 渐变 id 全文档共享：两处 logo 引用同一个 id，浏览器解析到第一份 defs 即可。
const LOGO_SVG = `<svg viewBox="0 0 1024 1024" aria-hidden="true" focusable="false">
  <defs><linearGradient id="fc-logo-fur" x1="0" y1="0" x2="0.45" y2="1">
    <stop offset="0" stop-color="#FF9E6B"/><stop offset="0.5" stop-color="#F75C86"/><stop offset="1" stop-color="#C247A8"/>
  </linearGradient></defs>
  <path fill="url(#fc-logo-fur)" d="M100 430 C105 300 130 120 185 100 C200 84 236 88 252 112 C300 150 352 206 396 246 C446 206 578 206 628 246 C672 206 724 150 772 112 C788 88 824 84 839 100 C894 120 919 300 924 430 C931 492 938 552 938 622 C938 822 748 956 512 956 C276 956 86 822 86 622 C86 552 93 492 100 430 Z"/>
  <path fill="#B23184" opacity="0.9" d="M168 368 L238 168 L376 258 Z M856 368 L786 168 L648 258 Z"/>
  <path fill="#FFF6EC" stroke="#FFF6EC" stroke-width="26" stroke-linejoin="round" d="M546 300 L448 393 L509 393 L484 467 L592 424 L531 424 Z"/>
  <ellipse fill="#2A1220" cx="335" cy="585" rx="76" ry="96" transform="rotate(-9 335 585)"/>
  <ellipse fill="#2A1220" cx="689" cy="585" rx="76" ry="96" transform="rotate(9 689 585)"/>
  <circle fill="#FFFFFF" cx="317" cy="555" r="24"/>
  <circle fill="#FFFFFF" cx="671" cy="555" r="24"/>
</svg>`;

// 侧栏手柄：macOS 的侧栏图标——一块面板 + 一道竖缝，缝左边就是被收起来的那一栏。
// 不做 chevron：‹ 那种尖角在小字号下永远毛糙，读起来也更像「返回」而不是「收起面板」。
// 描边做到 2.2/24（16px 下约 1.5px），再细就跟旁边 17px 的实心导航图标不是一个重量级。
const SIDE_ICON = navIcon(`<path fill-rule="evenodd" d="M6.2 3h11.6A3.2 3.2 0 0 1 21 6.2v11.6A3.2 3.2 0 0 1 17.8 21H6.2A3.2 3.2 0 0 1 3 17.8V6.2A3.2 3.2 0 0 1 6.2 3Zm-.4 2.2a.8.8 0 0 0-.8.8v12a.8.8 0 0 0 .8.8h12a.8.8 0 0 0 .8-.8V6a.8.8 0 0 0-.8-.8H5.8Z"/><rect x="8.6" y="5.2" width="1.9" height="13.6" rx=".95"/>`);

function renderSide() {
  const st = S.engine || {};
  const localCount = (S.library && S.library.entries || []).filter((x) => x.installed).length;
  const running = st.running;
  // starting/stopping 必须先于 running 判断：进程一拉起 running 就为 true，
  // 但此刻引擎还在加载权重，卡片不能提前报"运行中"。
  const statusText = st.switching ? "切换中"
    : (st.state === "starting" ? `启动中${stageLabel(st) ? " · " + stageLabel(st) : ""}`
    : (st.state === "stopping" ? "停止中"
    : (running ? "运行中" : (st.state === "failed" ? "异常" : "已停止"))));
  const dotCls = st.switching || st.state === "starting" || st.state === "stopping" ? "warn pulse" : (running ? "ok" : (st.state === "failed" ? "err" : ""));
  const act = running ? `<span class="act" data-a="stop">停止</span>`
    : (st.state === "starting" || st.switching ? `<span class="act busy">…</span>`
    : `<span class="act" data-a="start">启动</span>`);
  const threads = (S.threads || []).map((t) =>
    `<div class="recent" data-act="openThread" data-arg="${esc(t.id)}">${esc(t.title)}<span class="tm">${relTime(t.updatedAt)}</span></div>`).join("");
  const dlCount = (S.downloads && S.downloads.tasks || []).length;

  // 注意：模板里不带 active 类。切页只改 class（见 syncNavActive），整块重建会把
  // 用户正按着的 nav-item 在 mouseup 之前换掉，click 事件就永远不触发了。
  // 同理，模板也刻意不含折叠态：折叠只是一次布局变化，一旦让 html 随折叠而变，
  // 每次点手柄都会在动画途中把整棵子树换成新节点 —— 过渡被打断，看起来就是
  // 「先僵一下，再跳一格」。aria/title 由 applySidebar() 事后补到按钮上。
  const html = `
    <div class="brand"><div class="logo">${LOGO_SVG}</div><div class="txt"><div class="t">flashCat</div><div class="s">本地推理控制台</div></div></div>
    <div class="group">工作区</div>
    ${["overview", "chat", "models", "engines", "logs", "settings"].map((p) => `
      <div class="nav-item" data-act="nav" data-arg="${p}" title="${NAV_NAMES[p]}">
        <span class="ico">${NAV_ICONS[p]}</span><span class="lbl">${NAV_NAMES[p]}</span>
        ${p === "models" && localCount ? `<span class="badge">${localCount}</span>` : ""}
      </div>`).join("")}
    <div class="group">最近对话</div>
    <div class="recents"><div>${threads || '<div class="recent" style="color:var(--w-ink-3)">暂无对话</div>'}</div></div>
    <div class="engine-card" id="engineCard">
      <div class="row1"><span class="dot ${dotCls}"></span><span class="st">${statusText}</span>${act}</div>
      <div class="more">
        <div class="model switch" id="sideModelSwitcher" data-menu="sidebarModelSwitcher" title="${esc(S.selectedModel || "")} · 点击切换模型"><span class="nm">${esc(shortModel(S.selectedModel) || "未选择模型")}</span><span class="caret">⌄</span></div>
        <div class="chips">${["splash", "omlx", "mtplx"].map((e) =>
          `<span class="echip ${S.engine.id === e ? "on" : ""}" data-engine="${e}">${e === "splash" ? "Splash" : e === "omlx" ? "oMLX" : "MTPLX"}</span>`).join("")}</div>
        <div class="foot"><span>${esc((st.id || "").toUpperCase())} ${esc(st.version || "")}</span><span>:${S.port}</span></div>
      </div>
    </div>
    ${dlCount ? `<div class="side-dl" data-act="openDownloadCenter">↓ ${dlCount} 个下载任务</div>` : ""}`;

  const side = document.getElementById("side");
  if (html !== lastSideHTML) {
    // 按住指针时先攒着：等抬手再换 DOM，免得这次点击落到被替换掉的节点上。
    if (UI.pointerDown) {
      UI.sideDirty = true;
    } else {
      side.innerHTML = html;
      lastSideHTML = html;
      bindSide(side);
      // 重建后按钮是新节点，折叠态的 aria/title 要重新贴一遍。
      applySidebar();
    }
  }
  syncNavActive();
}


/// 切页只换 active 类，不重建侧栏 DOM（重建会打断正在进行的点击）。
function syncNavActive() {
  const page = S && S.page;
  document.querySelectorAll("#side .nav-item").forEach((el) => {
    el.classList.toggle("active", el.dataset.arg === page);
  });
}

function bindSide(side) {
  const card = side.querySelector("#engineCard");
  if (card) {
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
  }
  bindActs(side);
}

// 局部更新复用节点之后，after* 钩子里的监听必须幂等，否则每次推送叠一层：
// 典型症状是「暂停」点一下等于点两下（切两次 = 看着没反应）。
function bindOnce(el, type, fn) {
  if (!el) return;
  const flag = "__fc_" + type;
  if (el[flag]) return;
  el[flag] = true;
  el.addEventListener(type, fn);
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
// 采样只在生成时落点，两轮任务之间必然有断档。取最后一段「连续采样」作为
// 上一轮生成的曲线：断档超过 8 秒即视为新一轮，从那里切到末尾。
function tailRun(list) {
  const all = list || [];
  if (!all.length) return [];
  let i = all.length - 1;
  while (i > 0 && all[i].t - all[i - 1].t <= 8000) i -= 1;
  return all.slice(i);
}

// 面积折线图：samples 为 [{t,v}]。
// opts.id 决定渐变 id（同页多张图不能共用一个 id）；opts.max 固定纵轴上限（接受率传 1 = 100%）；
// opts.guide 画一条虚线参考线；opts.empty 是空态文案。
function sparkSVG(samples, opts) {
  const o = opts || {};
  const color = o.color || "#FF7A45";
  const gid = "spark-fill-" + (o.id || "default");
  if (!samples || samples.length < 2) {
    return `<div class="empty" style="height:88px;padding:0;display:grid;place-items:center">${esc(o.empty || "启动并生成一次回复后，这里会显示吞吐曲线")}</div>`;
  }
  const W = 800, H = 88;
  const max = o.max != null ? o.max : Math.max(...samples.map((s) => s.v), 10) * 1.15;
  const t0 = samples[0].t, t1 = Math.max(samples[samples.length - 1].t, t0 + 1);
  const y = (v) => H - (Math.min(Math.max(v, 0), max) / max) * (H - 6) - 3;
  const pts = samples.map((s) => [((s.t - t0) / (t1 - t0)) * (W - 4), y(s.v)]);
  const line = pts.map((p, i) => `${i ? "L" : "M"}${p[0].toFixed(1)},${p[1].toFixed(1)}`).join(" ");
  const area = `${line} L${pts[pts.length - 1][0].toFixed(1)},${H} L${pts[0][0].toFixed(1)},${H} Z`;
  const last = pts[pts.length - 1];
  const guide = o.guide != null
    ? `<line x1="0" y1="${y(o.guide).toFixed(1)}" x2="${W}" y2="${y(o.guide).toFixed(1)}"
        stroke="var(--w-line-strong)" stroke-width="1" stroke-dasharray="4 6"/>`
    : "";
  return `<svg class="spark" viewBox="0 0 ${W} ${H}" preserveAspectRatio="none">
    <defs><linearGradient id="${gid}" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="${color}" stop-opacity=".28"/><stop offset="1" stop-color="${color}" stop-opacity="0"/>
    </linearGradient></defs>
    ${guide}
    <path d="${area}" fill="url(#${gid})"/>
    <path d="${line}" fill="none" stroke="${color}" stroke-width="2" stroke-linejoin="round"/>
    <circle cx="${last[0].toFixed(1)}" cy="${last[1].toFixed(1)}" r="3.5" fill="${color}"/>
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

// 概览主卡：引擎状态 + 当前模型 + 启停控制。模型名本身是下拉触发器，点开复用分组模型菜单切换。
// 把原来那条细状态条展开成控制台：模型信息一眼可读，切换和启停不用离页。
function engineHero(st, stats, statusText, dotCls, stage, busy) {
  const meta = ENGINE_META[st.id]
    || { name: (st.id || "ENGINE").toUpperCase(), grad: "linear-gradient(135deg,#8E8E93,#636366)" };
  const isRun = running();
  const actions = busy
    ? `<button class="btn-p ghost" disabled>${esc(statusText)}…</button>`
    : (isRun
      ? `<button class="btn-p ghost" data-act="restart" title="重启服务以重新加载当前模型">重启</button><button class="btn-p danger" data-act="stop">停止</button>`
      : `<button class="btn-p dl" data-act="start">启动引擎</button>`);
  const metaBits = [`<span>ENGINE ${esc((st.id || "").toUpperCase())} ${esc(st.version || "")}</span>`, `<span>PORT :${esc(S.port)}</span>`];
  // 启动中就把已等待的时间摆出来：预热阶段引擎可能几分钟不打一行日志。
  if (st.state === "starting" || st.switching) {
    metaBits.push(`<span>WAIT ${esc(fmtElapsed(st.startupSeconds))}</span>`);
  }
  if (isRun) {
    metaBits.push(`<span id="uptime">UP ${esc(fmtUptime(stats && stats.startedAt))}</span>`);
    if (stats && stats.instancePid) metaBits.push(`<span>PID ${stats.instancePid}</span>`);
    // 上下文一律给「已用 / 总量」：只报总量看不出这一轮还剩多少余量。
    const ctxTotal = (S.context && S.context.total) || (stats && stats.maximumContextTokens) || 0;
    const ctxUsed = (S.context && S.context.used) || 0;
    if (ctxTotal || ctxUsed) {
      const left = ctxUsed ? fmtTokens(ctxUsed) : "0";
      metaBits.push(`<span>CTX ${esc(left)} / ${esc(ctxTotal ? fmtTokens(ctxTotal) : "—")} tok</span>`);
    }
    if (stats && stats.thermal && stats.thermal !== "nominal") metaBits.push(`<span style="color:var(--w-warn)">TEMP ${esc(stats.thermalText)}</span>`);
  }
  return `
    <div class="hero">
      <div class="hero-top">
        <div class="hero-status"><span class="dot ${dotCls}"></span><span class="hero-st">${esc(statusText)}</span>${stage ? `<span class="hero-stage">${esc(stage)}…</span>` : ""}</div>
        <div class="hero-actions">${actions}</div>
      </div>
      <div class="hero-model switch" id="heroModelSwitcher" data-menu="modelSwitcher"
           title="点击切换模型" role="button" tabindex="0" aria-haspopup="menu">
        <span class="hm-eng" style="background:${meta.grad}">${esc(meta.name)}</span>
        <span class="hm-name" title="${esc(S.selectedModel || "")}">${esc(shortModel(S.selectedModel) || "未选择模型")}</span>
        <span class="hm-switch">
          <svg viewBox="0 0 12 12" aria-hidden="true"><path d="M2.5 4.5 6 8l3.5-3.5" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg>
          切换模型
        </span>
      </div>
      <div class="hero-meta">${metaBits.join("")}</div>
    </div>`;
}

function pageOverview() {
  const st = S.engine || {};
  const stats = S.stats;
  const loading = st.switching || st.state === "starting" || (st.ready && !stats);
  const busyState = st.switching || st.state === "starting" || st.state === "stopping";
  const stage = st.switching ? (st.switchStage || "")
    : (st.state === "starting" ? stageLabel(st) : "");
  const statusText = st.switching ? "切换中"
    : (st.state === "starting" ? "启动中"
    : (st.state === "stopping" ? "停止中"
    : (running() ? "运行中" : (st.state === "failed" ? "启动失败" : "已停止"))));
  const dotCls = busyState ? "warn pulse" : (running() ? "ok" : (st.state === "failed" ? "err" : ""));

  const cut = UI.chartRange ? Date.now() - UI.chartRange * 1000 : 0;
  // 后端只在生成时采样，空闲后窗口会自然排空。窗口空了就回落到「上一轮生成」
  // 的曲线：图停在那轮结束的位置，均值也只反映有生成发生的那段时间，
  // 不再被空闲时间稀释或拖着走。
  const decodeWindow = (S.throughput || []).filter((s) => !cut || s.t >= cut);
  const samples = decodeWindow.length ? decodeWindow : tailRun(S.throughput);
  const idle = !decodeWindow.length && samples.length > 0;
  // 接受率曲线与吞吐共用同一个时间窗，两张图一起滚动。
  const accWindow = (S.acceptance || []).filter((s) => !cut || s.t >= cut);
  const accSamples = accWindow.length ? accWindow : tailRun(S.acceptance);
  const accLabel = S.draftLabel || (stats && stats.dflashLabel) || "草稿接受率";
  const accNow = stats && stats.draftAcceptance != null ? Math.round(stats.draftAcceptance * 100) + "%" : "—";
  const accEmpty = !stats ? "引擎启动后显示"
    : (stats.draftAcceptance == null ? "当前引擎未上报接受率数据（DFlash2 / MTP）"
      : "生成一次回复后开始绘制");
  // 生成期间的本地测速（Swift 侧按流式增量算出来的 tok/s），比引擎自报的
  // 累计均值更真实——oMLX 的 avg_generation_tps 整个生成过程一动不动。
  const liveRate = S.generating && stats && stats.liveDecodeRate != null ? stats.liveDecodeRate : null;
  // 引擎不报 TTFT（oMLX）时回落到应用内最近一次回复的本地测量值。
  const lastTtft = (() => {
    const msgs = (S.messages || []).filter((m) => m.role === "assistant" && m.ttft != null);
    return msgs.length ? msgs[msgs.length - 1].ttft : null;
  })();
  const mem = stats && stats.memoryBytes && stats.physicalMemoryBytes;
  // 当前会话上下文：used 来自引擎回报的 usage，total 取模型上限与引擎窗口的小值。
  // 两个数都由 Swift 侧算好（S.context），前端只负责换算显示。
  const ctxTotal = (S.context && S.context.total) || (stats && stats.maximumContextTokens) || 0;
  const ctxRaw = (S.context && S.context.used) || 0;
  const ctxUsed = ctxTotal ? Math.min(ctxRaw, ctxTotal) : ctxRaw;
  const ctxPct = ctxTotal ? Math.min(100, ctxUsed / ctxTotal * 100) : 0;
  const ctxTone = ctxPct >= 90 ? "err" : (ctxPct >= 70 ? "warn" : "ok");
  // 总量已知时「0」比「—」实在：新会话确实是 0，不是没数据。
  const ctxUsedText = ctxUsed ? fmtTokens(ctxUsed) : (ctxTotal ? "0" : "—");
  const ctxHint = !ctxTotal ? "引擎上报窗口后显示"
    : (!ctxUsed ? "发送第一条消息后开始计量"
      : `剩余 ${fmtTokens(ctxTotal - ctxUsed)} tok${ctxPct >= 90 ? " · 接近上限，建议新建会话" : ""}`);
  // 解码均值跟随图表区间（45 秒 / 5 分钟 / 全部）；空闲时回落到上一轮任务的均值。
  const avgDecode = samples.length ? samples.reduce((a, s) => a + s.v, 0) / samples.length : null;
  const rangeLabel = UI.chartRange === 45 ? "45 秒" : (UI.chartRange === 300 ? "5 分钟" : "全部");
  const decodeHint = avgDecode != null
    ? `均值 ${avgDecode.toFixed(1)} tok/s · ${idle ? "上次任务" : rangeLabel}`
    : "等待生成请求";
  // Claude 侧用根地址（Anthropic SDK 自己拼 /v1/messages）；快照缺字段时从 OpenAI 地址回退。
  const claudeURL = S.gatewayClaudeURL || String(S.gatewayURL || "").replace(/\/v1$/, "");
  const kv = [
    ["设备", stats ? `${stats.deviceName || "—"}${stats.gpuCores ? " · " + stats.gpuCores + "C" : ""}` : "—"],
    ["进程", stats && stats.instancePid ? `PID ${stats.instancePid}` : "未运行"],
    ["热状态", stats ? (stats.thermalText || "—") : "—", stats && stats.thermal && stats.thermal !== "nominal"],
    ["请求统计", stats ? `${stats.requestsCompleted} 完成 · ${stats.requestsFailed} 失败` : "—"],
    [stats && stats.dflashLabel ? stats.dflashLabel : "草稿接受率", stats && stats.draftAcceptance != null ? Math.round(stats.draftAcceptance * 100) + "%" : (stats ? "未上报" : "—")],
    ["上下文窗口", stats && stats.maximumContextTokens ? (stats.maximumContextTokens >= 1000 ? Math.round(stats.maximumContextTokens / 1000) + "K tok" : stats.maximumContextTokens + " tok") : "—"],
  ].map(([k, v, warn]) => `<div class="r"><span class="k">${esc(k)}</span><span class="v" ${warn ? 'style="color:var(--w-warn)"' : ""}>${esc(v)}</span></div>`).join("");

  return `
    <h2 class="pg">概览</h2>
    ${st.failure ? `<div class="confirm-strip" style="border-color:color-mix(in srgb, var(--w-err) 40%,transparent);color:var(--w-err);background:color-mix(in srgb, var(--w-err) 9%,transparent)">${esc(st.failure)}</div>` : ""}
    ${engineHero(st, stats, statusText, dotCls, stage, busyState)}
    <div class="metrics">
      ${metricCard("解码速度", loading ? "SYNC" : "LIVE", liveRate != null ? liveRate.toFixed(1) : (stats && stats.decodeTokensPerSecond ? stats.decodeTokensPerSecond.toFixed(1) : "—"), "tok/s", decodeHint, true, loading)}
      ${metricCard("首字延迟", "TTFT", stats && stats.ttftMilliseconds != null ? Math.round(stats.ttftMilliseconds) : (lastTtft != null ? Math.round(lastTtft * 1000) : "—"), "ms", "最近请求", false, loading)}
      ${metricCard("预填充", "PREFILL", stats && stats.prefillTokensPerSecond ? Math.round(stats.prefillTokensPerSecond) : "—", "tok/s", "引擎 prefill 采样", false, loading)}
      ${metricCard("内存压力", "MEM", stats && mem ? Math.round(stats.memoryBytes / stats.physicalMemoryBytes * 100) : "—", "%",
        mem ? `${stats.memoryPressureText && stats.memoryPressureText !== "正常" ? stats.memoryPressureText + " · " : ""}${fmtBytes(stats.memoryBytes)} / ${fmtBytes(stats.physicalMemoryBytes)}` : "引擎运行后显示", false, loading)}
    </div>
    <div class="chart-row">
      <div class="chart-card">
        <div class="hd"><span class="t">解码吞吐${idle ? " · 空闲" : ""}</span>
          <span class="range"><span class="${UI.chartRange === 45 ? "on" : ""}" data-act="chartRange" data-arg="45">45 秒</span><span class="${UI.chartRange === 300 ? "on" : ""}" data-act="chartRange" data-arg="300">5 分钟</span><span class="${UI.chartRange === 0 ? "on" : ""}" data-act="chartRange" data-arg="0">全部</span></span>
        </div>
        ${loading ? '<div class="skeleton" style="height:88px"></div>' : sparkSVG(samples, { id: "decode" })}
      </div>
      <div class="chart-card">
        <div class="hd"><span class="t">${esc(accLabel)}</span><span class="now">${esc(accNow)}</span></div>
        ${loading ? '<div class="skeleton" style="height:88px"></div>'
          : sparkSVG(accSamples, { id: "accept", color: "var(--w-ok)", max: 1, guide: 0.5, empty: accEmpty })}
      </div>
    </div>
    <div class="cols">
      <div class="panel"><div class="t">运行详情</div><div class="kv">${kv}</div>
        <div class="ctx">
          <div class="ctx-hd"><span>当前会话上下文</span>
            <span class="ctx-num">${esc(ctxUsedText)} / ${esc(fmtTokens(ctxTotal))} tok${ctxTotal ? `<small>${Math.round(ctxPct)}%</small>` : ""}</span>
          </div>
          <div class="ctx-track"><div class="ctx-fill ${ctxTone}" style="width:${ctxPct.toFixed(1)}%"></div></div>
          <div class="ctx-hint">${esc(ctxHint)}</div>
        </div>
      </div>
      <div class="panel"><div class="t">API 网关</div>
        <div class="endpoint"><span class="fmt o">OpenAI</span><span class="url">${esc(S.gatewayURL)}</span><span class="copy" data-act="copyGateway" data-arg="openai">复制</span></div>
        <div class="endpoint"><span class="fmt c">Claude</span><span class="url">${esc(claudeURL)}</span><span class="copy" data-act="copyGateway" data-arg="claude">复制</span></div>
        <div class="gw-hint">Claude 填根地址即可，SDK 会自行拼上 /v1/messages</div>
      </div>
    </div>`;
}

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
  const live = S.generating ? `<div class="livestrip"><span class="spinner"></span><span id="liveStatus">${esc(S.generationStatus || "生成中")}</span>
    <span class="chips"><span class="mchip" id="liveRate">— tok/s</span><span class="mchip" id="liveElapsed">0.0s</span></span></div>` : "";
  return `
    <div class="chat-head">
      <span class="dot ${running() ? "ok" : ""}"></span>
      <div class="mdl" id="modelSwitcher" data-menu="modelSwitcher">${esc(shortModel(S.selectedModel))}<small>点击切换模型</small></div>
      <div class="right">
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
        <span class="cap click" data-act="chatParams" title="温度 / Top P / 最大 tokens / 系统提示词">参数设置</span>
        <span class="cap click" id="thinkLevel" data-menu="thinkLevel" title="思考等级（列表来自推理引擎）">思考 · ${esc(thinkChipLabel())} ⌄</span>
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
  // data-key：消息按 id 认领节点。没有它的时候局部更新只能按下标对齐，
  // 新消息插入后整列都要改一遍（实测 300 条的对话一次推送多改 600 多个节点）。
  return `<div class="msg ${isUser ? "user" : "ai"}" data-key="msg-${esc(m.id)}">${av}<div>${think}${bubble}${meta}</div></div>`;
}

// 流式期间同一渲染管线（md 每帧全量重算对小消息足够快）
const mdStream = md;

function afterChatRender(pageChanged) {
  const input = document.getElementById("chatInput");
  const send = document.getElementById("sendBtn");
  const msgs = document.getElementById("msgs");
  if (input) {
    input.value = UI.chatDraft || "";
    bindOnce(input, "input", () => {
      UI.chatDraft = input.value;
      input.style.height = "auto";
      input.style.height = Math.min(input.scrollHeight, 160) + "px";
      const btn = document.getElementById("sendBtn");
      if (btn && !S.generating) btn.disabled = !(UI.chatDraft || "").trim() || !running();
    });
    bindOnce(input, "keydown", (e) => {
      if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); if (UI.chatDraft && UI.chatDraft.trim() && running() && !S.generating) doSend(); }
    });
  }
  bindOnce(send, "click", () => { if (S.generating) cmd("stopGeneration"); else if (UI.chatDraft && UI.chatDraft.trim()) doSend(); });
  document.querySelectorAll("[data-think]").forEach((el) => {
    bindOnce(el, "click", () => {
      const id = el.dataset.think;
      UI.thinkOpen[id] = !UI.thinkOpen[id];
      el.classList.toggle("open", UI.thinkOpen[id]);
      const tb = el.querySelector(".tb");
      tb.style.webkitLineClamp = UI.thinkOpen[id] ? "none" : "";
    });
  });
  document.querySelectorAll("[data-copy]").forEach((el) => {
    bindOnce(el, "click", () => {
      const m = (S.messages || []).find((x) => x.id === el.dataset.copy);
      if (m) cmd("copyText", { text: m.content, label: "已复制消息" });
    });
  });
  document.querySelectorAll("[data-say]").forEach((el) => {
    bindOnce(el, "click", () => { UI.chatDraft = el.dataset.say; doSend(); });
  });
  // livestrip 实时值：速率优先用 Swift 侧流式测速（recordStreamDelta，思考流
  // 也计入），其次消息自带的结束统计；耗时用本地锚点计时。此前只读
  // cur.rate/cur.tokens，而这两者流式期间都还没值，chip 永远停在「— tok/s」。
  // 再挂一个 250ms 本地时钟兜底推送空档（长 prefill、引擎无增量时秒表也照走）。
  if (S.generating) {
    updateLiveStrip();
    if (!UI.liveStripTimer) UI.liveStripTimer = setInterval(() => {
      if (!S || !S.generating || !document.querySelector(".livestrip")) {
        clearInterval(UI.liveStripTimer);
        UI.liveStripTimer = 0;
        return;
      }
      updateLiveStrip();
    }, 250);
  } else {
    if (UI.liveStripTimer) { clearInterval(UI.liveStripTimer); UI.liveStripTimer = 0; }
    if (Object.keys(UI.streamStart).length) UI.streamStart = {};
  }
  // 跟随底部：切页强制吸底；同页重绘恢复到重绘前的滚动位——用户在流式输出
  // 期间上翻阅读时不会被弹回顶部，本就在底部附近则继续跟随新内容。
  // 注意：.msg 的 content-visibility 只在折叠动画窗口开（body.side-anim），
  // 这里赋 scrollTop 时布局必须已完整，否则会被钳位回 0（详见 app.css）。
  if (msgs) {
    const saved = UI.chatScroll;
    if (!pageChanged && saved) {
      msgs.scrollTop = saved.nearBottom ? msgs.scrollHeight : saved.top;
      UI.chatScroll = null;
    } else {
      msgs.scrollTop = msgs.scrollHeight;
    }
  }
  if (input && UI.chatDraft) { input.style.height = "auto"; input.style.height = Math.min(input.scrollHeight, 160) + "px"; }
}

// 直播条就地刷新：不重建 DOM（保住 spinner 动画），只更新状态文本与两个 chip。
function updateLiveStrip() {
  const cur = (S.messages || []).filter((m) => m.streaming && m.role !== "user").pop();
  const status = document.getElementById("liveStatus");
  if (status) status.textContent = S.generationStatus || "生成中";
  if (!cur) return;
  if (!UI.streamStart[cur.id]) UI.streamStart[cur.id] = Date.now();
  const rate = document.getElementById("liveRate");
  const elapsed = document.getElementById("liveElapsed");
  const liveRate = S.stats && S.stats.liveDecodeRate != null ? S.stats.liveDecodeRate : null;
  if (rate) rate.textContent = liveRate != null ? liveRate.toFixed(1) + " tok/s"
    : (cur.rate ? cur.rate.toFixed(1) + " tok/s"
    : (cur.tokens ? cur.tokens + " tokens" : "— tok/s"));
  if (elapsed) elapsed.textContent = ((Date.now() - UI.streamStart[cur.id]) / 1000).toFixed(1) + "s";
}

function doSend() {
  const text = (UI.chatDraft || "").trim();
  if (!text) return;
  UI.chatDraft = "";
  cmd("sendChat", { text });
  render();
}

// 分组模型菜单：按已安装引擎列出各自的模型（对齐旧原生 ModelSwitcher）。
// 选中跨引擎的模型时 useModel 会自动停旧引擎再加载（hop），无需额外确认。
function groupedModelMenuItems() {
  const groups = S.modelsMenu || [];
  const items = [];
  let any = false;
  groups.forEach((g) => {
    const models = g.models || [];
    if (!models.length) return;
    if (items.length) items.push("-");
    any = true;
    items.push({ label: esc(g.name), header: true });
    models.forEach((id) => items.push({
      label: esc(shortModel(id)), act: "useModel", arg: `${g.engine}|${id}`,
      on: id === S.selectedModel && g.engine === S.engine.id,
    }));
  });
  if (!any) items.push({ label: "还没有可切换的模型，去模型页下载", header: true });
  items.push("-", { label: "在模型页浏览全部…", act: "nav", arg: "models" });
  return items;
}

function modelSwitcherMenu() {
  popover("modelSwitcher", groupedModelMenuItems());
}

function sidebarModelMenu() {
  popover("sideModelSwitcher", groupedModelMenuItems());
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

// 思考等级 chip 的文案：开启时显示当前推理等级，否则显示思考模式（自动/关闭）。
function thinkChipLabel() {
  const s = S.settings || {};
  return s.thinkingMode === "on" ? (s.reasoningEffortLabel || "中") : (s.thinkingModeLabel || "自动");
}

// 思考等级菜单：下拉列表来自推理引擎（快照 settings.reasoningEfforts，
// Swift 侧已对未报告的引擎用内置档位兜底），点选即切换，不重启引擎。
function thinkLevelMenu() {
  const s = S.settings || {};
  const options = s.reasoningEfforts || [];
  const items = options.length
    ? options.map((o) => ({ label: esc(o.label), act: "setEffort", arg: o.value, on: o.value === s.reasoningEffort }))
    : [{ label: "引擎未报告思考等级", header: true }];
  popover("thinkLevel", items);
}

// ---------- 对话参数弹层 ----------
function chatParamsDraft() {
  if (!UI.chatParamsDraft) {
    const s = S.settings || {};
    UI.chatParamsDraft = {
      temperature: s.temperature != null ? s.temperature : 0.7,
      topP: s.topP != null ? s.topP : 0.95,
      maxTokens: s.maxTokens > 0 ? s.maxTokens : "",
      systemPrompt: s.systemPrompt || "",
    };
  }
  return UI.chatParamsDraft;
}

function chatParamsBody() {
  const d = chatParamsDraft();
  // 留空时真正发出去的上限由快照算好（模型自身上限，引擎生效窗口封顶），
  // placeholder 直接显示它，不要再写一句无从核对的「默认」。
  const cap = (S.settings && S.settings.effectiveMaxTokens) || 0;
  const capText = cap > 0 ? (cap >= 1000 ? Math.round(cap / 1000) + "K tok" : cap + " tok") : "自动";
  return `
    <div class="modal-body">
      <div class="set-row"><div class="lab"><b>温度</b><small>越高越有创造性，越低越确定</small></div>
        <div class="ctl"><input type="range" min="0" max="2" step="0.05" value="${d.temperature}" data-cprange="temperature" style="width:150px">
        <span class="field" style="min-width:52px" id="cpv-temperature">${Number(d.temperature).toFixed(2)}</span></div></div>
      <div class="set-row"><div class="lab"><b>Top P</b><small>核采样概率质量上限</small></div>
        <div class="ctl"><input type="range" min="0" max="1" step="0.05" value="${d.topP}" data-cprange="topP" style="width:150px">
        <span class="field" style="min-width:52px" id="cpv-topP">${Number(d.topP).toFixed(2)}</span></div></div>
      <div class="set-row"><div class="lab"><b>最大生成 tokens</b><small>留空 = 模型自身上限，按引擎生效窗口封顶；思考与正文共享该上限</small></div>
        <div class="ctl"><input class="field" data-key="cpMaxTokens" data-cpnum="maxTokens" placeholder="默认（${capText}）" value="${esc(d.maxTokens)}"></div></div>
      <div class="set-row" style="align-items:flex-start"><div class="lab"><b>系统提示词</b><small>对每次请求生效，留空则不发送</small></div>
        <div class="ctl"><textarea class="cp-sys" data-key="cpSystem" data-cptext="systemPrompt" rows="4" placeholder="例如：你是一个简洁的本地助手。">${esc(d.systemPrompt)}</textarea></div></div>
    </div>
    <div class="modal-foot">
      <button class="btn-quiet" data-act="resetChatParams">恢复默认</button>
      <button class="btn-quiet" data-act="closeChatParams">取消</button>
      <button class="btn-main" data-act="saveChatParams">应用</button>
    </div>`;
}

// 只把草稿打回默认值，真正的提交仍走「应用」——一键改配置太容易误伤。
function resetChatParams() {
  UI.chatParamsDraft = { temperature: 0.7, topP: 0.95, maxTokens: "", systemPrompt: "" };
  render();
}

function saveChatParams() {
  const d = UI.chatParamsDraft;
  if (!d) { UI.chatParamsOpen = false; render(); return; }
  const maxTokensRaw = String(d.maxTokens == null ? "" : d.maxTokens).trim();
  const maxTokens = maxTokensRaw === "" ? 0 : parseInt(maxTokensRaw, 10);
  cmd("saveSettings", {
    temperature: Math.min(Math.max(Number(d.temperature) || 0, 0), 2),
    topP: Math.min(Math.max(Number(d.topP) || 0, 0), 1),
    maxTokens: maxTokens >= 16 ? maxTokens : 0,
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
  // 已下载（可使用）的模型排前面，未下载的靠后；组内保持原有顺序（sort 稳定）。
  return lib.entries.filter((e) => {
    const passF = UI.modelsFilter === "all" || (UI.modelsFilter === "local" ? e.installed : !e.installed);
    const passQ = !q || e.id.toLowerCase().includes(q) || (e.display || "").toLowerCase().includes(q);
    return passF && passQ;
  }).sort((a, b) => (b.installed ? 1 : 0) - (a.installed ? 1 : 0));
}

// 网格独立成块：搜索输入时只重绘这块，不碰搜索框本身（否则每敲一个字焦点就丢）。
function modelsGridHTML() {
  const entries = filteredModelEntries();
  return entries.length ? `<div class="model-grid">${entries.map(modelCard).join("")}</div>`
    : `<div class="panel"><div class="empty" style="padding:36px"><div class="t">没有符合条件的模型</div><div>试试切到「全部」或清空搜索词</div></div></div>`;
}

function pageModels() {
  const lib = S.library || { engine: "splash", entries: [] };
  const chips = [["splash", "Splash"], ["omlx", "oMLX"], ["mtplx", "MTPLX"]];
  return `
    <h2 class="pg">模型</h2>
    <div class="chipbar">
      ${chips.map(([id, name]) => `<span class="echip ${lib.engine === id ? "on" : ""}" data-act="browseEngine" data-arg="${id}">${name}</span>`).join(" ")}
      <span class="search"><input data-key="modelsSearch" placeholder="⌕ 搜索模型…" value="${esc(UI.modelsSearch)}"></span>
      ${[["all", "全部"], ["local", "本机"], ["remote", "可下载"]].map(([v, n]) =>
        `<span class="filter ${UI.modelsFilter === v ? "on" : ""}" data-f="${v}">${n}</span>`).join("")}
      <span class="filter" style="margin-left:auto" data-act="rescan" data-arg="${esc(lib.engine)}">↻ 刷新状态</span>
      <span class="filter" data-act="openDownloadCenter">下载中心${S.downloads && S.downloads.tasks.length ? " · " + S.downloads.tasks.length : ""}</span>
    </div>
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
  // 「⋯」只在已安装时出现：未安装的卡片唯一可做的操作是下载，卡片上已有
  // 「下载」按钮，菜单里再放一个属于重复入口。未安装时不渲染空的「⋯」。
  // 样式用 btn-p ghost 胶囊，和「使用 / 下载」按钮同高同形，不再是方形小按钮。
  const more = e.installed
    ? `<button class="btn-p ghost more" data-act="modelMenu" data-arg="${esc(e.engine)}|${esc(e.id)}" title="更多操作">⋯</button>`
    : "";
  return `<div class="model-card ${inUse ? "inuse" : ""}">
    <div class="nm" title="${esc(e.id)}">${esc(e.display || e.id)}</div>
    <div class="mtags">${tags.join("")}</div>
    <div class="ft"><span class="sz">${esc(e.originText)}${e.repo ? " · " + esc(e.repo) : ""}</span>
      ${actions}${more}</div>
  </div>`;
}

function modelMenu(arg) {
  const [engine, id] = arg.split("|");
  const entry = (S.library.entries || []).find((x) => x.engine === engine && x.id === id);
  // 未安装的模型没有菜单：下载入口只保留卡片上的那一个按钮，不在菜单里重复。
  if (!entry || !entry.installed) return;
  popover("modelMenuBtn", [
    { label: "在 Finder 中显示", act: "revealModel", arg },
    { label: "删除模型…", act: "removeModel", arg },
  ]);
}

// ---------- 引擎 ----------
const ENGINE_META = {
  splash: { name: "Splash", grad: "linear-gradient(135deg,#FF9F0A,#FF375F)" },
  omlx: { name: "oMLX", grad: "linear-gradient(135deg,#2AA8A0,#1F5FBF)" },
  mtplx: { name: "MTPLX", grad: "linear-gradient(135deg,#5E5CE6,#7B2CBF)" },
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
      btns.push(`<button class="icon-btn" data-menu="engineMenu" data-arg="${id}" title="更多操作">⋯</button>`);
      ft = `<div class="ft">${btns.join("")}</div>`;
    }
    return `<div class="eng-card">
      <div class="hd">
        <span class="eng-ico" style="background:${meta.grad}">${meta.name[0]}</span>
        <div class="nm">${meta.name}</div>
        <div class="right"><span class="dot ${dot}"></span>${stTag}</div>
      </div>
      <div class="kvrow">${kv.join("")}</div>
      ${ft}
    </div>`;
  }).join("");
  return `
    <h2 class="pg">引擎</h2>
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

// 数值旋钮的 key：保存时以数字提交，避免 Swift 侧 Int 解码失败。
const cfgNumericKeys = { mtpDepth: 1, mtpQuantBits: 1, thinkingBudget: 1 };

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
  // 自定义思考截断的开关状态：显式存过以存值为准，否则由「是否填了数值」派生。
  const thinkCustom = () => T().thinkingBudgetCustom ?? (T().thinkingBudget != null);
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
        ${cfgToggle("自定义思考截断", "开启后手动设定思考 token 上限；关闭不限制", "thinkingBudgetCustom", thinkCustom())}
        ${cfgField("思考截断大小", "--thinking-token-budget，思考超过 N 个 token 强制结束思考并开始回答", "thinkingBudget", "不限制", "96px", !thinkCustom())}
      </div>`;
  } else if (id === "mtplx") {
    engineCards = `
      <div class="set-card">
        <div class="card-hd">MTP <small>多 token 预测</small></div>
        ${cfgToggle("启用 MTP", "--mtp / --no-mtp；关闭时不做投机解码", "mtp", true)}
        ${cfgToggle("启动即加载 MTP 权重", "--load-mtp，避免首个请求才付出加载开销", "loadMtp", true)}
        ${cfgField("量化位数", "--mtp-quant-bits，留空使用引擎默认", "mtpQuantBits", "默认", "72px")}
        ${cfgToggle("自定义思考截断", "开启后手动设定思考 token 上限；关闭不限制", "thinkingBudgetCustom", thinkCustom())}
        ${cfgField("思考截断大小", "MTPLX_THINKING_BUDGET，思考超过 N 个 token 强制结束思考并开始回答", "thinkingBudget", "不限制", "96px", !thinkCustom())}
      </div>`;
  } else if (id === "omlx") {
    engineCards = `
      <div class="set-card">
        <div class="card-hd">MTP / DFlash2 <small>按模型生效，两者互斥</small></div>
        ${cfgToggle("启用 MTP", "开启后关闭 DFlash2（oMLX 不允许同时开）", "mtp", false)}
        ${cfgField("MTP 深度", "留空为自适应；固定值优先", "mtpDepth", "自适应", "72px", T().mtp !== true)}
        ${cfgToggle("启用 DFlash2", "开启后关闭 MTP", "dflash", false)}
        ${cfgToggle("PLE n-gram 表卸载到 SSD", "n-gram 表留在 SSD 走 mmap；显存装不下时 oMLX 会自动开启，代价约 2.5× 解码变慢", "pleSSDOffload", true)}
        ${cfgToggle("自定义思考截断", "开启后手动设定思考 token 上限；关闭不限制", "thinkingBudgetCustom", thinkCustom())}
        ${cfgField("思考截断大小", "thinking_budget_tokens，按模型生效；思考超过 N 个 token 强制结束思考并开始回答", "thinkingBudget", "不限制", "96px", !thinkCustom())}
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
        ${id === "omlx" ? "" : `<div class="set-note">启动参数在下次启动时生效；保存后如需立即应用，请在引擎页重启。</div>`}
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
// 展示为倒序（最新在最上），存储仍是正序追加；过滤后 slice().reverse() 再拼 HTML。
// 日志控制台：增量渲染。
// 旧做法是每秒把 800 行重新拼成 HTML 再解析成 DOM（实测 23~24ms，是唯一还会
// 掉帧的地方）。实际上 1Hz 推送通常只多 1~5 行，所以这里只往头部插入新增行、
// 超量从尾部裁掉；只有筛选/搜索/暂停变化或旧头部被-roll 掉时才整段重建。
function logRows() {
  const source = UI.logPaused && UI.logSnapshot ? UI.logSnapshot : (S.logs || []);
  const needle = (UI.logSearch || "").trim().toLowerCase();
  const rows = source.filter((l) => {
    const passF = UI.logFilter === "all" || l.level === UI.logFilter;
    const passQ = !needle || l.text.toLowerCase().includes(needle);
    return passF && passQ;
  }).reverse();  // 倒序：最新在最上面
  return { rows: rows, needle: needle };
}

function logRowHTML(l, needle) {
  const open = !!UI.logOpen[l.id];
  return `<div class="log-line ${l.level === "error" ? "err" : ""}${open ? " open" : ""}" data-log="${l.id}" title="${open ? "点击收起" : "点击展开完整详情"}"><span class="ts">${esc(l.time)}</span><span class="lv ${l.level[0]}">${l.level.toUpperCase()}</span><span class="body">${hl(esc(l.text), needle)}</span></div>`;
}

// 最新在顶部：跟随指示也放在顶部第一行，新日志到达时正好插在它下面。
function logFollowHTML() {
  return UI.logPaused
    ? `<div class="follow">‖ 已暂停 · 显示快照</div>`
    : `<div class="follow" id="followLine">█ 实时跟随中 · ${new Date().toTimeString().slice(0, 8)}</div>`;
}

function logsConsoleHTML() {
  const r = logRows();
  const lines = r.rows.map((l) => logRowHTML(l, r.needle)).join("");
  return logFollowHTML() + (lines || '<div class="follow">暂无日志输出</div>');
}

function syncLogConsole(force) {
  const host = document.getElementById("logConsole");
  if (!host) return;
  const r = logRows();
  const rows = r.rows;
  const sig = [UI.logFilter || "all", UI.logSearch || "", UI.logPaused ? 1 : 0].join("|");
  const head = rows.length ? rows[0].id : "";
  const prev = UI.logRendered;
  const rebuild = !!force || !prev || prev.sig !== sig || !head || !prev.head || rows.length < prev.count;
  if (rebuild) {
    host.innerHTML = logsConsoleHTML();
    UI.logRendered = { sig: sig, head: head, count: rows.length };
    bindLogRows(host);
    return;
  }
  if (head !== prev.head) {
    const n = rows.findIndex((x) => x.id === prev.head);
    if (n < 0) {  // 旧头部已经被裁掉，拼接不可靠 -> 重建
      host.innerHTML = logsConsoleHTML();
      UI.logRendered = { sig: sig, head: head, count: rows.length };
      return;
    }
    if (n > 0) {
      const tpl = document.createElement("template");
      tpl.innerHTML = rows.slice(0, n).map((l) => logRowHTML(l, r.needle)).join("");
      const follow = host.firstElementChild && host.firstElementChild.classList.contains("follow") ? host.firstElementChild : null;
      host.insertBefore(tpl.content, follow ? follow.nextSibling : host.firstChild);
    }
  }
  // 尾部裁剪：保留 rows.length 行 + 顶部跟随行
  const keep = rows.length + 1;
  while (host.children.length > keep) host.removeChild(host.lastElementChild);
  // 跟随行的时间戳要跟着走（快照没变时 tickLive 也会补）
  const f = document.getElementById("followLine");
  if (f) f.textContent = "█ 实时跟随中 · " + new Date().toTimeString().slice(0, 8);
  UI.logRendered = { sig: sig, head: head, count: rows.length };
}

function pageLogs() {
  const source = UI.logPaused && UI.logSnapshot ? UI.logSnapshot : (S.logs || []);
  const counts = { all: source.length, info: 0, warning: 0, error: 0 };
  source.forEach((l) => { if (counts[l.level] != null) counts[l.level]++; });
  return `
    <h2 class="pg">日志</h2>
    <div class="chipbar">
      ${[["all", "全部"], ["info", "提示"], ["warning", "警告"], ["error", "错误"]].map(([v, n]) =>
        `<span class="filter ${UI.logFilter === v ? "on" : ""}" data-lf="${v}">${n}${v !== "all" ? " " + counts[v] : ""}</span>`).join("")}
      <span class="search"><input data-key="logSearch" placeholder="⌕ 搜索关键词…" value="${esc(UI.logSearch)}"></span>
      <span class="filter ${UI.logPaused ? "on" : ""}" style="margin-left:auto" id="pauseBtn">⏸ ${UI.logPaused ? "继续" : "暂停滚动"}</span>
      <span class="icon-btn" id="logMenuBtn" data-menu="logMenu">⋯</span>
    </div>
    <div class="log-console" id="logConsole" data-managed></div>`;
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
  if (consoleEl) {
    bindLogRows(consoleEl);
    // consoleEl 的内容由 syncLogConsole 自己维护（morph 不管它），这里只负责滚动位。
    // 倒序后最新在顶部：「跟随」= 吸顶。有捕获则原地恢复；切进日志页直接吸顶。
    // 插入新日志会让旧内容整体下移 delta = 新高度 - 旧高度，正在往下翻旧日志时
    // scrollTop 需补上 delta 才不会跳行。
    const saved = UI.logScroll;
    syncLogConsole(false);
    if (saved) {
      consoleEl.scrollTop = saved.nearTop ? 0 : saved.top + Math.max(0, consoleEl.scrollHeight - saved.h);
      UI.logScroll = null;
    } else {
      consoleEl.scrollTop = 0;
    }
  }
  bindPageExtras();
}

// 日志行默认单行省略，点击就地展开/收起；展开状态存在 UI.logOpen 上，
// 秒级快照重绘后仍保留。只切这一行的 class，不重绘整块，避免滚动跳动。
function bindLogRows(consoleEl) {
  if (consoleEl.__logBound) return;
  consoleEl.__logBound = true;
  consoleEl.addEventListener("click", (ev) => {
    if (String(window.getSelection() || "").trim()) return; // 正在选中复制时不切换
    const row = ev.target.closest(".log-line");
    if (!row || !row.dataset.log) return;
    const id = row.dataset.log;
    const open = !UI.logOpen[id];
    if (open) UI.logOpen[id] = true; else delete UI.logOpen[id];
    row.classList.toggle("open", open);
    row.title = open ? "点击收起" : "点击展开完整详情";
  });
}

// 模型页此前没有任何 after 钩子：bindPageExtras 只被日志页调用过，
// 搜索框和 全部/本机/可下载 筛选在这一页从未绑上事件，点了没反应。
function afterModelsRender() {
  bindPageExtras();
}

function bindPageExtras() {
  bindActs(document.getElementById("main"));  const pause = document.getElementById("pauseBtn");
  bindOnce(pause, "click", () => {
    if (!UI.logPaused) { UI.logPaused = true; UI.logSnapshot = (S.logs || []).slice(); }
    else { UI.logPaused = false; UI.logSnapshot = null; }
    render();
  });
  const search = document.querySelector('[data-key="logSearch"]');
  bindOnce(search, "input", () => { UI.logSearch = search.value; renderLogConsoleOnly(); });
  const msearch = document.querySelector('[data-key="modelsSearch"]');
  bindOnce(msearch, "input", () => { UI.modelsSearch = msearch.value; renderModelsGridOnly(); });
  document.querySelectorAll("[data-lf]").forEach((el) => bindOnce(el, "click", () => { UI.logFilter = el.dataset.lf; render(); }));
  document.querySelectorAll("[data-f]").forEach((el) => bindOnce(el, "click", () => { UI.modelsFilter = el.dataset.f; render(); }));
  // 输入框失焦时补做挂起的重绘（快照推送在输入期间被挂起）。
  document.querySelectorAll(".search input, .field").forEach((el) =>
    bindOnce(el, "blur", flushPendingRender));
}

// 搜索过滤只更新对应区块（不滚屏、不动输入框），整页重绘留给换页/快照变化。
function renderLogConsoleOnly() {
  const consoleEl = document.getElementById("logConsole");
  if (!consoleEl) { render(); return; }
  syncLogConsole(true);
  consoleEl.scrollTop = 0; // 过滤结果回到顶部：倒序后最新的匹配在最上面
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

// 设置页只「拥有」下面这些字段，改动比较只看它们。不能拿整包快照比：
// 快照里还带着聊天参数（temperature/topP/maxTokens/systemPrompt）等本页
// 不展示的字段，它们一变，用户什么都没碰也会看到「有未保存的更改」。
// 网关开关与网关端口即时生效（走各自的命令），天然不在名单里。
const DRAFT_KEYS = ["ports", "thinkingMode", "reasoningEffort", "defaultModel",
                    "autoStart", "launchAtLogin", "hfCache"];
function comparableSettings(value) {
  const source = value || {};
  const copy = {};
  DRAFT_KEYS.forEach((k) => { copy[k] = source[k] === undefined ? null : source[k]; });
  // 端口在草稿里是字符串（输入框语义），快照里是数字，比较前归一化。
  copy.ports = JSON.parse(JSON.stringify(copy.ports || {}));
  for (const k of Object.keys(copy.ports)) copy.ports[k] = String(copy.ports[k]);
  return JSON.stringify(copy);
}

function savebarState(d) {
  const engines = ["splash", "omlx", "mtplx"];
  const dirty = comparableSettings(d) !== comparableSettings(settingsStored());
  // 草稿的端口是字符串、快照里是数字，两边都要 String 归一化，
  // 否则恒不等，提示会被错误升级成「改动将重启引擎以生效」。
  const activePortChanged = String(d.ports[S.engine.id]) !== String(S.settings.ports[S.engine.id]);
  // 键名必须跟快照一致（thinkingMode / reasoningEffort / defaultModel）。
  // 这里原先比的是 thinking / effort / model —— 两边都是 undefined，恒等，
  // 于是这三项改动从来不会提示「要重启才生效」。
  const otherChanged = ["thinkingMode", "reasoningEffort", "defaultModel",
                        "autoStart", "launchAtLogin", "hfCache"]
    .some((k) => JSON.stringify(d[k]) !== JSON.stringify(S.settings[k]));
  const restartHint = dirty && (activePortChanged || otherChanged) && running();
  const portInvalid = engines.some((e) => { const v = parseInt(d.ports[e], 10); return !v || v < 1024 || v > 65535; });
  const headline = !dirty ? "所有改动已保存"
    : restartHint ? `改动将重启 ${ENGINE_META[S.engine.id].name} 以生效`
    : "有未保存的更改";
  return { dirty, restartHint, portInvalid, headline };
}

function savebarHTML(d) {
  const st = savebarState(d);
  return `<div class="savebar ${st.dirty ? "" : "quiet"}" id="savebar" data-sig="${esc(JSON.stringify(st))}">${esc(st.headline)}
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
    <h2 class="pg">设置</h2>
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
        seg([["automatic", "自动"], ["off", "关闭"], ["on", "开启"]], d.thinkingMode, "thinkingMode"))}
      ${d.thinkingMode === "on" ? row("推理等级", "仅在思考模式为「开启」时生效",
        seg([["minimal", "最小"], ["low", "低"], ["medium", "中"], ["high", "高"], ["xhigh", "超高"], ["max", "最大"]], d.reasoningEffort, "reasoningEffort")) : ""}
      ${row("默认模型", "引擎启动时自动加载", field("defaultModel", d.defaultModel, true))}
      ${row("下载缓存目录", "默认沿用 HF_HUB_CACHE", field("hfCache", d.hfCache, true))}
    </div>
    ${savebarHTML(d)}`;
}

function engines3() { return ["splash", "omlx", "mtplx"]; }

function refreshSettingsChrome() {
  const d = UI.settingsDraft;
  if (!d || S.page !== "settings") return;
  const bar = document.getElementById("savebar");
  // 只在提示条状态真的变了才换 DOM：每个键都 outerHTML 重建一次，
  // 打字时那条提示会跟着一下一下地闪。
  if (bar && bar.dataset.sig !== JSON.stringify(savebarState(d))) {
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
  bindOnce(discard, "click", () => { UI.settingsDraft = null; render(); });
  const save = document.getElementById("saveBtn");
  bindOnce(save, "click", () => {
    const d = UI.settingsDraft;
    if (!d) return;
    cmd("saveSettings", {
      ports: d.ports, thinking: d.thinkingMode, effort: d.reasoningEffort,
      model: (d.defaultModel || "").trim(), autoStart: !!d.autoStart,
      launchAtLogin: !!d.launchAtLogin, hfCache: (d.hfCache || "").trim(),
    });
    UI.settingsDraft = null;
  });
}

function afterSettingsRender() {
  document.querySelectorAll("[data-setseg]").forEach((el) => bindOnce(el, "click", () => {
    const act = el.dataset.setseg, arg = el.dataset.arg;
    if (act === "appearance") { cmd("appearance", { mode: arg }); return; }
    const d = settingsModel();
    d[act] = arg;
    render();
  }));
  document.querySelectorAll("[data-settgl]").forEach((el) => bindOnce(el, "click", () => {
    const key = el.dataset.settgl;
    if (key === "gateway") { cmd("setGatewayEnabled", { on: S.settings.gatewayEnabled ? false : true }); return; }
    const d = settingsModel();
    d[key] = !d[key];
    render();
  }));
  document.querySelectorAll("[data-setfield]").forEach((el) => {
    bindOnce(el, "click", (e) => e.stopPropagation());
    bindOnce(el, "input", () => {
      const key = el.dataset.setfield;
      const d = settingsModel();
      if (key.startsWith("port_")) d.ports[key.slice(5)] = el.value.replace(/[^0-9]/g, "").slice(0, 5);
      else if (key === "gatewayPort") { /* 网关端口即时生效，回车提交 */ }
      else d[key] = el.value;
      refreshSettingsChrome();
    });
    bindOnce(el, "blur", flushPendingRender);
  });
  document.querySelectorAll('[data-setfield="gatewayPort"]').forEach((el) => bindOnce(el, "keydown", (e) => {
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
      <div class="brand" style="padding-left:0"><div class="logo">${LOGO_SVG}</div><div><div class="t">flashCat</div><div class="s">本地推理控制台</div></div></div>
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
  const html = parts.join("");
  // 引擎/下载状态变化会高频推快照，每次全量 render 都走到这里。HTML 没变就
  // 别重建：.modal-body 是自己的滚动容器，重建一次 scrollTop 就被顶回 0——
  // 「模型启动时开着引擎配置，页面一直弹回顶部」就是这么来的。
  if (host.dataset.sig === html) return;
  // 真要重建（进度/阶段文本确实变了）时，按顺序保留每个弹层的滚动位。
  const prevTops = [...host.querySelectorAll(".modal-body")].map((el) => el.scrollTop);
  host.innerHTML = html;
  host.querySelectorAll(".modal-body").forEach((el, i) => {
    if (prevTops[i]) el.scrollTop = prevTops[i];
  });
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
    if (key === "thinkingBudgetCustom") {
      // 开关只是自定义与默认 16384 之间的切换：开 = 补默认值可改，关 = 清空回落。
      t.thinkingBudgetCustom = value;
      if (value && t.thinkingBudget == null) t.thinkingBudget = 16384;
      if (!value) t.thinkingBudget = null;
    } else {
      t[key] = value;
    }
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
    // 数值旋钮（mtpDepth/mtpQuantBits/thinkingBudget）必须以数字提交，
    // 字符串会在 Swift 侧解码 EngineTuning 时失败。
    const n = Number(v);
    cfgModel().tuning[key] = v === "" ? null
      : (cfgNumericKeys[key] && Number.isFinite(n) ? n : v);
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

// 标题栏那一行现在铺在网页里（红绿灯浮在最上层），所以「按住空白处拖窗口」
// 也得由网页转给 Swift。原生 titlebar 自己吞掉鼠标事件时这里根本不会触发，
// 两条路都通，不会互相抢。
document.addEventListener("mousedown", (e) => {
  if (e.button !== 0 || e.clientY > 28) return;
  if (e.target.closest(".side-toggle, .nav-item, button, a, input, textarea, [data-act]")) return;
  cmd("dragWindow");
});

// 折叠手柄是静态节点（在 index.html 里，不参与侧栏/页面重绘）：
// 开机给它填图标、接上动作。它必须留在 #side 外面——折叠后它停在红绿灯右侧 x=72，
// 而侧栏只剩 68 宽，放在里面会被 overflow:hidden / contain:paint 裁掉。
(function initSideToggle() {
  const btn = document.querySelector(".side-toggle");
  if (!btn) return;
  btn.innerHTML = SIDE_ICON;
  btn.addEventListener("click", (e) => { e.stopPropagation(); handleAction("toggleSidebar"); });
})();

window.addEventListener("keydown", (e) => {
  if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "n") { e.preventDefault(); handleAction("newChat"); }
  // 概览主卡的模型切换是 role=button 的 div：键盘 Enter / 空格也要能打开菜单。
  if (e.key === "Enter" || e.key === " ") {
    const sw = e.target.closest && e.target.closest(".hero-model.switch");
    if (sw) { e.preventDefault(); sw.click(); }
  }
});
