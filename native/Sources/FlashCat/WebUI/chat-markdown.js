/*
 * flashCat · chat markdown
 *
 * A small, dependency-free Markdown renderer for the chat page. It renders the
 * common subset models actually emit — headings, paragraphs, fenced code,
 * block quotes, lists (nested + task lists), tables, rules, and inline
 * emphasis / code / links — and it never trusts the source: every byte is
 * escaped first, and only the tags built here reach the DOM.
 *
 * Two entry points:
 *
 *   FCChatMarkdown.render(text)      → full HTML string (finished messages)
 *   FCChatMarkdown.sync(el, text, { streaming })
 *                                    → patch a container in place; unchanged
 *                                      blocks are reused, only the block that
 *                                      grew is re-rendered. This is what makes
 *                                      streaming markdown affordable: a reply
 *                                      that is already 8 000 characters long
 *                                      still costs one small block per frame.
 *
 * Images are not fetched. A remote image inside a local, private conversation
 * would leak a request the reader never asked for, so `![alt](url)` renders as
 * a quiet chip with the alt text instead.
 */
import { esc } from "./esc.js";



function safeUrl(raw) {
  var url = String(raw == null ? "" : raw).trim();
  if (!url) return "";
  // Relative anchors are fine; anything with a scheme must be one of the two
  // a chat link may legitimately use. Everything else (data:, javascript:,
  // file:) renders as plain text instead of a live link.
  if (/^(https?:\/\/|mailto:)/i.test(url)) return url;
  if (/^[#/]/.test(url) && !/^\/\//.test(url)) return url;
  return "";
}

function token(store, html) {
  store.push(html);
  return "\u0000" + (store.length - 1) + "\u0001";
}

function restore(text, store) {
  if (!store.length) return text;
  return text.replace(/\u0000(\d+)\u0001/g, function (match, index) {
    return store[Number(index)] != null ? store[Number(index)] : "";
  });
}

// ---------- inline ----------
// Order matters: escapes and code spans are stashed before emphasis runs, so
// `**not bold**` inside a code span stays literal.
function inline(source) {
  var store = [];
  var text = String(source == null ? "" : source).replace(/\u0000/g, "").replace(/\u0001/g, "");

  text = text.replace(/\\([\\`*_{}\[\]()#+\-.!|>~$])/g, function (match, char) {
    return token(store, esc(char));
  });

  text = esc(text);

  text = text.replace(/`([^`\n]+)`/g, function (match, code) {
    return token(store, '<code class="md-code">' + code + "</code>");
  });

  // ![alt](url "title") — rendered as a chip, never fetched.
  text = text.replace(/!\[([^\]]*)\]\(([^()\s]*(?:\([^()\s]*\)[^()\s]*)*)(?:\s+&quot;[^&]*&quot;)?\)/g, function (match, alt, url) {
    var href = safeUrl(url);
    var label = alt || "图片";
    return token(store, '<span class="md-media" title="' + esc(href || label) + '">' +
      '<i class="md-media-mark" aria-hidden="true"></i>' + label + "</span>");
  });

  text = text.replace(/\[([^\]]+)\]\(([^()\s]*(?:\([^()\s]*\)[^()\s]*)*)(?:\s+&quot;[^&]*&quot;)?\)/g, function (match, label, url) {
    var href = safeUrl(url);
    // An unsafe scheme stays visible as text, never as a live link.
    if (!href) return "[" + label + "](" + url + ")";
    var external = /^https?:\/\//i.test(href);
    return token(store, '<a class="md-link" href="' + href + '"' +
      (external ? ' target="_blank" rel="noreferrer noopener"' : "") + ">" + label + "</a>");
  });

  text = text.replace(/&lt;((?:https?:\/\/|mailto:)[^\s&]+)&gt;/g, function (match, url) {
    return '<a class="md-link" href="' + url + '" target="_blank" rel="noreferrer noopener">' + url + "</a>";
  });

  text = text.replace(/\*\*(?=\S)([\s\S]*?\S)\*\*/g, "<strong>$1</strong>");
  text = text.replace(/__(?=\S)([\s\S]*?\S)__/g, "<strong>$1</strong>");
  text = text.replace(/~~(?=\S)([\s\S]*?\S)~~/g, "<del>$1</del>");
  text = text.replace(/(^|[\s(（["'])\*(?=\S)([^*\n]*?\S)\*(?=$|[\s)）.,!?，。；：、\]"'])/g, "$1<em>$2</em>");
  text = text.replace(/(^|[\s(（["'])_(?=\S)([^_\n]*?\S)_(?=$|[\s)）.,!?，。；：、\]"'])/g, "$1<em>$2</em>");

  return restore(text, store);
}

function inlineBlock(text) {
  // Single newlines inside a paragraph become <br>: chat replies use them as
  // line structure far more often than as soft wraps.
  return inline(text).replace(/\n/g, "<br>");
}

/// A paragraph that has grown past one line gets one block span per line.
/// `sync()` uses those markers to fade in newly arrived lines, staggered,
/// without holding the text back: the characters are already in the DOM and
/// only their opacity is animated, so a fast engine cannot build a backlog.
/// A single-line paragraph keeps the original shape (no wrapper at all).
function paragraphHTML(text, key) {
  var lines = String(text == null ? "" : text).split("\n");
  if (lines.length === 1) {
    return '<p class="md-p" data-md-line="' + key + ':p0">' + inline(text) + "</p>";
  }
  return '<p class="md-p">' + lines.map(function (line, index) {
    return '<span class="md-line" data-md-line="' + key + ":p" + index + '">' +
      inline(line) + "</span>";
  }).join("") + "</p>";
}

// ---------- block helpers ----------
var FENCE = /^ {0,3}(`{3,}|~{3,})\s*([^`\n]*)$/;
var CLOSE_FENCE = /^ {0,3}(`{3,}|~{3,})\s*$/;
var HEADING = /^ {0,3}(#{1,6})\s+(.*?)\s*#*\s*$/;
var RULE = /^ {0,3}(?:(?:\*\s*){3,}|(?:-\s*){3,}|(?:_\s*){3,})$/;
var QUOTE = /^ {0,3}>\s?/;
var LIST_ITEM = /^(\s*)([-*+]|\d{1,9}[.)])\s+(.*)$/;
var TABLE_SEP = /^ {0,3}\|?\s*:?-{2,}:?\s*(?:\|\s*:?-{2,}:?\s*)*\|?\s*$/;

function listMarker(line) {
  return line.match(LIST_ITEM);
}

function isTableSeparator(line) {
  return Boolean(line) && TABLE_SEP.test(line) && line.indexOf("|") >= 0;
}

function splitRow(line) {
  var text = String(line).trim();
  if (text.charAt(0) === "|") text = text.slice(1);
  if (text.charAt(text.length - 1) === "|") text = text.slice(0, -1);
  var cells = [];
  var current = "";
  for (var i = 0; i < text.length; i += 1) {
    var char = text[i];
    if (char === "\\" && text[i + 1] === "|") {
      current += "|";
      i += 1;
    } else if (char === "|") {
      cells.push(current.trim());
      current = "";
    } else {
      current += char;
    }
  }
  cells.push(current.trim());
  return cells;
}

function tableAt(lines, index) {
  if (index + 1 >= lines.length) return null;
  if (lines[index].indexOf("|") < 0) return null;
  if (!isTableSeparator(lines[index + 1])) return null;
  var header = splitRow(lines[index]);
  var separators = splitRow(lines[index + 1]);
  if (!header.length || !separators.length) return null;
  var aligns = separators.map(function (cell) {
    var left = cell.charAt(0) === ":";
    var right = cell.charAt(cell.length - 1) === ":";
    return left && right ? "center" : right ? "right" : left ? "left" : "";
  });
  var rows = [];
  var i = index + 2;
  while (i < lines.length && lines[i].trim() && lines[i].indexOf("|") >= 0) {
    rows.push(splitRow(lines[i]));
    i += 1;
  }
  return { header: header, aligns: aligns, rows: rows, next: i };
}

function startsBlock(lines, index, allowSetext) {
  var line = lines[index];
  if (!line || !line.trim()) return true;
  if (FENCE.test(line) || HEADING.test(line) || RULE.test(line)) return true;
  if (QUOTE.test(line) || listMarker(line)) return true;
  if (tableAt(lines, index)) return true;
  if (allowSetext && index + 1 < lines.length && /^ {0,3}(=+|-+)\s*$/.test(lines[index + 1])) return true;
  return false;
}

function parseList(lines, start) {
  var first = lines[start].match(LIST_ITEM);
  if (!first) return null;
  var baseIndent = first[1].length;
  var ordered = /\d/.test(first[2]);
  var startNumber = ordered ? parseInt(first[2], 10) : 1;
  var items = [];
  var i = start;

  while (i < lines.length) {
    var line = lines[i];
    if (!line.trim()) {
      // A blank line only survives inside a list when what follows is still
      // part of it (indented continuation or the next item at this depth).
      var nextLine = lines[i + 1];
      if (nextLine == null) break;
      var nextItem = nextLine.match(LIST_ITEM);
      if ((nextItem && nextItem[1].length === baseIndent) || /^\s{2,}\S/.test(nextLine)) {
        i += 1;
        continue;
      }
      break;
    }

    var item = line.match(LIST_ITEM);
    if (item && item[1].length <= baseIndent + 1) {
      if (item[1].length < baseIndent) break;
      // Switching between bullets and numbers starts a new list, exactly as
      // CommonMark renders `- a\n1. b` — two lists, not one mixed one.
      if (/^\d/.test(item[2]) !== ordered) break;
      items.push({ text: item[3], sub: [] });
      i += 1;
      continue;
    }

    if (!items.length) break;
    if (item && item[1].length > baseIndent + 1) {
      items[items.length - 1].sub.push(line);
      i += 1;
      continue;
    }
    if (/^\s{2,}\S/.test(line)) {
      items[items.length - 1].text += "\n" + line.trim();
      i += 1;
      continue;
    }
    break;
  }

  return { ordered: ordered, start: startNumber, items: items, next: i };
}

function dedent(lines, spaces) {
  return lines.map(function (line) {
    var index = 0;
    while (index < spaces && (line.charAt(index) === " " || line.charAt(index) === "\t")) index += 1;
    return line.slice(index);
  });
}

function listHTML(list, key) {
  var tag = list.ordered ? "ol" : "ul";
  var start = list.ordered && list.start !== 1 ? ' start="' + list.start + '"' : "";
  var items = list.items.map(function (item, index) {
    var itemKey = key + ":l" + index;
    var text = item.text;
    var task = "";
    var check = text.match(/^\[([ xX])\]\s+(.*)$/);
    if (check) {
      var done = check[1].toLowerCase() === "x";
      task = '<i class="md-check' + (done ? " is-done" : "") + '" aria-hidden="true"></i>';
      text = check[2];
    }
    var sub = "";
    if (item.sub.length) {
      var minimum = Math.min.apply(null, item.sub.filter(function (line) { return line.trim(); })
        .map(function (line) { return line.match(/^\s*/)[0].length; }));
      if (!Number.isFinite(minimum)) minimum = 2;
      sub = renderInner(parse(dedent(item.sub, minimum).join("\n")), itemKey + ":s");
    }
    return '<li data-md-line="' + itemKey + '">' +
      (task ? '<span class="md-task">' + task + "</span>" : "") +
      inlineBlock(text) + sub + "</li>";
  }).join("");
  return "<" + tag + (tag === "ol" ? start : "") + ' class="md-list' + (list.ordered ? " is-ordered" : "") + '">' +
    items + "</" + tag + ">";
}

function blockHTML(block, key) {
  var id = key == null ? "n" : String(key);
  switch (block.type) {
    case "heading":
      return "<h" + block.level + ' class="md-h" data-md-line="' + id + ':h">' +
        inline(block.text) + "</h" + block.level + ">";
    case "code":
      // One marker for the whole code block: splitting <pre> into line spans
      // would break copy/paste of the newlines, and fences are short enough
      // that a single fade reads fine.
      return '<pre class="md-pre' + (block.closed ? "" : " is-open") + '"' +
        (block.lang ? ' data-lang="' + esc(block.lang) + '"' : "") +
        '><code class="md-code-block" data-md-line="' + id + ':c">' +
        esc(block.code) + "</code></pre>";
    case "quote":
      return '<blockquote class="md-quote">' + renderInner(block.children, id + ":q") + "</blockquote>";
    case "list":
      return listHTML(block, id);
    case "rule":
      return '<hr class="md-rule" data-md-line="' + id + ':r">';
    case "table":
      var head = block.header.map(function (cell, index) {
        return '<th' + (block.aligns[index] ? ' style="text-align:' + block.aligns[index] + '"' : "") + ">" +
          inline(cell) + "</th>";
      }).join("");
      var body = block.rows.map(function (row, rowIndex) {
        return '<tr data-md-line="' + id + ":r" + (rowIndex + 1) + '">' +
          block.header.map(function (cell, index) {
            return "<td" + (block.aligns[index] ? ' style="text-align:' + block.aligns[index] + '"' : "") + ">" +
              inline(row[index] == null ? "" : row[index]) + "</td>";
          }).join("") + "</tr>";
      }).join("");
      return '<div class="md-table-wrap"><table class="md-table"><thead><tr data-md-line="' + id + ':r0">' + head +
        "</tr></thead><tbody>" + body + "</tbody></table></div>";
    default:
      return paragraphHTML(block.text, id);
  }
}

// Nested content (list items, quotes) stays unwrapped: the wrapper exists so
// the top-level streamer can replace one block at a time, not to add another
// box inside every <li>. Its line keys derive from the parent so they stay
// stable while the surrounding block is repainted.
function renderInner(blocks, key) {
  return blocks.map(function (block, index) {
    return blockHTML(block, (key == null ? "n" : key) + ":" + index);
  }).join("");
}

function renderBlocks(blocks) {
  // Static and streaming markup must have the same shape. `sync()` reuses
  // `.md-block` wrappers; if `render()` emitted bare <p>/<ul> instead, the
  // first streaming patch would append wrapped blocks next to the static ones
  // and the paragraph would appear twice.
  return blocks.map(function (block, index) {
    return '<div class="md-block md-block-' + block.type + '">' +
      blockHTML(block, String(index)) + "</div>";
  }).join("");
}

// ---------- block parser ----------
function parse(source) {
  var text = String(source == null ? "" : source).replace(/\r\n?/g, "\n");
  var lines = text.split("\n");
  var blocks = [];
  var i = 0;

  while (i < lines.length) {
    var line = lines[i];
    if (!line.trim()) { i += 1; continue; }

    var fence = line.match(FENCE);
    if (fence) {
      var marker = fence[1].charAt(0);
      var markerLength = fence[1].length;
      var code = [];
      var closed = false;
      var j = i + 1;
      for (; j < lines.length; j += 1) {
        var close = lines[j].match(CLOSE_FENCE);
        if (close && close[1].charAt(0) === marker && close[1].length >= markerLength) {
          closed = true;
          break;
        }
        code.push(lines[j]);
      }
      blocks.push({
        type: "code",
        lang: String(fence[2] || "").trim().split(/\s+/)[0].slice(0, 24),
        code: code.join("\n"),
        closed: closed,
        key: "code\u0001" + markerLength + "\u0001" + (fence[2] || "") + "\u0001" + (closed ? "1" : "0") + "\u0001" + code.join("\n"),
      });
      i = closed ? j + 1 : lines.length;
      continue;
    }

    var heading = line.match(HEADING);
    if (heading) {
      var level = Math.min(4, heading[1].length);
      blocks.push({
        type: "heading",
        level: level,
        text: heading[2],
        key: "heading\u0001" + level + "\u0001" + heading[2],
      });
      i += 1;
      continue;
    }

    // Setext heading: text followed by === or ---. Checked before the rule so
    // a two-line title does not turn into an <hr>.
    if (i + 1 < lines.length && line.trim() && /^ {0,3}(=+|-+)\s*$/.test(lines[i + 1]) &&
        !FENCE.test(line) && !listMarker(line) && !QUOTE.test(line)) {
      var setextLevel = lines[i + 1].trim().charAt(0) === "=" ? 1 : 2;
      blocks.push({
        type: "heading",
        level: setextLevel,
        text: line.trim(),
        key: "heading\u0001" + setextLevel + "\u0001" + line.trim(),
      });
      i += 2;
      continue;
    }

    if (RULE.test(line)) {
      blocks.push({ type: "rule", key: "rule" });
      i += 1;
      continue;
    }

    if (QUOTE.test(line)) {
      var quoted = [];
      var q = i;
      while (q < lines.length && (QUOTE.test(lines[q]) || (lines[q].trim() && quoted.length && !startsBlock(lines, q)))) {
        quoted.push(lines[q].replace(QUOTE, ""));
        q += 1;
      }
      var quoteChildren = parse(quoted.join("\n"));
      blocks.push({
        type: "quote",
        children: quoteChildren,
        key: "quote\u0001" + quoteChildren.map(function (child) { return child.key; }).join("\u0002"),
      });
      i = q;
      continue;
    }

    var table = tableAt(lines, i);
    if (table) {
      blocks.push({
        type: "table",
        header: table.header,
        aligns: table.aligns,
        rows: table.rows,
        key: "table\u0001" + JSON.stringify(table.header) + "\u0001" + JSON.stringify(table.rows),
      });
      i = table.next;
      continue;
    }

    var list = parseList(lines, i);
    if (list) {
      var listKey = "list\u0001" + (list.ordered ? "ol" : "ul") + "\u0001" + list.start + "\u0001" +
        list.items.map(function (item) { return item.text + "\u0002" + item.sub.join("\u0003"); }).join("\u0002");
      blocks.push({
        type: "list",
        ordered: list.ordered,
        start: list.start,
        items: list.items,
        key: listKey,
      });
      i = list.next;
      continue;
    }

    // Paragraph: everything until a blank line or a block that can interrupt
    // a paragraph. A table header only interrupts once its separator exists.
    var paragraph = [line];
    var p = i + 1;
    while (p < lines.length && lines[p].trim() && !startsBlock(lines, p, false)) {
      paragraph.push(lines[p]);
      p += 1;
    }
    var paragraphText = paragraph.join("\n");
    blocks.push({
      type: "paragraph",
      text: paragraphText,
      key: "paragraph\u0001" + paragraphText,
    });
    i = p;
  }

  return blocks;
}

// ---------- container sync ----------
function blockElement(block, index) {
  var element = document.createElement("div");
  element.className = "md-block md-block-" + block.type;
  element.dataset.mdKey = block.key;
  element.innerHTML = blockHTML(block, String(index));
  return element;
}

// Characters that can change the shape of a Markdown block. A chunk made
// only of ordinary prose can be appended to the existing text node directly.
var STRUCTURAL = /[\n\r`*_#>|\[\]!\\~$\u0000\u0001]/;

// A burst that lands in one frame is split into a few short reveal pieces.
// The text is already in the DOM; only its opacity is staggered. That is the
// difference from a typewriter: nothing is queued, so a fast engine never
// leaves an animation backlog running after generation has stopped.
var CHUNK_MIN = 6;        // shorter deltas just land, no span per token
var CHUNK_SIZE = 18;
var CHUNK_MAX = 4;
var CHUNK_STAGGER = 42;
var LINE_REVEAL_MAX = 10;
var LINE_STAGGER = 38;
var LINE_STAGGER_CAP = 5;

/// Remember which line keys were already on screen. The first `sync()` on a
/// statically rendered container seeds the set, so opening an old thread
/// never fades the whole history in.
function seedLines(container) {
  if (container.__fcSeenLines) return;
  var seen = new Set();
  Array.prototype.forEach.call(container.querySelectorAll("[data-md-line]"), function (el) {
    seen.add(el.getAttribute("data-md-line"));
  });
  container.__fcSeenLines = seen;
}

/// A brand-new line can itself be very long (one frame of a fast engine, or
/// a snapshot repair). Fade it as several short pieces instead of one wall
/// of text. Only text nodes are touched, so inline markup stays intact.
function chunkLine(el, lineIndex) {
  var walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT, null, false);
  var texts = [];
  var node;
  while ((node = walker.nextNode())) texts.push(node);
  var budget = CHUNK_MAX;
  var made = 0;
  var base = Math.min(lineIndex, LINE_STAGGER_CAP) * LINE_STAGGER;
  for (var t = 0; t < texts.length && budget > 0; t += 1) {
    var value = texts[t].nodeValue || "";
    if (value.length < CHUNK_MIN) continue;
    var count = Math.min(budget, Math.ceil(value.length / CHUNK_SIZE));
    var size = Math.ceil(value.length / count);
    var fragment = document.createDocumentFragment();
    for (var offset = 0, index = 0; offset < value.length; offset += size, index += 1) {
      var span = document.createElement("span");
      span.className = "fc-reveal is-revealing";
      span.style.animationDelay = Math.min(260, base + index * CHUNK_STAGGER) + "ms";
      span.textContent = value.slice(offset, offset + size);
      fragment.appendChild(span);
      made += 1;
    }
    // Trailing text node keeps the O(1) append fast path alive next frame.
    fragment.appendChild(document.createTextNode(""));
    texts[t].parentNode.replaceChild(fragment, texts[t]);
    budget -= count;
  }
  return made;
}

function retireReveals(container) {
  if (!container) return;
  Array.prototype.forEach.call(container.querySelectorAll(".fc-reveal"), function (span) {
    var parent = span.parentNode;
    if (!parent) return;
    var parked = span.querySelector(".fc-caret");
    if (parked) parent.appendChild(parked);
    span.replaceWith(document.createTextNode(span.textContent || ""));
    if (parent.normalize) parent.normalize();
  });
  Array.prototype.forEach.call(container.querySelectorAll(".is-revealing"), function (el) {
    el.classList.remove("is-revealing");
    el.style.animationDelay = "";
  });
}

/// animationend is the fast path; a bounded timer is the safety net for
/// hidden tabs, disabled animations and engines that swallow the event. A
/// reveal left at `opacity: 0` would be invisible text, so this must always
/// run even when nothing animated.
function scheduleRevealCleanup(container) {
  window.clearTimeout(container.__fcRevealTimer);
  container.__fcRevealTimer = window.setTimeout(function () {
    container.__fcRevealTimer = 0;
    retireReveals(container);
  }, 900);
}

function revealFreshLines(container, reveal) {
  var seen = container.__fcSeenLines;
  if (!seen) return;
  var fresh = [];
  var nodes = container.querySelectorAll("[data-md-line]");
  Array.prototype.forEach.call(nodes, function (el) {
    var key = el.getAttribute("data-md-line");
    if (seen.has(key)) return;
    seen.add(key);
    fresh.push(el);
  });
  if (!reveal || !fresh.length) return;
  var count = Math.min(fresh.length, LINE_REVEAL_MAX);
  for (var i = 0; i < count; i += 1) {
    var el = fresh[i];
    var length = (el.textContent || "").length;
    if (length >= CHUNK_MIN * 3 && chunkLine(el, i)) {
      scheduleRevealCleanup(container);
      continue;
    }
    el.style.animationDelay = Math.min(i, LINE_STAGGER_CAP) * LINE_STAGGER + "ms";
    el.classList.add("is-revealing");
    scheduleRevealCleanup(container);
  }
  // Anything beyond the cap is already visible: a large snapshot repair
  // should not fade twenty lines at once and read as a flash.
}

/// O(1) streaming fast path. A stream appends a few characters per frame;
/// re-parsing and re-painting the whole reply for those characters is what
/// makes a long answer cost O(n^2) over its lifetime. When the only change
/// is plain text growth inside the tail paragraph, extend its last text node
/// instead. Anything that could alter structure falls through to the full
/// block diff below.
function appendPlainGrowth(container, text, reveal) {
  var previous = container.__fcText;
  if (typeof previous !== "string" || text.length <= previous.length) return false;
  if (!text.startsWith(previous)) return false;
  var suffix = text.slice(previous.length);
  if (!suffix || STRUCTURAL.test(suffix)) return false;

  var block = container.lastElementChild;
  if (!block || !block.classList.contains("md-block-paragraph")) return false;
  var paragraph = block.firstElementChild;
  if (!paragraph || paragraph.tagName !== "P") return false;
  var tail = paragraph.lastChild;
  // The live caret is parked at the end of the growing paragraph. It is an
  // element, but the text node just before it is still the append target.
  if (tail && tail.nodeType === 1 && tail.classList && tail.classList.contains("fc-caret")) {
    tail = tail.previousSibling;
  }
  if (!tail || tail.nodeType !== 3) return false;

  // Text nodes need no escaping: the character itself is the rendered value.
  if (reveal && suffix.length >= CHUNK_MIN) {
    var count = Math.min(CHUNK_MAX, Math.ceil(suffix.length / CHUNK_SIZE));
    var size = Math.ceil(suffix.length / count);
    var fragment = document.createDocumentFragment();
    for (var offset = 0, index = 0; offset < suffix.length; offset += size, index += 1) {
      var piece = document.createElement("span");
      piece.className = "fc-reveal is-revealing";
      piece.style.animationDelay = index * CHUNK_STAGGER + "ms";
      piece.textContent = suffix.slice(offset, offset + size);
      fragment.appendChild(piece);
    }
    // Keep an empty text node at the tail: the next frame can keep appending
    // to it (or insert before the caret) without a full re-parse.
    fragment.appendChild(document.createTextNode(""));
    var caret = paragraph.lastChild;
    if (caret && caret.nodeType === 1 && caret.classList.contains("fc-caret")) {
      paragraph.insertBefore(fragment, caret);
    } else {
      paragraph.appendChild(fragment);
    }
    scheduleRevealCleanup(container);
  } else {
    tail.appendData(suffix);
  }
  var tailText = (container.__fcTailText || "") + suffix;
  container.__fcTailText = tailText;
  container.__fcText = text;
  block.dataset.mdKey = "paragraph\u0001" + tailText;
  return true;
}

function rememberSync(container, text, blocks, streaming) {
  var last = blocks.length ? blocks[blocks.length - 1] : null;
  container.__fcText = text;
  container.__fcTailText = last && last.type === "paragraph" ? last.text : "";
  container.__fcTailStreaming = Boolean(streaming);
}

function sync(container, text, options) {
  if (!container) return;
  text = String(text == null ? "" : text);
  var opts = options || {};
  seedLines(container);
  // A stream that only grew by plain characters never needs a full diff.
  if (appendPlainGrowth(container, text, opts.reveal)) return;
  var blocks = parse(text);
  var nodes = Array.prototype.slice.call(container.children).filter(function (node) {
    return node.classList && node.classList.contains("md-block");
  });

  for (var i = 0; i < blocks.length; i += 1) {
    var node = nodes[i];
    if (node && !node.dataset.mdKey) {
      // A block painted by render(): the wrapper exists but carries no key.
      // The text is the same, so adopt it instead of replacing it.
      node.dataset.mdKey = blocks[i].key;
      node.classList.toggle("is-tail", opts.streaming && i === blocks.length - 1);
      continue;
    }
    if (node && node.dataset.mdKey === blocks[i].key) {
      node.classList.toggle("is-tail", opts.streaming && i === blocks.length - 1);
      continue;
    }
    if (node && i === blocks.length - 1) {
      // The block that is still growing keeps its element: replacing it on
      // every frame would restart its paint and move the caret. Repaint its
      // HTML in place instead, so only the text region is dirty.
      node.className = "md-block md-block-" + blocks[i].type;
      node.dataset.mdKey = blocks[i].key;
      node.innerHTML = blockHTML(blocks[i], String(i));
    } else {
      var fresh = blockElement(blocks[i], i);
      if (node) {
        fresh.classList.add("is-replaced");
        node.replaceWith(fresh);
        nodes[i] = fresh;
      } else {
        fresh.classList.add("is-enter");
        container.appendChild(fresh);
        nodes[i] = fresh;
      }
      fresh.classList.toggle("is-tail", opts.streaming && i === blocks.length - 1);
    }
  }

  for (var k = nodes.length - 1; k >= blocks.length; k -= 1) {
    if (nodes[k] && nodes[k].parentNode === container) nodes[k].remove();
  }

  // One-shot entrance / reveal animations are cleaned up on animationend,
  // so a long stream does not leave thousands of wrapper spans behind.
  if (!container.dataset.mdBound) {
    container.dataset.mdBound = "1";
    container.addEventListener("animationend", function (event) {
      var target = event.target;
      if (!target || !target.classList) return;
      if (target.classList.contains("md-block")) {
        target.classList.remove("is-enter", "is-replaced");
      }
      if (target.classList.contains("fc-reveal")) {
        var parent = target.parentNode;
        // Defensive: a caret that ended up inside the chunk must survive its
        // unwrap (chat-stream.js normally keeps it out).
        var parked = target.querySelector(".fc-caret");
        if (parked && parent) parent.appendChild(parked);
        target.replaceWith(document.createTextNode(target.textContent || ""));
        if (parent && parent.normalize) parent.normalize();
      } else if (target.classList.contains("is-revealing")) {
        target.classList.remove("is-revealing");
      }
    });
  }
  revealFreshLines(container, opts.reveal);
  rememberSync(container, text, blocks, opts.streaming);
}

function render(text) {
  return renderBlocks(parse(text));
}

export const FCChatMarkdown = {
  render: render,
  sync: sync,
  settleReveals: function (container) {
    if (!container) return;
    window.clearTimeout(container.__fcRevealTimer);
    container.__fcRevealTimer = 0;
    retireReveals(container);
  },
  parse: parse,
  inline: inline,
  esc: esc,
  safeUrl: safeUrl,
};
