import { Icon } from "../icons";
import { engine, kpis, requests, throughput } from "../data/mock";

function Hero() {
  return (
    <div className="hero">
      <div>
        <h1>
          {engine.model}
          <span className="chip">{engine.variant}</span>
        </h1>
        <div className="status">
          <span className="live-dot" />
          引擎{engine.state} · 已加载 {engine.loaded} 个模型 · {engine.memory}
        </div>
      </div>
      <div className="hero-actions">
        <button className="btn" type="button">
          <Icon name="bolt" size={12} />
          预热
        </button>
        <button className="btn" type="button">
          重新加载
        </button>
        <button className="btn" data-variant="ink" type="button">
          <Icon name="gear" size={12} />
          引擎设置
        </button>
      </div>
    </div>
  );
}

function Kpis() {
  return (
    <div className="kpi">
      {kpis.map((k) => (
        <div className="kpi-cell" key={k.label}>
          <div className="label">{k.label}</div>
          <div className="value" data-tone={"tone" in k ? k.tone : undefined}>
            {k.value}
            <span className="unit">{k.unit}</span>
          </div>
          <div className="sub">{k.sub}</div>
        </div>
      ))}
    </div>
  );
}

function Chart() {
  const peak = Math.max(...throughput);
  const now = throughput[throughput.length - 1];
  return (
    <div className="card chart">
      <div className="card-head" style={{ padding: "10px 14px 0" }}>
        <h3>生成吞吐</h3>
        <span className="aside">
          近 60 秒 · 全模型
        </span>
      </div>
      <div className="axis" style={{ marginTop: 8 }}>
        <div className="big">
          {now}
          <span className="unit">tok/s</span>
        </div>
        <span className="peak">峰值 {peak} · 均值 42.8</span>
      </div>
      <div className="bars">
        {throughput.map((v, i) => (
          <i
            key={i}
            data-last={i === throughput.length - 1 ? "true" : undefined}
            style={{ height: `${(v / peak) * 100}%` }}
          />
        ))}
      </div>
      <div className="chart-foot">
        <span>-60s</span>
        <span>-30s</span>
        <span>now</span>
      </div>
    </div>
  );
}

function GatewayCard() {
  return (
    <div className="card">
      <div className="card-head">
        <h3>API 网关</h3>
        <span className="aside">
          <span className="live-dot" />
          监听中
        </span>
      </div>
      <div className="card-body">
        <div className="endpoint">
          {engine.endpoint}
          <button
            className="copy"
            type="button"
            title="复制"
            onClick={() => navigator.clipboard?.writeText(engine.endpoint)}
          >
            <Icon name="copy" size={11} />
          </button>
        </div>
        <div className="dialects">
          <span className="tag" data-tone="ok">
            OpenAI · ok
          </span>
          <span className="tag" data-tone="ok">
            Anthropic · ok
          </span>
        </div>
        <div style={{ marginTop: 6 }}>
          <div className="kv">
            <span className="k">端口</span>
            <span className="v">9000</span>
          </div>
          <div className="kv">
            <span className="k">密钥</span>
            <span className="v">2 个 · 已验证</span>
          </div>
          <div className="kv">
            <span className="k">今日请求</span>
            <span className="v">1,284</span>
          </div>
        </div>
      </div>
    </div>
  );
}

function RuntimeCard() {
  return (
    <div className="card">
      <div className="card-head">
        <h3>运行时</h3>
        <span className="aside">{engine.uptime}</span>
      </div>
      <div className="card-body">
        <div className="kv">
          <span className="k">后端</span>
          <span className="v">{engine.backend}</span>
        </div>
        <div className="kv">
          <span className="k">上下文</span>
          <span className="v">{engine.context.toLocaleString()}</span>
        </div>
        <div className="kv">
          <span className="k">并发槽</span>
          <span className="v accent">{engine.parallel} / 4</span>
        </div>
        <div className="kv">
          <span className="k">内存</span>
          <span className="v">{engine.memory}</span>
        </div>
        <div className="kv">
          <span className="k">KV 命中</span>
          <span className="v">63.4%</span>
        </div>
      </div>
    </div>
  );
}

function Requests() {
  return (
    <div className="card">
      <div className="card-head" style={{ paddingBottom: 10 }}>
        <h3>最近请求</h3>
        <span className="aside">
          实时
          <span className="live-dot" style={{ marginLeft: 2 }} />
        </span>
      </div>
      <div style={{ padding: "0 14px 6px" }}>
        <table className="table">
          <thead>
            <tr>
              <th>时间</th>
              <th>模型</th>
              <th>方言</th>
              <th style={{ textAlign: "right" }}>输入</th>
              <th style={{ textAlign: "right" }}>输出</th>
              <th style={{ textAlign: "right" }}>延迟</th>
              <th>状态</th>
            </tr>
          </thead>
          <tbody>
            {requests.map((r) => (
              <tr key={r.time}>
                <td className="mono">{r.time}</td>
                <td>
                  <strong>{r.model}</strong>
                </td>
                <td>
                  <span className="tag">{r.dialect}</span>
                </td>
                <td className="mono" style={{ textAlign: "right" }}>
                  {r.input.toLocaleString()}
                </td>
                <td className="mono" style={{ textAlign: "right" }}>
                  {r.output ? r.output.toLocaleString() : "—"}
                </td>
                <td className="mono" style={{ textAlign: "right" }}>
                  {r.latency}
                </td>
                <td>
                  {r.status === "ok" ? (
                    <span className="tag" data-tone="ok">
                      200
                    </span>
                  ) : (
                    <span className="tag" style={{ color: "var(--err)", borderColor: "var(--err)" }}>
                      429
                    </span>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}

export function Overview() {
  return (
    <div className="page">
      <div className="page-scroll scroll">
        <div className="page-inner">
          <Hero />
          <Kpis />
          <div className="mid">
            <Chart />
            <div style={{ display: "flex", flexDirection: "column", gap: 14 }}>
              <GatewayCard />
              <RuntimeCard />
            </div>
          </div>
          <Requests />
        </div>
      </div>
    </div>
  );
}
