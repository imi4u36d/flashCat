/* 轻量 Markdown：够渲染对话里的模型输出即可。
   块级：段落 / 标题 / 无序列表 / 围栏代码 / 表格 / 引用。
   行内：粗体 / 行内码 / 链接。
   刻意不做完整 CommonMark —— 复杂语法交给模型侧收敛，不在这里养一个解析器。 */

import type { ReactNode } from "react";

type Block =
  | { kind: "p"; text: string }
  | { kind: "h2"; text: string }
  | { kind: "h3"; text: string }
  | { kind: "ul"; items: string[] }
  | { kind: "quote"; text: string }
  | { kind: "code"; lang: string; code: string }
  | { kind: "table"; head: string[]; rows: string[][] };

function splitRow(line: string): string[] {
  return line
    .replace(/^\s*\|/, "")
    .replace(/\|\s*$/, "")
    .split("|")
    .map((c) => c.trim());
}

function parse(src: string): Block[] {
  const lines = src.replace(/\r\n/g, "\n").split("\n");
  const out: Block[] = [];
  let buf: string[] = [];
  let i = 0;

  const flush = () => {
    if (!buf.length) return;
    const text = buf.join(" ").trim();
    if (text) out.push({ kind: "p", text });
    buf = [];
  };

  while (i < lines.length) {
    const line = lines[i];

    // 围栏代码
    if (/^\s*```/.test(line)) {
      flush();
      const lang = line.replace(/^\s*```/, "").trim();
      const code: string[] = [];
      i += 1;
      while (i < lines.length && !/^\s*```/.test(lines[i])) {
        code.push(lines[i]);
        i += 1;
      }
      i += 1;
      out.push({ kind: "code", lang: lang || "text", code: code.join("\n") });
      continue;
    }

    // 表格：表头 + 分隔行
    if (/^\s*\|/.test(line) && i + 1 < lines.length && /^\s*\|[\s:|-]+\|?\s*$/.test(lines[i + 1])) {
      flush();
      const head = splitRow(line);
      const rows: string[][] = [];
      i += 2;
      while (i < lines.length && /^\s*\|/.test(lines[i])) {
        rows.push(splitRow(lines[i]));
        i += 1;
      }
      out.push({ kind: "table", head, rows });
      continue;
    }

    if (/^###\s+/.test(line)) {
      flush();
      out.push({ kind: "h3", text: line.replace(/^###\s+/, "") });
      i += 1;
      continue;
    }

    if (/^##\s+/.test(line)) {
      flush();
      out.push({ kind: "h2", text: line.replace(/^##\s+/, "") });
      i += 1;
      continue;
    }

    if (/^#\s+/.test(line)) {
      flush();
      out.push({ kind: "h2", text: line.replace(/^#\s+/, "") });
      i += 1;
      continue;
    }

    if (/^\s*[-*]\s+/.test(line)) {
      flush();
      const items: string[] = [];
      while (i < lines.length && /^\s*[-*]\s+/.test(lines[i])) {
        items.push(lines[i].replace(/^\s*[-*]\s+/, ""));
        i += 1;
      }
      out.push({ kind: "ul", items });
      continue;
    }

    if (/^>\s?/.test(line)) {
      flush();
      const quoted: string[] = [];
      while (i < lines.length && /^>\s?/.test(lines[i])) {
        quoted.push(lines[i].replace(/^>\s?/, ""));
        i += 1;
      }
      out.push({ kind: "quote", text: quoted.join(" ") });
      continue;
    }

    if (!line.trim()) {
      flush();
      i += 1;
      continue;
    }

    buf.push(line.trim());
    i += 1;
  }

  flush();
  return out;
}

const INLINE = /(\*\*[^*]+\*\*|`[^`]+`|\[[^\]]+\]\([^)]+\))/g;

function inline(text: string, keyPrefix: string): ReactNode[] {
  return text.split(INLINE).map((part, idx) => {
    const key = `${keyPrefix}-${idx}`;
    if (!part) return null;
    if (part.startsWith("**") && part.endsWith("**")) {
      return <strong key={key}>{part.slice(2, -2)}</strong>;
    }
    if (part.startsWith("`") && part.endsWith("`")) {
      return <code key={key}>{part.slice(1, -1)}</code>;
    }
    const link = /^\[([^\]]+)\]\(([^)]+)\)$/.exec(part);
    if (link) {
      return (
        <a key={key} href={link[2]} target="_blank" rel="noreferrer">
          {link[1]}
        </a>
      );
    }
    return <span key={key}>{part}</span>;
  });
}

/* 代码着色：只认四类 token，够看即可。 */
const KWS = new Set(
  "flashcat run if else for while let var const func return import from def class export await async in not and or true false nil null None True False".split(
    " "
  )
);
const TOKEN = /("[^"]*"|'[^']*'|\b\d+(?:\.\d+)?\b|[A-Za-z_][A-Za-z0-9_]*)/g;

function highlight(code: string): ReactNode[] {
  const nodes: ReactNode[] = [];
  code.split("\n").forEach((line, li) => {
    if (li > 0) nodes.push("\n");
    if (/^\s*(#|\/\/)/.test(line)) {
      nodes.push(
        <span className="cm" key={`c${li}`}>
          {line}
        </span>
      );
      return;
    }
    let last = 0;
    let m: RegExpExecArray | null;
    TOKEN.lastIndex = 0;
    let n = 0;
    while ((m = TOKEN.exec(line)) !== null) {
      if (m.index > last) nodes.push(line.slice(last, m.index));
      const tok = m[0];
      const key = `${li}-${n++}`;
      if (/^["']/.test(tok)) {
        nodes.push(
          <span className="str" key={key}>
            {tok}
          </span>
        );
      } else if (/^\d/.test(tok)) {
        nodes.push(
          <span className="num" key={key}>
            {tok}
          </span>
        );
      } else if (KWS.has(tok)) {
        nodes.push(
          <span className="kw" key={key}>
            {tok}
          </span>
        );
      } else {
        nodes.push(tok);
      }
      last = m.index + tok.length;
    }
    if (last < line.length) nodes.push(line.slice(last));
  });
  return nodes;
}

export function CodeBlock({ lang, code }: { lang: string; code: string }) {
  return (
    <div className="code">
      <div className="code-head">
        <span>{lang}</span>
        <button className="copy" type="button" onClick={() => navigator.clipboard?.writeText(code)}>
          复制
        </button>
      </div>
      <pre>
        <code>{highlight(code)}</code>
      </pre>
    </div>
  );
}

export function Markdown({ text, caret }: { text: string; caret?: boolean }) {
  const blocks = parse(text);
  return (
    <div className="md">
      {blocks.map((b, i) => {
        const key = `b${i}`;
        switch (b.kind) {
          case "h2":
            return <h2 key={key}>{inline(b.text, key)}</h2>;
          case "h3":
            return <h3 key={key}>{inline(b.text, key)}</h3>;
          case "ul":
            return (
              <ul key={key}>
                {b.items.map((it, j) => (
                  <li key={`${key}-${j}`}>{inline(it, `${key}-${j}`)}</li>
                ))}
              </ul>
            );
          case "quote":
            return <blockquote key={key}>{inline(b.text, key)}</blockquote>;
          case "code":
            return <CodeBlock key={key} lang={b.lang} code={b.code} />;
          case "table":
            return (
              <table key={key}>
                <thead>
                  <tr>
                    {b.head.map((h, j) => (
                      <th key={`${key}-h${j}`}>{inline(h, `${key}-h${j}`)}</th>
                    ))}
                  </tr>
                </thead>
                <tbody>
                  {b.rows.map((r, j) => (
                    <tr key={`${key}-r${j}`}>
                      {r.map((c, k) => (
                        <td key={`${key}-r${j}c${k}`}>{inline(c, `${key}-r${j}c${k}`)}</td>
                      ))}
                    </tr>
                  ))}
                </tbody>
              </table>
            );
          default:
            return (
              <p key={key}>
                {inline(b.text, key)}
                {caret && i === blocks.length - 1 ? <span className="caret" /> : null}
              </p>
            );
        }
      })}
      {caret && blocks.length === 0 ? <span className="caret" /> : null}
    </div>
  );
}
