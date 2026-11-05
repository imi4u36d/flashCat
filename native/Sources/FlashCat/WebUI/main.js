// main.js — 打包入口（`make webui-build` 用 esbuild 从这里开始打包）。
//
// 职责只有一个：确定模块求值顺序。import 按依赖展开后，实际求值顺序与旧的
// <script> 标签顺序一致——叶子组件先于状态层，app.js 先于 live.js（app.js
// import live.js 构成循环依赖，ESM 按「先完成依赖方」的规则解析，而两个文件
// 的求值期外部引用都为 0，所有跨模块调用都发生在事件回调里，TDZ 安全已经
// 用分析器实证过，见 docs/reviews 附录 C）。
//
// Swift 桥面（WebViewShell.swift 的 evaluateJavaScript 只调用这些）：
//   window.__fc__.push / stream / setSidebar   — 快照、流式 token、侧栏专线
//   window.__fcToast                            — 原生通知
// 渲染测试台（WebUIRenderCheck）读取：
//   window.__fcErrors / __fcErrorDetails        — 控制台错误收集
// 这五个名字由 live.js 显式挂在 window 上，是整个控制台仅有的全局面；
// 除此之外不再有任何 window.X = 接线。
import "./esc.js";
import "./icons.js";
import "./overview-components.js";
import "./model-brand.js";
import "./model-workspace.js";
import "./engine-workspace.js";
import "./chat-thinking.js";
import "./overlay-bounds.js";
import "./motion-guard.js";
import "./chat-markdown.js";
import "./chat-stream.js";
import "./segments.js";
import "./live.js";
import "./app.js";
