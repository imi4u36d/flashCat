import { useEffect, useRef, useState } from "react";
import type { AppInfo, DownloadProgress, EngineStatus, ForeignModel, ModelCard } from "../bridge";
import { bridge, isTauri } from "../bridge";
import { Icon } from "../icons";

/** 能一键下载的权重：只放「手机上真的跑得动」的尺寸，避免用户先下 5GB 再发现内存不够。 */
const PRESETS = [
  {
    name: "Qwen3-0.6B-Q4_K_M.gguf",
    label: "Qwen3 0.6B · Q4_K_M",
    note: "默认推荐：中文可用，内存约 0.9GB，模拟器也能跑",
    sizeMb: 378,
    url: "https://huggingface.co/unsloth/Qwen3-0.6B-GGUF/resolve/main/Qwen3-0.6B-Q4_K_M.gguf?download=true",
  },
  {
    name: "Qwen3-1.7B-Q4_K_M.gguf",
    label: "Qwen3 1.7B · Q4_K_M",
    note: "更聪明一档：内存约 2.2GB，建议 8GB 以上的机器",
    sizeMb: 1100,
    url: "https://huggingface.co/unsloth/Qwen3-1.7B-GGUF/resolve/main/Qwen3-1.7B-Q4_K_M.gguf?download=true",
  },
];

const mb = (bytes: number) => `${(bytes / 1024 / 1024).toFixed(0)} MB`;

/**
 * 模型页：本地权重的真实清单 + 应用内下载。
 *
 * 为什么下载放在这里而不是「设置」：手机上装完 APK 之后，用户没有任何手段
 * 把 400MB 的 gguf 放进沙盒——这一页就是「拿到模型」的唯一入口。
 */
/** 旧版桌面 App 的权重库，扫到了就标出来，免得用户以为是新下的。 */
function originHint(source: string): string {
  return /Application Support\/(flashCat|Splash)\//.test(source) ? "旧库 · " : "";
}

function shortSource(source: string): string {
  const parts = source.split("/").filter(Boolean);
  return parts.slice(-2).join("/");
}

export function Models({
  info,
  models,
  status,
  foreign,
  onChanged,
}: {
  info: AppInfo | null;
  models: ModelCard[];
  status: EngineStatus | null;
  /** 旧库里 mlx / safetensors 这类 llama.cpp 读不了的权重（桌面才有）。 */
  foreign: ForeignModel[];
  onChanged: () => void;
}) {
  const dir = info?.modelDir ?? null;
  const loaded = status?.modelId ?? null;
  const total = models.reduce((n, m) => n + m.sizeMb, 0);
  const tauri = isTauri();
  const mobile = document.documentElement.dataset.mobile === "true";

  const [progress, setProgress] = useState<DownloadProgress | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busyId, setBusyId] = useState<string | null>(null);
  // 手机上点一行 → 底部动作表。表格里塞两枚按钮是桌面习惯，手指容易点错。
  const [sheet, setSheet] = useState<ModelCard | null>(null);
  const unsub = useRef<(() => void) | null>(null);

  useEffect(() => {
    if (!tauri) return;
    void bridge.onDownload((p) => {
      // 取消不是错误：把进度条收掉，别在界面上留一行红字吓人。
      if (p.cancelled) {
        setProgress(null);
        return;
      }
      setProgress(p);
      if (p.done) {
        setError(null);
        onChanged();
        // 下完直接切过去：用户点「下载」的意图就是「我要用它」。
        void bridge.selectModel(p.name.replace(/\.gguf$/, "")).then(onChanged).catch(() => {});
      }
      if (p.error) setError(p.error);
    }).then((un) => {
      unsub.current = un;
    });
    return () => {
      unsub.current?.();
      unsub.current = null;
    };
  }, [tauri, onChanged]);

  const downloading = progress !== null && !progress.done && !progress.error;
  const pct =
    progress && progress.total > 0
      ? Math.min(100, Math.round((progress.received / progress.total) * 100))
      : null;

  const installed = (name: string) => models.some((m) => `${m.id}.gguf` === name);

  // 开发期自检：?autodl=1 直接走一遍「下载 → 落盘 → 切换」，
  // 无头验证时不必在模拟器里点按钮（与 ?demo=stream 同类）。
  const autoRan = useRef(false);
  useEffect(() => {
    if (!tauri || autoRan.current) return;
    if (new URLSearchParams(window.location.search).get("autodl") !== "1") return;
    // StrictMode 会挂载两次并清掉第一次的定时器，所以标记要放在真正触发时。
    const t = window.setTimeout(() => {
      autoRan.current = true;
      start(PRESETS[0]);
    }, 400);
    return () => window.clearTimeout(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [tauri]);

  const start = (preset: (typeof PRESETS)[number]) => {
    setError(null);
    setProgress({ name: preset.name, received: 0, total: preset.sizeMb * 1024 * 1024, done: false, cancelled: false, error: null });
    void bridge.log("info", `download invoke ${preset.name}`);
    void bridge.download(preset.url, preset.name).catch((e) => {
      setProgress(null);
      setError(String(e));
      void bridge.log("error", `download invoke failed: ${String(e)}`);
    });
  };

  const act = (kind: "select" | "delete", id: string) => {
    setBusyId(id);
    setError(null);
    const call = kind === "select" ? bridge.selectModel(id) : bridge.deleteModel(id);
    void call
      .then(() => onChanged())
      .catch((e) => setError(String(e)))
      .finally(() => setBusyId(null));
  };

  return (
    <div className="page">
      <div className="page-scroll scroll">
        <div className="page-inner">
          <div className="hero">
            <div>
              <h1>模型</h1>
              <div className="status">
                <span className="live-dot" data-state={models.length ? "ok" : "idle"} />
                <span>
                  {info?.platform ?? "预览"}
                  <span className="dot">·</span>
                  {status?.backend ?? "无后端"}
                  <span className="dot">·</span>
                  {models.length} 个本地权重
                </span>
              </div>
            </div>
            <div className="hero-actions">
              <button
                type="button"
                className="btn"
                disabled={!dir}
                onClick={() => dir && void navigator.clipboard?.writeText(dir)}
              >
                复制权重目录
              </button>
            </div>
          </div>

          <div className="kpi" style={{ gridTemplateColumns: "repeat(3, 1fr)" }}>
            <div className="kpi-cell">
              <div className="label">已装权重</div>
              <div className="value">
                {models.length}
                <span className="unit">个</span>
              </div>
              <div className="sub">扫描自权重目录</div>
            </div>
            <div className="kpi-cell">
              <div className="label">磁盘占用</div>
              <div className="value">
                {(total / 1024).toFixed(2)}
                <span className="unit">GB</span>
              </div>
              <div className="sub">gguf 原始大小</div>
            </div>
            <div className="kpi-cell">
              <div className="label">当前加载</div>
              <div className="value" style={{ fontSize: 15 }}>
                {loaded ?? "—"}
              </div>
              <div className="sub">{status?.quantization ?? "未加载"}</div>
            </div>
          </div>

          <div className="card" style={{ marginTop: 14 }}>
            <div className="card-head" style={{ paddingBottom: 10 }}>
              <h3>下载模型</h3>
              <span className="aside">在应用内直接下载，不需要 adb 或数据线</span>
            </div>
            <div style={{ padding: "0 14px 14px", display: "grid", gap: 10 }}>
              {PRESETS.map((p) => {
                const has = installed(p.name);
                const isThis = progress?.name === p.name;
                return (
                  <div
                    key={p.name}
                    style={{
                      display: "flex",
                      alignItems: "center",
                      gap: 12,
                      padding: "10px 12px",
                      borderRadius: 12,
                      background: "var(--fill-2)",
                    }}
                  >
                    <div style={{ flex: 1, minWidth: 0 }}>
                      <div style={{ fontSize: 13, fontWeight: 590 }}>{p.label}</div>
                      <div style={{ fontSize: 12, color: "var(--text3)", marginTop: 2 }}>{p.note}</div>
                      {isThis && downloading ? (
                        <div style={{ marginTop: 8 }}>
                          <div className="bar" style={{ height: 4, borderRadius: 2, background: "var(--line2)" }}>
                            <div
                              style={{
                                width: pct === null ? "40%" : `${pct}%`,
                                height: "100%",
                                borderRadius: 2,
                                background: "var(--accent)",
                                transition: "width .2s linear",
                              }}
                            />
                          </div>
                          <div className="mono" style={{ fontSize: 11, color: "var(--text3)", marginTop: 4 }}>
                            {mb(progress.received)}
                            {progress.total ? ` / ${mb(progress.total)}` : ""}
                            {pct !== null ? ` · ${pct}%` : ""}
                          </div>
                        </div>
                      ) : null}
                    </div>
                    {isThis && downloading ? (
                      <button type="button" className="btn" onClick={() => void bridge.cancelDownload()}>
                        取消
                      </button>
                    ) : (
                      <button
                        type="button"
                        className="btn"
                        disabled={!tauri || has || (downloading && !isThis)}
                        onClick={() => start(p)}
                      >
                        {has ? "已装" : `${p.sizeMb >= 1024 ? (p.sizeMb / 1024).toFixed(1) + " GB" : p.sizeMb + " MB"}`}
                      </button>
                    )}
                  </div>
                );
              })}
              {error ? (
                <div className="mono" style={{ fontSize: 12, color: "var(--err)" }}>
                  {error}
                </div>
              ) : null}
              {!tauri ? (
                <div style={{ fontSize: 12, color: "var(--text3)" }}>
                  浏览器预览里没有后端，下载按钮只在应用内可用。
                </div>
              ) : null}
            </div>
          </div>

          <div className="card" style={{ marginTop: 14 }}>
            <div className="card-head" style={{ paddingBottom: 10 }}>
              <h3>本地权重</h3>
              <span className="aside mono">{dir ?? "浏览器预览无权重目录"}</span>
            </div>
            {models.length === 0 ? (
              <div className="empty" style={{ minHeight: 220 }}>
                <div className="mark">
                  <Icon name="stack" size={20} strokeWidth={1.3} />
                </div>
                <h2>还没有权重</h2>
                <p>上面点一个尺寸下载，或者把 .gguf 放进下面这个目录。</p>
                <p className="mono" style={{ fontSize: 12, color: "var(--text3)" }}>
                  {dir ?? "~/Library/Application Support/dev.flashcat.desktop/models"}
                </p>
              </div>
            ) : (
              <div style={{ padding: "0 14px 6px" }}>
                <table className="table">
                  <thead>
                    <tr>
                      <th>模型</th>
                      <th className="col-opt">家族</th>
                      <th className="col-opt">量化</th>
                      <th className="col-opt" style={{ textAlign: "right" }}>参数</th>
                      <th style={{ textAlign: "right" }}>大小</th>
                      <th className="col-opt" style={{ textAlign: "right" }}>上下文</th>
                      <th>状态</th>
                      <th />
                    </tr>
                  </thead>
                  <tbody>
                    {models.map((m) => (
                      <tr
                        key={m.id}
                        className="model-row"
                        onClick={() => (mobile ? setSheet(m) : undefined)}
                      >
                        <td>
                          <strong>{m.name}</strong>
                          {m.source ? (
                            <div className="src-line mono" title={m.source}>
                              {originHint(m.source)}
                              {shortSource(m.source)}
                            </div>
                          ) : null}
                        </td>
                        <td className="col-opt">{m.family}</td>
                        <td className="col-opt">
                          <span className="tag mono">{m.quantization}</span>
                        </td>
                        <td className="col-opt mono" style={{ textAlign: "right" }}>
                          {m.paramsB ? `${m.paramsB}B` : "—"}
                        </td>
                        <td className="mono" style={{ textAlign: "right" }}>
                          {m.sizeMb >= 1024 ? `${(m.sizeMb / 1024).toFixed(2)} GB` : `${m.sizeMb} MB`}
                        </td>
                        <td className="col-opt mono" style={{ textAlign: "right" }}>
                          {m.context}
                        </td>
                        <td>
                          {m.id === loaded ? (
                            <span className="tag" data-tone="ok">
                              已加载
                            </span>
                          ) : (
                            <span className="tag">就绪</span>
                          )}
                        </td>
                        <td className="row-actions" style={{ textAlign: "right", whiteSpace: "nowrap" }}>
                          <button
                            type="button"
                            className="btn"
                            disabled={!tauri || m.id === loaded || busyId === m.id}
                            onClick={() => act("select", m.id)}
                          >
                            加载
                          </button>
                          <button
                            type="button"
                            className="btn"
                            disabled={!tauri || busyId === m.id}
                            style={{ marginLeft: 6 }}
                            onClick={() => act("delete", m.id)}
                          >
                            删除
                          </button>
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </div>

          <div className="card" style={{ marginTop: 14 }}>
            <div className="card-head">
              <h3>手动放权重</h3>
            </div>
            <div style={{ padding: "0 14px 14px", fontSize: 13, lineHeight: 1.7, color: "var(--text2)" }}>
              <p>
                文件放进 <code>{dir ?? "权重目录"}</code>，文件名随意：量化与参数量从文件名解析。
              </p>
              <p>
                放好后点表格里的「加载」，或重启应用——启动时会自动预热，首条消息不再等十几秒。
              </p>
              <p style={{ color: "var(--text3)" }}>
                手机上内存紧张：≤1.7B / Q4 在 4GB 可用内存内比较安全，8B 级别请留给桌面。
              </p>
          {foreign.length > 0 ? (
            <div className="card" style={{ marginTop: 14 }}>
              <div className="card-head">
                <h3>旧库里的其它权重</h3>
                <span className="aside mono">{foreign.length} 个</span>
              </div>
              <div style={{ padding: "0 14px 14px", fontSize: 13, lineHeight: 1.7, color: "var(--text2)" }}>
                <p style={{ color: "var(--text3)" }}>
                  这些是旧版引擎的格式（mlx / safetensors / 打包量化），llama.cpp 读不了，所以不能加载。
                  要在这里跑，得转成 GGUF；不转的话可以留给旧引擎。
                </p>
                <ul className="legacy-list">
                  {foreign.slice(0, 12).map((f) => (
                    <li key={f.path}>
                      <span className="tag mono">{f.engine}</span>
                      <span className="legacy-name" title={f.path}>
                        {f.name}
                      </span>
                      <span className="mono legacy-size">
                        {f.sizeMb >= 1024 ? `${(f.sizeMb / 1024).toFixed(1)} GB` : `${f.sizeMb} MB`}
                      </span>
                    </li>
                  ))}
                </ul>
                {foreign.length > 12 ? (
                  <p style={{ color: "var(--text3)" }}>还有 {foreign.length - 12} 个未展开。</p>
                ) : null}
              </div>
            </div>
          ) : null}

              <p style={{ color: "var(--text3)" }}>
                桌面端还会读旧版 App 的库（<code>Application Support/flashCat/models</code>、
                <code>Application Support/Splash/models</code>），扫描到的 GGUF 标「旧库」直接能用；
                那里的 mlx / safetensors 是给旧引擎的，llama.cpp 读不了，不会列出。
              </p>
            </div>
          </div>
        </div>
      </div>

      {sheet ? (
        <div className="sheet-scrim" onClick={() => setSheet(null)}>
          <div className="sheet" onClick={(e) => e.stopPropagation()}>
            <div className="sheet-grabber" />
            <div className="sheet-title">
              <strong>{sheet.name}</strong>
              <span>
                {sheet.family} · {sheet.quantization} ·{" "}
                {sheet.sizeMb >= 1024 ? `${(sheet.sizeMb / 1024).toFixed(2)} GB` : `${sheet.sizeMb} MB`}
              </span>
            </div>
            <button
              type="button"
              className="sheet-item"
              disabled={!tauri || sheet.id === loaded || busyId === sheet.id}
              onClick={() => {
                act("select", sheet.id);
                setSheet(null);
              }}
            >
              {sheet.id === loaded ? "当前已加载" : "设为当前模型"}
            </button>
            <button
              type="button"
              className="sheet-item"
              disabled={!tauri || busyId === sheet.id}
              onClick={() => {
                void navigator.clipboard?.writeText(`${dir ?? ""}/${sheet.id}.gguf`);
              }}
            >
              复制文件路径
            </button>
            <button
              type="button"
              className="sheet-item"
              data-tone="danger"
              disabled={!tauri || busyId === sheet.id}
              onClick={() => {
                act("delete", sheet.id);
                setSheet(null);
              }}
            >
              删除这个权重
            </button>
            <button type="button" className="sheet-item" data-tone="cancel" onClick={() => setSheet(null)}>
              取消
            </button>
          </div>
        </div>
      ) : null}
    </div>
  );
}
