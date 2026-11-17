import { useEffect, useLayoutEffect, useRef, useState } from "react";
import type { ModelCard } from "../bridge";
import { Icon } from "../icons";
import { Markdown } from "../components/md";
import type { Live } from "../chat";
import type { Message } from "../data/mock";

function formatTok(ms: number, tokens: number): string {
  if (!ms) return "";
  const rate = (tokens / Math.max(ms, 1)) * 1000;
  return `${rate.toFixed(1)} tok/s`;
}

function Thinking({ text, open, onToggle }: { text: string; open: boolean; onToggle: () => void }) {
  const secs = Math.max(1, Math.round(text.length / 260));
  return (
    <div className="think">
      <button className="think-head" type="button" onClick={onToggle}>
        <Icon name={open ? "chevron" : "chevron"} size={11} style={{ transform: open ? "none" : "rotate(-90deg)", transition: "transform var(--m-snappy)" }} />
        <span>{open ? "思考中" : "已思考"}</span>
        <span className="mono">{secs}.{Math.floor((text.length % 260) / 26)}s</span>
      </button>
      {open && <div className="think-body">{text}</div>}
    </div>
  );
}

function Bubble({ m, live }: { m: Message; live: Live }) {
  const [open, setOpen] = useState<boolean>(Boolean(m.streaming));
  const prevStreaming = useRef(m.streaming);

  useEffect(() => {
    if (prevStreaming.current !== m.streaming) {
      prevStreaming.current = m.streaming;
      if (!m.streaming) setOpen(false);
    }
  }, [m.streaming]);

  if (m.role === "user") {
    return (
      <div className="msg" data-role="user" data-msg-id={m.id}>
        <div className="msg-meta">
          <span>你</span>
        </div>
        <div className="bubble">{m.text}</div>
      </div>
    );
  }

  const tokens = m.stats?.tokens ?? 0;
  const ms = m.stats?.ms ?? 0;

  return (
    <div className="msg" data-role="assistant" data-msg-id={m.id}>
      <div className="msg-meta">
        <span className="who">{m.streaming ? "生成中" : "flashCat"}</span>
        {m.streaming ? (
          <span className="mono">
            {live.tokens} tok · {formatTok(live.ms, live.tokens)}
          </span>
        ) : (
          <span className="mono">
            {tokens} tok · {(ms / 1000).toFixed(1)}s · {formatTok(ms, tokens)}
          </span>
        )}
      </div>
      {m.thinking ? <Thinking text={m.thinking} open={open} onToggle={() => setOpen((v) => !v)} /> : null}
      <div className="body">
        {m.text ? <Markdown text={m.text} caret={m.streaming} /> : m.streaming ? <span className="caret" /> : null}
      </div>
    </div>
  );
}

// 触摸设备判定：Android WebView 的 pointer 媒体查询不一定报 coarse，
// 但 maxTouchPoints 一直是准的（模拟器与真机都算触摸）
const COARSE =
  typeof window !== "undefined" &&
  (navigator.maxTouchPoints > 0 || window.matchMedia("(pointer: coarse)").matches);

export function Chat({
  messages,
  generating,
  live,
  onSend,
  onStop,
  onNewThread,
  onHistory,
  model,
  needsModel = false,
  onGetModel,
}: {
  messages: Message[];
  generating: boolean;
  live: Live;
  onSend: (text: string) => void;
  onStop: () => void;
  onNewThread: () => void;
  onHistory?: () => void;
  /** 当前加载的权重；没有后端或没装权重时是 null（输入卡的 chips 显示「—」）。 */
  model: ModelCard | null;
  /** 目录里一个权重都没有：此时后端是演示用的 mock，输出不是模型算的。 */
  needsModel?: boolean;
  onGetModel?: () => void;
}) {
  const [draft, setDraft] = useState("");
  const threadRef = useRef<HTMLDivElement>(null);
  const taRef = useRef<HTMLTextAreaElement>(null);

  /* 长按消息 → 复制。手机上这是最基础的文本操作，没有它就只能整段截图。
     用事件代理而不是给每个气泡挂定时器：一次 touchstart 只起一个计时器，
     手指一动（touchmove 超过 10px）就取消，滚动不会误触。 */
  const [press, setPress] = useState<{ text: string } | null>(null);
  const pressTimer = useRef<number | null>(null);
  const pressAt = useRef<{ x: number; y: number } | null>(null);

  const clearPress = () => {
    if (pressTimer.current !== null) {
      window.clearTimeout(pressTimer.current);
      pressTimer.current = null;
    }
    pressAt.current = null;
  };

  const onTouchStart = (e: React.TouchEvent<HTMLDivElement>) => {
    const id = (e.target as HTMLElement).closest<HTMLElement>("[data-msg-id]")?.dataset.msgId;
    const m = messages.find((x) => x.id === id);
    if (!m || !m.text) return;
    clearPress();
    const t = e.touches[0];
    pressAt.current = { x: t.clientX, y: t.clientY };
    pressTimer.current = window.setTimeout(() => setPress({ text: m.text }), 450);
  };

  const onTouchMove = (e: React.TouchEvent<HTMLDivElement>) => {
    const from = pressAt.current;
    const t = e.touches[0];
    if (from && Math.hypot(t.clientX - from.x, t.clientY - from.y) > 10) clearPress();
  };

  const copyText = async (text: string) => {
    try {
      await navigator.clipboard.writeText(text);
    } catch {
      // WebView 里 clipboard 权限可能被拒：退回老办法，同步且一定生效
      const ta = document.createElement("textarea");
      ta.value = text;
      ta.style.position = "fixed";
      ta.style.opacity = "0";
      document.body.appendChild(ta);
      ta.select();
      document.execCommand("copy");
      ta.remove();
    }
    setPress(null);
  };

  useLayoutEffect(() => {
    const el = threadRef.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [messages, generating]);

  useLayoutEffect(() => {
    const ta = taRef.current;
    if (!ta) return;
    ta.style.height = "auto";
    ta.style.height = `${Math.min(ta.scrollHeight, 160)}px`;
  }, [draft]);

  const submit = () => {
    if (!draft.trim() || generating) return;
    onSend(draft);
    setDraft("");
  };

  return (
    <div className="chat-wrap">
      <div className="chat-head">
        {onHistory ? (
          <button className="toggle" type="button" onClick={onHistory} aria-label="对话历史">
            <Icon name="doc" size={13} />
          </button>
        ) : null}
        <h2>16GB M2 上并发跑 3B</h2>
        <div className="aside">
          {generating ? (
            <span className="gen-status">
              <span className="live-dot" style={{ background: "currentColor" }} />
              {live.tokens} tok · {formatTok(live.ms, live.tokens)}
            </span>
          ) : (
            <span className="tag">Qwen2.5-VL-7B · Q4_K_M</span>
          )}
          <button className="btn" data-variant="ghost" type="button" onClick={onNewThread} title="新对话">
            <Icon name="plus" size={12} />
          </button>
          <button className="btn" data-variant="ghost" type="button" title="更多">
            <Icon name="slider" size={12} />
          </button>
        </div>
      </div>

      {needsModel ? (
        <div className="notice">
          <span>
            未装权重，当前是<strong>演示输出</strong>
          </span>
          {onGetModel ? (
            <button className="btn" type="button" onClick={onGetModel}>
              去下载
            </button>
          ) : null}
        </div>
      ) : null}

      <div className="thread scroll" ref={threadRef}>
        <div
          className="thread-inner"
          onTouchStart={onTouchStart}
          onTouchMove={onTouchMove}
          onTouchEnd={clearPress}
          onTouchCancel={clearPress}
          onContextMenu={(e) => {
            // 桌面右键也给同一个入口，不必分两套 UI
            const id = (e.target as HTMLElement).closest<HTMLElement>("[data-msg-id]")?.dataset.msgId;
            const m = messages.find((x) => x.id === id);
            if (!m?.text) return;
            e.preventDefault();
            setPress({ text: m.text });
          }}
        >
          {messages.map((m) => (
            <Bubble key={m.id} m={m} live={live} />
          ))}
        </div>
      </div>

      {press ? (
        <div className="sheet-scrim" onClick={() => setPress(null)}>
          <div className="sheet" onClick={(e) => e.stopPropagation()}>
            <div className="sheet-grabber" />
            <div className="sheet-title">
              <strong>消息</strong>
              <span>{press.text.length} 字</span>
            </div>
            <button className="sheet-item" type="button" onClick={() => void copyText(press.text)}>
              复制文字
            </button>
            <button
              className="sheet-item"
              data-tone="danger"
              type="button"
              onClick={() => setPress(null)}
            >
              取消
            </button>
          </div>
        </div>
      ) : null}

      <div className="composer-wrap">
        <div className="composer">
          <textarea
            ref={taRef}
            rows={1}
            value={draft}
            placeholder={
              COARSE ? "问点什么…" : "问点什么，或者把一张图拖进来…"
            }
            onChange={(e) => setDraft(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter" && !e.shiftKey && !e.nativeEvent.isComposing) {
                e.preventDefault();
                submit();
              }
            }}
          />
          <div className="composer-bar">
            <button className="mini" type="button" title={model?.name ?? "尚未加载权重"}>
              <Icon name="stack" size={11} />
              模型
              <span className="mono">{model ? `${model.paramsB}B` : "—"}</span>
            </button>
            <button className="mini" type="button">
              <Icon name="plus" size={11} />
              附件
            </button>
            <button className="mini" type="button" title="每次请求的上下文窗口">
              <Icon name="cpu" size={11} />
              上下文
              <span className="mono">{model ? `${Math.round(model.context / 1024)}k` : "—"}</span>
            </button>
            {generating ? (
              <button className="send" type="button" onClick={onStop} title="停止">
                <Icon name="stop" size={12} />
              </button>
            ) : (
              <button
                className="send"
                type="button"
                data-idle={draft.trim() ? undefined : "true"}
                onClick={submit}
                title="发送"
              >
                <Icon name="up" size={13} strokeWidth={1.7} />
              </button>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
