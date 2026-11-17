import { useCallback, useEffect, useRef, useState } from "react";
import type { ReactNode } from "react";
import { Icon } from "./icons";
import type { IconName } from "./icons";
import { useChatEngine } from "./chat";
import type { AppInfo, ModelCard } from "./bridge";
import { bridge, isTauri, win } from "./bridge";
import type { EngineStatus } from "./bridge";
import { Chat } from "./pages/Chat";
import { Overview } from "./pages/Overview";
import { Models } from "./pages/Models";
import { Settings } from "./pages/Settings";
import { engine, navGroups, recents, seedMessages } from "./data/mock";

export type Page = "overview" | "chat" | "models" | "engines" | "logs" | "settings" | "lab";

const titles: Record<Page, string> = {
  overview: "概览",
  chat: "对话",
  models: "模型",
  engines: "引擎",
  logs: "日志",
  settings: "设置",
  lab: "实验",
};

/* 自绘窗口控制：decorations=false 之后系统红绿灯不再出现，
   这三颗按钮就是它们；浏览器预览里整块不渲染。 */
function WindowControls() {
  return (
    <div className="win-controls">
      <button className="wc" data-wc="close" type="button" aria-label="关闭" onClick={() => void win.close()} />
      <button className="wc" data-wc="min" type="button" aria-label="最小化" onClick={() => void win.minimize()} />
      <button className="wc" data-wc="max" type="button" aria-label="缩放" onClick={() => void win.toggleMaximize()} />
    </div>
  );
}

/* 手机导航：底部标签栏是 iOS/Android 都认的原生语言，比「藏在左上角的汉堡」好按得多。
   抽屉只留「更多」：最近对话、设置、引擎、日志、实验都在里面。 */
function MobileTabs({ page, onNavigate }: { page: Page; onNavigate: (p: Page) => void }) {
  /* 手机上只留三个页面：对话是主场，模型和设置是它的两个抽屉。
     概览/引擎/日志这些是桌面运维视角，塞进手机只会让主界面变成仪表盘。 */
  const items: { page: Page; label: string; icon: IconName }[] = [
    { page: "chat", label: "对话", icon: "bubble" },
    { page: "models", label: "模型", icon: "stack" },
    { page: "settings", label: "设置", icon: "slider" },
  ];
  return (
    <nav className="tabbar" aria-label="主导航">
      {items.map((i) => (
        <button
          key={i.page}
          className="tab"
          type="button"
          data-active={page === i.page ? "true" : undefined}
          onClick={() => onNavigate(i.page)}
        >
          <Icon name={i.icon} size={22} strokeWidth={1.45} />
          <span>{i.label}</span>
        </button>
      ))}
    </nav>
  );
}

/* 手机上的「历史」：只有最近对话，不再有引擎/日志/实验。
   对话是主场，这些是它的附页，不该和主界面并列。 */
function MobileDrawer({
  open,
  onClose,
  onNewThread,
}: {
  open: boolean;
  onClose: () => void;
  onNewThread: () => void;
}) {
  return (
    <aside className="sidebar" data-open={open ? "true" : undefined} aria-hidden={open ? undefined : true}>
      <div className="sidebar-top">
        <span className="drawer-title">对话</span>
        <button className="ghost-btn" type="button" onClick={onClose} aria-label="收起">
          <Icon name="chevron" size={12} />
        </button>
      </div>
      <button className="pill-btn drawer-new" type="button" onClick={onNewThread}>
        <span className="ico" style={{ display: "grid" }}>
          <Icon name="plus" size={10} strokeWidth={1.8} />
        </span>
        新对话
      </button>
      <div className="recents scroll">
        {recents.map((r) => (
          <button key={r.id} className="recent" type="button" onClick={onClose}>
            <span className="title">{r.title}</span>
            <span className="time">{r.time}</span>
          </button>
        ))}
        <div className="recents-empty">保留最近 14 条</div>
      </div>
    </aside>
  );
}

function Sidebar({
  page,
  onNavigate,
  onToggle,
  engineLabel,
}: {
  page: Page;
  onNavigate: (p: Page) => void;
  onToggle: () => void;
  engineLabel: string;
}) {
  return (
    <aside className="sidebar">
      <div className="sidebar-top" data-tauri-drag-region />

      <nav className="nav">
        {navGroups.map((group, gi) => (
          <div key={gi} style={{ display: "contents" }}>
            {group.label ? <div className="section-label">{group.label}</div> : null}
            {group.pages.map((item) => (
              <button
                key={item.page}
                className="nav-row"
                data-active={page === item.page ? "true" : undefined}
                type="button"
                onClick={() => onNavigate(item.page as Page)}
              >
                <span className="ico">
                  <Icon name={item.icon as IconName} size={13} />
                </span>
                {item.label}
                {item.page === "logs" ? <span className="badge">3</span> : null}
              </button>
            ))}
          </div>
        ))}
      </nav>

      <div className="section-label">
        <span className="grow">最近对话</span>
        <button className="pill-btn" type="button" onClick={() => onNavigate("chat")}>
          <span className="ico" style={{ display: "grid" }}>
            <Icon name="plus" size={9} strokeWidth={1.8} />
          </span>
          新对话
        </button>
      </div>

      <div className="recents scroll">
        {recents.map((r) => (
          <button
            key={r.id}
            className="recent"
            data-active={r.id === "r1" && page === "chat" ? "true" : undefined}
            type="button"
            onClick={() => onNavigate("chat")}
          >
            <span className="title">{r.title}</span>
            <span className="time" data-generating={r.generating ? "true" : undefined}>
              {r.generating ? "···" : r.time}
            </span>
          </button>
        ))}
        <div className="recents-empty">共 7 条，保留最近 14 条</div>
      </div>

      <div className="sidebar-spacer" />

      <div className="sidebar-footer">
        <div className="divider" />
        <div className="footer-row">
          <button className="ghost-btn" type="button" onClick={() => onNavigate("settings")}>
            <Icon name="slider" size={12} />
            设置
          </button>
          <span style={{ flex: 1 }} />
          <button className="ghost-btn" type="button" title="收进侧栏" onClick={onToggle}>
            <Icon name="panel" size={12} />
          </button>
        </div>
      </div>

      <div className="island" data-tone="ok">
        <span className="dot" />
        <b>引擎</b>
        {engineLabel}
      </div>
    </aside>
  );
}

function Placeholder({ page }: { page: Page }) {
  return (
    <div className="page">
      <div className="page-scroll scroll">
        <div className="page-inner">
          <div className="empty" style={{ minHeight: "calc(100vh - 150px)" }}>
            <div className="mark">
              <Icon name={(page === "lab" ? "flask" : page === "models" ? "stack" : page === "engines" ? "cpu" : page === "logs" ? "doc" : "slider") as IconName} size={20} strokeWidth={1.3} />
            </div>
            <h2>{titles[page]}</h2>
            <p>
              这一页还没接上数据。壳、侧栏、标题栏与设计 token 已经就位，
              页面本体按同一套「仪器化」语言逐页补齐。
            </p>
          </div>
        </div>
      </div>
    </div>
  );
}

/* 开发期参数：?page=overview&theme=light&sidebar=0 —— 用于无头截图逐页核对。 */
const q = new URLSearchParams(location.search);

export default function App() {
  const shell = isTauri();
  const edge = useRef<{ x: number; y: number } | null>(null);
  const [mobile, setMobile] = useState(() => document.documentElement.dataset.mobile === "true");
  const [status, setStatus] = useState<EngineStatus | null>(null);
  const [info, setInfo] = useState<AppInfo | null>(null);
  const [models, setModels] = useState<ModelCard[]>([]);
  const [page, setPage] = useState<Page>((q.get("page") as Page) || "chat");
  // 手机上侧栏是抽屉，进页面时不占位置：默认收着，点左上角才出来。
  const [sidebar, setSidebar] = useState<boolean>(() =>
    document.documentElement.dataset.mobile === "true" ? q.get("sidebar") === "1" : q.get("sidebar") !== "0"
  );
  // 初值取 main.tsx 已经在首帧前算好的那个（手机上是系统外观，桌面上是上次的选择）
  const [theme, setTheme] = useState<"dark" | "light">(() =>
    document.documentElement.dataset.theme === "light" ? "light" : "dark"
  );
  const chat = useChatEngine(seedMessages);

  const navigate = (p: Page) => {
    // 手机上只有三页：其余页面是桌面运维视角，落到它们时退回对话，
    // 免得从 URL 或旧状态进到一个没有出口的页面。
    const allowed: Page[] = ["chat", "models", "settings"];
    setPage(mobile && !allowed.includes(p) ? "chat" : p);
    if (mobile) setSidebar(false);
  };

  useEffect(() => {
    document.documentElement.dataset.theme = theme;
    // 手机上外观跟系统走，不落 localStorage；桌面记住用户的选择。
    if (!mobile) localStorage.setItem("flashcat.theme", theme);
  }, [theme, mobile]);

  // 系统切换深浅色时，手机界面跟着变（状态栏图标也由系统同步换色）
  useEffect(() => {
    if (!mobile) return;
    const mq = window.matchMedia("(prefers-color-scheme: light)");
    const on = () => setTheme(mq.matches ? "light" : "dark");
    mq.addEventListener("change", on);
    return () => mq.removeEventListener("change", on);
  }, [mobile]);

  // 只有进了 Tauri 才有真后端；浏览器预览继续用 mock 读数。
  // 顺带回传一条自检日志：它是「WebView 渲染完成 + IPC 往返通」的证据，
  // 在 iOS / Android 上没有 devtools 时，这是唯一能拿到的启动信号。
  useEffect(() => {
    if (!shell) return;
    // 空闲时先把权重读进内存：手机上这是十几秒的 IO，放进首条消息就是「点了没反应」。
    void bridge.warm();
    bridge
      .status()
      .then(async (s) => {
        setStatus(s);
        const info = await bridge.info();
        setInfo(info);
        // 权重清单也在这里拉：模型页与状态栏用的是同一份快照。
        setModels(await bridge.models());
        // 用 Rust 侧的真实平台校正首帧的 UA 推断（浏览器预览走不到这里）。
        document.documentElement.dataset.platform = info.platform;
        if (info.platform === "android" || info.platform === "ios") {
          document.documentElement.dataset.mobile = "true";
          setMobile(true);
        }
        await bridge.log(
          "info",
          `shell ready · ${info.platform}/${info.arch} · v${info.version} · ` +
            `backend=${s.backend} model=${s.modelId ?? "none"} state=${s.state}`
        );
      })
      .catch((e) => void bridge.log("error", `bootstrap failed: ${String(e)}`));
  }, [shell]);

  /** 下载/加载/删除之后重新取一份清单：模型页不做本地乐观更新，
      以 Rust 侧扫描结果为准（磁盘才是唯一事实）。 */
  const refreshModels = useCallback(() => {
    if (!shell) return;
    void Promise.all([bridge.status(), bridge.models()]).then(([s, m]) => {
      setStatus(s);
      setModels(m);
    });
  }, [shell]);

  // 开发期：?demo=stream 自动发一轮，用来无头核对流式中的思考块 / 光标 / 结算读数
  useEffect(() => {
    if (q.get("demo") !== "stream") return;
    const t = window.setTimeout(() => chat.send("再帮我压一压首字延迟？"), 300);
    return () => window.clearTimeout(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  let body: ReactNode;
  if (page === "overview") {
    body = <Overview />;
  } else if (page === "chat") {
    body = (
      <Chat
        messages={chat.messages}
        generating={chat.generating}
        live={chat.live}
        onSend={chat.send}
        onStop={chat.stop}
        onNewThread={chat.reset}
        model={models.find((m) => m.id === status?.modelId) ?? models[0] ?? null}
        onHistory={mobile ? () => setSidebar(true) : undefined}
      />
    );
  } else if (page === "models") {
    body = <Models info={info} models={models} status={status} onChanged={refreshModels} />;
  } else if (page === "settings") {
    body = (
      <Settings
        info={info}
        status={status}
        models={models}
        onChanged={refreshModels}
        onNavigate={(p) => navigate(p)}
      />
    );
  } else {
    body = <Placeholder page={page} />;
  }

  return (
    <div
      className="app"
      data-sidebar={sidebar ? "shown" : "hidden"}
      data-mobile={mobile ? "true" : undefined}
      data-shell={shell ? "tauri" : undefined}
      /* 屏幕左缘内滑打开抽屉：手机上人人都会试一下的手势，缺了它就像网页。 */
      onTouchStart={(e) => {
        if (!mobile) return;
        const t = e.touches[0];
        edge.current = { x: t.clientX, y: t.clientY };
      }}
      onTouchMove={(e) => {
        if (!mobile || !edge.current) return;
        const t = e.touches[0];
        const dx = t.clientX - edge.current.x;
        const dy = t.clientY - edge.current.y;
        if (Math.abs(dy) > Math.abs(dx)) return;
        // 抽屉开着：向左甩就收回（和开着抽屉的键盘一样，是肌肉记忆）
        if (sidebar) {
          if (dx < -52) {
            setSidebar(false);
            edge.current = null;
          }
          return;
        }
        // 关着：只认屏幕左缘起手，别和页面横滑抢手势
        if (edge.current.x > 28) return;
        if (dx > 52) {
          setSidebar(true);
          edge.current = null;
        }
      }}
      onTouchEnd={() => {
        edge.current = null;
      }}
    >
      {shell && !mobile ? <WindowControls /> : null}
      {mobile && sidebar ? <div className="scrim" onClick={() => setSidebar(false)} /> : null}
      {mobile ? (
        <MobileDrawer
          open={sidebar}
          onClose={() => setSidebar(false)}
          onNewThread={() => {
            chat.reset();
            setSidebar(false);
            navigate("chat");
          }}
        />
      ) : (
        <Sidebar
          page={page}
          onNavigate={navigate}
          onToggle={() => setSidebar(false)}
          engineLabel={status ? `${status.backend} · ${status.quantization ?? "fp16"}` : engine.state}
        />
      )}

      <div className="titlebar" data-tauri-drag-region>
        {/* 手机上导航在底部标签栏，标题栏不再放汉堡：两个入口指向同一处只会让人犹豫 */}
        {mobile ? null : (
          <button className="toggle" type="button" onClick={() => setSidebar((v) => !v)} title="显示/隐藏侧栏">
            <Icon name="panel" size={13} />
          </button>
        )}
        <div className="title-crumbs">
          <b>{titles[page]}</b>
          {/* 手机上不显示网关地址：那是桌面调试信息，手机上一没有网关二看不懂 */}
          {page === "chat" ? <span>· 本地</span> : mobile ? null : <span>· 127.0.0.1:9000</span>}
        </div>
        <div style={{ flex: 1 }} />
        {mobile ? null : (
          <button
            className="toggle"
            type="button"
            onClick={() => setTheme((t) => (t === "dark" ? "light" : "dark"))}
            title="切换外观"
          >
            <Icon name={theme === "dark" ? "sun" : "moon"} size={13} />
          </button>
        )}
      </div>

      {body}

      {mobile ? (
        <MobileTabs page={page} onNavigate={navigate} />
      ) : null}
    </div>
  );
}
