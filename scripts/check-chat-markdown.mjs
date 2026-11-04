#!/usr/bin/env node
/*
 * Contract checks for WebUI/chat-markdown.js.
 *
 * The renderer is the only place where model output becomes DOM, so the parts
 * worth pinning are the safe ones: raw HTML never survives, unsafe URL schemes
 * never become links, remote images are never fetched, and the block parser
 * keeps its shape while a stream is still mid-sentence.
 *
 *   node scripts/check-chat-markdown.mjs
 */
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const source = fs.readFileSync(
  path.join(root, "native", "Sources", "FlashCat", "WebUI", "chat-markdown.js"),
  "utf8"
);
const sandbox = { window: {} };
vm.createContext(sandbox);
vm.runInContext(source, sandbox, { filename: "chat-markdown.js" });
const md = sandbox.window.FCChatMarkdown;

assert.ok(md, "chat-markdown.js should expose FCChatMarkdown");

// ---- escaping -------------------------------------------------------------
const dangerous = md.render('<img src=x onerror="alert(1)"> <script>alert(2)</script>');
assert.ok(!dangerous.includes("<img"), "raw <img> must be escaped");
assert.ok(!dangerous.includes("<script"), "raw <script> must be escaped");
assert.ok(dangerous.includes("&lt;script&gt;"), "escaped text should stay visible");

// ---- links ----------------------------------------------------------------
const unsafe = md.render("[点我](javascript:alert(1))");
assert.ok(!unsafe.includes('href="javascript:'), "javascript: URLs must not become hrefs");
assert.ok(unsafe.includes("javascript:alert(1)"), "the rejected URL stays as text");

const safe = md.render("[文档](https://example.com/a?b=1&c=2)");
assert.ok(safe.includes('href="https://example.com/a?b=1&amp;c=2"'), "https links are kept and escaped");
assert.ok(safe.includes('rel="noreferrer noopener"'), "external links do not leak the opener");

// ---- remote images are placeholders --------------------------------------
const image = md.render("![架构图](https://example.com/a.png)");
assert.ok(!image.includes("<img"), "images must not be fetched");
assert.ok(image.includes("架构图"), "the alt text remains readable");

// ---- blocks ---------------------------------------------------------------
assert.match(md.render("# 标题"), /<h1 class="md-h"[^>]*>标题<\/h1>/);
assert.match(md.render("```js\nconst a = 1;\n```"), /data-lang="js"[\s\S]*const a = 1;/);
assert.match(md.render("```js\nconst a = 1;"), /md-pre is-open/, "an unclosed fence stays a code block");
assert.match(md.render("- a\n  - b"), /<ul class="md-list">[\s\S]*<ul class="md-list">[\s\S]*<\/ul><\/li><\/ul>/, "nested lists keep their shape");
assert.match(md.render("- a\n  - b"), /data-md-line="0:l0"/, "list items carry a line key for the reveal");
assert.match(md.render("- [x] 完成\n- [ ] 未完成"), /md-check is-done/);
assert.match(md.render("1. 一\n2. 二"), /<ol class="md-list is-ordered">/);
assert.match(md.render("| a | b |\n| :--- | ---: |\n| 1 | 2 |"), /text-align:left/);
assert.match(md.render("> 引用"), /<blockquote class="md-quote">/);
assert.match(md.render("---"), /<hr class="md-rule"[^>]*>/);
assert.match(md.render("**粗** 与 `code`"), /<strong>粗<\/strong>/);

// ---- streaming shapes -----------------------------------------------------
for (const prefix of ["**未闭合", "| 表头 |", "```", "- 列", "[链接](", "## 标题"]) {
  assert.doesNotThrow(() => md.render(prefix), `streaming prefix should not throw: ${prefix}`);
}
assert.match(md.render("**未闭合"), /<p class="md-p"[^>]*>\*\*未闭合<\/p>/, "an unfinished emphasis stays literal");
assert.match(md.render("| 表头 |"), /<p class="md-p"[^>]*>\| 表头 \|<\/p>/, "a header without its separator is still a paragraph");

// ---- line markers for staggered reveal -----------------------------------
const marked = md.render("第一行\n第二行\n第三行");
assert.match(marked, /data-md-line="0:p0"/, "a single-line paragraph is one reveal line");
assert.match(marked, /class="md-line" data-md-line="0:p1"/, "a multi-line paragraph wraps each line");
assert.equal((marked.match(/data-md-line=/g) || []).length, 3, "one marker per paragraph line");
assert.ok(!marked.includes("<br>"), "block lines replace the old <br> when a paragraph wraps");
assert.match(md.render("| a | b |\n| :--- | ---: |\n| 1 | 2 |"), /data-md-line="0:r1"/, "table rows are reveal lines");
assert.match(md.render("# 标题"), /data-md-line="0:h"/, "a heading is a reveal line");
// Static and streaming markup must agree on the keys, or a patch would replay
// the reveal on every frame.
assert.equal(md.render("第一行\n第二行"), md.render("第一行\n第二行"), "line keys are deterministic");

console.log("chat-markdown: all checks passed");
