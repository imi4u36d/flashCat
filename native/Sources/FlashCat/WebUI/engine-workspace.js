/* flashCat · engine workspace
   Pure renderers for the engine page. Interaction stays in the host app. */
(function () {
  "use strict";

  const ENGINE_META = {
    Splash: {
      adapter: "splash",
      glyph: "S",
      color: "#e86186",
      description: "单模型运行，DFlash2 草稿加速",
      features: ["DFlash2", "GGUF", "PLE SSD"],
    },
    oMLX: {
      adapter: "omlx",
      glyph: "O",
      color: "#4f9ddd",
      description: "多模型常驻，热切换不停进程",
      features: ["MTP", "MLX", "热切换"],
    },
    MTPLX: {
      adapter: "mtplx",
      glyph: "M",
      color: "#8d78e8",
      description: "长上下文与多 token 预测",
      features: ["MTP", "长上下文", "多 token"],
    },
  };

  const ENGINE_ORDER = ["Splash", "oMLX", "MTPLX"];

  const esc = (value) => String(value == null ? "" : value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");

  const icon = (name, size = 14) => {
    if (window.FCIcons && typeof window.FCIcons.svg === "function") {
      return window.FCIcons.svg(name, "fc-engine-icon", size);
    }
    return `<span class="fc-engine-icon-fallback" aria-hidden="true"></span>`;
  };

  function normalizeState(state) {
    return state && typeof state === "object" ? state : {};
  }

  function adapterFor(id, engine, state) {
    const catalogItem = Array.isArray(state.engineCatalog)
      ? state.engineCatalog.find((item) => item.id === id)
      : null;
    return catalogItem?.adapter || engine?.adapter || ENGINE_META[id]?.adapter || id.toLowerCase();
  }

  function engineInfo(state, id) {
    return state.enginesInstall?.[id] || {};
  }

  function engineList(state) {
    const source = Array.isArray(state.engines) && state.engines.length ? state.engines : [];
    const byId = new Map(source.map((engine) => [engine.id, engine]));
    // The app ships five runtimes; the preview only ever mocked three. Take the
    // order from the catalog the host provides, with the mock order as fallback.
    const ids = Array.isArray(state.engineCatalog) && state.engineCatalog.length
      ? state.engineCatalog.map((item) => item.id)
      : (source.length ? source.map((engine) => engine.id) : ENGINE_ORDER);
    return ids.map((id) => {
      const engine = byId.get(id) || { id };
      return {
        ...ENGINE_META[id],
        ...engine,
        id,
        adapter: adapterFor(id, engine, state),
        info: engineInfo(state, id),
      };
    });
  }

  function resolvedEngineId(state, engine) {
    return state.engineConfigOpen || state.configEngine ||
      state.activeEngineView || state.engine || engine?.id || "Splash";
  }

  function engineDraft(state, id) {
    const draft = state.engineConfigDraft || state.configDraft;
    if (draft && (!draft.engine || draft.engine === id)) {
      return {
        tuning: draft.tuning || draft,
        port: draft.port,
      };
    }
    const info = engineInfo(state, id);
    return {
      tuning: info.tuning || {},
      port: info.port,
    };
  }

  function installedFor(engine) {
    if (engine.installed != null) return Boolean(engine.installed);
    if (engine.info.installed != null) return Boolean(engine.info.installed);
    return Array.isArray(engine.info.versions) ? engine.info.versions.length > 0 : false;
  }

  function runningFor(state, engine) {
    if (engine.running != null) return Boolean(engine.running);
    if (engine.state === "running") return true;
    if (engine.id === state.engine) return Boolean(state.engineRunning);
    return false;
  }

  function busyFor(engine) {
    return Boolean(
      engine.busy ||
      engine.installing ||
      engine.updating ||
      engine.downloading ||
      engine.actionState === "busy"
    );
  }

  function updateFor(engine) {
    if (engine.updateAvailable != null) return Boolean(engine.updateAvailable);
    return Boolean(
      installedFor(engine) &&
      engine.latest &&
      engine.version &&
      String(engine.latest) !== String(engine.version)
    );
  }

  function statusFor(state, engine) {
    if (!installedFor(engine)) {
      return { label: busyFor(engine) ? "下载中" : "未安装", tone: busyFor(engine) ? "busy" : "muted" };
    }
    if (busyFor(engine)) return { label: "处理中", tone: "busy" };
    if (runningFor(state, engine)) return { label: "运行中", tone: "running" };
    return { label: "已停止", tone: "stopped" };
  }

  function modelLabel(model) {
    const raw = String(model || "").trim().replace(/--/g, "/");
    if (!raw) return "未加载模型";
    const short = raw.split("/").pop() || raw;
    return short.length > 28 ? `${short.slice(0, 26)}…` : short;
  }

  function metricLabel(engine, state, running) {
    if (!installedFor(engine)) return "等待安装";
    if (!running) return "进程未启动";
    if (engine.id === state.engine && state.model) return modelLabel(state.model);
    return engine.model ? modelLabel(engine.model) : "模型已就绪";
  }

  function statusMarkup(state, engine) {
    const status = statusFor(state, engine);
    return `<span class="fc-engine-status fc-engine-status-${status.tone}">
      <i aria-hidden="true"></i>${esc(status.label)}
    </span>`;
  }

  function actionButton(label, iconName, attributes, tone = "") {
    return `<button class="fc-engine-action ${tone ? `fc-engine-action-${tone}` : ""}" type="button" ${attributes}>
      ${icon(iconName, 13)}<span>${esc(label)}</span>
    </button>`;
  }

  function cardActions(state, engine, installed, running, busy, hasUpdate) {
    const id = esc(engine.id);
    if (busy) {
      const progress = Number(engine.progress ?? engine.downloadProgress ?? 0);
      return `<div class="fc-engine-progress" aria-label="处理中 ${Math.round(progress)}%">
        <span><i style="width:${Math.max(3, Math.min(100, progress))}%"></i></span>
        <b>${Math.round(progress)}%</b>
      </div>`;
    }

    if (!installed) {
      return `<div class="fc-engine-actions">
        ${actionButton("下载", "download", `data-act="installEngine" data-arg="${id}" data-engine-download="${id}"`, "primary")}
      </div>`;
    }

    const toggle = running
      ? actionButton("停止", "stop", `data-engine-toggle="${id}" data-engine-stop="${id}"`, "danger")
      : actionButton("启动", "play", `data-engine-toggle="${id}" data-engine-start="${id}"`, "primary");

    return `<div class="fc-engine-actions">
      ${toggle}
      ${actionButton("配置", "sliders", `data-action="engine-config" data-engine-config="${id}"`)}
      ${hasUpdate ? actionButton("更新", "arrowUp", `data-act="installEngine" data-arg="${id}" data-engine-update="${id}"`, "update") : ""}
      ${actionButton("删除", "trash", `data-engine-remove="${id}"`, "danger")}
    </div>`;
  }

  function engineCard(state, engine, index) {
    const installed = installedFor(engine);
    const running = runningFor(state, engine);
    const busy = busyFor(engine);
    const hasUpdate = updateFor(engine);
    const selected = resolvedEngineId(state) === engine.id;
    const version = installed ? engine.version || engine.info.version || "—" : engine.latest || engine.version || "—";
    const port = engine.port || engine.info.port || "—";
    const tone = !installed ? "missing" : running ? "running" : "stopped";
    const features = Array.isArray(engine.features) ? engine.features : ENGINE_META[engine.id]?.features || [];

    return `<article class="fc-engine-card fc-engine-card-${tone} ${selected ? "fc-engine-card-selected" : ""}"
      data-engine-view="${esc(engine.id)}"
      tabindex="0"
      aria-label="${esc(engine.id)} 运行时"
      style="--fc-engine-accent:${esc(engine.color)};--fc-engine-order:${index}">
      <span class="fc-engine-card-light" aria-hidden="true"></span>
      <span class="fc-engine-watermark" aria-hidden="true">${esc(engine.glyph || engine.id.slice(0, 1))}</span>
      <header class="fc-engine-card-head">
        <span class="fc-engine-mark">${esc(engine.glyph || engine.id.slice(0, 1))}</span>
        <span class="fc-engine-card-title">
          <strong>${esc(engine.id)}</strong>
          <small>v${esc(version)} · :${esc(port)}</small>
        </span>
        ${statusMarkup(state, engine)}
      </header>
      <p class="fc-engine-description">${esc(engine.description || "本地推理运行时")}</p>
      <div class="fc-engine-card-meta">
        <span><small>当前</small><b>${esc(metricLabel(engine, state, running))}</b></span>
        <span><small>接口</small><b>${installed ? `127.0.0.1:${esc(port)}` : `端口 ${esc(port)}`}</b></span>
        <span><small>状态</small><b>${running ? esc(engine.uptime || "在线") : installed ? "待机" : "未下载"}</b></span>
      </div>
      <div class="fc-engine-features">
        ${features.map((feature) => `<span>${esc(feature)}</span>`).join("")}
      </div>
      ${running ? `<div class="fc-engine-signal" aria-hidden="true">
        ${Array.from({ length: 14 }, (_, bar) => `<i style="--fc-engine-bar:${bar}"></i>`).join("")}
      </div>` : ""}
      <footer class="fc-engine-card-foot">
        ${cardActions(state, engine, installed, running, busy, hasUpdate)}
      </footer>
    </article>`;
  }

  function summary(state, engines) {
    const installed = engines.filter(installedFor).length;
    const running = engines.filter((engine) => runningFor(state, engine)).length;
    return `<header class="fc-engine-summary">
      <span class="fc-engine-summary-title">运行时</span>
      <span class="fc-engine-summary-count"><i></i>${running} 运行中</span>
      <span class="fc-engine-summary-separator" aria-hidden="true"></span>
      <span class="fc-engine-summary-meta">${installed} / ${engines.length} 已安装</span>
      <button class="fc-engine-summary-refresh" type="button" data-action="refresh-engines" aria-label="刷新引擎状态">
        ${icon("refresh", 13)}
      </button>
    </header>`;
  }

  function tuningValue(draft, key, fallback) {
    const value = draft?.tuning?.[key];
    return value == null ? fallback : value;
  }

  function toggleRow(label, detail, key, value, defaultValue, disabled = false) {
    return `<div class="fc-engine-config-row">
      <span class="fc-engine-config-copy">
        <strong>${esc(label)}</strong>
        <small>${esc(detail)}</small>
      </span>
      <button class="fc-engine-switch ${value ? "fc-engine-switch-on" : ""} ${disabled ? "fc-engine-switch-disabled" : ""}"
        type="button" role="switch" aria-checked="${value ? "true" : "false"}"
        data-cfgtgl="${esc(key)}" data-fc-engine-toggle="${esc(key)}"
        data-d="${defaultValue ? "1" : "0"}" ${disabled ? "disabled" : ""}>
        <i aria-hidden="true"></i>
      </button>
    </div>`;
  }

  function fieldRow(label, detail, key, value, options = {}) {
    const type = options.type || "text";
    const placeholder = options.placeholder || "";
    const disabled = Boolean(options.disabled);
    const extraAttributes = [
      `data-cfg="${esc(key)}"`,
      `data-fc-engine-field="${esc(key)}"`,
      options.min != null ? `min="${esc(options.min)}"` : "",
      options.max != null ? `max="${esc(options.max)}"` : "",
      options.step != null ? `step="${esc(options.step)}"` : "",
    ].filter(Boolean).join(" ");

    return `<label class="fc-engine-config-row">
      <span class="fc-engine-config-copy">
        <strong>${esc(label)}</strong>
        <small>${esc(detail)}</small>
      </span>
      <input class="fc-engine-input ${options.wide ? "fc-engine-input-wide" : ""}" type="${esc(type)}"
        value="${esc(value == null ? "" : value)}"
        placeholder="${esc(placeholder)}"
        inputmode="${type === "number" ? "numeric" : "text"}"
        ${extraAttributes} ${disabled ? "disabled" : ""}>
    </label>`;
  }

  function directoryRow(label, detail, path, action, id) {
    return `<div class="fc-engine-config-row fc-engine-directory-row">
      <span class="fc-engine-config-copy">
        <strong>${esc(label)}</strong>
        <small>${esc(detail)}</small>
      </span>
      <span class="fc-engine-directory">
        <code title="${esc(path)}">${esc(path || "未设置")}</code>
        <button type="button" data-finder="${esc(action)}|${esc(id)}" aria-label="${esc(label)}">
          ${icon(action === "engineModels" ? "folderOpen" : "fileText", 13)}
        </button>
      </span>
    </div>`;
  }

  function group(title, body, note = "") {
    return `<section class="fc-engine-config-group">
      <header><h3>${esc(title)}</h3></header>
      <div class="fc-engine-config-list">${body}</div>
      ${note ? `<p class="fc-engine-config-note">${esc(note)}</p>` : ""}
    </section>`;
  }

  function splashFields(draft) {
    const dflash = tuningValue(draft, "dflash", false) !== false;
    const pleMemory = tuningValue(draft, "pleMemory", "");
    return `
      ${group("投机解码", `
        ${toggleRow("DFlash2", "并行生成草稿 token", "dflash", dflash, false)}
        ${fieldRow("Draft 目录", "留空自动匹配主模型", "draftModel", tuningValue(draft, "draftModel", ""), {
          placeholder: "自动",
          wide: true,
          disabled: !dflash,
        })}
      `)}
      ${group("资源", `
        ${fieldRow("内存上限", "--max-memory", "maxMemory", tuningValue(draft, "maxMemory", ""), { placeholder: "自动" })}
        ${fieldRow("上下文长度", "--max-context", "maxContext", tuningValue(draft, "maxContext", ""), { placeholder: "模型默认" })}
        ${toggleRow("仅语言模型", "跳过视觉与多模态准备", "languageOnly", Boolean(tuningValue(draft, "languageOnly", false)), false)}
        ${toggleRow("空闲时保留权重", "关闭空闲释放", "idleReleaseOff", Boolean(tuningValue(draft, "idleReleaseOff", false)), false)}
        ${fieldRow("n-gram 缓存", "--ple-memory", "pleMemory", pleMemory, { placeholder: "自动" })}
        ${toggleRow("n-gram 表固定 SSD", "减少常驻内存", "pleSSDOffload", Boolean(tuningValue(draft, "pleSSDOffload", true)), true, Boolean(pleMemory))}
      `)}
      ${group("思考", fieldRow("思考截断", "留空表示不限制", "thinkingBudget", tuningValue(draft, "thinkingBudget", ""), {
        type: "number",
        min: 0,
        max: 131072,
        step: 256,
        placeholder: "不限制",
      }))}`;
  }

  function omlxFields(draft) {
    const mtp = Boolean(tuningValue(draft, "mtp", true));
    const dflash = Boolean(tuningValue(draft, "dflash", false));
    return `
      ${group("投机解码", `
        ${toggleRow("MTP", "与 DFlash2 互斥", "mtp", mtp, false)}
        ${fieldRow("MTP 深度", "留空自适应", "mtpDepth", tuningValue(draft, "mtpDepth", ""), {
          type: "number",
          min: 1,
          max: 16,
          step: 1,
          placeholder: "自适应",
          disabled: !mtp,
        })}
        ${toggleRow("DFlash2", "开启后自动关闭 MTP", "dflash", dflash, false)}
      `, "oMLX 按模型保存，两项不能同时开启。")}
      ${group("资源", toggleRow("PLE n-gram 表卸载到 SSD", "显存不足时自动启用", "pleSSDOffload", Boolean(tuningValue(draft, "pleSSDOffload", true)), true))}
      ${group("思考", fieldRow("思考截断", "留空表示不限制", "thinkingBudget", tuningValue(draft, "thinkingBudget", ""), {
        type: "number",
        min: 0,
        max: 131072,
        step: 256,
        placeholder: "不限制",
      }))}`;
  }

  function mtplxFields(draft) {
    const mtp = Boolean(tuningValue(draft, "mtp", true));
    return `
      ${group("MTP", `
        ${toggleRow("启用 MTP", "多 token 预测", "mtp", mtp, true)}
        ${toggleRow("启动时加载 MTP 权重", "--load-mtp", "loadMtp", Boolean(tuningValue(draft, "loadMtp", true)), true, !mtp)}
        ${fieldRow("量化位数", "--mtp-quant-bits", "mtpQuantBits", tuningValue(draft, "mtpQuantBits", ""), {
          type: "number",
          min: 2,
          max: 16,
          step: 1,
          placeholder: "引擎默认",
          disabled: !mtp,
        })}
      `)}
      ${group("思考", fieldRow("思考截断", "留空表示不限制", "thinkingBudget", tuningValue(draft, "thinkingBudget", ""), {
        type: "number",
        min: 0,
        max: 131072,
        step: 256,
        placeholder: "不限制",
      }))}`;
  }

  function specificFields(adapter, draft) {
    if (adapter === "splash") return splashFields(draft);
    if (adapter === "omlx") return omlxFields(draft);
    if (adapter === "mtplx") return mtplxFields(draft);
    return group("运行时", `<p class="fc-engine-config-note">该引擎由运行时自行管理，可在高级项追加启动参数。</p>`);
  }

  function configPanelMarkup(stateInput, draftInput) {
    const state = normalizeState(stateInput);
    const engines = engineList(state);
    const id = resolvedEngineId(state, engines[0]);
    const engine = engines.find((item) => item.id === id) || engines[0];
    if (!engine) return "";

    const fallbackDraft = engineDraft(state, id);
    const draft = !draftInput
      ? fallbackDraft
      : draftInput.tuning || draftInput.port != null
        ? { tuning: draftInput.tuning || {}, port: draftInput.port }
        : { tuning: draftInput, port: fallbackDraft.port };
    const info = engineInfo(state, id);
    const installed = installedFor(engine);
    const running = runningFor(state, engine);
    const port = draft.port ?? info.port ?? engine.port ?? "";
    const modelDir = info.modelsDir || info.modelDir || engine.modelsDir || `~/Library/Application Support/flashCat/models/${id}`;
    const logDir = info.logsDir || info.logDir || engine.logDir || `~/Library/Logs/flashCat/${id}`;
    const versions = Array.isArray(info.versions) ? info.versions : [];
    const version = versions[versions.length - 1] || engine.version || "";

    return `<aside class="fc-engine-panel" aria-label="${esc(id)} 配置">
      <header class="fc-engine-panel-head">
        <span class="fc-engine-mark" style="--fc-engine-accent:${esc(engine.color)}">${esc(engine.glyph || id.slice(0, 1))}</span>
        <span class="fc-engine-panel-title">
          <small>RUNTIME CONFIG</small>
          <h2>${esc(id)}</h2>
        </span>
        ${statusMarkup(state, engine)}
        <button class="fc-engine-panel-close" type="button" data-act="closeConfig" data-engine-config-close aria-label="关闭配置">
          ${icon("x", 14)}
        </button>
      </header>
      <div class="fc-engine-panel-scroll">
        ${group("基础", `
          ${fieldRow("端口", `${installed ? `已安装 v${version}` : "尚未安装"}${running ? " · 运行中" : ""}`, "port", port, {
            type: "number",
            min: 1,
            max: 65535,
            placeholder: "8000",
            disabled: running,
          })}
          ${directoryRow("模型目录", "权重与草稿模型", modelDir, "engineModels", id)}
          ${directoryRow("日志目录", "启动命令与运行输出", logDir, "engineLogs", id)}
        `)}
        ${specificFields(engine.adapter, draft)}
        ${group("高级", fieldRow("额外参数", "按空格切分，支持引号", "extraArguments", tuningValue(draft, "extraArguments", ""), {
          placeholder: "--no-webui --queue-size 8",
          wide: true,
        }))}
      </div>
      <footer class="fc-engine-panel-foot">
        <button class="fc-engine-panel-cancel" type="button" data-act="closeConfig">取消</button>
        <button class="fc-engine-panel-save" type="button" data-act="saveEngineConfig">
          ${icon("check", 13)}<span>保存配置</span>
        </button>
      </footer>
    </aside>`;
  }

  function render(stateInput) {
    const state = normalizeState(stateInput);
    const engines = engineList(state);
    const openId = state.engineConfigOpen || state.configEngine || "";
    const panelOpen = Boolean(openId);
    const draft = panelOpen ? state.engineConfigDraft || state.configDraft : null;

    return `<section class="fc-engine-workspace ${panelOpen ? "fc-engine-workspace-panel-open" : ""}" data-fc-engine-workspace>
      <div class="fc-engine-main">
        ${summary(state, engines)}
        <div class="fc-engine-card-stack">
          ${engines.map((engine, index) => engineCard(state, engine, index)).join("")}
        </div>
      </div>
      ${panelOpen ? configPanelMarkup({ ...state, engineConfigOpen: openId }, draft) : ""}
    </section>`;
  }

  window.FCEngineWorkspace = {
    render,
    configPanelMarkup,
  };
}());
