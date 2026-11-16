import type { AppInfo, EngineStatus, ModelCard } from "../bridge";
import { Icon } from "../icons";

/**
 * 模型页：本地权重的真实清单。
 *
 * 这一页的数据全部来自 Rust 侧扫描权重目录（`engine.models()`），
 * 浏览器预览里没有后端，所以走空态——但空态也不是一句「没数据」，
 * 而是把「该把 gguf 放哪」直接给出来。
 */
export function Models({
  info,
  models,
  status,
}: {
  info: AppInfo | null;
  models: ModelCard[];
  status: EngineStatus | null;
}) {
  const dir = info?.modelDir ?? null;
  const loaded = status?.modelId ?? null;
  const total = models.reduce((n, m) => n + m.sizeMb, 0);

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
              <h3>本地权重</h3>
              <span className="aside mono">{dir ?? "浏览器预览无权重目录"}</span>
            </div>
            {models.length === 0 ? (
              <div className="empty" style={{ minHeight: 260 }}>
                <div className="mark">
                  <Icon name="stack" size={20} strokeWidth={1.3} />
                </div>
                <h2>还没有权重</h2>
                <p>
                  把 <code>.gguf</code> 放进上面那个目录，重启即可加载。
                  手机端可以先用「文件」/「下载」存到本地，再复制进应用目录。
                </p>
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
                      <th>家族</th>
                      <th>量化</th>
                      <th style={{ textAlign: "right" }}>参数</th>
                      <th style={{ textAlign: "right" }}>大小</th>
                      <th style={{ textAlign: "right" }}>上下文</th>
                      <th>状态</th>
                    </tr>
                  </thead>
                  <tbody>
                    {models.map((m) => (
                      <tr key={m.id}>
                        <td>
                          <strong>{m.name}</strong>
                        </td>
                        <td>{m.family}</td>
                        <td>
                          <span className="tag mono">{m.quantization}</span>
                        </td>
                        <td className="mono" style={{ textAlign: "right" }}>
                          {m.paramsB ? `${m.paramsB}B` : "—"}
                        </td>
                        <td className="mono" style={{ textAlign: "right" }}>
                          {m.sizeMb >= 1024 ? `${(m.sizeMb / 1024).toFixed(2)} GB` : `${m.sizeMb} MB`}
                        </td>
                        <td className="mono" style={{ textAlign: "right" }}>
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
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </div>

          <div className="card" style={{ marginTop: 14 }}>
            <div className="card-head">
              <h3>怎么加权重</h3>
            </div>
            <div style={{ padding: "0 14px 14px", fontSize: 13, lineHeight: 1.7, color: "var(--text2)" }}>
              <p>
                1. 下载任意 <code>.gguf</code>（Q4_K_M 在手机与桌面都是最稳的选择）。
              </p>
              <p>
                2. 放进 <code>{dir ?? "权重目录"}</code>，文件名随意，量化与参数量会从文件名解析。
              </p>
              <p>
                3. 重启应用：启动时会扫描目录并预热权重，首条消息不再等十几秒。
              </p>
              <p style={{ color: "var(--text3)" }}>
                手机上内存紧张：≤1.7B / Q4 的模型在 4GB 可用内存内比较安全，
                8B 级别请留给桌面。
              </p>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
