/* 对话引擎：两条实现，一套对外形状。
   - native：Tauri IPC，`chat_start` 起生成，增量从 `chat:delta` 事件回来；
   - mock：浏览器里（pnpm dev / 静态预览）用定时器复刻同样的节奏。
   两条路都只做「思考块先涨 → 正文按 token 推进 → 收尾结算」，
   差异全部收在本文件里，页面层不认识 transport。 */

import { useCallback, useEffect, useRef, useState } from "react";
import type { Message } from "./data/mock";
import { bridge, isTauri } from "./bridge";

const THINKING =
  "先算账：16GB 统一内存，系统与桌面吃掉约 4.5GB，留给推理的约 11.5GB。3B 的 q4_k_m 权重 1.9GB，KV cache 按 512 上下文、4 路并发算，每路约 180MB——总量还在安全线内，但默认的 --parallel 1 会把 4 路请求串行化，白白浪费。关键是给 KV 设上限，并且让批处理而非并行去赚吞吐。";

const REPLY = `**首字延迟的九成在 prefill，不在采样。**

你现在 218ms 的 p50 里，大约 190ms 花在把提示词整个 forward 一遍。按收益排序：

1. 打开 \`--flash-attn\`，prefill 直接快三成
2. 把 system prompt 压到 200 token 以内——它每轮都要重算
3. 开 prefix cache，多轮对话的公共前缀只算一次

| 动作 | p50 收益 | 代价 |
| --- | --- | --- |
| flash-attn | -58ms | 几乎为零 |
| 短 system | -34ms | 提示词要重写 |
| prefix cache | -41ms | 多占 0.4GB |

先做第 1 项，它是纯赚的。`;

export type Live = { tokens: number; ms: number };
export type Transport = "auto" | "mock" | "native";

type Active = {
  replyId: string;
  runId: string | null;
  text: string;
  thinking: string;
  /** 思考段已产生的 token 估算，计入 live 读数。 */
  thinkTokens: number;
  started: number;
};

export function useChatEngine(
  seed: Message[],
  transport: Transport = "auto",
  demoFlag = false
) {
  const [messages, setMessages] = useState<Message[]>(seed);
  const [generating, setGenerating] = useState(false);
  const [live, setLive] = useState<Live>({ tokens: 0, ms: 0 });

  // 挂载时定一次：中途不切换传输层。
  const native = useRef(
    transport === "native" ? true : transport === "mock" ? false : isTauri()
  ).current;

  const active = useRef<Active | null>(null);
  const mismatch = useRef(false);
  const timer = useRef<number | null>(null);
  const generatingRef = useRef(false);
  generatingRef.current = generating;

  const clearTimer = useCallback(() => {
    if (timer.current !== null) {
      window.clearInterval(timer.current);
      timer.current = null;
    }
  }, []);

  /** 只改「当前这条回复」，避免整表重渲染带来的键错位。 */
  const patch = useCallback((merge: (m: Message) => Partial<Message>) => {
    const id = active.current?.replyId;
    if (!id) return;
    setMessages((prev) => prev.map((m) => (m.id === id ? { ...m, ...merge(m) } : m)));
  }, []);

  // ── native 事件订阅 ────────────────────────────────────────────────
  useEffect(() => {
    if (!native) return;
    let unlisten: (() => void) | undefined;
    let disposed = false;

    bridge
      .onDelta((d) => {
        const a = active.current;
        if (!a) return;
        // 首个 delta 可能早于 chat_start 的返回值，这里以事件里的 runId 为准。
        if (a.runId === null) a.runId = d.runId;
        if (a.runId !== d.runId) {
          // 静默丢弃过一次：Rust 侧 Delta 的字段没做 camelCase，d.runId 是 undefined，
          // 结果「chat_start 先返回 → 之后每个 delta 都被判定为别人的 run」。
          // 以后协议再对不上，至少留一条能搜到的线索。
          if (!mismatch.current) {
            mismatch.current = true;
            console.warn("chat:delta 的 runId 与当前回复不一致，已忽略", d.runId, a.runId);
          }
          return;
        }

        switch (d.kind) {
          case "thinking":
            a.thinking += d.delta;
            // 思考也是 token。之前只统计正文，导致手机上「思考了 40 秒仍显示 0 tok」，
            // 看上去像卡死——这是同一个数字在骗人，不是另一个 bug。
            a.thinkTokens = Math.round(a.thinking.length / 1.6);
            setLive({ tokens: a.thinkTokens, ms: Math.round(performance.now() - a.started) });
            patch(() => ({ thinking: a.thinking }));
            break;
          case "text": {
            a.text += d.delta;
            const ms = Math.round(performance.now() - a.started);
            setLive({ tokens: a.thinkTokens + Math.round(a.text.length / 1.6), ms });
            patch(() => ({ text: a.text }));
            break;
          }
          case "usage":
            setLive({ tokens: d.outputTokens, ms: d.totalMs });
            patch(() => ({ stats: { tokens: d.outputTokens, ms: d.totalMs } }));
            break;
          case "done":
            setGenerating(false);
            patch(() => ({ streaming: false }));
            break;
          case "error":
            setGenerating(false);
            patch(() => ({ text: `${a.text}\n\n> ${d.message}`, streaming: false }));
            break;
        }
      })
      .then((fn) => (disposed ? fn() : (unlisten = fn)))
      .catch((e) => console.error("订阅 chat:delta 失败", e));

    return () => {
      disposed = true;
      unlisten?.();
    };
  }, [native, patch]);

  useEffect(() => clearTimer, [clearTimer]);


  // ── 发送 ──────────────────────────────────────────────────────────
  const send = useCallback(
    (raw: string) => {
      const text = raw.trim();
      if (!text || generatingRef.current) return;

      const id = `m${Date.now()}`;
      const replyId = `${id}-a`;
      active.current = {
        replyId,
        runId: null,
        text: "",
        thinking: "",
        thinkTokens: 0,
        started: performance.now(),
      };

      const history = messages
        .filter((m) => m.text.trim().length > 0)
        .slice(-12)
        .map((m) => ({ role: m.role, content: m.text }));

      setMessages((prev) => [
        ...prev,
        { id, role: "user", text },
        { id: replyId, role: "assistant", text: "", thinking: "", streaming: true },
      ]);
      setGenerating(true);
      setLive({ tokens: 0, ms: 0 });

      if (native) {
        bridge
          .chatStart({ threadId: "local", message: text, modelId: null, history })
          .then((runId) => {
            if (active.current) active.current.runId = runId;
          })
          .catch((e: unknown) => {
            const msg = e instanceof Error ? e.message : String(e);
            patch(() => ({ streaming: false, text: `连接本地引擎失败：${msg}` }));
            setGenerating(false);
          });
        return;
      }

      // ── mock ──
      let think = 0;
      let body = 0;
      let phase: "think" | "body" = "think";

      clearTimer();
      timer.current = window.setInterval(() => {
        const ms = Math.round(performance.now() - (active.current?.started ?? 0));

        if (phase === "think") {
          think = Math.min(THINKING.length, think + 9);
          const done = think >= THINKING.length;
          patch(() => ({ thinking: THINKING.slice(0, think) }));
          if (done) phase = "body";
          setLive({ tokens: Math.round(think / 3.2), ms });
          return;
        }

        body = Math.min(REPLY.length, body + 4 + (body % 3));
        const done = body >= REPLY.length;
        patch(() => ({
          text: REPLY.slice(0, body),
          streaming: !done,
          stats: done ? { tokens: Math.round(body / 3.4), ms } : undefined,
        }));
        setLive({ tokens: Math.round(body / 3.4), ms });

        if (done) {
          clearTimer();
          setGenerating(false);
        }
      }, 24);
    },
    [clearTimer, messages, native, patch]
  );

  // 自检：进程带 `FLASHCAT_DEMO=1` 时自动发一句，让「有没有真出字」只看日志就能判断
  // （桌面窗口截图受 TCC 限制、移动端没有 devtools、Linux 容器里没有窗口管理器）。
  const demo = import.meta.env.VITE_DEMO || demoFlag;
  useEffect(() => {
    if (!native || !demo) return;
    const t = window.setTimeout(() => send("用一句话说明你是谁"), 900);
    return () => window.clearTimeout(t);
    // send 依赖 messages，故意只在挂载时跑一次。
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [native, demo]);

  const stop = useCallback(() => {
    clearTimer();
    const a = active.current;
    if (native && a?.runId) void bridge.chatCancel(a.runId);
    setGenerating(false);
    patch((m) => ({ streaming: false, stats: m.stats ?? { tokens: live.tokens, ms: live.ms } }));
  }, [clearTimer, live.ms, live.tokens, native, patch]);

  const reset = useCallback(() => {
    clearTimer();
    const a = active.current;
    if (native && a?.runId) void bridge.chatCancel(a.runId);
    active.current = null;
    setGenerating(false);
    setLive({ tokens: 0, ms: 0 });
    setMessages([]);
  }, [clearTimer, native]);

  return { messages, generating, live, send, stop, reset };
}
