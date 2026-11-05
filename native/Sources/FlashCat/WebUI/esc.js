// esc.js — 全局唯一的 HTML 转义实现（阶段 2 收敛：此前有 8 份各不相同的副本）。
// 转义 &, <, >, " 和 ' 五个实体：前三个是 HTML 正文上下文必需，后两个在
// 属性上下文必需——本控制台的大量模板串都在拼接属性值。旧副本大多漏掉
// '，统一版补齐；对正文上下文无害。

var ENTITIES = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" };
export function esc(value) {
  return String(value == null ? "" : value).replace(/[&<>"']/g, function (char) {
    return ENTITIES[char];
  });
}
