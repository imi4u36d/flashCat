/* flashCat · sliding segments
   一组切换按钮共用一块滑块：位置、尺寸都按真实按钮量出来，切换时从旧位置
   滑到新位置，而不是整块淡入淡出。原来三套各写一遍的 index 计算（模型页
   用 translateX(index * 100%)、日志页用 left/width、设置页用另一套）在这里
   合成一套，宽度不等的按钮组（全部 / 提示 / 警告 / 错误）也能对齐。

   接入方式：按钮组带 data-fc-segments，或落在这几个类名里 —— 模型页的
   .fc-model-engine-switch、.filter-pills、.settings-segmented、.segmented、
   .engine-tabs。缺滑块时自动补一块 .fc-seg-slider，样式按所在组件决定。 */

const GROUPS = [
  "[data-fc-segments]",
  ".fc-model-engine-switch",
  ".filter-pills",
  ".settings-segmented",
  ".segmented",
  ".engine-tabs",
].join(", ");

const ACTIVE = "button.active, button.fc-model-filter-button-active, [role='tab'][aria-selected='true']";
// 只认直接子元素：将来按钮组套按钮组时，别把里层的滑块量到外层的组上。
const SLIDERS = ["fc-seg-slider", "segment-indicator", "segment-slider", "engine-tab-indicator", "fc-model-filter-indicator"]
  .map((name) => `:scope > .${name}`)
  .join(", ");
const GLIDE_MS = 380;

const ready = new WeakSet();
const reduced = () => window.matchMedia("(prefers-reduced-motion: reduce)").matches;

function groupOf(node) {
  return node && node.closest ? node.closest(GROUPS) : null;
}

function sliderOf(group) {
  let slider = group.querySelector(SLIDERS);
  if (!slider) {
    slider = document.createElement("span");
    slider.setAttribute("aria-hidden", "true");
    group.appendChild(slider);
  }
  // 老滑块各有自己的视觉类（.segment-indicator 等），统一再挂上 .fc-seg-slider
  // 才吃得到共用那套定位；否则它会被当成网格/弹性子项，把工具栏挤变形。
  slider.classList.add("fc-seg-slider");
  // 滑块自己就是那块「选中」背景，按钮不再各画一个，否则点击时会闪两下。
  group.classList.add("sliding-segments");
  return slider;
}

// 量按钮而不是算 index：按钮宽度不一样（带计数的日志筛选）时也不会错位。
function paint(group, { animate = true } = {}) {
  const slider = sliderOf(group);
  const active = group.querySelector(ACTIVE);
  if (!active || !active.offsetWidth) {
    slider.style.opacity = "0";
    return;
  }

  const settled = ready.has(group);
  if (!settled) slider.classList.add("is-static");

  // 换页/首帧时直接落位，别让滑块从 0 宽长出来；之后的切换才走动画。
  slider.style.setProperty("--seg-x", `${active.offsetLeft}px`);
  slider.style.setProperty("--seg-y", `${active.offsetTop}px`);
  slider.style.setProperty("--seg-w", `${active.offsetWidth}px`);
  slider.style.setProperty("--seg-h", `${active.offsetHeight}px`);
  slider.style.setProperty("--seg-r", window.getComputedStyle(active).borderRadius);
  slider.style.opacity = "1";

  if (settled) {
    if (animate && !reduced()) glide(slider);
  } else {
    ready.add(group);
    requestAnimationFrame(() => {
      slider.classList.remove("is-static");
    });
  }
}

// 滑动时把阴影轻轻提一点，停下再落回去：滑块看起来是「抬起来移动」，
// 而不是整块淡入淡出。用 timeout 兜底，免得 transitionend 没触发时卡住。
function glide(slider) {
  slider.classList.add("is-gliding");
  clearTimeout(slider._glideTimer);
  slider._glideTimer = setTimeout(() => slider.classList.remove("is-gliding"), GLIDE_MS);
}

function paintAll({ animate = true } = {}) {
  document.querySelectorAll(GROUPS).forEach((group) => paint(group, { animate }));
}

function refresh(root) {
  if (root && root.matches && root.matches(GROUPS)) paint(root);
  const scope = root && root.querySelectorAll ? root : document;
  scope.querySelectorAll(GROUPS).forEach((group) => paint(group));
}

// 尺寸变了（窗口缩放、侧栏展开、字体变化）要重排，但不该看到滑块缓慢爬过去。
const sizes = new ResizeObserver((entries) => {
  entries.forEach((entry) => {
    const group = entry.target;
    const slider = group.querySelector(SLIDERS);
    if (!slider) return;
    slider.classList.add("is-static");
    paint(group, { animate: false });
    requestAnimationFrame(() => slider.classList.remove("is-static"));
  });
});

// 换页会整块重建 DOM，旧的按钮组已经从文档里摘掉了：ResizeObserver 会一直
// 攥着它们不放，所以留一份强引用集合，扫描时顺手把断开的摘掉。
const watched = new Set();
function watch(group) {
  sliderOf(group);
  if (watched.has(group)) return;
  watched.add(group);
  sizes.observe(group);
}

function prune() {
  watched.forEach((group) => {
    if (group.isConnected) return;
    sizes.unobserve(group);
    watched.delete(group);
  });
}

// 点击只会改按钮的 class：这里统一接住，谁切了 active 就重画谁，
// 各个页面不用再各写一遍 updateXxxIndicator。直接在观察回调里量、直接改，
// 让过渡从下一帧就开始；再等一个 rAF 会白白慢半拍。

let structural = 0;
function scheduleScan() {
  if (structural) return;
  structural = requestAnimationFrame(() => {
    structural = 0;
    prune();
    document.querySelectorAll(GROUPS).forEach(watch);
    paintAll({ animate: false });
  });
}

function boot() {
  document.querySelectorAll(GROUPS).forEach((group) => {
    paint(group, { animate: false });
    watch(group);
  });

  const observer = new MutationObserver((records) => {
    const touched = new Set();
    records.forEach((record) => {
      // 只看按钮自己的 class/aria 变化；滑块和容器上我们自己也加 class，
      // 一起看会自激成死循环。
      if (record.type === "attributes" && record.target.matches && record.target.matches("button, [role='tab'], [role='radio']")) {
        const group = groupOf(record.target);
        if (group) touched.add(group);
        return;
      }
      if (record.type === "childList" && (record.addedNodes.length || record.removedNodes.length)) {
        scheduleScan();
      }
    });
    touched.forEach((group) => {
      if (!group.isConnected) return;
      watch(group);
      paint(group);
    });
  });
  observer.observe(document.body, {
    subtree: true,
    childList: true,
    attributes: true,
    attributeFilter: ["class", "aria-selected"],
  });

  if (document.fonts && document.fonts.ready) document.fonts.ready.then(scheduleScan);
  window.addEventListener("resize", scheduleScan, { passive: true });
}

export const FCSegments = { refresh, paint, paintAll, groups: () => document.querySelectorAll(GROUPS) };

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", boot, { once: true });
} else {
  boot();
}
