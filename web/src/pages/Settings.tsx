import type { AppInfo, EngineStatus, ModelCard } from "../bridge";
import { bridge, isTauri } from "../bridge";

/**
 * 设置页：手机上三页之一。
 *
 * 这里刻意不放引擎/日志那些仪表：手机上用户想知道的只有
 * 「我在用什么模型、东西存在哪、这个版本是什么、要不要清缓存」。
 */
export function Settings({
  info,
  status,
  models,
  onChanged,
  onNavigate,
}: {
  info: AppInfo | null;
  status: EngineStatus | null;
  models: ModelCard[];
  onChanged: () => void;
  onNavigate: (page: "models") => void;
}) {
  const dir = info?.modelDir ?? null;
  const tauri = isTauri();
  const loaded = models.find((m) => m.id === status?.modelId) ?? null;
  const total = models.reduce((n, m) => n + m.sizeMb, 0);

  const row = (label: string, value: string, action?: { text: string; run: () => void }) => (
    <div className="set-row" key={label}>
      <span className="set-label">{label}</span>
      <span className="set-value mono">{value}</span>
      {action ? (
        <button type="button" className="btn" onClick={action.run}>
          {action.text}
        </button>
      ) : null}
    </div>
  );

  return (
    <div className="page">
      <div className="page-scroll scroll">
        <div className="page-inner">
          <div className="hero">
            <div>
              <h1>设置</h1>
              <div className="status">
                <span className="live-dot" data-state={status?.state === "ready" ? "ok" : "idle"} />
                <span>{info?.name ?? "FlashCat"} {info?.version ?? ""}</span>
              </div>
            </div>
          </div>

          <div className="card">
            <div className="card-head">
              <h3>当前模型</h3>
            </div>
            <div className="set-list">
              {row("模型", loaded ? loaded.name : "未加载")}
              {row("量化", loaded ? loaded.quantization : "—")}
              {row("上下文", loaded ? `${loaded.context} token` : "—")}
              {row("后端", status?.backend ?? "无后端")}
            </div>
          </div>

          <div className="card" style={{ marginTop: 14 }}>
            <div className="card-head">
              <h3>存储</h3>
              <span className="aside">{models.length} 个权重 · {(total / 1024).toFixed(2)} GB</span>
            </div>
            <div className="set-list">
              {row(
                "权重目录",
                dir ? dir.replace(/^.*\//, "…/") + "/" : "浏览器预览",
                dir ? { text: "复制", run: () => void navigator.clipboard?.writeText(dir) } : undefined
              )}
              {row(
                "打开模型页",
                "下载 / 切换 / 删除",
                { text: "打开", run: () => onNavigate("models") }
              )}
            </div>
          </div>

          <div className="card" style={{ marginTop: 14 }}>
            <div className="card-head">
              <h3>外观</h3>
            </div>
            <div className="set-list">
              {row("主题", "跟随系统（手机）", undefined)}
              {row("平台", `${info?.platform ?? "预览"} · ${info?.arch ?? "—"}`, undefined)}
            </div>
            <div className="set-note">
              手机上外观跟随系统深浅色：这样 Android 的状态栏图标与界面永远一致，不会出现「浅色底 + 白图标」。
            </div>
          </div>

          <div className="card" style={{ marginTop: 14 }}>
            <div className="card-head">
              <h3>维护</h3>
            </div>
            <div className="set-list">
              {row(
                "预热权重",
                "把 gguf 读进内存",
                { text: "预热", run: () => { void bridge.warm(); onChanged(); } }
              )}
              {row(
                "刷新状态",
                "重新扫描权重目录",
                { text: "刷新", run: onChanged }
              )}
            </div>
            <div className="set-note">
              日志：{info?.platform === "android" ? "logcat 里搜 RustStdoutStderr" : "应用日志目录 / flashcat.log"}
              。{tauri ? "" : "（浏览器预览没有后端，按钮不会真正生效。）"}
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
