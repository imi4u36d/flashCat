/*
 * flashCat · chat thinking selector
 *
 * Standalone markup, positioning and dismissal for the chat page's thinking
 * level picker. This file deliberately does not call cmd() or mutate settings.
 *
 * Integration:
 *   HTML:  ${window.FCChatThinking.trigger(state)}
 *   Open:  window.FCChatThinking.open(triggerElement, state)
 *   State: window.FCChatThinking.update(state)
 *   Close: window.FCChatThinking.close()
 *
 * Choice attributes:
 *   data-fc-thinking-kind="mode"   data-fc-thinking-value="automatic|off|on"
 *   data-fc-thinking-kind="effort" data-fc-thinking-value="minimal|low|..."
 */
(function () {
  "use strict";

  if (window.FCChatThinking) return;

  var MODES = [
    {
      value: "automatic",
      label: "自动",
      detail: "跟随模型的聊天模板",
      icon: "rotate"
    },
    {
      value: "off",
      label: "关闭",
      detail: "直接回答，不做隐藏推理",
      icon: "circleX"
    },
    {
      value: "on",
      label: "开启",
      detail: "使用指定的推理等级",
      icon: "brain"
    }
  ];

  var EFFORTS = [
    { value: "minimal", label: "最少" },
    { value: "low", label: "低" },
    { value: "medium", label: "中" },
    { value: "high", label: "高" },
    { value: "xhigh", label: "极高" },
    { value: "max", label: "最大" }
  ];

  var DEFAULTS = {
    boundary: ".window",
    align: "start",
    gap: 10,
    padding: 10,
    width: 304,
    minWidth: 252,
    maxHeight: 560,
    portal: null,
    id: "fc-thinking-menu",
    className: ""
  };

  var sequence = 0;
  var active = null;
  var globalListenersReady = false;

  function escapeHTML(value) {
    return String(value == null ? "" : value)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  function icon(name, size) {
    if (window.FCIcons && typeof window.FCIcons.svg === "function") {
      return window.FCIcons.svg(name, "", size || 14);
    }
    return '<svg class="fc-thinking-fallback-icon" viewBox="0 0 24 24" width="' +
      (size || 14) + '" height="' + (size || 14) +
      '" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' +
      '<path d="M12 3a4 4 0 0 0-4 4v1a4 4 0 0 0 0 8v1a4 4 0 0 0 8 0v-1a4 4 0 0 0 0-8V7a4 4 0 0 0-4-4Z"/>' +
      '<path d="M12 8v8"/></svg>';
  }

  function clamp(value, min, max) {
    if (max < min) return min;
    return Math.min(max, Math.max(min, value));
  }

  function finite(value, fallback) {
    var number = Number(value);
    return Number.isFinite(number) ? number : fallback;
  }

  function sourceState(state) {
    if (!state || typeof state !== "object") return {};
    if (state.settings && typeof state.settings === "object") return state.settings;
    if (state.params && typeof state.params === "object") {
      return {
        thinkingMode: state.params.thinking,
        reasoningEfforts: state.reasoningEfforts,
        reasoningEffort: state.reasoningEffort
      };
    }
    return state;
  }

  function modeFrom(value) {
    var key = String(value == null ? "" : value).toLowerCase();
    if (key === "automatic" || key === "auto" || key === "自动") return "automatic";
    if (key === "off" || key === "none" || key === "关闭") return "off";
    if (key === "on" || key === "开启") return "on";
    return "automatic";
  }

  function effortDefinition(value) {
    var key = String(value == null ? "" : value).toLowerCase();
    for (var i = 0; i < EFFORTS.length; i += 1) {
      if (EFFORTS[i].value === key) return EFFORTS[i];
    }
    return { value: key || "medium", label: key || "中" };
  }

  function optionList(raw) {
    var list = Array.isArray(raw) ? raw : [];
    var seen = Object.create(null);
    var normalized = [];

    list.forEach(function (item) {
      var value = typeof item === "string" ? item : item && (item.value || item.id);
      if (value == null || value === "") return;
      var key = String(value).toLowerCase();
      if (seen[key]) return;
      seen[key] = true;
      normalized.push({
        value: key,
        label: typeof item === "string"
          ? effortDefinition(key).label
          : String(item.label || item.name || effortDefinition(key).label)
      });
    });

    return normalized.length ? normalized : EFFORTS.slice();
  }

  function normalize(state, options) {
    var source = sourceState(state);
    var settings = options || {};
    var mode = modeFrom(
      source.thinkingMode != null ? source.thinkingMode :
        source.thinking != null ? source.thinking :
          source.mode
    );
    var efforts = optionList(
      source.reasoningEfforts ||
      source.efforts ||
      settings.efforts
    );
    var rawEffort = String(
      source.reasoningEffort != null ? source.reasoningEffort :
        source.effort != null ? source.effort :
          "medium"
    ).toLowerCase();
    var effort = efforts.some(function (item) { return item.value === rawEffort; })
      ? rawEffort
      : (efforts[2] || efforts[0]).value;
    var modeMeta = MODES.filter(function (item) { return item.value === mode; })[0];
    var effortMeta = efforts.filter(function (item) { return item.value === effort; })[0];

    return {
      mode: mode,
      modeLabel: source.thinkingModeLabel || modeMeta.label,
      efforts: efforts,
      effort: effort,
      effortLabel: source.reasoningEffortLabel || effortMeta.label,
      displayLabel: mode === "on"
        ? (source.reasoningEffortLabel || effortMeta.label)
        : (source.thinkingModeLabel || modeMeta.label)
    };
  }

  function menuOptions(options) {
    var merged = {};
    Object.keys(DEFAULTS).forEach(function (key) { merged[key] = DEFAULTS[key]; });
    Object.keys(options || {}).forEach(function (key) { merged[key] = options[key]; });
    return merged;
  }

  function modeMarkup(model) {
    return MODES.map(function (mode, index) {
      var checked = mode.value === model.mode;
      return '<button class="fc-thinking-mode' + (checked ? ' fc-thinking-mode-active' : '') +
        '" type="button" role="menuitemradio" aria-checked="' + (checked ? "true" : "false") +
        '" data-fc-thinking-kind="mode" data-fc-thinking-value="' + escapeHTML(mode.value) +
        '" style="--fc-thinking-index:' + index + '">' +
        '<span class="fc-thinking-mode-icon">' + icon(mode.icon, 14) + '</span>' +
        '<span class="fc-thinking-mode-copy"><strong>' + escapeHTML(mode.label) +
        '</strong><small>' + escapeHTML(mode.detail) + '</small></span>' +
        '<span class="fc-thinking-check" aria-hidden="true">' +
        (checked ? icon("check", 13) : "") + '</span></button>';
    }).join("");
  }

  function effortMarkup(model) {
    if (model.mode !== "on") return "";

    return '<section class="fc-thinking-efforts" aria-labelledby="fc-thinking-efforts-label">' +
      '<div class="fc-thinking-section-head">' +
      '<span id="fc-thinking-efforts-label">推理等级</span><small>开启时生效</small></div>' +
      '<div class="fc-thinking-effort-grid" role="group" aria-label="推理等级">' +
      model.efforts.map(function (effort, index) {
        var checked = effort.value === model.effort;
        var strength = model.efforts.length > 1 ? index / (model.efforts.length - 1) : 1;
        var bars = [0, 1, 2, 3].map(function (bar) {
          var lit = strength >= (bar / 3);
          return '<i class="fc-thinking-meter-bar' + (lit ? " fc-thinking-meter-lit" : "") + '"></i>';
        }).join("");

        return '<button class="fc-thinking-effort' + (checked ? " fc-thinking-effort-active" : "") +
          '" type="button" role="menuitemradio" aria-checked="' + (checked ? "true" : "false") +
          '" data-fc-thinking-kind="effort" data-fc-thinking-value="' + escapeHTML(effort.value) +
          '" style="--fc-thinking-index:' + (index + 3) + '">' +
          '<span class="fc-thinking-effort-label">' + escapeHTML(effort.label) + '</span>' +
          '<span class="fc-thinking-meter" aria-hidden="true">' + bars + '</span>' +
          '</button>';
      }).join("") +
      '</div></section>';
  }

  function contentMarkup(model) {
    return '<header class="fc-thinking-head">' +
      '<span class="fc-thinking-head-icon">' + icon("brain", 16) + '</span>' +
      '<span class="fc-thinking-head-copy"><strong>思考级别</strong><small>' +
      (model.mode === "on" ? "手动指定推理深度" : "当前 · " + escapeHTML(model.displayLabel)) +
      '</small></span>' +
      '<span class="fc-thinking-status' + (model.mode === "on" ? " fc-thinking-status-on" : "") +
      '" aria-hidden="true"><i></i>' + (model.mode === "on" ? "ON" : "AUTO") + '</span>' +
      '</header>' +
      '<div class="fc-thinking-scroll">' +
      '<section class="fc-thinking-modes" aria-label="思考模式">' + modeMarkup(model) + '</section>' +
      effortMarkup(model) +
      '</div>';
  }

  function trigger(state, options) {
    var model = normalize(state, options);
    var attrs = options && options.attributes ? " " + options.attributes : "";
    var extraClass = options && options.className ? " " + options.className : "";

    return '<button type="button" class="fc-thinking-trigger' + extraClass +
      '" data-fc-thinking-trigger data-fc-thinking-mode="' + model.mode +
      '" aria-haspopup="menu" aria-expanded="false"' + attrs + '>' +
      '<span class="fc-thinking-trigger-icon">' + icon("brain", 13) + '</span>' +
      '<span class="fc-thinking-trigger-text">思考</span>' +
      '<span class="fc-thinking-trigger-value">' + escapeHTML(model.displayLabel) + '</span>' +
      '<span class="fc-thinking-trigger-caret">' + icon("chevronDown", 11) + '</span>' +
      '</button>';
  }

  function menu(state, options) {
    var merged = menuOptions(options);
    var model = normalize(state, options);
    var panel = document.createElement("div");
    var id = merged.id || "fc-thinking-menu-" + (++sequence);

    panel.id = id;
    panel.className = "fc-thinking-menu" + (merged.className ? " " + merged.className : "");
    panel.setAttribute("role", "menu");
    panel.setAttribute("aria-label", "思考级别");
    panel.setAttribute("data-fc-thinking-menu", "");
    panel.setAttribute("data-fc-thinking-mode", model.mode);
    panel.innerHTML = contentMarkup(model);
    return panel;
  }

  function boundaryElement(value) {
    if (value && value.nodeType === 1) return value;
    if (value && value.current) return boundaryElement(value.current);
    if (typeof value === "string") return document.querySelector(value);
    return document.querySelector(".window") || document.documentElement;
  }

  function viewportRect() {
    if (window.visualViewport) {
      return {
        left: window.visualViewport.offsetLeft,
        top: window.visualViewport.offsetTop,
        right: window.visualViewport.offsetLeft + window.visualViewport.width,
        bottom: window.visualViewport.offsetTop + window.visualViewport.height,
        width: window.visualViewport.width,
        height: window.visualViewport.height
      };
    }
    return {
      left: 0,
      top: 0,
      right: window.innerWidth,
      bottom: window.innerHeight,
      width: window.innerWidth,
      height: window.innerHeight
    };
  }

  function boundsFor(options) {
    var padding = finite(options.padding, DEFAULTS.padding);
    var boundary = boundaryElement(options.boundary);
    var rect = boundary === document.documentElement
      ? viewportRect()
      : boundary.getBoundingClientRect();
    var viewport = viewportRect();
    var left = Math.max(rect.left, viewport.left) + padding;
    var top = Math.max(rect.top, viewport.top) + padding;
    var right = Math.min(rect.right, viewport.right) - padding;
    var bottom = Math.min(rect.bottom, viewport.bottom) - padding;

    return {
      left: left,
      top: top,
      right: Math.max(left, right),
      bottom: Math.max(top, bottom),
      width: Math.max(0, right - left),
      height: Math.max(0, bottom - top)
    };
  }

  function position() {
    if (!active || !active.panel || !active.anchor) return;
    if (!active.anchor.isConnected) {
      close();
      return;
    }

    var panel = active.panel;
    var anchor = active.anchor;
    var options = active.options;
    var bounds = boundsFor(options);
    var anchorRect = anchor.getBoundingClientRect();
    var gap = finite(options.gap, DEFAULTS.gap);
    var preferredWidth = finite(options.width, DEFAULTS.width);
    var minWidth = Math.min(finite(options.minWidth, DEFAULTS.minWidth), bounds.width);
    var width = clamp(preferredWidth, minWidth, bounds.width);
    var maxHeight = Math.max(120, Math.min(finite(options.maxHeight, DEFAULTS.maxHeight), bounds.height));

    panel.style.width = Math.round(width) + "px";
    panel.style.maxHeight = Math.round(maxHeight) + "px";

    var panelRect = panel.getBoundingClientRect();
    var panelHeight = Math.min(panelRect.height, maxHeight);
    var roomAbove = anchorRect.top - bounds.top - gap;
    var roomBelow = bounds.bottom - anchorRect.bottom - gap;
    var side = "top";
    var top = anchorRect.top - gap - panelHeight;

    if (roomAbove < panelHeight && roomBelow >= panelHeight) {
      side = "bottom";
      top = anchorRect.bottom + gap;
    } else if (roomAbove < panelHeight && roomBelow > roomAbove) {
      side = "bottom";
      top = anchorRect.bottom + gap;
    }

    top = clamp(top, bounds.top, bounds.bottom - panelHeight);

    var align = options.align === "end" || options.align === "center"
      ? options.align
      : "start";
    var left = anchorRect.left;
    if (align === "end") left = anchorRect.right - width;
    if (align === "center") left = anchorRect.left + (anchorRect.width - width) / 2;
    left = clamp(left, bounds.left, bounds.right - width);

    panel.style.left = Math.round(left) + "px";
    panel.style.top = Math.round(top) + "px";
    panel.dataset.fcThinkingSide = side;
    panel.style.setProperty("--fc-thinking-origin-x", Math.round(clamp(anchorRect.left + anchorRect.width / 2 - left, 20, width - 20)) + "px");
    panel.style.setProperty("--fc-thinking-origin-y", side === "top" ? Math.round(panelHeight - 10) + "px" : "10px");
  }

  function close(options) {
    if (!active) return;
    var closing = active;
    active = null;
    if (closing.anchor) {
      closing.anchor.setAttribute("aria-expanded", "false");
      closing.anchor.classList.remove("fc-thinking-trigger-active");
    }
    var finish = function () {
      if (closing.panel && closing.panel.parentNode) {
        closing.panel.parentNode.removeChild(closing.panel);
      }
      if (!options || options.restoreFocus !== false) {
        if (closing.anchor && closing.anchor.isConnected && closing.anchor.focus) {
          closing.anchor.focus({ preventScroll: true });
        }
      }
    };
    if (
      closing.panel &&
      !prefersReducedMotion() &&
      typeof closing.panel.animate === "function"
    ) {
      closing.panel.animate(
        [
          { opacity: 1, transform: "translateY(0) scale(1)" },
          { opacity: 0, transform: "translateY(5px) scale(.98)" }
        ],
        { duration: 140, easing: "cubic-bezier(.4, 0, 1, 1)", fill: "forwards" }
      ).finished.then(finish, finish);
    } else {
      finish();
    }
  }

  function prefersReducedMotion() {
    return Boolean(
      window.matchMedia &&
      window.matchMedia("(prefers-reduced-motion: reduce)").matches
    );
  }

  function outsideClick(event) {
    if (!active) return;
    if (active.panel && active.panel.contains(event.target)) return;
    if (active.anchor && active.anchor.contains(event.target)) return;
    if (event.target && event.target.closest && event.target.closest("[data-fc-thinking-menu]")) return;
    close();
  }

  function onKeydown(event) {
    if (!active || event.key !== "Escape") return;
    event.preventDefault();
    event.stopPropagation();
    close();
  }

  function prepareGlobalListeners() {
    if (globalListenersReady) return;
    globalListenersReady = true;
    document.addEventListener("click", outsideClick, false);
    document.addEventListener("keydown", onKeydown, true);
    window.addEventListener("resize", position, { passive: true });
    window.addEventListener("scroll", position, true);
    if (window.visualViewport) {
      window.visualViewport.addEventListener("resize", position, { passive: true });
      window.visualViewport.addEventListener("scroll", position, { passive: true });
    }
  }

  function open(anchor, state, options) {
    var target = typeof anchor === "string" ? document.querySelector(anchor) : anchor;
    if (!target) return null;
    if (active && active.anchor === target) return active.panel;

    close({ restoreFocus: false });
    prepareGlobalListeners();

    var merged = menuOptions(options);
    var panel = menu(state, merged);
    panel.style.visibility = "hidden";
    panel.style.opacity = "0";
    (merged.portal ? boundaryElement(merged.portal) : document.body).appendChild(panel);

    active = {
      anchor: target,
      panel: panel,
      options: merged
    };

    target.setAttribute("aria-expanded", "true");
    target.classList.add("fc-thinking-trigger-active");
    position();

    requestAnimationFrame(function () {
      if (!active || active.panel !== panel) return;
      panel.style.visibility = "";
      panel.style.opacity = "";
      panel.classList.add("fc-thinking-menu-visible");
      var checked = panel.querySelector('[aria-checked="true"]');
      (checked || panel).focus({ preventScroll: true });
    });

    return panel;
  }

  function update(state, options) {
    if (!active) return;
    var merged = active.options;
    if (options) {
      Object.keys(options).forEach(function (key) { merged[key] = options[key]; });
    }

    var focused = document.activeElement;
    var focusedKind = focused && focused.getAttribute && focused.getAttribute("data-fc-thinking-kind");
    var focusedValue = focused && focused.getAttribute && focused.getAttribute("data-fc-thinking-value");
    var model = normalize(state, merged);
    var panel = active.panel;

    panel.dataset.fcThinkingMode = model.mode;
    panel.innerHTML = contentMarkup(model);
    position();

    if (focusedKind && focusedValue) {
      var next = panel.querySelector(
        '[data-fc-thinking-kind="' + focusedKind + '"][data-fc-thinking-value="' + focusedValue + '"]'
      );
      if (next) next.focus({ preventScroll: true });
    }
  }

  function isOpen() {
    return !!(active && active.panel && active.panel.isConnected);
  }

  window.FCChatThinking = {
    trigger: trigger,
    menu: menu,
    open: open,
    close: close,
    update: update,
    position: position,
    isOpen: isOpen,
    MODES: MODES.map(function (item) { return { value: item.value, label: item.label }; }),
    EFFORTS: EFFORTS.map(function (item) { return { value: item.value, label: item.label }; })
  };
}());
