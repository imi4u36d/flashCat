import React from "react";
import { createRoot } from "react-dom/client";
import App from "./App";
import "./tokens.css";
import "./app.css";

/* 主题必须在第一次绘制之前落到 <html> 上：否则 React 挂载后翻转 data-theme，
   整棵树的 color/background 会走一遍 180ms 过渡，首屏会出现半帧「深色文字在浅色底上」的闪。
   真实 Tauri 壳里这里读的是 shell 主题（跟随系统或用户设置）。 */
const params = new URLSearchParams(location.search);
const ua = navigator.userAgent;
const platform = /Android/i.test(ua)
  ? "android"
  : /iPhone|iPad|iPod/i.test(ua)
    ? "ios"
    : /Macintosh/i.test(ua)
      ? "macos"
      : /Windows/i.test(ua)
        ? "windows"
        : "linux";
const mobile = platform === "android" || platform === "ios" || window.innerWidth <= 760;
const systemLight = window.matchMedia("(prefers-color-scheme: light)").matches;

/* 手机上外观跟随系统：Android 的 edge-to-edge 状态栏图标颜色也跟系统走，
   应用自己另存一套深浅色就会出现「浅色背景 + 白色图标」。桌面保留手动切换。 */
const initial =
  params.get("theme") === "light"
    ? "light"
    : params.get("theme") === "dark"
      ? "dark"
      : mobile
        ? systemLight
          ? "light"
          : "dark"
        : localStorage.getItem("flashcat.theme") === "light"
          ? "light"
          : "dark";
document.documentElement.dataset.theme = initial;

/* 窗口圆角与透明背景只在 Tauri 里生效：
   decorations=false 的自绘窗口需要 html/body 透明，圆角才不会被裁成直角。
   浏览器预览保持不透明画布。 */
if ("__TAURI_INTERNALS__" in window) document.documentElement.dataset.shell = "tauri";

/* 平台判定要在首帧前完成，否则手机上会先闪一帧桌面布局：
   UA 是同步可得的（WebView 里 UA 一定带 Android / iPhone），
   之后 App 再拿 bridge.info() 的真实平台做校正。
   移动端与窄窗口走同一套抽屉式布局。 */
document.documentElement.dataset.platform = platform;
if (mobile) document.documentElement.dataset.mobile = "true";

/* 键盘占位：Android 的 edge-to-edge 与 iOS 的 WebView 都不会替我们压缩布局，
   键盘只是盖在上面。visualViewport 是唯一能拿到「被键盘吃掉多少」的地方，
   量出来写进 --kb，移动端布局据此让出高度。 */
function trackKeyboard() {
  const vv = window.visualViewport;
  if (!vv) return;
  const sync = () => {
    const kb = Math.max(0, Math.min(420, window.innerHeight - vv.height - vv.offsetTop));
    document.documentElement.style.setProperty("--kb", `${Math.round(kb)}px`);
  };
  vv.addEventListener("resize", sync);
  vv.addEventListener("scroll", sync);
  sync();
}
trackKeyboard();

createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>
);
