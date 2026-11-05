/*
 * FCOverlayBounds
 *
 * Keeps floating panels inside the visible flashCat window.
 * The helper owns layout only. It never binds application actions.
 *
 * Basic usage:
 *   window.FCOverlayBounds.place(anchorElement, panelElement, {
 *     boundary: "#window",
 *     preferredSide: "bottom",
 *     align: "start",
 *     gap: 8,
 *     padding: 12
 *   });
 */


var DEFAULTS = {
  boundary: "auto",
  preferredSide: "bottom",
  align: "start",
  gap: 8,
  padding: 12,
  flip: true,
  clamp: true,
  matchAnchorWidth: false,
  minWidth: 0,
  maxWidth: Infinity,
  maxHeight: Infinity,
  minHeight: 0,
  scroll: true,
  observe: true,
  animate: false,
  setTransformOrigin: true
};

var SIDE_OPPOSITE = {
  bottom: "top",
  top: "bottom",
  left: "right",
  right: "left"
};

var registrations = new Map();
var originalStyles = new WeakMap();
var resizeObserver = null;
var mutationObserver = null;
var observedBoundaries = new WeakSet();
var observedAnchors = new WeakSet();
var frameId = 0;
var listenersReady = false;
var destroyed = false;
var settleUntil = 0;

function resolveElement(value) {
  if (!value) return null;
  if (value instanceof Element) return value;
  if (typeof value === "string") return document.querySelector(value);
  if (value && value.current) return resolveElement(value.current);
  return null;
}

function clamp(value, min, max) {
  if (max < min) return min;
  return Math.min(max, Math.max(min, value));
}

function finiteNumber(value, fallback) {
  var number = Number(value);
  return Number.isFinite(number) ? number : fallback;
}

function normalizePadding(value) {
  if (typeof value === "number") {
    return { top: value, right: value, bottom: value, left: value };
  }

  value = value || {};
  return {
    top: finiteNumber(value.top, 0),
    right: finiteNumber(value.right, finiteNumber(value.horizontal, 0)),
    bottom: finiteNumber(value.bottom, 0),
    left: finiteNumber(value.left, finiteNumber(value.horizontal, 0))
  };
}

function normalizeSide(value) {
  return Object.prototype.hasOwnProperty.call(SIDE_OPPOSITE, value)
    ? value
    : DEFAULTS.preferredSide;
}

function normalizeAlign(value) {
  return value === "center" || value === "end" ? value : "start";
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

function intersectRects(a, b) {
  var left = Math.max(a.left, b.left);
  var top = Math.max(a.top, b.top);
  var right = Math.min(a.right, b.right);
  var bottom = Math.min(a.bottom, b.bottom);

  return {
    left: left,
    top: top,
    right: right,
    bottom: bottom,
    width: Math.max(0, right - left),
    height: Math.max(0, bottom - top)
  };
}

function insetRect(rect, padding) {
  return {
    left: rect.left + padding.left,
    top: rect.top + padding.top,
    right: rect.right - padding.right,
    bottom: rect.bottom - padding.bottom,
    width: Math.max(0, rect.width - padding.left - padding.right),
    height: Math.max(0, rect.height - padding.top - padding.bottom)
  };
}

function resolveBoundary(options) {
  var requested = options.boundary;

  if (requested === "window") requested = ".window";
  if (requested === "content" || requested === "content-shell") requested = ".content-shell";

  if (requested !== "auto") {
    return resolveElement(requested) || resolveElement(".window") || document.documentElement;
  }

  return resolveElement(".window") || resolveElement(".content-shell") || document.documentElement;
}

function getBoundaryRect(boundary, padding) {
  var raw = boundary === document.documentElement
    ? viewportRect()
    : boundary.getBoundingClientRect();

  return insetRect(intersectRects(raw, viewportRect()), padding);
}

function snapshotStyles(panel) {
  if (originalStyles.has(panel)) return originalStyles.get(panel);

  var style = panel.style;
  var snapshot = {
    position: style.position,
    left: style.left,
    top: style.top,
    right: style.right,
    bottom: style.bottom,
    width: style.width,
    margin: style.margin,
    minWidth: style.minWidth,
    maxWidth: style.maxWidth,
    minHeight: style.minHeight,
    maxHeight: style.maxHeight,
    overflowX: style.overflowX,
    overflowY: style.overflowY,
    transform: style.transform,
    transformOrigin: style.transformOrigin
  };

  originalStyles.set(panel, snapshot);
  return snapshot;
}

function restoreStyle(panel, property, value) {
  if (value) panel.style[property] = value;
  else panel.style.removeProperty(property.replace(/[A-Z]/g, function (char) {
    return "-" + char.toLowerCase();
  }));
}

function measurePanel(panel, targetWidth) {
  var style = panel.style;
  var computed = window.getComputedStyle(panel);
  var previous = {
    display: style.display,
    visibility: style.visibility,
    width: style.width,
    maxHeight: style.maxHeight,
    minHeight: style.minHeight,
    transform: style.transform
  };
  var displayWasNone = computed.display === "none";

  if (displayWasNone) {
    style.display = "block";
    style.visibility = "hidden";
  }

  panel.classList.add("fc-bounds-measuring");
  style.width = targetWidth > 0 ? targetWidth + "px" : computed.width;
  style.maxHeight = "none";
  style.minHeight = "0";
  style.transform = "none";

  var rect = panel.getBoundingClientRect();
  var result = {
    width: Math.max(0, rect.width),
    height: Math.max(0, rect.height),
    scrollHeight: panel.scrollHeight,
    scrollWidth: panel.scrollWidth
  };

  restoreStyle(panel, "display", previous.display);
  restoreStyle(panel, "visibility", previous.visibility);
  restoreStyle(panel, "width", previous.width);
  restoreStyle(panel, "maxHeight", previous.maxHeight);
  restoreStyle(panel, "minHeight", previous.minHeight);
  restoreStyle(panel, "transform", previous.transform);
  panel.classList.remove("fc-bounds-measuring");

  return result;
}

function intrinsicPanelSize(panel, options) {
  var style = panel.style;
  var computed = window.getComputedStyle(panel);
  var previous = {
    display: style.display,
    visibility: style.visibility,
    maxHeight: style.maxHeight,
    minHeight: style.minHeight,
    transform: style.transform
  };
  var displayWasNone = computed.display === "none";

  if (displayWasNone) {
    style.display = "block";
    style.visibility = "hidden";
  }

  panel.classList.add("fc-bounds-measuring");
  style.maxHeight = "none";
  style.minHeight = "0";
  style.transform = "none";

  var rect = panel.getBoundingClientRect();
  var result = {
    width: Math.max(0, rect.width),
    height: Math.max(0, rect.height)
  };

  restoreStyle(panel, "display", previous.display);
  restoreStyle(panel, "visibility", previous.visibility);
  restoreStyle(panel, "maxHeight", previous.maxHeight);
  restoreStyle(panel, "minHeight", previous.minHeight);
  restoreStyle(panel, "transform", previous.transform);
  panel.classList.remove("fc-bounds-measuring");

  return result;
}

function sideSpaces(anchorRect, bounds, gap) {
  return {
    bottom: {
      width: bounds.width,
      height: Math.max(0, bounds.bottom - anchorRect.bottom - gap)
    },
    top: {
      width: bounds.width,
      height: Math.max(0, anchorRect.top - bounds.top - gap)
    },
    right: {
      width: Math.max(0, bounds.right - anchorRect.right - gap),
      height: bounds.height
    },
    left: {
      width: Math.max(0, anchorRect.left - bounds.left - gap),
      height: bounds.height
    }
  };
}

function candidateSides(preferredSide, flip) {
  if (!flip) return [preferredSide];
  return [preferredSide, SIDE_OPPOSITE[preferredSide]];
}

function chooseSide(sides, naturalSize, available, maxWidth, maxHeight) {
  for (var index = 0; index < sides.length; index += 1) {
    var side = sides[index];
    var space = available[side];
    var widthFits = Math.min(naturalSize.width, maxWidth) <= space.width + 0.5;
    var heightFits = Math.min(naturalSize.height, maxHeight) <= space.height + 0.5;

    if (widthFits && heightFits) {
      return { side: side, constrained: false };
    }
  }

  var vertical = sides[0] === "top" || sides[0] === "bottom";
  var fallback = sides.reduce(function (best, side) {
    var distance = vertical ? available[side].height : available[side].width;
    var bestDistance = vertical ? available[best].height : available[best].width;
    return distance > bestDistance ? side : best;
  }, sides[0]);

  return { side: fallback, constrained: true };
}

function alignedPosition(side, align, anchorRect, width, height) {
  var left;
  var top;

  if (side === "top" || side === "bottom") {
    if (align === "center") {
      left = anchorRect.left + anchorRect.width / 2 - width / 2;
    } else if (align === "end") {
      left = anchorRect.right - width;
    } else {
      left = anchorRect.left;
    }
    top = side === "bottom" ? anchorRect.bottom : anchorRect.top - height;
  } else {
    if (align === "center") {
      top = anchorRect.top + anchorRect.height / 2 - height / 2;
    } else if (align === "end") {
      top = anchorRect.bottom - height;
    } else {
      top = anchorRect.top;
    }
    left = side === "right" ? anchorRect.right : anchorRect.left - width;
  }

  return { left: left, top: top };
}

function setImportantStyles(panel) {
  panel.style.setProperty("position", "fixed");
  panel.style.setProperty("right", "auto");
  panel.style.setProperty("bottom", "auto");
  panel.style.setProperty("margin", "0");
}

function applyPanelLayout(panel, layout, options) {
  setImportantStyles(panel);

  var style = panel.style;
  style.left = layout.left + "px";
  style.top = layout.top + "px";
  style.width = layout.width + "px";
  style.minWidth = "0";
  style.maxWidth = layout.maxWidth + "px";
  style.maxHeight = layout.maxHeight === Infinity ? "none" : layout.maxHeight + "px";
  style.minHeight = options.minHeight > 0
    ? Math.min(options.minHeight, layout.maxHeight) + "px"
    : "0";
  style.overflowY = layout.scrollY ? "auto" : "";
  style.overflowX = layout.scrollY ? "hidden" : "";

  if (options.setTransformOrigin) {
    var x = clamp(layout.anchorX - layout.left, 0, layout.width);
    var y = layout.side === "bottom"
      ? 0
      : layout.side === "top"
        ? layout.height
        : clamp(layout.anchorY - layout.top, 0, layout.height);
    style.transformOrigin = x + "px " + y + "px";
  }

  panel.style.setProperty("--fc-bounds-anchor-x", layout.anchorX - layout.left + "px");
  panel.style.setProperty("--fc-bounds-anchor-y", layout.anchorY - layout.top + "px");
  panel.style.setProperty("--fc-bounds-available-height", layout.availableHeight + "px");
  panel.style.setProperty("--fc-bounds-available-width", layout.availableWidth + "px");

  panel.classList.add("fc-bounds-managed", "fc-bounds-panel");
  panel.classList.toggle("fc-bounds-side-top", layout.side === "top");
  panel.classList.toggle("fc-bounds-side-bottom", layout.side === "bottom");
  panel.classList.toggle("fc-bounds-side-left", layout.side === "left");
  panel.classList.toggle("fc-bounds-side-right", layout.side === "right");
  panel.classList.toggle("fc-bounds-flipped", layout.flipped);
  panel.classList.toggle("fc-bounds-constrained", layout.constrained);
  panel.classList.toggle("fc-bounds-scroll-y", layout.scrollY);
  panel.classList.toggle("fc-bounds-animated", options.animate);

  panel.dataset.fcBoundsSide = layout.side;
  panel.dataset.fcBoundsFlipped = String(layout.flipped);
  panel.dataset.fcBoundsConstrained = String(layout.constrained);
}

function computeLayout(anchor, panel, options) {
  var boundary = resolveBoundary(options);
  if (!boundary || !anchor.isConnected || !panel.isConnected) return null;

  var padding = normalizePadding(options.padding);
  var bounds = getBoundaryRect(boundary, padding);
  var anchorRect = anchor.getBoundingClientRect();

  if (bounds.width <= 0 || bounds.height <= 0) return null;

  var natural = intrinsicPanelSize(panel, options);
  var baseWidth = options.matchAnchorWidth ? anchorRect.width : natural.width;
  if (Number.isFinite(options.width) && options.width > 0) baseWidth = options.width;
  baseWidth = Math.max(baseWidth, options.minWidth);
  baseWidth = Math.min(baseWidth, options.maxWidth, bounds.width);

  var measured = measurePanel(panel, baseWidth);
  var naturalSize = {
    width: Math.min(baseWidth, Math.max(measured.width, baseWidth)),
    height: Math.max(measured.height, measured.scrollHeight)
  };
  var gap = Math.max(0, finiteNumber(options.gap, DEFAULTS.gap));
  var maxWidth = Math.min(bounds.width, options.maxWidth);
  var maxHeight = Math.min(bounds.height, options.maxHeight);
  var available = sideSpaces(anchorRect, bounds, gap);
  var preferredSide = normalizeSide(options.preferredSide);
  var sides = candidateSides(preferredSide, options.flip);
  var choice = chooseSide(sides, naturalSize, available, maxWidth, maxHeight);
  var side = choice.side;
  var sideSpace = available[side];
  var vertical = side === "top" || side === "bottom";
  var width = vertical
    ? Math.min(naturalSize.width, sideSpace.width, maxWidth)
    : Math.min(naturalSize.width, sideSpace.width, maxWidth);
  var height = vertical
    ? Math.min(naturalSize.height, sideSpace.height, maxHeight)
    : Math.min(naturalSize.height, sideSpace.height, maxHeight);

  var minimumHeight = Math.min(options.minHeight, sideSpace.height, maxHeight);
  height = Math.max(minimumHeight > 0 ? minimumHeight : 0, height);

  var position = alignedPosition(side, normalizeAlign(options.align), anchorRect, width, height);
  var left = position.left;
  var top = position.top;

  if (options.clamp) {
    left = clamp(left, bounds.left, bounds.right - width);
    top = clamp(top, bounds.top, bounds.bottom - height);
  }

  var constrained = height + 0.5 < naturalSize.height || width + 0.5 < naturalSize.width;
  var scrollY = options.scroll && constrained && height + 0.5 < naturalSize.height;
  var anchorX = anchorRect.left + anchorRect.width / 2;
  var anchorY = anchorRect.top + anchorRect.height / 2;

  return {
    side: side,
    flipped: side !== preferredSide,
    constrained: constrained,
    scrollY: scrollY,
    left: left,
    top: top,
    width: width,
    height: height,
    maxWidth: maxWidth,
    maxHeight: height,
    availableWidth: sideSpace.width,
    availableHeight: sideSpace.height,
    anchorX: anchorX,
    anchorY: anchorY,
    anchorRect: anchorRect,
    boundaryRect: bounds,
    boundary: boundary
  };
}

function sameLayout(panel, layout) {
  if (!layout) return false;
  var style = panel.style;
  return style.left === layout.left + "px"
    && style.top === layout.top + "px"
    && style.width === layout.width + "px"
    && style.maxHeight === (layout.maxHeight === Infinity ? "none" : layout.maxHeight + "px")
    && panel.dataset.fcBoundsSide === layout.side
    && panel.dataset.fcBoundsConstrained === String(layout.constrained);
}

function place(anchorValue, panelValue, incomingOptions) {
  var anchor = resolveElement(anchorValue);
  var panel = resolveElement(panelValue);
  if (!anchor || !panel) return null;

  var options = Object.assign({}, DEFAULTS, incomingOptions || {});
  options.preferredSide = normalizeSide(options.preferredSide);
  options.align = normalizeAlign(options.align);
  snapshotStyles(panel);

  var existing = registrations.get(panel);
  if (existing) {
    existing.panel = panel;
    existing.anchor = anchor;
    existing.options = options;
  } else {
    registrations.set(panel, { panel: panel, anchor: anchor, options: options });
  }

  if (options.observe) observeLayout();

  var layout = computeLayout(anchor, panel, options);
  if (!layout) return null;

  applyPanelLayout(panel, layout, options);
  return layout;
}

function repositionOne(entry) {
  var anchor = entry.anchor;
  var options = entry.options;
  var boundary = resolveBoundary(options);

  if (boundary && options.observe) {
    observeBoundary(boundary);
  }

  var layout = computeLayout(anchor, entry.panel, options);
  if (!layout) return null;
  if (!sameLayout(entry.panel, layout)) applyPanelLayout(entry.panel, layout, options);
  return layout;
}

function reposition(panelValue) {
  if (panelValue) {
    var panel = resolveElement(panelValue);
    var entry = panel && registrations.get(panel);
    return entry ? repositionOne(entry) : null;
  }

  var results = [];
  registrations.forEach(function (entry, panel) {
    if (!entry.anchor.isConnected || !panel.isConnected) {
      registrations.delete(panel);
      return;
    }
    var layout = repositionOne(entry);
    if (layout) results.push(layout);
  });
  return results;
}

function scheduleReposition() {
  if (frameId) return;
  frameId = window.requestAnimationFrame(function () {
    frameId = 0;
    if (!destroyed && registrations.size) reposition();
    if (!destroyed && registrations.size && performance.now() < settleUntil) {
      scheduleReposition();
    }
  });
}

function settleLayout(duration) {
  settleUntil = Math.max(settleUntil, performance.now() + duration);
  scheduleReposition();
}

function isInsideManagedPanel(target) {
  if (!(target instanceof Node)) return false;
  var element = target.nodeType === Node.ELEMENT_NODE ? target : target.parentElement;
  return Boolean(element && element.closest(".fc-bounds-managed"));
}

function handleDocumentScroll(event) {
  if (!isInsideManagedPanel(event.target)) scheduleReposition();
}

function handlePointerMove() {
  if (document.body.classList.contains("sidebar-resizing")) scheduleReposition();
}

// The window sheen follows the mouse by writing --pointer-x/--pointer-y onto
// #window on every pointer move. Those are paint-only custom properties, but
// the style mutation still reached the observer below and started a 500ms
// reposition loop. Each pass re-measured the open panel, which restarted its
// entrance animation frame after frame: the dropdown flickered at its 0%
// keyframe (clipped and transparent) until the pointer stopped. Ignore
// mutations that only move the sheen spotlight.
function stripPointerSheen(styleText) {
  return String(styleText || "")
    .replace(/--pointer-[xy]\s*:[^;]*;?/g, "")
    .replace(/\s+/g, " ")
    .replace(/^\s+|\s+$/g, "");
}

function isPointerSheenMutation(record) {
  if (record.attributeName !== "style") return false;
  var target = record.target;
  if (!(target instanceof Element) || target.id !== "window") return false;
  return stripPointerSheen(record.oldValue) === stripPointerSheen(target.getAttribute("style"));
}

function handleWindowResize() {
  settleLayout(420);
}

function handlePointerRelease() {
  settleLayout(420);
}

function observeBoundary(boundary) {
  if (!resizeObserver || observedBoundaries.has(boundary)) return;
  observedBoundaries.add(boundary);
  resizeObserver.observe(boundary);
}

function observePanelEntry(entry, panel) {
  if (!resizeObserver) return;
  observeBoundary(resolveBoundary(entry.options));

  if (!observedAnchors.has(entry.anchor)) {
    observedAnchors.add(entry.anchor);
    resizeObserver.observe(entry.anchor);
  }

  resizeObserver.observe(panel);
}

function observeLayout() {
  if (!listenersReady) {
    listenersReady = true;

    if (window.ResizeObserver) {
      resizeObserver = new ResizeObserver(scheduleReposition);
      registrations.forEach(function (entry, panel) {
        observePanelEntry(entry, panel);
      });
    }

    if (window.MutationObserver) {
      mutationObserver = new MutationObserver(function (records) {
        var layoutChanged = records.some(function (record) {
          return !isPointerSheenMutation(record);
        });
        if (layoutChanged) settleLayout(500);
      });
      [document.documentElement, document.body, document.querySelector(".window"), document.querySelector(".sidebar"), document.querySelector(".content-shell")]
        .filter(Boolean)
        .forEach(function (target) {
          mutationObserver.observe(target, {
            attributes: true,
            attributeOldValue: true,
            attributeFilter: ["class", "style"]
          });
        });
    }

    window.addEventListener("resize", handleWindowResize, { passive: true });
    document.addEventListener("scroll", handleDocumentScroll, true);
    window.addEventListener("pointermove", handlePointerMove, { passive: true });
    window.addEventListener("pointerup", handlePointerRelease, { passive: true });
    window.addEventListener("pointercancel", handlePointerRelease, { passive: true });

    if (window.visualViewport) {
      window.visualViewport.addEventListener("resize", handleWindowResize, { passive: true });
      window.visualViewport.addEventListener("scroll", handleWindowResize, { passive: true });
    }
  }

  registrations.forEach(function (entry, panel) {
    if (entry.options.observe) observePanelEntry(entry, panel);
  });
}

function restorePanel(panel) {
  var snapshot = originalStyles.get(panel);
  if (!snapshot) return;

  Object.keys(snapshot).forEach(function (property) {
    restoreStyle(panel, property, snapshot[property]);
  });
  originalStyles.delete(panel);
}

// 退出动画期间只需要「别再跟着锚点跑」，还不能动已经量好的位置和会改变
// 内容宽度的滚动条类。freeze 只摘掉注册，clear 才负责把样式还回去。
function freeze(panelValue) {
  var panels = panelValue ? [resolveElement(panelValue)] : Array.from(registrations.keys());

  panels.filter(Boolean).forEach(function (panel) {
    registrations.delete(panel);
    observedAnchors = new WeakSet();
    if (resizeObserver) resizeObserver.unobserve(panel);
  });

  if (!registrations.size && frameId) {
    window.cancelAnimationFrame(frameId);
    frameId = 0;
  }
}

function clear(panelValue, clearOptions) {
  var shouldRestore = !clearOptions || clearOptions.restore !== false;
  var panels = panelValue ? [resolveElement(panelValue)] : Array.from(registrations.keys());

  panels.filter(Boolean).forEach(function (panel) {
    registrations.delete(panel);
    observedAnchors = new WeakSet();
    if (resizeObserver) resizeObserver.unobserve(panel);
    panel.classList.remove(
      "fc-bounds-managed",
      "fc-bounds-panel",
      "fc-bounds-side-top",
      "fc-bounds-side-bottom",
      "fc-bounds-side-left",
      "fc-bounds-side-right",
      "fc-bounds-flipped",
      "fc-bounds-constrained",
      "fc-bounds-scroll-y",
      "fc-bounds-animated",
      "fc-bounds-measuring"
    );
    delete panel.dataset.fcBoundsSide;
    delete panel.dataset.fcBoundsFlipped;
    delete panel.dataset.fcBoundsConstrained;
    ["--fc-bounds-anchor-x", "--fc-bounds-anchor-y", "--fc-bounds-available-height", "--fc-bounds-available-width"]
      .forEach(function (property) {
        panel.style.removeProperty(property);
      });
    if (shouldRestore) restorePanel(panel);
  });
}

function measure(boundaryValue, options) {
  var boundary = resolveElement(boundaryValue) || resolveBoundary(Object.assign({}, DEFAULTS, options || {}));
  if (!boundary) return null;
  return getBoundaryRect(boundary, normalizePadding((options || {}).padding || DEFAULTS.padding));
}

function destroy() {
  destroyed = true;
  clear(null, { restore: true });

  if (frameId) {
    window.cancelAnimationFrame(frameId);
    frameId = 0;
  }

  window.removeEventListener("resize", handleWindowResize);
  document.removeEventListener("scroll", handleDocumentScroll, true);
  window.removeEventListener("pointermove", handlePointerMove);
  window.removeEventListener("pointerup", handlePointerRelease);
  window.removeEventListener("pointercancel", handlePointerRelease);

  if (window.visualViewport) {
    window.visualViewport.removeEventListener("resize", handleWindowResize);
    window.visualViewport.removeEventListener("scroll", handleWindowResize);
  }

  if (resizeObserver) resizeObserver.disconnect();
  if (mutationObserver) mutationObserver.disconnect();

  resizeObserver = null;
  mutationObserver = null;
  observedBoundaries = new WeakSet();
  observedAnchors = new WeakSet();
  listenersReady = false;
  settleUntil = 0;
  destroyed = false;
}

export const FCOverlayBounds = Object.freeze({
  place: place,
  observe: place,
  reposition: reposition,
  refresh: reposition,
  measure: measure,
  freeze: freeze,
  clear: clear,
  destroy: destroy,
  defaults: Object.freeze(Object.assign({}, DEFAULTS))
});
