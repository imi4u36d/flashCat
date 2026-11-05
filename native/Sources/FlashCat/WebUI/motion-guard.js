/*
 * FCMotionGuard
 *
 * A non-invasive motion utility for the flashCat preview.
 * It owns animation lifecycle only and never binds page-specific actions.
 *
 * Suggested load order:
 *   overlay-bounds.js -> motion-guard.js -> app.js
 *
 * API:
 *   FCMotionGuard.fadeSwap(container, commit, options)
 *   FCMotionGuard.exit(target, options)
 *   FCMotionGuard.pulse(target, options)
 *   FCMotionGuard.observeTruthy(selector, options)
 *   FCMotionGuard.prefersReducedMotion()
 */


var VERSION = "1.0.0";
var EASE_OUT = "cubic-bezier(.16, 1, .3, 1)";
var EASE_IN = "cubic-bezier(.4, 0, 1, 1)";
var sequence = 0;
var swapTokens = new WeakMap();
var swapAnimations = new WeakMap();

function resolveElement(value) {
  if (!value) return null;
  if (value instanceof Element) return value;
  if (typeof value === "string") return document.querySelector(value);
  if (value.current) return resolveElement(value.current);
  return null;
}

function prefersReducedMotion() {
  return Boolean(
    window.matchMedia &&
    window.matchMedia("(prefers-reduced-motion: reduce)").matches
  );
}

function numberOption(value, fallback) {
  var number = Number(value);
  return Number.isFinite(number) ? number : fallback;
}

function normalizeOptions(options) {
  options = options || {};
  return {
    durationOut: numberOption(options.durationOut, 90),
    durationIn: numberOption(options.durationIn, 220),
    distance: numberOption(options.distance, 3),
    easingOut: options.easingOut || EASE_IN,
    easingIn: options.easingIn || EASE_OUT,
    className: options.className || "fc-motion-swapping"
  };
}

function settle(animation) {
  if (!animation) return Promise.resolve();
  return animation.finished.catch(function () {});
}

function cancelOwnedAnimation(element) {
  var animation = swapAnimations.get(element);
  if (!animation) return;
  try {
    animation.cancel();
  } catch (error) {
    // The animation may already have finished.
  }
  swapAnimations.delete(element);
}

async function fadeSwap(container, commit, options) {
  var element = resolveElement(container);
  if (typeof commit !== "function") {
    throw new TypeError("FCMotionGuard.fadeSwap requires a commit function.");
  }

  if (!element) return commit();

  var settings = normalizeOptions(options);
  var token = ++sequence;
  swapTokens.set(element, token);
  cancelOwnedAnimation(element);

  if (
    prefersReducedMotion() ||
    typeof element.animate !== "function"
  ) {
    return commit();
  }

  element.classList.add(settings.className);
  var outgoing = element.animate(
    [
      { opacity: 1, translate: "0 0" },
      { opacity: .72, translate: "0 -" + settings.distance + "px" }
    ],
    {
      duration: settings.durationOut,
      easing: settings.easingOut,
      fill: "both"
    }
  );
  swapAnimations.set(element, outgoing);
  await settle(outgoing);

  if (swapTokens.get(element) !== token) return undefined;

  var result;
  try {
    result = await commit();
  } catch (error) {
    element.classList.remove(settings.className);
    if (swapTokens.get(element) === token) {
      element.animate(
        [
          { opacity: .72, translate: "0 -" + settings.distance + "px" },
          { opacity: 1, translate: "0 0" }
        ],
        {
          duration: settings.durationIn,
          easing: settings.easingIn,
          fill: "none"
        }
      );
    }
    throw error;
  }

  if (swapTokens.get(element) !== token) return result;

  var incoming = element.animate(
    [
      { opacity: .72, translate: "0 " + settings.distance + "px" },
      { opacity: 1, translate: "0 0" }
    ],
    {
      duration: settings.durationIn,
      easing: settings.easingIn,
      fill: "both"
    }
  );
  swapAnimations.set(element, incoming);
  await settle(incoming);

  if (swapTokens.get(element) === token) {
    element.classList.remove(settings.className);
    swapAnimations.delete(element);
    swapTokens.delete(element);
  }

  return result;
}

async function exit(target, options) {
  var element = resolveElement(target);
  if (!element) return false;

  var settings = Object.assign({
    duration: 150,
    distance: 6,
    easing: EASE_IN,
    remove: false,
    hide: false
  }, options || {});

  if (
    prefersReducedMotion() ||
    typeof element.animate !== "function"
  ) {
    if (settings.hide) element.hidden = true;
    if (settings.remove === true) element.remove();
    if (typeof settings.remove === "function") settings.remove(element);
    return true;
  }

  var animation = element.animate(
    [
      { opacity: 1, translate: "0 0", scale: 1 },
      {
        opacity: 0,
        translate: "0 -" + settings.distance + "px",
        scale: .985
      }
    ],
    {
      duration: settings.duration,
      easing: settings.easing,
      fill: "forwards"
    }
  );

  await settle(animation);
  if (settings.hide) element.hidden = true;
  if (settings.remove === true) element.remove();
  if (typeof settings.remove === "function") settings.remove(element);
  return true;
}

function pulse(target, options) {
  var element = resolveElement(target);
  if (
    !element ||
    prefersReducedMotion() ||
    typeof element.animate !== "function"
  ) {
    return Promise.resolve(false);
  }

  var settings = Object.assign({
    duration: 260,
    scale: .97,
    brightness: 1.06
  }, options || {});

  var animation = element.animate(
    [
      { scale: 1, filter: "brightness(1)" },
      {
        scale: settings.scale,
        filter: "brightness(" + settings.brightness + ")"
      },
      { scale: 1, filter: "brightness(1)" }
    ],
    {
      duration: settings.duration,
      easing: EASE_OUT,
      fill: "none"
    }
  );

  return animation.finished.then(
    function () { return true; },
    function () { return false; }
  );
}

function isTruthyVisible(element) {
  if (!(element instanceof Element) || !element.isConnected || element.hidden) {
    return false;
  }
  if (element.getAttribute("aria-hidden") === "true") return false;
  var style = window.getComputedStyle(element);
  return (
    style.display !== "none" &&
    style.visibility !== "hidden" &&
    style.opacity !== "0"
  );
}

function animateEnter(element, options, index) {
  if (!element || !isTruthyVisible(element)) return;
  if (typeof element.animate !== "function") return;

  var settings = Object.assign({
    duration: 240,
    distance: 4,
    delay: 0,
    stagger: 0,
    scale: .995
  }, options || {});

  element.animate(
    [
      {
        opacity: 0,
        translate: "0 " + settings.distance + "px",
        scale: settings.scale
      },
      { opacity: 1, translate: "0 0", scale: 1 }
    ],
    {
      duration: settings.duration,
      delay: settings.delay + index * settings.stagger,
      easing: EASE_OUT,
      fill: "none"
    }
  );
}

function observeTruthy(selector, options) {
  if (!selector) {
    throw new TypeError("FCMotionGuard.observeTruthy requires a selector.");
  }

  var settings = Object.assign({
    root: document,
    initial: true,
    animation: {}
  }, options || {});
  var root = resolveElement(settings.root) || document;
  var seen = new WeakSet();
  var disconnected = false;

  function scan(scope) {
    if (disconnected) return;
    var host = scope instanceof Element ? scope : document;
    var matches = [];
    if (host.matches && host.matches(selector)) matches.push(host);
    if (host.querySelectorAll) {
      matches.push.apply(matches, host.querySelectorAll(selector));
    }
    matches.forEach(function (element, index) {
      if (seen.has(element) || !isTruthyVisible(element)) return;
      seen.add(element);
      animateEnter(element, settings.animation, index);
    });
  }

  function syncSeen(scope) {
    var host = scope instanceof Element ? scope : document;
    var matches = [];
    if (host.matches && host.matches(selector)) matches.push(host);
    if (host.querySelectorAll) {
      matches.push.apply(matches, host.querySelectorAll(selector));
    }
    matches.forEach(function (element) {
      if (!isTruthyVisible(element)) seen.delete(element);
    });
  }

  if (settings.initial) {
    window.requestAnimationFrame(function () {
      scan(root);
    });
  }

  var observer = new MutationObserver(function (records) {
    records.forEach(function (record) {
      if (record.type === "attributes") {
        if (isTruthyVisible(record.target)) scan(record.target);
        else seen.delete(record.target);
        return;
      }

      record.addedNodes.forEach(function (node) {
        if (node.nodeType === Node.ELEMENT_NODE) scan(node);
      });
      record.removedNodes.forEach(function (node) {
        if (node.nodeType === Node.ELEMENT_NODE) seen.delete(node);
      });
      syncSeen(root);
    });
  });

  observer.observe(root, {
    childList: true,
    subtree: true,
    attributes: true,
    attributeFilter: ["class", "style", "hidden", "aria-hidden"]
  });

  return {
    refresh: function () {
      scan(root);
    },
    disconnect: function () {
      disconnected = true;
      observer.disconnect();
    }
  };
}

export const FCMotionGuard = Object.freeze({
  version: VERSION,
  fadeSwap: fadeSwap,
  exit: exit,
  pulse: pulse,
  observeTruthy: observeTruthy,
  prefersReducedMotion: prefersReducedMotion
});
