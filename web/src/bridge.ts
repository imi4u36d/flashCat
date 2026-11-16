/* 唯一的前后端通道。
   浏览器里（pnpm dev / 静态预览）所有调用都会走 mock 分支，页面照样能跑；
   进了 Tauri 就是真实 IPC，命令名与载荷见 src-tauri/src/commands.rs。 */

export type Platform = "macos" | "windows" | "linux" | "ios" | "android";

export type AppInfo = {
  name: string;
  version: string;
  platform: Platform;
  arch: string;
  mobile: boolean;
  modelDir: string | null;
};

export type SystemInfo = { cpuCount: number; platform: Platform; accelerator: string };

export type EngineStatus = {
  backend: string;
  state: "idle" | "loading" | "ready" | "error";
  modelId: string | null;
  residentMb: number;
  tokensPerSec: number | null;
  quantization: string | null;
};

export type ModelCard = {
  id: string;
  name: string;
  family: string;
  paramsB: number;
  quantization: string;
  sizeMb: number;
  context: number;
  tags: string[];
  platforms: Platform[];
  installed: boolean;
  note: string | null;
};

export type ChatRequest = {
  threadId: string;
  message: string;
  modelId?: string | null;
  history: { role: string; content: string }[];
  temperature?: number;
  maxTokens?: number;
};

export type Delta =
  | { kind: "thinking"; runId: string; delta: string }
  | { kind: "text"; runId: string; delta: string }
  | {
      kind: "usage";
      runId: string;
      inputTokens: number;
      outputTokens: number;
      firstTokenMs: number;
      totalMs: number;
      tokensPerSec: number;
      modelId: string;
    }
  | { kind: "done"; runId: string }
  | { kind: "error"; runId: string; message: string };

export const isTauri = (): boolean =>
  typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;

/* 动态 import：浏览器预览时不必把 @tauri-apps/api 拉进首包。 */
async function ipc<T>(cmd: string, args?: Record<string, unknown>): Promise<T> {
  const { invoke } = await import("@tauri-apps/api/core");
  return invoke<T>(cmd, args);
}

export const bridge = {
  info: () => ipc<AppInfo>("app_info"),
  system: () => ipc<SystemInfo>("system_info"),
  status: () => ipc<EngineStatus>("engine_status"),
  models: () => ipc<ModelCard[]>("list_models"),
  chatStart: (req: ChatRequest) => ipc<string>("chat_start", { req }),
  /** 预热权重：调用即返回，后端在后台加载，失败只记日志。 */
  async warm(): Promise<void> {
    try {
      const { invoke } = await import("@tauri-apps/api/core");
      await invoke("engine_warm");
    } catch {
      /* 没有后端（浏览器预览）时忽略 */
    }
  },

  chatCancel: (runId: string) => ipc<boolean>("chat_cancel", { runId }),

  /** 前端日志回传：移动端没有 devtools，出错时只能靠它把话传到 stdout / 系统日志。 */
  log: (level: "debug" | "info" | "warn" | "error", message: string) =>
    ipc<void>("log_frontend", { level, message }).catch(() => {}),

  /** 订阅流式增量，返回取消订阅函数。 */
  onDelta: async (cb: (d: Delta) => void): Promise<() => void> => {
    const { listen } = await import("@tauri-apps/api/event");
    const un = await listen<Delta>("chat:delta", (e) => cb(e.payload));
    return un;
  },
};

/** 自绘标题栏的窗口控制；浏览器里是空操作（失败静默，预览不报错）。 */
async function window_() {
  const { getCurrentWindow } = await import("@tauri-apps/api/window");
  return getCurrentWindow();
}

export const win = {
  minimize: () => window_().then((w) => w.minimize()).catch(() => {}),
  toggleMaximize: () => window_().then((w) => w.toggleMaximize()).catch(() => {}),
  close: () => window_().then((w) => w.close()).catch(() => {}),
};
