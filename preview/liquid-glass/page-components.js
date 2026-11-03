/* flashCat · workspace page components
   Shared by the preview shell. Each page is built from the same compact widgets,
   typography, action states and clear-glass surfaces as the overview page. */
(function () {
  "use strict";

  const icon = (name, size = 16) => window.FCIcons.svg(name, "", size);
  const esc = (value) => String(value == null ? "" : value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
  const shortModel = (model) => String(model || "未选择模型").split("/").pop();
  const prettyModel = (model) => {
    const name = shortModel(model);
    if (name.includes("Qwen3.8-Flash-Next")) return "Qwen3.8 Flash-Next";
    if (name.includes("Qwen3.8-27B")) return "Qwen3.8 27B";
    if (name.includes("Qwen3.6-35B")) return "Qwen3.6 35B";
    return name.length > 26 ? `${name.slice(0, 24)}…` : name;
  };

  function chat(state) {
    const messages = state.chatMessages.map((message) => {
      if (message.role === "user") {
        return `<article class="message user">
          <div class="message-body"><div class="user-bubble">${esc(message.content)}</div></div>
        </article>`;
      }
      const lines = String(message.content || "").split("\n").filter(Boolean);
      const answer = message.streaming && !message.content
        ? `<span class="typing-dots" aria-label="正在思考"><i></i><i></i><i></i></span>`
        : lines.map((line, index) => `<p>${esc(line)}${message.streaming && index === lines.length - 1 ? '<span class="stream-caret"></span>' : ""}</p>`).join("");
      return `<article class="message ai">
        <div class="avatar">${icon("message", 14)}</div>
        <div class="message-body">
          <div class="reasoning" data-reasoning>
            <button class="reasoning-toggle" type="button" data-action="toggle-reasoning" aria-expanded="false">
              ${icon("brain", 11)}<span>思考过程</span><span style="margin-left:auto">${icon("chevronDown", 11)}</span>
            </button>
            <div class="reasoning-copy"><div><p>${esc(message.reasoning || "正在整理回答策略。")}</p></div></div>
          </div>
          <div class="assistant-card ${message.streaming ? "is-streaming" : ""}" id="${message.streaming ? "streamingAnswer" : ""}">
            <div class="assistant-text">${answer}</div>
          </div>
          ${message.streaming ? "" : `<div class="message-meta">
            <span>${esc(message.rate || "—")} tok/s</span>
            <span>首字 ${esc(message.ttft || "—")} ms</span>
            <span>${esc(message.tokens || "—")} tokens</span>
          </div>`}
        </div>
      </article>`;
    }).join("");

    return `
      <section class="chat-page minimal-chat">
        <header class="chat-utilitybar">
          <span class="status-pill ${state.engineRunning ? "" : "stopped"}"><i></i>Splash · ${state.engineRunning ? "运行中" : "已停止"}</span>
          <button class="chat-model-line" type="button" data-action="model-menu">
            <span>${esc(prettyModel(state.model))}</span>
            ${icon("chevronDown", 11)}
          </button>
          <span class="chat-context">430 / 262K</span>
          <span class="spacer"></span>
          <button class="button" type="button" data-action="new-chat">${icon("messagePlus", 13)}<span>新对话</span></button>
        </header>
        <div class="chat-messages" id="chatMessages">
          <div class="messages-inner" id="messagesInner">${messages}</div>
        </div>
        <div class="chat-composer-wrap">
          <div class="chat-composer">
            <label class="visually-hidden" for="chatInput">消息</label>
            <textarea id="chatInput" rows="1" placeholder="输入消息…"></textarea>
            <div class="composer-row">
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

  function models(state, allModels) {
    const current = allModels.find((model) => model.name === state.model) || allModels[0];
    const filtered = modelFilter(allModels, state);
    return `
      <section class="models-workspace">
        <div class="models-topbar">
          <div class="engine-tabs" aria-label="按引擎筛选">
            ${["全部", "Splash", "oMLX", "MTPLX"].map((engine) =>
              `<button type="button" class="${state.modelFilter === engine ? "active" : ""}" data-model-filter="${engine}">${engine}</button>`).join("")}
          </div>
          <label class="search-field">
            ${icon("search", 14)}
            <input id="modelSearch" type="search" placeholder="搜索模型" value="${esc(state.modelSearch)}" autocomplete="off">
          </label>
          <span class="spacer"></span>
          <button class="button icon-only" type="button" data-action="refresh-models" aria-label="刷新">${icon("refresh", 14)}</button>
        </div>
        <div class="models-main-grid">
          <section class="widget model-library-widget">
            <div class="section-line-head">
              <span>本机模型</span><span>1</span>
            </div>
            ${currentModelRow(current, state)}
            <div class="section-line-head">
              <span>可下载</span><span>${filtered.length}</span>
            </div>
            <div class="model-row-list" id="modelsGrid">${modelRows(filtered, state)}</div>
          </section>
          <aside class="widget download-widget">
            <div class="section-line-head">
              <span>下载</span><span>2 项</span>
            </div>
            <div class="download-minimal-list">
              ${downloadRow("Qwen3.8-27B-4bit", "MLX", "13.8 / 20.2 GB", 68)}
              ${downloadRow("Qwen3.5-4B-Q4_K_M", "GGUF", "1.7 / 2.6 GB", 64, true)}
            </div>
            <button class="download-more" type="button" data-action="downloads">
              <span>打开下载中心</span>${icon("chevronRight", 12)}
            </button>
            <div class="market-shortcut">
              <span>${icon("search", 14)}</span>
              <div><strong>模型广场</strong><small>在 Hugging Face 中查找</small></div>
              <button class="glass-icon-btn small" type="button" data-action="search-hub" aria-label="打开模型广场">${icon("chevronRight", 13)}</button>
            </div>
          </aside>
        </div>
      </section>`;
  }

  function modelFilter(allModels, state) {
    const search = state.modelSearch.trim().toLowerCase();
    return allModels.slice(1).filter((model) => {
      const engineMatch = state.modelFilter === "全部" || model.engine === state.modelFilter;
      const searchMatch = !search || `${model.name} ${model.repo} ${model.engine}`.toLowerCase().includes(search);
      return engineMatch && searchMatch;
    });
  }

  function modelRows(models, state) {
    if (!models.length) return `<div class="empty-row">没有匹配的模型</div>`;
    return models.map((model) => {
      const busy = state.downloadsInFlight.has(model.name);
      const done = state.downloaded.has(model.name);
      const progress = state.downloadsInFlight.get(model.name) || 0;
      return `<div class="model-row" data-model-name="${esc(model.name)}">
        <span class="model-row-mark">${icon("database", 14)}</span>
        <span class="model-row-copy">
          <strong>${esc(prettyModel(model.name))}</strong>
          <small>${esc(model.engine)} · ${esc(model.format)} · ${esc(model.size)}</small>
        </span>
        <span class="model-row-memory">${esc(model.memory)}</span>
        <button class="model-row-action" type="button" data-download-model="${esc(model.name)}" ${busy ? "disabled" : ""}>
          ${icon(busy ? "loader" : done ? "check" : "download", 11)}
          <span>${done ? "已下载" : busy ? `${Math.round(progress)}%` : "下载"}</span>
        </button>
      </div>`;
    }).join("");
  }

  function currentModelRow(model, state) {
    return `<div class="current-model-row" data-model-name="${esc(model.name)}">
      <span class="current-model-mark">${icon("brain", 15)}</span>
      <span class="current-model-copy">
        <strong>${esc(prettyModel(model.name))}</strong>
        <small>${esc(model.engine)} · ${esc(model.size)} · 256K</small>
      </span>
      <span class="current-model-state"><i></i>使用中</span>
      <button class="glass-icon-btn small" type="button" data-action="model-more" aria-label="更多模型操作">${icon("ellipsis", 14)}</button>
    </div>`;
  }

  function downloadRow(name, kind, size, progress, paused = false) {
    return `<div class="download-minimal-row ${paused ? "paused" : ""}">
      <div class="download-minimal-top">
        <span>${esc(kind)}</span><strong>${esc(name)}</strong><b>${progress}%</b>
      </div>
      <div class="progress-track"><i style="width:${progress}%"></i></div>
      <small>${esc(size)}</small>
    </div>`;
  }

  function engines(state) {
    const selectedId = state.activeEngineView || "Splash";
    const selected = state.engines.find((engine) => engine.id === selectedId) || state.engines[0];
    const selectedRunning = selected.id === "Splash" ? state.engineRunning : selected.state === "running";
    return `
      <section class="engines-workspace">
        <aside class="widget engine-selector">
          <div class="section-line-head"><span>运行时</span><span>${state.engines.length}</span></div>
          ${state.engines.map((engine) => {
            const running = engine.id === "Splash" ? state.engineRunning : engine.state === "running";
            return `<button class="engine-selector-row ${engine.id === selectedId ? "active" : ""}" type="button" data-engine-view="${esc(engine.id)}">
              <span class="engine-selector-mark" style="--c:${engine.color}">${esc(engine.glyph)}</span>
              <span class="engine-selector-copy">
                <strong>${esc(engine.id)}</strong>
                <small>${esc(engine.version)} · :${esc(engine.port)}</small>
              </span>
              <span class="engine-mini-state ${running ? "running" : ""}"><i></i>${running ? "运行中" : "已停止"}</span>
            </button>`;
          }).join("")}
        </aside>
        <section class="widget engine-detail">
          <div class="engine-detail-head">
            <div>
              <span class="engine-detail-mark" style="--c:${selected.color}">${esc(selected.glyph)}</span>
              <div><h2>${esc(selected.id)}</h2><p>v${esc(selected.version)} · 端口 :${esc(selected.port)}</p></div>
            </div>
            <span class="status-pill ${selectedRunning ? "" : "stopped"}"><i></i>${selectedRunning ? "运行中" : "已停止"}</span>
          </div>
          <p class="engine-detail-description">${esc(selected.description)}</p>
          <div class="engine-detail-stats">
            <div><span>运行时间</span><strong>${selectedRunning ? esc(selected.uptime) : "—"}</strong></div>
            <div><span>进程</span><strong>${selectedRunning ? esc(selected.pid) : "—"}</strong></div>
            <div><span>当前模型</span><strong>${selectedRunning ? esc(prettyModel(state.model)) : "未加载"}</strong></div>
          </div>
          <div class="engine-detail-actions">
            <button class="button primary" type="button" data-engine-toggle="${esc(selected.id)}">
              ${icon(selectedRunning ? "stop" : "play", 13)}<span>${selectedRunning ? "停止引擎" : "启动引擎"}</span>
            </button>
            <button class="button" type="button" data-action="engine-config">${icon("sliders", 13)}<span>配置</span></button>
          </div>
          <div class="engine-log-preview">
            <span>最近输出</span>
            <code>${selectedRunning ? "Ready · context 262K · http://127.0.0.1:8000" : "Runtime is stopped."}</code>
            <code>${selectedRunning ? `Weights loaded · ${prettyModel(state.model)}` : `Install complete · v${esc(selected.version)}`}</code>
          </div>
        </section>
      </section>`;
  }

  function logs(state, linesHtml, counts) {
    return `
      <section class="logs-workspace">
        <div class="logs-topbar">
          <div class="filter-pills">
            ${["全部", "提示", "警告", "错误"].map((filter) =>
              `<button class="filter-pill ${state.logFilter === filter ? "active" : ""}" type="button" data-log-filter="${filter}">${filter}<b>${counts[filter]}</b></button>`).join("")}
          </div>
          <label class="search-field">
            ${icon("search", 14)}
            <input id="logSearch" type="search" placeholder="搜索" value="${esc(state.logSearch)}" autocomplete="off">
          </label>
          <span class="spacer"></span>
          <button class="button" type="button" data-action="toggle-log-pause">
            ${icon(state.logPaused ? "play" : "pause", 13)}<span>${state.logPaused ? "继续" : "暂停"}</span>
          </button>
          <button class="button icon-only quiet" type="button" data-action="clear-logs" aria-label="清空日志">${icon("trash", 13)}</button>
        </div>
        <section class="console">
          <header class="console-head">
            <span class="live-toggle"><i></i>${state.logPaused ? "PAUSED" : "LIVE"}</span>
            <span>splash.log</span>
            <span class="spacer"></span>
            <span>60 秒</span>
          </header>
          <div class="console-body" id="consoleBody">${linesHtml}</div>
        </section>
      </section>`;
  }

  function settings(state) {
    return `
      <section class="settings-workspace">
        <div class="settings-two-column">
          <section class="settings-group">
            <div class="settings-row">
              <div class="settings-copy"><strong>外观</strong><span>跟随系统或固定外观</span></div>
              <div class="settings-segmented" data-appearance-choice>
                ${["system", "light", "dark"].map((choice) =>
                  `<button type="button" class="${state.theme === choice ? "active" : ""}" data-appearance="${choice}">${choice === "system" ? "跟随系统" : choice === "light" ? "浅色" : "深色"}</button>`).join("")}
              </div>
            </div>
            <div class="settings-row">
              <div class="settings-copy"><strong>登录时启动</strong></div>
              <button class="toggle ${state.settings.login ? "on" : ""}" type="button" data-setting-toggle="login" role="switch" aria-checked="${state.settings.login}"></button>
            </div>
            <div class="settings-row">
              <div class="settings-copy"><strong>随应用启动引擎</strong></div>
              <button class="toggle ${state.settings.launchEngine ? "on" : ""}" type="button" data-setting-toggle="launchEngine" role="switch" aria-checked="${state.settings.launchEngine}"></button>
            </div>
          </section>

          <section class="settings-group">
            <div class="settings-row">
              <div class="settings-copy"><strong>API 网关</strong><span>OpenAI 与 Claude</span></div>
              <button class="toggle ${state.settings.gateway ? "on" : ""}" type="button" data-setting-toggle="gateway" role="switch" aria-checked="${state.settings.gateway}"></button>
            </div>
            <div class="settings-row">
              <div class="settings-copy"><strong>思考模式</strong></div>
              <div class="settings-segmented" data-thinking-choice>
                ${["自动", "关闭", "开启"].map((choice) =>
                  `<button type="button" class="${state.settings.thinking === choice ? "active" : ""}" data-thinking="${choice}">${choice}</button>`).join("")}
              </div>
            </div>
            <div class="settings-row">
              <div class="settings-copy"><strong>默认模型</strong><span>${esc(prettyModel(state.model))}</span></div>
              <button class="button" type="button" data-action="model-menu">${icon("layers", 13)}<span>更改</span></button>
            </div>
          </section>

          <section class="settings-group settings-ports">
            <div class="settings-row">
              <div class="settings-copy"><strong>引擎端口</strong></div>
              <div class="port-row">
                <label class="port-input"><span>:</span><input value="8000" inputmode="numeric" aria-label="Splash 端口"></label>
                <label class="port-input"><span>:</span><input value="8100" inputmode="numeric" aria-label="oMLX 端口"></label>
                <label class="port-input"><span>:</span><input value="8200" inputmode="numeric" aria-label="MTPLX 端口"></label>
              </div>
            </div>
            <div class="settings-row">
              <div class="settings-copy"><strong>下载缓存</strong><span>默认使用 HF_HUB_CACHE</span></div>
              <button class="button" type="button" data-action="engine-config">${icon("folderOpen", 13)}<span>选择</span></button>
            </div>
          </section>

          <section class="settings-group about-settings">
            <div class="settings-row">
              <div class="settings-copy"><strong>flashCat</strong><span>1.0 preview</span></div>
              <span class="about-device">Apple M5 Max · 128 GB</span>
            </div>
            <div class="settings-row">
              <div class="settings-copy"><strong>运行环境</strong><span>macOS 26.4 · Apple Silicon</span></div>
              <button class="button quiet" type="button" data-action="reset-settings">${icon("refresh", 13)}<span>恢复默认</span></button>
            </div>
          </section>
        </div>
      </section>`;
  }

  window.FCPages = { chat, models, modelRows, engines, logs, settings };
}());
