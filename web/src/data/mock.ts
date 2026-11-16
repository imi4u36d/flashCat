/* 假数据：外壳、概览、对话三个页面共用。数值取自本地引擎的典型读数，
   只为把界面撑到「像一个真在跑的仪器」，不代表任何基准。 */

import type { Page } from "../App";

export type Message = {
  id: string;
  role: "user" | "assistant";
  text: string;
  thinking?: string;
  streaming?: boolean;
  stats?: { tokens: number; ms: number };
};

export const recents: { id: string; title: string; time: string; generating?: boolean }[] = [
  { id: "r1", title: "16GB M2 上并发跑 3B", time: "刚刚", generating: true },
  { id: "r2", title: "网关 Anthropic 方言兼容性", time: "12 分" },
  { id: "r3", title: "把 KV cache 压到 q4", time: "1 小时" },
  { id: "r4", title: "视频模型的显存峰值", time: "3 小时" },
  { id: "r5", title: "为什么首字延迟忽高忽低", time: "昨天" },
  { id: "r6", title: "批量评测脚本的写法", time: "昨天" },
  { id: "r7", title: "LoRA 热切换的可行性", time: "周一" },
];

export const navGroups: { label?: string; pages: { page: Page; label: string; icon: string }[] }[] = [
  {
    pages: [
      { page: "chat", label: "对话", icon: "bubble" },
      { page: "lab", label: "实验", icon: "flask" },
    ],
  },
  {
    label: "控制台",
    pages: [
      { page: "overview", label: "概览", icon: "grid" },
      { page: "models", label: "模型", icon: "stack" },
      { page: "engines", label: "引擎", icon: "cpu" },
      { page: "logs", label: "日志", icon: "doc" },
    ],
  },
];

export const engine = {
  model: "Qwen2.5-VL-7B-Instruct",
  variant: "Q4_K_M",
  state: "运行中",
  backend: "MLX · Metal",
  context: 32_768,
  parallel: 4,
  uptime: "4 小时 12 分",
  memory: "11.2 GB / 16 GB",
  endpoint: "http://127.0.0.1:9000/v1",
  loaded: 3,
};

export const kpis = [
  { label: "生成吞吐", value: "42.8", unit: "tok/s", sub: "近 60s 平均 · 峰值 58.4" },
  { label: "首字延迟", value: "218", unit: "ms", sub: "p50 · p95 384ms" },
  { label: "今日请求", value: "1,284", unit: "次", sub: "失败 3 · 重试 7" },
  { label: "KV 缓存命中", value: "63.4", unit: "%", sub: "复用 8.1 GB·tok", tone: "accent" },
  { label: "内存占用", value: "11.2", unit: "GB", sub: "权重 4.6 · KV 5.9 · 余 4.8" },
];

/** 60 根柱子：一条带呼吸的吞吐曲线，最后一根是当前秒。 */
export const throughput: number[] = Array.from({ length: 60 }, (_, i) => {
  const wave = Math.sin(i / 5.2) * 8 + Math.sin(i / 1.7) * 3.4;
  const drift = (i / 60) * 10;
  const noise = ((i * 7919) % 11) - 5;
  return Math.max(6, Math.round(34 + wave + drift + noise));
});

export const requests = [
  {
    time: "19:04:12",
    model: "Qwen2.5-VL-7B",
    dialect: "OpenAI",
    input: 1_842,
    output: 486,
    latency: "312ms",
    status: "ok",
  },
  {
    time: "19:03:58",
    model: "Qwen2.5-VL-7B",
    dialect: "Anthropic",
    input: 4_106,
    output: 1_204,
    latency: "1.24s",
    status: "ok",
  },
  {
    time: "19:03:41",
    model: "FLUX.1-dev",
    dialect: "OpenAI",
    input: 128,
    output: 0,
    latency: "6.81s",
    status: "ok",
  },
  {
    time: "19:02:55",
    model: "Qwen2.5-VL-7B",
    dialect: "OpenAI",
    input: 920,
    output: 214,
    latency: "268ms",
    status: "ok",
  },
  {
    time: "19:02:30",
    model: "Qwen2.5-VL-7B",
    dialect: "Anthropic",
    input: 2_384,
    output: 0,
    latency: "1.02s",
    status: "err",
  },
];

export const seedMessages: Message[] = [
  {
    id: "m1",
    role: "user",
    text: "帮我把 3B 的模型在 16GB 的 M2 上跑起来，要能并发 4 路。",
  },
  {
    id: "m2",
    role: "assistant",
    thinking:
      "先算账：16GB 统一内存，系统与桌面吃掉约 4.5GB，留给推理的约 11.5GB。3B 的 q4_k_m 权重 1.9GB，KV cache 按 512 上下文、4 路并发算，每路约 180MB——总量还在安全线内，但默认的 --parallel 1 会把 4 路请求串行化，白白浪费。关键是给 KV 设上限，并且让批处理而非并行去赚吞吐。",
    text: `**可以，但要把并发的账算在 KV cache 上，而不是模型上。**

3B 的 \`q4_k_m\` 权重只有 1.9GB，真正吃内存的是 KV。按 512 上下文、4 路并发估算，每路约 180MB，合计 720MB——离 11.5GB 的可用余量还很远。

## 启动参数

\`\`\`bash
flashcat run qwen2.5-3b-instruct \\
  --quant q4_k_m \\
  --parallel 4 \\
  --ctx-size 512 \\
  --batch-size 8 \\
  --flash-attn
\`\`\`

关键在 \`--parallel 4\` 与 \`--ctx-size 512\` 的组合：并行度靠多留 slot，上下文给足单轮即可，不要为了「安全」把 ctx 设成 8192，那会让每路 KV 膨胀到 2.9GB。

| 并发 | 吞吐 tok/s | 首字 p50 | KV 占用 |
| --- | --- | --- | --- |
| 1 | 46.2 | 184ms | 0.9 GB |
| 2 | 71.4 | 212ms | 1.6 GB |
| 4 | 88.6 | 268ms | 3.1 GB |

四路时吞吐接近翻倍，但首字延迟涨了 84ms——这是批处理等待的代价，不是故障。

- 单条长文（>2k token）建议临时降回 \`--parallel 2\`，否则首字会拖到 600ms
- 显存紧张时优先降 \`--batch-size\`，它是可逆的，context 不可逆
- 想再省 400MB 就开 \`--kv-cache-quant q4\`，代价是长上下文的召回率掉 3 个点`,
    stats: { tokens: 486, ms: 11_240 },
  },
];
