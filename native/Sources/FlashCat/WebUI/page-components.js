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
  const shortModel = (model) => {
    const canonical = String(model || "").trim().replace(/--/g, "/");
    return canonical ? canonical.split("/").pop() : "未选择模型";
  };
  const prettyModel = shortModel;

  function chat(state) {
    const messages = state.chatMessages.map((message, index) => {
      const id = esc(message.id || `m${index}`);
      if (message.role === "user") {
        return `<article class="message user is-new" data-msg-id="${id}">
          <div class="message-body"><div class="user-bubble">${esc(message.content)}</div></div>
        </article>`;
      }
      const thinking = window.FCChatStream ? window.FCChatStream.thinkingHTML(message) : "";
      const answer = window.FCChatStream
        ? window.FCChatStream.answerHTML(message)
        : `<div class="md-body">${window.FCChatMarkdown ? window.FCChatMarkdown.render(message.content || "") : esc(message.content)}</div>`;
      return `<article class="message ai is-new${thinking ? " has-think" : ""}" data-msg-id="${id}">
        ${window.FCModelBrand
          ? window.FCModelBrand.tile(message.model || state.model, { size: 15, className: "avatar ai-icon model-avatar" })
          : `<div class="avatar ai-icon">${icon("brain", 14)}</div>`}
        <div class="message-body">
          ${thinking}
          <div class="assistant-card ${message.streaming ? "is-streaming" : ""}${!message.content ? " is-empty" : ""}" id="${message.streaming ? "streamingAnswer" : ""}">
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
          <button class="chat-model-line" type="button" data-action="model-menu"
                  data-model-key="${esc(state.model)}" title="${esc(state.model)}">
            <span class="model-glyph" data-model-glyph>${window.FCModelBrand ? window.FCModelBrand.inline(state.model, 12) : ""}</span>
            <span class="model-label" data-model-label>${esc(prettyModel(state.model))}</span>
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
              <span class="spacer"></span>
              <button class="composer-chip" type="button" data-action="open-inspector">${icon("sliders", 12)}<span>参数</span></button>
              ${window.FCChatThinking ? window.FCChatThinking.trigger(state) : ""}
              <button class="send-button" id="sendButton" type="button" data-action="send-chat" aria-label="发送消息">
                ${icon(state.chatStreaming ? "stop" : "arrowUp", 14)}
              </button>
            </div>
          </div>
        </div>
      </section>`;
  }

  function models(state, allModels) {
    const filtered = modelFilter(allModels, state);
    return `
      <section class="models-workspace">
        <div class="models-topbar">
          <div class="engine-tabs" data-engine-tabs aria-label="按引擎筛选">
            <span class="engine-tab-indicator" aria-hidden="true"></span>
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
        <div class="models-card-grid" id="modelsGrid">${modelTiles(filtered, state)}</div>
      </section>`;
  }

  function modelFilter(allModels, state) {
    const search = state.modelSearch.trim().toLowerCase();
    return allModels.filter((model) => {
      const engineMatch = state.modelFilter === "全部" || model.engine === state.modelFilter;
      const searchMatch = !search || `${model.name} ${model.repo} ${model.engine}`.toLowerCase().includes(search);
      return engineMatch && searchMatch;
    });
  }

  function modelTiles(models, state) {
    if (!models.length) return `<div class="empty-row">没有匹配的模型</div>`;
    return models.map((model, index) => {
      const current = model.name === state.model;
      const busy = state.downloadsInFlight.has(model.name);
      const done = state.downloaded.has(model.name);
      const progress = state.downloadsInFlight.get(model.name) || 0;
      return `<article class="model-tile ${current ? "is-current" : ""}" style="--row:${index}" data-model-name="${esc(model.name)}">
        <header class="model-tile-head">
          <span class="model-tile-icon">${icon(current ? "brain" : "database", 16)}</span>
          <span class="model-tile-flags">
            <span>${esc(model.engine)}</span><span>${esc(model.format)}</span><span>${esc(model.size)}</span>
          </span>
          ${current ? `<span class="model-current-badge"><i></i>使用中</span>` : ""}
        </header>
        <h2>${esc(prettyModel(model.name))}</h2>
        <p class="model-tile-repo">${esc(model.repo)}</p>
        <div class="model-tile-tags">
          ${model.flags.map((flag) => `<span>${esc(flag)}</span>`).join("")}
        </div>
        <footer class="model-tile-foot">
          <span>${esc(model.memory)}</span>
          ${current
            ? `<span class="model-tile-running">已加载</span>`
            : `<button class="model-tile-action" type="button" data-download-model="${esc(model.name)}" ${busy ? "disabled" : ""}>
                ${icon(busy ? "loader" : done ? "check" : "download", 12)}
                <span>${done ? "已下载" : busy ? `${Math.round(progress)}%` : "下载"}</span>
              </button>`}
        </footer>
      </article>`;
    }).join("");
  }

  function modelRows(models, state) {
    if (!models.length) return `<div class="empty-row">没有匹配的模型</div>`;
    return models.map((model, rowIndex) => {
      const busy = state.downloadsInFlight.has(model.name);
      const done = state.downloaded.has(model.name);
      const progress = state.downloadsInFlight.get(model.name) || 0;
      return `<div class="model-row" style="--row:${rowIndex}" data-model-name="${esc(model.name)}">
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
              <div class="settings-segmented sliding-segments" data-appearance-choice data-sliding-segments>
                <span class="segment-slider" aria-hidden="true"></span>
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
              <div class="settings-segmented sliding-segments" data-thinking-choice data-sliding-segments>
                <span class="segment-slider" aria-hidden="true"></span>
                ${["自动", "关闭", "开启"].map((choice) =>
                  `<button type="button" class="${state.settings.thinking === choice ? "active" : ""}" data-thinking="${choice}">${choice}</button>`).join("")}
              </div>
            </div>
            <div class="settings-row">
              <div class="settings-copy"><strong>默认模型</strong><span data-default-model>${esc(prettyModel(state.model))}</span></div>
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

  window.FCPages = { chat, models, modelTiles, modelRows, engines, logs, settings };
}());
