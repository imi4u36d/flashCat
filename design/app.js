/* ==========================================================================
   flashCat · 交互原型脚本
   无依赖，所有状态都在内存里；主题持久化在 localStorage。
   ========================================================================== */
(() => {
  'use strict';

  const $ = (sel, root = document) => root.querySelector(sel);
  const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));
  const clamp = (v, min, max) => Math.min(max, Math.max(min, v));
  const raf = (fn) => requestAnimationFrame(fn);

  const storage = {
    get(key) { try { return localStorage.getItem(key); } catch { return null; } },
    set(key, value) { try { localStorage.setItem(key, value); } catch { /* file:// */ } },
  };

  const state = {
    theme: document.documentElement.dataset.theme || 'light',
    sidebarCollapsed: storage.get('flashcat-sidebar') === 'collapsed',
    page: 'overview',
    service: 'running',
    speed: 74.2,
    chartRange: 45,
    history: [],
    modelId: 'mlx-community/Qwen3.8-27B-4bit',
    modelFilter: 'all',
    modelQuery: '',
    downloads: {},
    hiddenModels: new Set(),
    logs: [],
    logLevel: 'all',
    logQuery: '',
    autoscroll: true,
    logPaused: false,
    streaming: false,
    streamText: '',
    streamTimer: null,
    streamStarted: 0,
    streamTokens: 0,
    messages: [],
    temp: 0.7,
    topP: 0.95,
    thinking: '自动',
    systemPrompt: '',
    dirty: false,
    savedSettings: null,
    lastFocus: null,
  };

  const DEFAULT_SETTINGS = {
    port: '8000',
    autoStart: true,
    launchAtLogin: false,
    memory: '24G',
    context: '100K',
    keepWeights: true,
    languageOnly: false,
    thinking: '自动',
    effort: '中',
    model: 'mlx-community/Qwen3.8-27B-4bit',
    extra: '',
    cache: '',
  };

  /* ------------------------------------------------------------------ 数据 */

  const MODELS = [
    {
      id: 'mlx-community/Qwen3.8-27B-4bit', short: 'Qwen3.8-27B-4bit', hero: 'Qwen3.8-27B', quant: '4-bit · MLX',
      owner: 'mlx-community', params: '27B', size: '15.8 GB', ctx: '100K', family: 'Dense', avatar: 'Q', av: '',
      tags: ['DFlash2 就绪', '视觉', '本机'], state: 'installed', speed: '74.2',
    },
    {
      id: 'mlx-community/Qwen3.6-35B-A3B-4bit', short: 'Qwen3.6-35B-A3B-4bit', hero: 'Qwen3.6-35B-A3B', quant: '4-bit · MoE',
      owner: 'mlx-community', params: '35B · 3B 激活', size: '19.2 GB', ctx: '128K', family: 'MoE', avatar: 'Q6', av: 'av-2',
      tags: ['DFlash2 就绪', 'MoE', '本机'], state: 'installed', speed: '96.8',
    },
    {
      id: 'unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M', short: 'Qwen3.8-27B-GGUF', hero: 'Qwen3.8-27B-GGUF', quant: 'UD-Q4_K_M',
      owner: 'unsloth', params: '27B', size: '16.4 GB', ctx: '100K', family: 'GGUF', avatar: 'G', av: 'av-3',
      tags: ['标准解码', '本机'], state: 'installed', speed: '58.4',
    },
    {
      id: 'mlx-community/Qwen3.8-8B-4bit', short: 'Qwen3.8-8B-4bit', hero: 'Qwen3.8-8B', quant: '4-bit · MLX',
      owner: 'mlx-community', params: '8B', size: '4.9 GB', ctx: '64K', family: 'Dense', avatar: 'Q8', av: 'av-4',
      tags: ['DFlash2 就绪', '轻量', '本机'], state: 'installed', speed: '128.6',
    },
    {
      id: 'mlx-community/DeepSeek-R1-Distill-14B-4bit', short: 'DeepSeek-R1-14B', hero: 'DeepSeek-R1-14B', quant: '4-bit · MLX',
      owner: 'mlx-community', params: '14B', size: '8.1 GB', ctx: '64K', family: '推理', avatar: 'R', av: 'av-5',
      tags: ['标准解码', '本机'], state: 'installed', speed: '62.1',
    },
    {
      id: 'mlx-community/Qwen3.8-27B-6bit', short: 'Qwen3.8-27B-6bit', hero: 'Qwen3.8-27B', quant: '6-bit · MLX',
      owner: 'mlx-community', params: '27B', size: '21.5 GB', ctx: '100K', family: 'Dense', avatar: 'Q', av: '',
      tags: ['DFlash2 可下载', '视觉'], state: 'remote', speed: '68.0',
    },
    {
      id: 'unsloth/Qwen3.6-35B-A3B-GGUF:UD-Q5_K_M', short: 'Qwen3.6-35B-A3B-GGUF', hero: 'Qwen3.6-35B-A3B', quant: 'UD-Q5_K_M',
      owner: 'unsloth', params: '35B', size: '24.7 GB', ctx: '128K', family: 'GGUF', avatar: 'G', av: 'av-3',
      tags: ['标准解码', 'MoE'], state: 'remote', speed: '52.0',
    },
    {
      id: 'mlx-community/Gemma-4-12B-4bit', short: 'Gemma-4-12B-4bit', hero: 'Gemma-4-12B', quant: '4-bit · MLX',
      owner: 'mlx-community', params: '12B', size: '6.7 GB', ctx: '32K', family: 'Dense', avatar: 'Ge', av: 'av-4',
      tags: ['DFlash2 可下载', '视觉'], state: 'remote', speed: '88.0',
    },
  ];

  const RESPONSES = {
    logs: [
      '42ms 的首字延迟其实不算高——它已经是 **p50**，意味着一半请求比这更快。真正值得关注的是下面两件事：',
      '',
      '- **warmup 只跑了 3 次。** 首轮请求仍可能触发 Metal 内核编译，第一个 token 会被拖到 150ms 以上。把 warmup 提到 5 次，再观察 p95。',
      '- **草稿窗口 `8` 偏大。** 长上下文里草稿命中率下降时，DFlash2 会退化成标准解码，首字反而更慢；`--draft-window 6` 通常更稳。',
      '',
      '另外，日志里 `ttft=41ms` 和 `p50=42ms` 基本一致，说明这不是偶发抖动，而是稳定基线。如果客户端体感慢，问题更可能在**提示词预处理**：上下文 1.2K 时 prefill 只需 3ms，但超过 8K 后线性增长。',
      '',
      '建议按这个顺序排查：',
      '',
      '1. 打开日志面板，按 **警告** 过滤，看看有没有 `admission queue depth`。',
      '2. 用 `/status` 对比 `metrics.ttft_ms.p50` 与 `p95`。',
      '3. 若 p95 高于 200ms，再检查 KV 缓存是否被换出（`kv.released`）。',
    ].join('\n'),

    code: [
      '用 `Semaphore` 控制并发最简单。下面这个版本会保留每个任务自己的进度回调，并在全部完成后统一返回：',
      '',
      '```dart',
      "import 'dart:async';",
      '',
      'class Semaphore {',
      '  Semaphore(this._available);',
      '  int _available;',
      '  final _waiters = <Completer<void>>[];',
      '',
      '  Future<void> acquire() async {',
      '    if (_available > 0) { _available--; return; }',
      '    final waiter = Completer<void>();',
      '    _waiters.add(waiter);',
      '    await waiter.future;',
      '  }',
      '',
      '  void release() {',
      '    if (_waiters.isNotEmpty) {',
      '      _waiters.removeAt(0).complete();',
      '    } else {',
      '      _available++;',
      '    }',
      '  }',
      '}',
      '',
      'class Downloader {',
      '  final _pool = Semaphore(4);',
      '',
      '  Future<void> fetchAll(',
      '    List<String> urls, {',
      '    void Function(int done, int total)? onProgress,',
      '  }) async {',
      '    var done = 0;',
      '    await Future.wait(urls.map((url) async {',
      '      await _pool.acquire();',
      '      try {',
      '        await _download(url);',
      '      } finally {',
      '        _pool.release();',
      '        onProgress?.call(++done, urls.length);',
      '      }',
      '    }));',
      '  }',
      '}',
      '```',
      '',
      '要点：',
      '',
      '1. `try/finally` 保证异常时也会归还信号量，否则 4 个槽位很快会被泄漏光。',
      '2. 进度用 `++done` 在单 isolate 内自增是安全的；跨 isolate 请改用 `SendPort`。',
      '3. 并发数不要超过服务端连接池，`4` 是对大多数 CDN 友好的默认值。',
      '',
      '> 需要断点续传时，再给请求加一个 `Range` 头即可，并发逻辑不用改。',
    ].join('\n'),

    dflash: [
      'DFlash2 的核心是 **先猜后验**：用一个很小的草稿头，一次生成多个候选 token，再让 27B 主模型并行验证。命中就整段接受，不命中就退回到下一个位置。',
      '',
      '可以把它想成输入法的联想：',
      '',
      '- 草稿模型猜「今天天气真」后面是「不错」——一次给出 4 个 token 的候选。',
      '- 主模型只做一次前向，就能同时确认这 4 个位置。',
      '- 全中时，一次前向产出 4 个 token，解码速度接近 4×；全错时退回标准解码。',
      '',
      '所以真正决定加速比的是**接受率**，而不是草稿长度。你现在的 78% 已经不错：接受率每提高 10 个百分点，平均每步产出大约多 0.5 个 token。',
      '',
      '- **55%** → 平均 1.6 token/步，约 1.5× 加速',
      '- **70%** → 平均 2.2 token/步，约 1.9× 加速',
      '- **80%** → 平均 2.8 token/步，约 2.4× 加速',
      '',
      '如果接受率突然掉到 50% 以下，通常是采样温度被调高了，或者切换到了代码场景——草稿头对代码的分布没那么熟。',
    ].join('\n'),

    sql: [
      '这段查询的瓶颈不在 `JOIN`，而在 `created_at` 上的范围扫描：它目前走的是全表扫描，然后对每一行做函数计算，索引直接失效。',
      '',
      '```sql',
      '-- 改写前：函数包裹列，无法命中索引',
      "SELECT id, user_id, total",
      'FROM orders',
      'WHERE date(created_at) = CURRENT_DATE',
      'ORDER BY created_at DESC',
      'LIMIT 50;',
      '',
      '-- 改写后：范围条件可下推，索引可用',
      "SELECT id, user_id, total",
      'FROM orders',
      'WHERE created_at >= CURRENT_DATE',
      '  AND created_at <  CURRENT_DATE + INTERVAL \'1 day\'',
      'ORDER BY created_at DESC',
      'LIMIT 50;',
      '```',
      '',
      '配套索引：',
      '',
      '```sql',
      'CREATE INDEX CONCURRENTLY idx_orders_created_at',
      '  ON orders (created_at DESC)',
      '  INCLUDE (user_id, total);',
      '```',
      '',
      '预期执行计划会从 `Seq Scan` 变成 `Index Only Scan`，50 行结果基本可以稳定在 2ms 内。',
    ].join('\n'),

    default: [
      '当然可以。先把目标拆成三件事：**输入是什么、输出要什么、边界在哪里**。',
      '',
      '本地模型的好处是响应稳定、没有配额，适合把重复性的分析放在这里跑。你这个需求我会这样组织：',
      '',
      '1. 先确认数据规模和更新频率——这决定了要不要做缓存。',
      '2. 把流程拆成可以单独验证的小步，每步都能回滚。',
      '3. 最后再接入 UI，避免界面掩盖掉逻辑问题。',
      '',
      '你可以把具体的输入样例贴给我，我按这个结构给出可运行的版本。',
    ].join('\n'),
  };

  /* ------------------------------------------------------------------ 图标 */

  const icon = (name, cls = '') => `<svg class="icon ${cls}"><use href="#${name}"/></svg>`;
  const LOGO_SVG = (cls = '') => `
    <svg class="${cls}" viewBox="0 0 40 40" aria-hidden="true">
      <path d="M11.2 9.6 12 3.4l5 4.3Z" fill="url(#avatarGrad)"/>
      <path d="M28.8 9.6 28 3.4l-5 4.3Z" fill="url(#avatarGrad)"/>
      <rect x="5" y="7.2" width="30" height="27.8" rx="9.6" fill="url(#avatarGrad)"/>
      <path d="M22.4 11.6 14 21.8h5.7L17 30.6l8.4-10.6h-5.9l2.9-8.4Z" fill="#fff"/>
    </svg>`;

  /* ------------------------------------------------------------------ 工具 */

  const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const escRe = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const pad = (n) => String(n).padStart(2, '0');
  const clock = (d = new Date()) => `${pad(d.getHours())}:${pad(d.getMinutes())}`;
  const stamp = (d) => `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}.${String(d.getMilliseconds()).padStart(3, '0')}`;

  const currentModel = () => MODELS.find((m) => m.id === state.modelId) || MODELS[0];

  const installedModels = () => MODELS.filter((m) => m.state === 'installed' && !state.hiddenModels.has(m.id));

  const shortModel = (id) => (MODELS.find((m) => m.id === id) || {}).short || String(id).split('/').pop();

  async function copyText(text, message = '已复制') {
    let ok = false;
    try {
      await navigator.clipboard.writeText(text);
      ok = true;
    } catch {
      try {
        const area = document.createElement('textarea');
        area.value = text;
        area.style.cssText = 'position:fixed;top:-1000px;opacity:0';
        document.body.appendChild(area);
        area.select();
        ok = document.execCommand('copy');
        area.remove();
      } catch { ok = false; }
    }
    toast(ok ? message : '复制失败，请手动选择', ok ? 'success' : 'error');
  }

  /* ------------------------------------------------------------------ 主题 */

  function applyTheme(theme, persist = true) {
    state.theme = theme;
    document.documentElement.dataset.theme = theme;
    if (persist) storage.set('flashcat-theme', theme);
    const btn = $('#theme-toggle');
    if (btn) btn.setAttribute('aria-label', theme === 'dark' ? '切换到浅色外观' : '切换到深色外观');
    raf(() => { renderChart(); });
  }

  function toggleTheme() {
    applyTheme(state.theme === 'dark' ? 'light' : 'dark');
    toast(state.theme === 'dark' ? '已切换到深色外观' : '已切换到浅色外观', 'info', 1600);
  }

  /* ------------------------------------------------------------------ 侧边栏折叠 */

  function applySidebar(collapsed, persist = true) {
    state.sidebarCollapsed = collapsed;
    const app = $('.app');
    if (app) app.classList.toggle('is-collapsed', collapsed);
    if (persist) storage.set('flashcat-sidebar', collapsed ? 'collapsed' : 'expanded');
    const btn = $('#sidebar-toggle');
    if (btn) {
      const label = collapsed ? '展开侧边栏' : '折叠侧边栏';
      btn.setAttribute('aria-expanded', String(!collapsed));
      btn.setAttribute('aria-label', label);
      btn.dataset.tip = `${label} ⌘\\`;
      btn.title = `${label} ⌘\\`;
    }
    raf(() => { if (state.page === 'overview') renderChart(); });
  }

  function toggleSidebar() {
    applySidebar(!state.sidebarCollapsed);
  }

  /* ------------------------------------------------------------------ 路由 */

  const PAGE_NAMES = { overview: '概览', chat: '对话', models: '模型', logs: '日志', settings: '设置' };

  function go(page, opts = {}) {
    if (!PAGE_NAMES[page]) page = 'overview';
    state.page = page;
    $$('.page').forEach((p) => { p.hidden = p.dataset.page !== page; });
    $$('.nav-item').forEach((b) => {
      if (b.dataset.nav === page) b.setAttribute('aria-current', 'page');
      else b.removeAttribute('aria-current');
    });
    $$('.mobile-nav button').forEach((b) => b.classList.toggle('is-active', b.dataset.nav === page));
    document.title = `${PAGE_NAMES[page]} · flashCat`;
    if (location.hash !== `#${page}`) {
      try { history.replaceState(null, '', `#${page}`); } catch { location.hash = page; }
    }
    if (page === 'chat') {
      raf(() => scrollChatToBottom(true));
      setTimeout(() => scrollChatToBottom(true), 120);
    }
    if (page === 'models') renderModels();
    if (page === 'logs') { renderLogs(); scrollLogsToEnd(); }
    if (page === 'overview') raf(renderChart);
    if (page === 'settings') updateCommandPreview();
    closePalette();
  }

  /* ------------------------------------------------------------------ Toast */

  function toast(message, type = 'success', duration = 2400) {
    const host = $('#toasts');
    if (!host) return;
    while (host.children.length >= 3) host.firstElementChild.remove();
    const el = document.createElement('div');
    el.className = `toast${type === 'info' ? ' is-info' : type === 'error' ? ' is-error' : ''}`;
    el.setAttribute('role', 'status');
    el.innerHTML = `<span class="toast-ico">${icon(type === 'error' ? 'i-alert' : type === 'info' ? 'i-sparkles' : 'i-check')}</span><span>${esc(message)}</span>`;
    host.appendChild(el);
    setTimeout(() => {
      el.classList.add('is-out');
      setTimeout(() => el.remove(), 220);
    }, duration);
  }

  /* ------------------------------------------------------------------ 服务 */

  function setService(next) {
    state.service = next;
    syncService();
  }

  function syncService() {
    const running = state.service === 'running';
    const starting = state.service === 'starting';
    const label = starting ? '启动中…' : running ? '运行中' : '未运行';
    $$('[data-service-label]').forEach((el) => { el.textContent = label; });
    $$('[data-service-text]').forEach((el) => { el.textContent = label; });
    $$('[data-toggle-label]').forEach((el) => { el.textContent = running || starting ? '停止' : '启动'; });
    $$('.engine-action').forEach((el) => { el.textContent = running || starting ? '停止' : '启动'; el.disabled = starting; });
    const heroToggle = $('.hero-actions [data-action="toggle-service"]');
    if (heroToggle) {
      heroToggle.classList.toggle('is-danger', running || starting);
      const use = heroToggle.querySelector('use');
      if (use) use.setAttribute('href', running || starting ? '#i-stop' : '#i-play');
    }

    $$('[data-service-dot]').forEach((el) => {
      el.classList.toggle('is-ok', running);
      el.classList.toggle('is-busy', starting);
      el.classList.toggle('is-off', !running && !starting);
      el.classList.toggle('is-error', state.service === 'failed');
    });
    $$('.pulse-dot[data-service-dot]').forEach((el) => {
      el.classList.toggle('is-off', !running && !starting);
      el.classList.toggle('is-busy', starting);
    });

    $$('[data-service-pill]').forEach((el) => {
      el.classList.toggle('pill-ok', running);
      el.innerHTML = running ? '<i></i>就绪' : starting ? '<i></i>启动中' : '<i></i>未运行';
    });

    const banner = $('#service-banner');
    if (banner) banner.hidden = running || starting;
    const composer = $('#composer');
    if (composer) composer.classList.toggle('is-disabled', !running);
    const send = $('#send-btn');
    if (send) {
      send.disabled = !running && !state.streaming;
      send.setAttribute('aria-disabled', String(!running && !state.streaming));
    }
    const input = $('#composer-input');
    if (input) {
      input.placeholder = running ? '输入消息，Enter 发送，Shift+Enter 换行' : '服务未运行，启动后即可输入';
    }
    const chartCard = $('.chart-card');
    if (chartCard) chartCard.classList.toggle('is-offline', !running);
    updateSpeedUI();
  }

  function toggleService() {
    if (state.service === 'starting') return;
    if (state.service === 'running') {
      stopStreaming(true);
      setService('stopped');
      addLog('warn', 'service stopped by user · pid 48213 released');
      toast('推理服务已停止', 'info');
      return;
    }
    setService('starting');
    addLog('info', 'splash serve --model ' + currentModel().id + ' --port 8000');
    toast('正在启动推理引擎…', 'info', 1700);
    setTimeout(() => {
      setService('running');
      addLog('info', 'warmup 3/3 · ttft p50=42ms');
      addLog('info', 'listening on http://127.0.0.1:8000');
      toast('服务已就绪 · 74.2 tok/s');
      updateSpeedUI();
    }, 1700);
  }

  function restartService() {
    if (state.service === 'starting') return;
    stopStreaming(true);
    setService('starting');
    addLog('info', 'restart requested · reloading model ' + currentModel().id);
    toast('正在重启引擎…', 'info', 1900);
    setTimeout(() => {
      setService('running');
      addLog('info', 'model reloaded in 1.82s · ready');
      toast('引擎已重启');
    }, 1850);
  }

  function updateSpeedUI() {
    const running = state.service === 'running';
    const speed = running ? state.speed : 0;
    $$('[data-speed-text]').forEach((el) => { el.textContent = speed > 0 ? speed.toFixed(1) : '0.0'; });
    const arc = $('#gauge-arc');
    if (arc) arc.style.strokeDashoffset = String(clamp(100 - speed, 0, 100));
    const gaugeValue = $('#gauge-value');
    if (gaugeValue) gaugeValue.textContent = running ? speed.toFixed(1) : '—';
  }

  /* ------------------------------------------------------------------ 图表 */

  function seedHistory() {
    const now = Date.now();
    for (let i = 249; i >= 0; i--) {
      const base = 72 + Math.sin((i + 8) / 7) * 6 + (Math.random() - 0.5) * 5;
      state.history.push({ t: now - i * 1200, v: clamp(base, 56, 86) });
    }
  }

  function smoothPath(points) {
    if (!points.length) return '';
    if (points.length === 1) return `M ${points[0][0]},${points[0][1]}`;
    let d = `M ${points[0][0].toFixed(2)},${points[0][1].toFixed(2)}`;
    for (let i = 0; i < points.length - 1; i++) {
      const p0 = points[i - 1] || points[i];
      const p1 = points[i];
      const p2 = points[i + 1];
      const p3 = points[i + 2] || p2;
      const t = 0.17;
      const c1x = p1[0] + (p2[0] - p0[0]) * t;
      const c1y = p1[1] + (p2[1] - p0[1]) * t;
      const c2x = p2[0] - (p3[0] - p1[0]) * t;
      const c2y = p2[1] - (p3[1] - p1[1]) * t;
      d += ` C ${c1x.toFixed(2)},${c1y.toFixed(2)} ${c2x.toFixed(2)},${c2y.toFixed(2)} ${p2[0].toFixed(2)},${p2[1].toFixed(2)}`;
    }
    return d;
  }

  function renderChart() {
    const wrap = $('#chart-wrap');
    const svg = $('#chart');
    if (!wrap || !svg || wrap.clientWidth < 40) return;
    const W = Math.round(wrap.clientWidth);
    const H = Math.max(260, Math.round(wrap.clientHeight) || 0);
    const padL = 36;
    const padR = 8;
    const padT = 14;
    const padB = 24;
    const plotW = W - padL - padR;
    const plotH = H - padT - padB;
    const values = state.history.slice(state.chartRange === 45 ? -45 : -250);
    if (!values.length) return;

    const yMin = 50;
    const yMax = 90;
    const xFor = (i) => padL + (values.length === 1 ? plotW : (plotW * i) / (values.length - 1));
    const yFor = (v) => padT + plotH - ((clamp(v, yMin, yMax) - yMin) / (yMax - yMin)) * plotH;

    const points = values.map((p, i) => [xFor(i), yFor(p.v)]);
    const line = smoothPath(points);
    const area = `${line} L ${xFor(values.length - 1).toFixed(2)},${(padT + plotH).toFixed(2)} L ${padL.toFixed(2)},${(padT + plotH).toFixed(2)} Z`;
    const avg = values.reduce((sum, p) => sum + p.v, 0) / values.length;
    const avgY = yFor(avg);
    const last = points[points.length - 1];

    let grid = '';
    for (let i = 0; i <= 4; i++) {
      const v = yMax - ((yMax - yMin) / 4) * i;
      const y = padT + (plotH / 4) * i;
      grid += `<line class="grid-line" x1="${padL}" y1="${y.toFixed(1)}" x2="${W - padR}" y2="${y.toFixed(1)}"/>`;
      grid += `<text class="axis-label" x="${padL - 8}" y="${(y + 3.5).toFixed(1)}" text-anchor="end">${v}</text>`;
    }
    const labels = state.chartRange === 45 ? ['-45s', '-30s', '-15s', '现在'] : ['-5m', '-3m', '-1m', '现在'];
    let xlabels = '';
    labels.forEach((label, i) => {
      const x = padL + (plotW * i) / (labels.length - 1);
      const anchor = i === 0 ? 'start' : i === labels.length - 1 ? 'end' : 'middle';
      xlabels += `<text class="axis-label" x="${x.toFixed(1)}" y="${H - 5}" text-anchor="${anchor}">${label}</text>`;
    });

    svg.setAttribute('viewBox', `0 0 ${W} ${H}`);
    svg.setAttribute('width', String(W));
    svg.setAttribute('height', String(H));
    svg.innerHTML = `
      <defs>
        <linearGradient id="chartFill" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stop-color="var(--brand)" stop-opacity=".26"/>
          <stop offset=".65" stop-color="var(--brand)" stop-opacity=".06"/>
          <stop offset="1" stop-color="var(--brand)" stop-opacity="0"/>
        </linearGradient>
        <linearGradient id="chartLine" x1="0" y1="0" x2="1" y2="0">
          <stop offset="0" stop-color="var(--brand)"/>
          <stop offset="1" stop-color="var(--brand-2)"/>
        </linearGradient>
      </defs>
      ${grid}
      <line class="avg-line" x1="${padL}" y1="${avgY.toFixed(1)}" x2="${W - padR}" y2="${avgY.toFixed(1)}"/>
      <path d="${area}" fill="url(#chartFill)"/>
      <path d="${line}" fill="none" stroke="url(#chartLine)" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"/>
      <circle cx="${last[0].toFixed(1)}" cy="${last[1].toFixed(1)}" r="7" fill="var(--brand)" opacity=".16"/>
      <circle cx="${last[0].toFixed(1)}" cy="${last[1].toFixed(1)}" r="3.2" fill="var(--brand)" stroke="var(--surface)" stroke-width="1.5"/>
      ${xlabels}
    `;

    state.chartGeom = { values, points, padL, plotW, W, plotT: padT, plotH };
    const meta = $('.chart-meta');
    if (meta) meta.textContent = `峰值 ${Math.max(...values.map((p) => p.v)).toFixed(1)} · 均值 ${avg.toFixed(1)}`;
    const avgLabel = $('#avg-label');
    if (avgLabel) avgLabel.textContent = avg.toFixed(1);
  }

  function bindChartHover() {
    const wrap = $('#chart-wrap');
    const tip = $('#chart-tip');
    if (!wrap || !tip) return;
    wrap.addEventListener('mousemove', (event) => {
      const geom = state.chartGeom;
      if (!geom) return;
      const rect = wrap.getBoundingClientRect();
      const x = event.clientX - rect.left;
      if (x < geom.padL || x > geom.padL + geom.plotW) { tip.hidden = true; return; }
      const ratio = (x - geom.padL) / geom.plotW;
      const index = clamp(Math.round(ratio * (geom.values.length - 1)), 0, geom.values.length - 1);
      const point = geom.values[index];
      const px = geom.points[index][0];
      const py = geom.points[index][1];
      tip.hidden = false;
      tip.style.left = `${clamp(px, 54, geom.W - 54)}px`;
      tip.style.top = `${Math.max(py - 10, 12)}px`;
      const secondsAgo = Math.round((geom.values.length - 1 - index) * 1.2);
      const label = secondsAgo < 60 ? `${secondsAgo} 秒前` : `${Math.round(secondsAgo / 60)} 分钟前`;
      tip.innerHTML = `<strong>${point.v.toFixed(1)}</strong> tok/s<br><span style="opacity:.65">${label}</span>`;
    });
    wrap.addEventListener('mouseleave', () => { tip.hidden = true; });
  }

  function tick() {
    if (state.service === 'running') {
      const drift = (Math.random() - 0.48) * 3.4;
      state.speed = clamp(state.speed + drift, 62, 84);
      state.history.push({ t: Date.now(), v: state.speed });
      if (state.history.length > 250) state.history.shift();
      updateSpeedUI();
      if (state.page === 'overview') renderChart();
      if (Math.random() > 0.72) addLiveLog();
    }
    updateLiveMetrics();
  }

  /* ------------------------------------------------------------------ 日志 */

  const LOG_SEED = [
    ['info', 'splash serve 1.4.0 · metal backend ready · build 20261018'],
    ['info', 'device=Apple M3 Max · gpu_cores=40 · memory=36.0 GB'],
    ['info', 'model=mlx-community/Qwen3.8-27B-4bit · quant=4-bit'],
    ['info', 'loading weights from ~/.flashcat/models/Qwen3.8-27B-4bit'],
    ['info', 'weights loaded in 1.82s · 15.8 GB · 4 shards'],
    ['info', 'draft model dflash2 active · window=8 · acceptance=0.78'],
    ['info', 'kv cache format=q8 · max_context=102400'],
    ['info', 'warmup 3/3 · ttft p50=42ms'],
    ['info', 'listening on http://127.0.0.1:8000'],
    ['info', 'GET /status 200 · 0.6ms'],
    ['info', 'POST /v1/chat/completions 200 · 186 tok · 74.2 tok/s'],
    ['info', 'stream finished · ttft=41ms · decode=74.2 tok/s'],
    ['warn', 'admission queue depth 2 · request delayed 18ms'],
    ['info', 'POST /v1/chat/completions 200 · 412 tok · 73.6 tok/s'],
    ['info', 'kv cache hit rate 62% · active=1'],
    ['error', 'request aborted by client · 1 chunk discarded'],
    ['info', 'GET /v1/models 200 · 1.1ms'],
    ['info', 'thermal=nominal · memory_pressure=normal'],
    ['info', 'POST /v1/chat/completions 200 · 96 tok · 75.1 tok/s'],
    ['info', 'stream finished · ttft=43ms · decode=75.1 tok/s'],
    ['warn', 'prompt truncated to 102400 tokens · 2048 dropped'],
    ['info', 'kv cache hit rate 71% · active=1'],
    ['info', 'POST /v1/chat/completions 200 · 318 tok · 74.8 tok/s'],
    ['info', 'GET /status 200 · 0.4ms'],
    ['info', 'metrics sample · decode=74.2 prefill=1280 ttft_p50=42ms'],
  ];

  function seedLogs() {
    const base = Date.now() - 6 * 60 * 1000;
    let offset = 0;
    LOG_SEED.forEach(([level, msg], i) => {
      offset += 900 + Math.random() * 3800;
      state.logs.push({ n: i + 1, at: new Date(base + offset), level, msg });
    });
  }

  function addLog(level, msg) {
    state.logs.push({ n: state.logs.length + 1, at: new Date(), level, msg });
    if (state.logs.length > 600) state.logs.splice(0, state.logs.length - 600);
    if (state.page === 'logs') renderLogs(state.autoscroll);
    updateLogCounts();
  }

  const LIVE_LOGS = [
    ['info', () => `POST /v1/chat/completions 200 · ${120 + Math.round(Math.random() * 320)} tok · ${(70 + Math.random() * 6).toFixed(1)} tok/s`],
    ['info', () => `GET /status 200 · ${(0.3 + Math.random() * 0.6).toFixed(1)}ms`],
    ['info', () => `stream finished · ttft=${38 + Math.round(Math.random() * 10)}ms · decode=${(71 + Math.random() * 5).toFixed(1)} tok/s`],
    ['info', () => `kv cache hit rate ${55 + Math.round(Math.random() * 22)}% · active=${Math.random() > 0.7 ? 2 : 1}`],
    ['warn', () => `admission queue depth ${1 + Math.round(Math.random() * 2)} · request delayed ${12 + Math.round(Math.random() * 22)}ms`],
    ['info', () => `metrics sample · decode=${(70 + Math.random() * 7).toFixed(1)} prefill=${1200 + Math.round(Math.random() * 180)} ttft_p50=${40 + Math.round(Math.random() * 5)}ms`],
  ];

  function addLiveLog() {
    if (state.logPaused || state.page !== 'logs') return;
    const pool = LIVE_LOGS[Math.random() > 0.86 ? 4 : Math.floor(Math.random() * 4)];
    addLog(pool[0], pool[1]());
  }

  function updateLogCounts() {
    let info = 0; let warn = 0; let error = 0;
    state.logs.forEach((l) => {
      if (l.level === 'warn') warn++;
      else if (l.level === 'error') error++;
      else info++;
    });
    const set = (id, value) => { const el = $(id); if (el) el.textContent = String(value); };
    set('#lvl-all', state.logs.length);
    set('#lvl-info', info);
    set('#lvl-warn', warn);
    set('#lvl-error', error);
    set('#log-count', state.logs.length);
  }

  function logMatches(entry) {
    if (state.logLevel !== 'all' && entry.level !== state.logLevel) return false;
    if (state.logQuery) {
      const q = state.logQuery.toLowerCase();
      if (!entry.msg.toLowerCase().includes(q) && !entry.level.includes(q)) return false;
    }
    return true;
  }

  function highlight(text, query) {
    if (!query) return esc(text);
    const re = new RegExp(`(${escRe(query)})`, 'gi');
    const parts = String(text).split(re);
    return parts.map((part, i) => (i % 2 === 1 ? `<mark>${esc(part)}</mark>` : esc(part))).join('');
  }

  function renderLogs(scroll = false) {
    const host = $('#log-lines');
    if (!host) return;
    const rows = state.logs.filter(logMatches);
    const empty = $('#log-empty');
    if (!rows.length) {
      host.innerHTML = '';
      if (empty) {
        empty.hidden = false;
        const title = empty.querySelector('h3');
        const desc = empty.querySelector('p');
        if (state.logs.length === 0) {
          if (title) title.textContent = '还没有日志输出';
          if (desc) desc.textContent = '启动服务后，引擎日志会实时出现在这里。';
        } else {
          if (title) title.textContent = '没有匹配的日志';
          if (desc) desc.textContent = '调整搜索关键词或级别筛选后再试。';
        }
      }
      updateLogCounts();
      return;
    }
    if (empty) empty.hidden = true;
    const frag = rows.map((entry) => `
      <div class="log-row" data-level="${entry.level}">
        <span class="log-line-no">${String(entry.n).padStart(3, '0')}</span>
        <span class="log-time">${stamp(entry.at)}</span>
        <span class="log-level lvl-${entry.level}">${entry.level.toUpperCase()}</span>
        <span class="log-msg">${highlight(entry.msg, state.logQuery)}</span>
      </div>`).join('');
    host.innerHTML = frag;
    updateLogCounts();
    if (scroll && state.autoscroll) scrollLogsToEnd();
  }

  function scrollLogsToEnd() {
    const body = $('#log-body');
    if (!body) return;
    raf(() => { body.scrollTop = body.scrollHeight; });
  }

  function copyLogs() {
    const rows = state.logs.filter(logMatches);
    if (!rows.length) { toast('没有可复制的日志', 'info'); return; }
    copyText(rows.map((l) => `${stamp(l.at)} [${l.level}] ${l.msg}`).join('\n'), `已复制 ${rows.length} 行日志`);
  }

  function setLogPaused(paused) {
    state.logPaused = paused;
    const btn = $('#log-pause');
    if (btn) {
      btn.innerHTML = icon(paused ? 'i-play' : 'i-pause');
      btn.dataset.tip = paused ? '继续实时输出' : '暂停实时输出';
      btn.title = btn.dataset.tip;
    }
    const dot = $('#log-live-dot');
    if (dot) dot.classList.toggle('is-paused', paused);
    const text = $('#log-status-text');
    if (text) text.textContent = paused ? '已暂停实时输出' : '实时跟随 · 最新输出';
    toast(paused ? '已暂停实时输出' : '已恢复实时输出', 'info', 1600);
  }

  /* ------------------------------------------------------------------ 对话 */

  function initialMessages() {
    return [
      {
        role: 'user', at: '14:02',
        text: '帮我看下这段推理服务的日志，为什么首字延迟偏高？\n\n14:32:02.314 [info] draft model dflash2 active · window=8\n14:32:03.101 [info] warmup 3/3 · ttft p50=42ms\n14:32:14.553 [info] POST /v1/chat/completions 200 · 412 tok · 74.2 tok/s',
      },
      {
        role: 'assistant', at: '14:02', model: 'mlx-community/Qwen3.8-27B-4bit',
        text: RESPONSES.logs,
        stats: ['74.2 tok/s', '186 tokens', '2.8s', '上下文 1.2K'],
      },
      {
        role: 'user', at: '14:06',
        text: '那给我一段 Flutter 代码，限制 4 个并发下载，并显示进度。',
      },
      {
        role: 'assistant', at: '14:06', model: 'mlx-community/Qwen3.8-27B-4bit',
        text: RESPONSES.code,
        stats: ['73.6 tok/s', '412 tokens', '5.6s', '上下文 2.4K'],
      },
    ];
  }

  function inlineMd(text) {
    let out = esc(text);
    out = out.replace(/`([^`]+)`/g, '<code>$1</code>');
    out = out.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
    out = out.replace(/(^|[\s(])\*([^*\n]+)\*/g, '$1<em>$2</em>');
    out = out.replace(/\[([^\]]+)\]\((https?:\/\/[^)\s]+)\)/g, '<a href="$2" target="_blank" rel="noreferrer">$1</a>');
    return out;
  }

  const DART_KEYWORDS = /^(import|export|class|extends|implements|with|mixin|enum|final|const|var|late|required|await|async|return|if|else|for|while|do|try|catch|finally|throw|new|this|super|get|set|static|void|int|double|bool|String|Future|Stream|List|Map|Set|Completer|abstract|factory|operator|typedef|yield|switch|case|default|break|continue|in|is|as|SELECT|FROM|WHERE|ORDER|BY|LIMIT|JOIN|LEFT|RIGHT|INNER|ON|GROUP|HAVING|INSERT|UPDATE|DELETE|CREATE|INDEX|CONCURRENTLY|INCLUDE|INTERVAL|AND|OR|NOT|NULL|DESC|ASC)$/;

  function highlightCode(code) {
    const re = /(\/\/[^\n]*|\/\*[\s\S]*?\*\/|--[^\n]*)|('(?:\\.|[^'\\])*'|"(?:\\.|[^"\\])*")|\b(\d+(?:\.\d+)?)\b|\b([A-Za-z_][A-Za-z0-9_]*)\b/g;
    let out = '';
    let last = 0;
    for (const match of code.matchAll(re)) {
      out += esc(code.slice(last, match.index));
      const [raw, comment, str, num, word] = match;
      if (comment) out += `<span class="tok-com">${esc(comment)}</span>`;
      else if (str) out += `<span class="tok-str">${esc(str)}</span>`;
      else if (num) out += `<span class="tok-num">${esc(num)}</span>`;
      else if (word) {
        if (DART_KEYWORDS.test(word)) out += `<span class="tok-key">${esc(word)}</span>`;
        else if (/^[A-Z][A-Za-z0-9_]*$/.test(word)) out += `<span class="tok-type">${esc(word)}</span>`;
        else if (code[match.index + raw.length] === '(') out += `<span class="tok-fn">${esc(word)}</span>`;
        else out += esc(word);
      }
      last = match.index + raw.length;
    }
    out += esc(code.slice(last));
    return out;
  }

  function renderMarkdown(source) {
    let text = String(source);
    const fences = (text.match(/```/g) || []).length;
    if (fences % 2 === 1) text += '\n```';
    const blocks = [];
    text = text.replace(/```([\w-]*)\n([\s\S]*?)```/g, (m, lang, code) => {
      blocks.push({ lang: lang || 'text', code: code.replace(/\n$/, '') });
      return `\u0000CODE${blocks.length - 1}\u0000`;
    });
    const lines = text.split('\n');
    const out = [];
    let paragraph = [];
    const flush = () => {
      if (paragraph.length) {
        out.push(`<p>${inlineMd(paragraph.join('\n')).replace(/\n/g, '<br>')}</p>`);
        paragraph = [];
      }
    };
    let i = 0;
    while (i < lines.length) {
      const line = lines[i];
      const codeMatch = line.match(/^\u0000CODE(\d+)\u0000$/);
      if (codeMatch) {
        flush();
        const block = blocks[Number(codeMatch[1])];
        out.push(`<div class="code"><div class="code-head"><span>${esc(block.lang)}</span><button type="button" class="code-copy">${icon('i-copy')}复制</button></div><pre><code>${highlightCode(block.code)}</code></pre></div>`);
        i++;
        continue;
      }
      if (!line.trim()) { flush(); i++; continue; }
      if (/^#{1,4}\s+/.test(line)) {
        flush();
        const level = Math.min(4, line.match(/^#+/)[0].length + 1);
        out.push(`<h${level}>${inlineMd(line.replace(/^#{1,4}\s+/, ''))}</h${level}>`);
        i++;
        continue;
      }
      if (/^\s*[-*]\s+/.test(line)) {
        flush();
        const items = [];
        while (i < lines.length && /^\s*[-*]\s+/.test(lines[i])) {
          items.push(lines[i].replace(/^\s*[-*]\s+/, ''));
          i++;
        }
        out.push(`<ul>${items.map((item) => `<li>${inlineMd(item)}</li>`).join('')}</ul>`);
        continue;
      }
      if (/^\s*\d+[.)]\s+/.test(line)) {
        flush();
        const items = [];
        while (i < lines.length && /^\s*\d+[.)]\s+/.test(lines[i])) {
          items.push(lines[i].replace(/^\s*\d+[.)]\s+/, ''));
          i++;
        }
        out.push(`<ol>${items.map((item) => `<li>${inlineMd(item)}</li>`).join('')}</ol>`);
        continue;
      }
      if (/^>\s?/.test(line)) {
        flush();
        const quote = [];
        while (i < lines.length && /^>\s?/.test(lines[i])) {
          quote.push(lines[i].replace(/^>\s?/, ''));
          i++;
        }
        out.push(`<blockquote>${inlineMd(quote.join(' '))}</blockquote>`);
        continue;
      }
      paragraph.push(line);
      i++;
    }
    flush();
    return out.join('');
  }

  function messageNode(msg, index) {
    const isUser = msg.role === 'user';
    const meta = `<div class="msg-meta"><b>${isUser ? '你' : shortModel(msg.model || state.modelId)}</b><time>${msg.at || clock()}</time></div>`;
    let content;
    if (msg.streaming) {
      content = msg.text
        ? `${renderMarkdown(msg.text)}<span class="stream-caret"></span>`
        : `<div class="typing"><i></i><i></i><i></i></div>`;
    } else if (isUser) {
      content = esc(msg.text);
    } else {
      content = renderMarkdown(msg.text);
    }
    const stats = msg.stats && msg.stats.length
      ? `<div class="msg-stats">${msg.stats.map((s) => `<span>${esc(s)}</span>`).join('')}</div>`
      : '';
    const actions = msg.streaming ? '' : `
      <div class="msg-actions">
        ${!isUser && index === state.messages.length - 1 ? `<button class="icon-btn" data-regenerate data-tip="重新生成" aria-label="重新生成">${icon('i-refresh')}</button>` : ''}
        <button class="icon-btn" data-copy-message="${index}" data-tip="复制" aria-label="复制消息">${icon('i-copy')}</button>
      </div>`;
    const error = msg.error ? `<div class="msg-error">${icon('i-alert')}${esc(msg.error)}</div>` : '';
    return `
      <article class="msg msg-${isUser ? 'user' : 'assistant'}" data-index="${index}">
        ${isUser ? `<div class="msg-avatar">你</div>` : `<div class="msg-avatar msg-avatar--ai">${LOGO_SVG()}</div>`}
        <div class="msg-main">
          ${meta}
          <div class="msg-bubble ${isUser ? '' : 'prose'}">${content}</div>
          ${error}
          ${stats}
          ${actions}
        </div>
      </article>`;
  }

  function renderChat() {
    const host = $('#messages');
    const empty = $('#chat-empty');
    if (!host) return;
    host.innerHTML = state.messages.map((m, i) => messageNode(m, i)).join('');
    if (empty) empty.hidden = state.messages.length > 0;
    const clearBtn = $('#clear-chat');
    if (clearBtn) clearBtn.disabled = state.messages.length === 0;
    const title = $('#thread-title');
    if (title) {
      const firstUser = state.messages.find((m) => m.role === 'user');
      title.textContent = firstUser ? topicFor(firstUser.text) : '新对话';
    }
  }

  function scrollChatToBottom(force = false) {
    const scroller = $('#chat-scroll');
    if (!scroller) return;
    const distance = scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight;
    if (force || distance < 220) {
      const previous = scroller.style.scrollBehavior;
      scroller.style.scrollBehavior = 'auto';
      scroller.scrollTop = scroller.scrollHeight;
      raf(() => { scroller.style.scrollBehavior = previous || ''; });
    }
  }

  function topicFor(text) {
    const value = String(text || '').replace(/\s+/g, ' ').trim();
    const rules = [
      [/日志|延迟|ttft|首字|log/i, '推理日志排查'],
      [/flutter|dart|并发|下载器|代码/i, 'Flutter 并发下载'],
      [/草稿|dflash|加速|投机/i, 'DFlash2 加速原理'],
      [/sql|查询|索引|执行计划/i, 'SQL 查询优化'],
    ];
    for (const [re, title] of rules) if (re.test(value)) return title;
    return value.length > 18 ? `${value.slice(0, 18)}…` : value || '新对话';
  }

  function pickResponse(text) {
    if (/日志|延迟|ttft|首字|log/i.test(text)) return RESPONSES.logs;
    if (/flutter|dart|代码|并发|下载器/.test(text)) return RESPONSES.code;
    if (/草稿|dflash|加速|投机/.test(text)) return RESPONSES.dflash;
    if (/sql|查询|索引|执行计划/i.test(text)) return RESPONSES.sql;
    return RESPONSES.default;
  }

  function startAssistant() {
    if (!state.messages.length) return;
    const last = state.messages[state.messages.length - 1];
    const prompt = last.role === 'user' ? last.text : (state.messages.filter((m) => m.role === 'user').pop() || {}).text || '';
    if (!prompt) return;

    const response = pickResponse(prompt);
    state.messages.push({
      role: 'assistant', text: '', at: clock(), model: state.modelId, streaming: true,
    });
    state.streaming = true;
    state.streamText = '';
    state.streamStarted = Date.now();
    state.streamTokens = 0;
    renderChat();
    scrollChatToBottom(true);
    const send = $('#send-btn');
    if (send) { send.classList.add('is-streaming'); send.disabled = false; send.setAttribute('aria-label', '停止生成'); }
    const hint = $('#composer-hint');
    if (hint) hint.hidden = true;
    $('#live-strip').hidden = false;
    $('#live-rate').textContent = '0.0';
    $('#live-ttft').textContent = '—';
    $('#live-tokens').textContent = '0';
    $('#live-elapsed').textContent = '0.0s';

    let index = 0;
    let lastPaint = 0;
    clearInterval(state.streamTimer);
    state.streamTimer = setInterval(() => {
      const chunk = 3 + Math.floor(Math.random() * 4);
      index = Math.min(response.length, index + chunk);
      state.streamText = response.slice(0, index);
      const isDone = index >= response.length;
      const elapsed = (Date.now() - state.streamStarted) / 1000;
      state.streamTokens = Math.max(1, Math.round(state.streamText.length / 2.4));
      const streamingMsg = state.messages[state.messages.length - 1];
      streamingMsg.text = state.streamText;
      if (isDone || Date.now() - lastPaint > 90) {
        lastPaint = Date.now();
        paintStreamingMessage();
        scrollChatToBottom();
        updateLiveMetrics();
      }
      if (isDone) finishStreaming(false);
    }, 26);
  }

  function paintStreamingMessage() {
    const node = $$('#messages .msg').pop();
    if (!node) return;
    const bubble = node.querySelector('.msg-bubble');
    if (!bubble) return;
    bubble.innerHTML = state.streamText
      ? `${renderMarkdown(state.streamText)}<span class="stream-caret"></span>`
      : `<div class="typing"><i></i><i></i><i></i></div>`;
  }

  function updateLiveMetrics() {
    if (!state.streaming) return;
    const elapsed = (Date.now() - state.streamStarted) / 1000;
    const rate = state.streamText.length > 30 ? clamp(state.speed + (Math.random() - 0.5) * 6, 58, 88) : 0;
    const rateEl = $('#live-rate');
    if (rateEl) rateEl.textContent = rate.toFixed(1);
    const ttftEl = $('#live-ttft');
    if (ttftEl) ttftEl.textContent = state.streamText.length ? '42ms' : '—';
    const tokensEl = $('#live-tokens');
    if (tokensEl) tokensEl.textContent = String(state.streamTokens);
    const elapsedEl = $('#live-elapsed');
    if (elapsedEl) elapsedEl.textContent = `${elapsed.toFixed(1)}s`;
  }

  function finishStreaming(stopped) {
    clearInterval(state.streamTimer);
    state.streamTimer = null;
    state.streaming = false;
    const msg = state.messages[state.messages.length - 1];
    if (msg && msg.role === 'assistant') {
      const elapsed = Math.max(0.1, (Date.now() - state.streamStarted) / 1000);
      const tokens = state.streamTokens;
      msg.streaming = false;
      msg.text = state.streamText || (stopped ? '[已停止]' : '[空回复]');
      msg.stats = [
        `${(tokens / elapsed).toFixed(1)} tok/s`,
        `${tokens} tokens`,
        `${elapsed.toFixed(1)}s`,
        `上下文 ${(promptTokens(state.messages) / 1000).toFixed(1)}K`,
        ...(stopped ? ['已停止'] : []),
      ];
    }
    renderChat();
    scrollChatToBottom(true);
    const send = $('#send-btn');
    if (send) { send.classList.remove('is-streaming'); send.disabled = state.service !== 'running'; send.setAttribute('aria-label', '发送消息'); }
    const hint = $('#composer-hint');
    if (hint) hint.hidden = false;
    $('#live-strip').hidden = true;
    addLog('info', `POST /v1/chat/completions 200 · ${state.streamTokens} tok · ${state.speed.toFixed(1)} tok/s`);
    if (stopped) toast('已停止生成', 'info', 1600);
    state.streamText = '';
    state.streamTokens = 0;
  }

  function promptTokens(messages) {
    return messages.reduce((sum, m) => sum + Math.round((m.text || '').length / 1.8), 0);
  }

  function stopStreaming(silent = false) {
    if (!state.streaming) return;
    clearInterval(state.streamTimer);
    state.streamTimer = null;
    finishStreaming(true);
    if (silent) $('#live-strip').hidden = true;
  }

  function sendMessage(text) {
    const value = String(text || '').trim();
    if (!value || state.streaming) return;
    if (state.service !== 'running') {
      toast('服务未运行，请先启动推理服务', 'error');
      return;
    }
    state.messages.push({ role: 'user', text: value, at: clock() });
    renderChat();
    scrollChatToBottom(true);
    clearComposer();
    setTimeout(startAssistant, 200);
  }

  function clearComposer() {
    const input = $('#composer-input');
    if (!input) return;
    input.value = '';
    input.style.height = 'auto';
  }

  function openParams(open) {
    const aside = $('#chat-aside');
    if (!aside) return;
    const next = typeof open === 'boolean' ? open : aside.hidden;
    aside.hidden = !next;
    const paramsBtn = $('#params-btn');
    if (paramsBtn) paramsBtn.classList.toggle('btn-primary', next);
  }

  function syncComposerChips() {
    const temp = $('#composer-temp');
    if (temp) temp.textContent = state.temp.toFixed(2);
    const thinking = $('#composer-thinking');
    if (thinking) thinking.textContent = state.thinking;
    const tempReadout = $('#temp-readout');
    if (tempReadout) tempReadout.textContent = state.temp.toFixed(2);
    const topReadout = $('#topp-readout');
    if (topReadout) topReadout.textContent = state.topP.toFixed(2);
    const tempRange = $('#temp-range');
    if (tempRange) tempRange.value = String(state.temp);
    const topRange = $('#topp-range');
    if (topRange) topRange.value = String(state.topP);
  }

  /* ------------------------------------------------------------------ 模型 */

  function visibleModels() {
    const query = state.modelQuery.trim().toLowerCase();
    return MODELS.filter((m) => {
      if (state.hiddenModels.has(m.id)) return false;
      if (state.modelFilter === 'local' && m.state !== 'installed') return false;
      if (state.modelFilter === 'remote' && m.state !== 'remote') return false;
      if (query && !`${m.id} ${m.family} ${m.params}`.toLowerCase().includes(query)) return false;
      return true;
    });
  }

  function updateModelCounts() {
    const installed = installedModels().length;
    const badge = $('#model-count');
    if (badge) badge.textContent = String(installed);
    const all = $('#count-all');
    if (all) all.textContent = String(MODELS.filter((m) => !state.hiddenModels.has(m.id)).length);
  }

  function renderModels() {
    const grid = $('#model-grid');
    if (!grid) return;
    const models = visibleModels();
    updateModelCounts();
    if (!models.length) {
      grid.innerHTML = '<div class="model-empty">没有匹配的模型。试试别的关键词，或切换到「可下载」。</div>';
      return;
    }
    grid.innerHTML = models.map((model) => {
      const current = model.id === state.modelId;
      const downloading = state.downloads[model.id];
      const installed = model.state === 'installed';
      const tags = model.tags.map((tag) => {
        const cls = /就绪|已安装/.test(tag) ? 'tag-ok' : /DFlash2|视觉|MoE/.test(tag) ? 'tag-brand' : '';
        return `<span class="tag ${cls}">${esc(tag)}</span>`;
      }).join('');
      const progress = downloading && downloading.pct < 100 ? `
        <div class="model-progress">
          <div class="meter"><span style="width:${downloading.pct}%"></span></div>
          <div class="row"><span>正在下载 · ${downloading.pct}%</span><span>${model.size}</span></div>
        </div>` : '';
      const action = installed
        ? (current
          ? `<button class="btn" disabled>${icon('i-check')}使用中</button>`
          : `<button class="btn" data-model-use="${esc(model.id)}">${icon('i-play')}使用</button>`)
        : (downloading
          ? `<button class="btn" disabled>${icon('i-download')}下载中</button>`
          : `<button class="btn btn-download" data-model-download="${esc(model.id)}">${icon('i-download')}下载</button>`);
      const folder = installed ? `<button class="icon-btn" data-model-folder="${esc(model.id)}" data-tip="在访达中显示" aria-label="在访达中显示">${icon('i-folder')}</button>` : '';
      const trash = installed ? `<button class="icon-btn" data-model-delete="${esc(model.id)}" data-tip="删除模型" aria-label="删除模型">${icon('i-trash')}</button>` : '';
      return `
        <article class="model-card ${current ? 'is-current' : ''} ${downloading ? 'is-downloading' : ''}" data-model-card="${esc(model.id)}">
          <div class="model-head">
            <span class="model-avatar ${model.av}">${esc(model.avatar)}</span>
            <div class="model-title"><strong>${esc(model.short)}</strong><span>${esc(model.owner)}</span></div>
            ${current ? `<span class="model-badge">${icon('i-check')}使用中</span>` : ''}
          </div>
          <div class="model-specs">
            <span><b>${esc(model.params)}</b></span><span>${esc(model.size)}</span><span>${esc(model.family)}</span><span>${esc(model.ctx)} 上下文</span>
          </div>
          <div class="model-tags">${tags}</div>
          ${progress}
          <div class="model-actions">${action}${folder}${trash}</div>
        </article>`;
    }).join('');
  }

  function useModel(id) {
    const model = MODELS.find((m) => m.id === id);
    if (!model) return;
    if (model.state !== 'installed') {
      openDownloadConfirm(id);
      return;
    }
    if (id === state.modelId) return;
    state.modelId = id;
    updateModelChrome();
    renderModels();
    addLog('info', `model switched to ${id} · reloading engine`);
    toast(`已切换到 ${model.short}`, 'info');
    if (state.service === 'running') {
      setService('starting');
      setTimeout(() => { setService('running'); addLog('info', 'model reloaded in 1.6s · ready'); }, 1500);
    }
  }

  function updateModelChrome() {
    const model = currentModel();
    $$('[data-model-id]').forEach((el) => {
      if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') el.value = model.id;
      else el.textContent = model.id;
    });
    $$('.hero-title [data-model-name]').forEach((el) => { el.textContent = model.hero; });
    $$('.hero-quant').forEach((el) => { el.textContent = model.quant; });
    $$('.engine-model[data-model-name], .composer [data-model-name]').forEach((el) => { el.textContent = model.short; });
    const aside = $('#aside-model');
    if (aside) aside.value = model.id;
  }

  function openDownloadConfirm(id) {
    const model = MODELS.find((m) => m.id === id);
    const size = model ? model.size : '未知';
    openModal({
      title: '下载这个模型？',
      desc: id,
      body: `<p>模型会下载到 <code>~/.flashcat/models</code>，大约占用 <b>${esc(size)}</b> 磁盘空间。下载完成后会自动切换。</p>`,
      confirmLabel: '开始下载',
      onConfirm: () => startDownload(id),
    });
  }

  function startDownload(id) {
    if (!MODELS.find((m) => m.id === id)) {
      MODELS.push({
        id, short: id.split('/').pop(), hero: id.split('/').pop(), quant: '自定义', owner: id.split('/')[0],
        params: '—', size: '下载中', ctx: '—', family: 'Hub', avatar: 'H', av: 'av-3',
        tags: ['下载后可用', 'Hub'], state: 'remote',
      });
    }
    if (state.downloads[id] && state.downloads[id].timer) return;
    state.downloads[id] = { pct: 0, timer: null };
    toast('开始下载模型权重…', 'info');
    addLog('info', `download requested · ${id}`);
    renderModels();
    const timer = setInterval(() => {
      const item = state.downloads[id];
      if (!item) { clearInterval(timer); return; }
      item.pct = Math.min(100, item.pct + 3 + Math.random() * 7);
      const card = $(`[data-model-card="${CSS.escape(id)}"]`);
      if (card) {
        const meter = card.querySelector('.meter span');
        const pct = card.querySelector('.model-progress .row span');
        if (meter) meter.style.width = `${Math.round(item.pct)}%`;
        if (pct) pct.textContent = `正在下载 · ${Math.round(item.pct)}%`;
      } else if (state.page === 'models') {
        renderModels();
      }
      if (item.pct >= 100) {
        clearInterval(timer);
        const model = MODELS.find((m) => m.id === id);
        if (model) {
          model.state = 'installed';
          model.tags = ['DFlash2 就绪', '本机'];
          model.size = model.size === '下载中' ? '—' : model.size;
        }
        delete state.downloads[id];
        addLog('info', `download finished · ${id}`);
        toast('模型下载完成，即将切换');
        updateModelCounts();
        renderModels();
        setTimeout(() => useModel(id), 700);
      }
    }, 380);
    state.downloads[id].timer = timer;
  }

  function deleteModel(id) {
    const model = MODELS.find((m) => m.id === id);
    if (!model) return;
    if (id === state.modelId) { toast('正在使用的模型不能删除', 'error'); return; }
    openModal({
      title: '删除本地模型？',
      desc: '这个操作无法撤销。',
      danger: true,
      body: `<div class="modal-list"><b>${esc(model.id)}</b><code>${esc(model.size)} · ${esc(model.path || '~/.flashcat/models/' + model.short)}</code></div>`,
      confirmLabel: '删除',
      onConfirm: () => {
        state.hiddenModels.add(id);
        renderModels();
        toast('已删除模型', 'info');
        addLog('warn', `model removed · ${id}`);
      },
    });
  }

  function useCustomModel() {
    const input = $('#custom-model');
    const value = input.value.trim();
    if (!value) { input.focus(); return; }
    if (!/^[\w.-]+\/[\w.-]+(:\w[\w.-]*)?$/.test(value)) {
      toast('格式应为 owner/repo 或 owner/repo:VARIANT', 'error');
      input.focus();
      return;
    }
    const existing = MODELS.find((m) => m.id === value);
    if (existing) {
      useModel(value);
      input.value = '';
      return;
    }
    openDownloadConfirm(value);
  }

  function fakeImport() {
    openModal({
      title: '导入本地模型',
      desc: '选择一个包含权重的文件夹',
      body: `<div class="modal-list"><b>/Users/example/Models/Qwen3.8-27B-4bit</b><code>发现 4 个 safetensors 分片 · 14.6 GB · 草稿模型 780 MB</code></div><p style="margin-top:10px">“移动”会把权重整理进 <code>~/.flashcat/models</code>，“复制”保留原文件。</p>`,
      confirmLabel: '移动并导入',
      secondaryLabel: '复制',
      onConfirm: () => runFakeImport('move'),
      onSecondary: () => runFakeImport('copy'),
    });
  }

  function runFakeImport(mode) {
    toast(mode === 'move' ? '正在移动权重…' : '正在复制权重…', 'info', 1500);
    setTimeout(() => {
      const id = 'local/Qwen3.8-27B-4bit';
      if (!MODELS.find((m) => m.id === id)) {
        MODELS.push({
          id, short: 'Qwen3.8-27B-4bit', hero: 'Qwen3.8-27B', quant: '4-bit · 本地', owner: 'local',
          params: '27B', size: '14.6 GB', ctx: '100K', family: 'Dense', avatar: 'L', av: 'av-5',
          tags: ['DFlash2 就绪', '本机'], state: 'installed', path: '~/.flashcat/models/Qwen3.8-27B-4bit',
        });
      }
      renderModels();
      updateModelCounts();
      toast('已导入 local/Qwen3.8-27B-4bit');
      addLog('info', 'imported model local/Qwen3.8-27B-4bit · 14.6 GB');
    }, 1500);
  }

  /* ------------------------------------------------------------------ 设置 */

  function initSettings() {
    const fields = ['#set-port', '#set-memory', '#set-context', '#set-model', '#set-extra', '#set-cache'];
    fields.forEach((sel) => {
      const el = $(sel);
      if (el) el.addEventListener('input', () => { markDirty(); updateCommandPreview(); });
    });
    $$('[data-setting]').forEach((sw) => sw.addEventListener('click', () => {
      const on = !sw.classList.contains('is-on');
      sw.classList.toggle('is-on', on);
      sw.setAttribute('aria-checked', String(on));
      markDirty();
      updateCommandPreview();
    }));
    $$('[data-thinking-setting]').forEach((btn) => btn.addEventListener('click', () => {
      $$('[data-thinking-setting]').forEach((b) => b.classList.remove('is-active'));
      btn.classList.add('is-active');
      const mode = btn.dataset.thinkingSetting;
      const desc = $('#thinking-desc');
      const map = { 自动: '跟随模型的聊天模板', 关闭: '直接回答，不做隐藏推理', 开启: '使用指定的推理等级' };
      if (desc) desc.textContent = map[mode] || '';
      const effort = $('#set-effort');
      if (effort) effort.disabled = mode !== '开启';
      markDirty();
      updateCommandPreview();
    }));
    const effort = $('#set-effort');
    if (effort) effort.addEventListener('change', () => { markDirty(); updateCommandPreview(); });
    state.savedSettings = collectSettings();
  }

  function collectSettings() {
    const val = (sel) => { const el = $(sel); return el ? el.value : ''; };
    const sw = (idx) => {
      const el = $$('[data-setting]')[idx];
      return el ? el.classList.contains('is-on') : false;
    };
    const activeThinking = $('[data-thinking-setting].is-active');
    return {
      port: val('#set-port'),
      autoStart: sw(0),
      launchAtLogin: sw(1),
      memory: val('#set-memory'),
      context: val('#set-context'),
      keepWeights: sw(2),
      languageOnly: sw(3),
      thinking: activeThinking ? activeThinking.dataset.thinkingSetting : '自动',
      effort: val('#set-effort'),
      model: val('#set-model'),
      extra: val('#set-extra'),
      cache: val('#set-cache'),
    };
  }

  function applySettings(settings) {
    if (!settings) return;
    const setVal = (sel, value) => { const el = $(sel); if (el) el.value = value; };
    setVal('#set-port', settings.port);
    setVal('#set-memory', settings.memory);
    setVal('#set-context', settings.context);
    setVal('#set-model', settings.model || state.modelId);
    setVal('#set-extra', settings.extra);
    setVal('#set-cache', settings.cache);
    [settings.autoStart, settings.launchAtLogin, settings.keepWeights, settings.languageOnly].forEach((on, i) => {
      const sw = $$('[data-setting]')[i];
      if (!sw) return;
      sw.classList.toggle('is-on', on);
      sw.setAttribute('aria-checked', String(on));
    });
    $$('[data-thinking-setting]').forEach((b) => b.classList.toggle('is-active', b.dataset.thinkingSetting === settings.thinking));
    const desc = $('#thinking-desc');
    const map = { 自动: '跟随模型的聊天模板', 关闭: '直接回答，不做隐藏推理', 开启: '使用指定的推理等级' };
    if (desc) desc.textContent = map[settings.thinking] || '';
    const effort = $('#set-effort');
    if (effort) { effort.value = settings.effort; effort.disabled = settings.thinking !== '开启'; }
    updateCommandPreview();
  }

  function markDirty() {
    state.dirty = true;
    const chip = $('#unsaved-chip');
    if (chip) chip.hidden = false;
    const save = $('#save-btn');
    const saveRestart = $('#save-restart-btn');
    if (save) save.disabled = false;
    if (saveRestart) saveRestart.disabled = false;
    const bar = $('#save-bar');
    if (bar) bar.hidden = false;
  }

  function clearDirty() {
    state.dirty = false;
    const chip = $('#unsaved-chip');
    if (chip) chip.hidden = true;
    const save = $('#save-btn');
    const saveRestart = $('#save-restart-btn');
    if (save) save.disabled = true;
    if (saveRestart) saveRestart.disabled = true;
    const bar = $('#save-bar');
    if (bar) bar.hidden = true;
  }

  function saveSettings(restart) {
    state.savedSettings = collectSettings();
    clearDirty();
    toast(restart ? '设置已保存，正在重启引擎…' : '设置已保存');
    addLog('info', `settings saved · port=${state.savedSettings.port} · model=${state.savedSettings.model}`);
    if (restart) {
      restartService();
    } else if (state.service === 'running') {
      setTimeout(() => toast('新参数将在下次启动时生效', 'info', 2000), 800);
    }
  }

  function discardSettings() {
    applySettings(state.savedSettings);
    clearDirty();
    toast('已放弃未保存的修改', 'info', 1600);
  }

  function resetSettings() {
    openModal({
      title: '恢复默认设置？',
      desc: '端口、资源上限、开关与附加参数都会恢复默认值。',
      danger: true,
      body: '<p>这次操作只会修改表单，点击“保存”后才会应用到引擎。</p>',
      confirmLabel: '恢复默认',
      onConfirm: () => {
        applySettings({ ...DEFAULT_SETTINGS, model: state.modelId });
        markDirty();
        toast('已恢复默认值，记得保存', 'info');
      },
    });
  }

  function updateCommandPreview() {
    const pre = $('#command-preview code');
    if (!pre) return;
    const model = ($('#set-model')?.value || state.modelId).trim();
    const port = ($('#set-port')?.value || '8000').trim();
    const memory = ($('#set-memory')?.value || '').trim();
    const context = ($('#set-context')?.value || '').trim();
    const extra = ($('#set-extra')?.value || '').trim();
    const keepWeights = $$('[data-setting]')[2]?.classList.contains('is-on');
    const languageOnly = $$('[data-setting]')[3]?.classList.contains('is-on');
    const thinking = $('[data-thinking-setting].is-active')?.dataset.thinkingSetting || '自动';
    const effort = $('#set-effort')?.value || '中';
    const effortMap = { 最少: 'minimal', 低: 'low', 中: 'medium', 高: 'high', 极高: 'xhigh', 最大: 'max' };

    const parts = [
      ['cmd', 'splash'], ['cmd', 'serve'],
      ['flag', '--model'], ['val', model || '<模型>'],
      ['flag', '--port'], ['val', port || '8000'],
    ];
    if (memory) parts.push(['flag', '--max-memory'], ['val', memory]);
    if (context) parts.push(['flag', '--max-context'], ['val', context]);
    if (keepWeights) parts.push(['flag', '--idle-release'], ['val', 'off']);
    if (languageOnly) parts.push(['flag', '--language-only']);
    if (thinking === '关闭') parts.push(['flag', '--default-reasoning-effort'], ['val', 'none']);
    if (thinking === '开启') parts.push(['flag', '--default-reasoning-effort'], ['val', effortMap[effort] || 'medium']);
    if (extra) extra.split(/\s+/).forEach((token) => parts.push([token.startsWith('-') ? 'flag' : 'val', token]));

    pre.innerHTML = parts.map(([cls, value]) => `<span class="c-${cls}">${esc(value)}</span>`).join(' ');
  }

  function checkUpdate() {
    const btn = $('[data-action="check-update"]');
    if (!btn) return;
    const original = btn.textContent;
    btn.disabled = true;
    btn.textContent = '检查中…';
    setTimeout(() => {
      btn.disabled = false;
      btn.textContent = original;
      toast('splash 已是最新版本（1.4.0）', 'success', 2000);
    }, 900);
  }

  function restoreRuntime() {
    openModal({
      title: '恢复内置运行时？',
      desc: '会移除应用内更新过的 splash 运行时。',
      danger: true,
      body: '<p>当前版本 <b>1.4.0</b>，恢复后仍使用内置的同一版本。正在运行的服务会重启。</p>',
      confirmLabel: '恢复内置',
      onConfirm: () => { toast('已恢复内置运行时'); restartService(); },
    });
  }

  /* ------------------------------------------------------------------ 弹窗 */

  let modalResolve = null;

  function openModal({ title, desc = '', body = '', confirmLabel = '确认', cancelLabel = '取消', danger = false, secondaryLabel = '', onConfirm = null, onSecondary = null }) {
    const modal = $('#modal');
    if (!modal) return;
    state.lastFocus = document.activeElement;
    $('#modal-title').textContent = title;
    $('#modal-desc').textContent = desc;
    $('#modal-body').innerHTML = body || '';
    const iconWrap = $('#modal-icon');
    if (iconWrap) {
      iconWrap.classList.toggle('is-danger', danger);
      iconWrap.innerHTML = icon(danger ? 'i-alert' : 'i-bolt');
    }
    const actions = $('#modal-actions');
    actions.innerHTML = `
      <button class="btn" data-modal-cancel>${esc(cancelLabel)}</button>
      ${secondaryLabel ? `<button class="btn" data-modal-secondary>${esc(secondaryLabel)}</button>` : ''}
      <button class="btn ${danger ? 'btn-danger' : 'btn-primary'}" data-modal-confirm>${esc(confirmLabel)}</button>`;
    modal.hidden = false;
    modalResolve = (value) => {
      modal.hidden = true;
      modalResolve = null;
      if (state.lastFocus && state.lastFocus.focus) state.lastFocus.focus();
      if (value === 'confirm' && onConfirm) onConfirm();
      if (value === 'secondary' && onSecondary) onSecondary();
    };
    raf(() => actions.querySelector('[data-modal-confirm]')?.focus());
  }

  function closeModal(value = null) {
    if (modalResolve) modalResolve(value);
  }

  /* ------------------------------------------------------------------ 命令面板 */

  const PALETTE_ITEMS = [
    { group: '页面', label: '概览', icon: 'i-gauge', hint: '⌘1', run: () => go('overview') },
    { group: '页面', label: '对话', icon: 'i-chat', hint: '⌘2', run: () => go('chat') },
    { group: '页面', label: '模型', icon: 'i-cube', hint: '⌘3', run: () => go('models') },
    { group: '页面', label: '日志', icon: 'i-terminal', hint: '⌘4', run: () => go('logs') },
    { group: '页面', label: '设置', icon: 'i-sliders', hint: '⌘5', run: () => go('settings') },
    { group: '操作', label: '启动 / 停止服务', icon: 'i-bolt', hint: '⌘⇧S', keywords: 'service start stop 引擎', run: () => toggleService() },
    { group: '操作', label: '重启引擎', icon: 'i-restart', keywords: 'restart reload', run: () => restartService() },
    { group: '操作', label: '折叠 / 展开侧边栏', icon: 'i-panel', hint: '⌘\\', keywords: 'sidebar collapse 侧栏 面板', run: () => toggleSidebar() },
    { group: '操作', label: '切换深浅色外观', icon: 'i-sun', keywords: 'theme dark light 主题', run: () => toggleTheme() },
    { group: '操作', label: '复制 API 地址', icon: 'i-copy', keywords: 'api url 复制', run: () => copyText('http://127.0.0.1:8000/v1', '已复制 API 地址') },
    { group: '操作', label: '新建对话', icon: 'i-plus', keywords: 'new chat 清空', run: () => newChat() },
    { group: '操作', label: '检查运行时更新', icon: 'i-download', keywords: 'update splash', run: () => { go('settings'); checkUpdate(); } },
  ];

  let paletteIndex = 0;
  let paletteFiltered = [];

  function openPalette() {
    const overlay = $('#palette');
    if (!overlay) return;
    overlay.hidden = false;
    const input = $('#palette-input');
    if (input) { input.value = ''; setTimeout(() => input.focus(), 30); }
    renderPalette('');
  }

  function closePalette() {
    const overlay = $('#palette');
    if (overlay && !overlay.hidden) overlay.hidden = true;
  }

  function renderPalette(query) {
    const host = $('#palette-results');
    if (!host) return;
    const q = query.trim().toLowerCase();
    paletteFiltered = PALETTE_ITEMS.filter((item) => {
      const hay = `${item.label} ${item.keywords || ''}`.toLowerCase();
      return !q || hay.includes(q);
    });
    if (!paletteFiltered.length) {
      host.innerHTML = '<div class="palette-empty">没有找到匹配的操作</div>';
      paletteIndex = 0;
      return;
    }
    if (paletteIndex >= paletteFiltered.length) paletteIndex = 0;
    let html = '';
    let group = '';
    paletteFiltered.forEach((item, index) => {
      if (item.group !== group) {
        group = item.group;
        html += `<div class="palette-group">${group}</div>`;
      }
      html += `<button class="palette-item ${index === paletteIndex ? 'is-active' : ''}" data-palette-index="${index}">${icon(item.icon)}<span>${esc(item.label)}</span><span class="pi-hint">${esc(item.hint || '')}</span></button>`;
    });
    host.innerHTML = html;
  }

  function movePalette(delta) {
    if (!paletteFiltered.length) return;
    paletteIndex = (paletteIndex + delta + paletteFiltered.length) % paletteFiltered.length;
    $$('.palette-item').forEach((el, i) => el.classList.toggle('is-active', i === paletteIndex));
    const active = $('.palette-item.is-active');
    if (active) active.scrollIntoView({ block: 'nearest' });
  }

  function runPalette(index) {
    const item = paletteFiltered[index];
    if (!item) return;
    closePalette();
    setTimeout(() => item.run(), 10);
  }

  /* ------------------------------------------------------------------ 聊天之外的全局动作 */

  function newChat() {
    if (state.streaming) { toast('正在生成，先停止再新建对话', 'error'); return; }
    const reset = () => {
      state.messages = [];
      state.streamText = '';
      renderChat();
      closeComposer();
      toast('已开始新对话', 'info', 1500);
    };
    if (state.messages.length) {
      openModal({
        title: '开始新对话？',
        desc: '当前对话会从界面移除。',
        body: '<p>只会清空界面记录，不会影响模型或推理服务。</p>',
        confirmLabel: '新建对话',
        onConfirm: reset,
      });
    } else {
      reset();
    }
  }

  function clearChat() {
    if (!state.messages.length) return;
    openModal({
      title: '清空当前对话？',
      desc: '只会删除界面上的记录，不会影响模型或服务。',
      confirmLabel: '清空',
      danger: true,
      onConfirm: () => {
        stopStreaming(true);
        state.messages = [];
        state.streamText = '';
        renderChat();
        toast('对话已清空', 'info');
      },
    });
  }

  function closeComposer() {
    const input = $('#composer-input');
    if (input) { input.value = ''; input.style.height = 'auto'; }
  }

  /* ------------------------------------------------------------------ 绑定 */

  function bindEvents() {
    // 导航 / 复制 / 通用动作
    document.addEventListener('click', (event) => {
      const nav = event.target.closest('[data-nav]');
      if (nav) { go(nav.dataset.nav); return; }

      const copy = event.target.closest('[data-copy]');
      if (copy) { copyText(copy.dataset.copy, '已复制'); return; }

      const modelUse = event.target.closest('[data-model-use]');
      if (modelUse) { useModel(modelUse.dataset.modelUse); return; }

      const download = event.target.closest('[data-model-download]');
      if (download) { openDownloadConfirm(download.dataset.modelDownload); return; }

      const del = event.target.closest('[data-model-delete]');
      if (del) { deleteModel(del.dataset.modelDelete); return; }

      const folder = event.target.closest('[data-model-folder]');
      if (folder) { toast('已在访达中显示模型目录', 'info', 1600); return; }

      const copyMsg = event.target.closest('[data-copy-message]');
      if (copyMsg) {
        const msg = state.messages[Number(copyMsg.dataset.copyMessage)];
        if (msg) copyText(msg.text, '已复制消息');
        return;
      }

      const regen = event.target.closest('[data-regenerate]');
      if (regen) {
        if (state.streaming) return;
        const last = state.messages[state.messages.length - 1];
        if (last && last.role === 'assistant') state.messages.pop();
        renderChat();
        setTimeout(startAssistant, 120);
        return;
      }

      const codeCopy = event.target.closest('.code-copy');
      if (codeCopy) {
        const code = codeCopy.closest('.code')?.querySelector('code');
        if (code) copyText(code.textContent, '已复制代码');
        return;
      }

      const suggestion = event.target.closest('[data-suggestion]');
      if (suggestion) {
        const input = $('#composer-input');
        if (input) {
          input.value = suggestion.dataset.suggestion;
          input.focus();
          input.dispatchEvent(new Event('input'));
        }
        return;
      }

      const action = event.target.closest('[data-action]');
      if (action) {
        const name = action.dataset.action;
        if (name === 'palette') return openPalette();
        if (name === 'toggle-sidebar') return toggleSidebar();
        if (name === 'toggle-service') return toggleService();
        if (name === 'restart') return restartService();
        if (name === 'refresh') { updateSpeedUI(); renderChart(); toast('已刷新采样', 'info', 1400); return; }
        if (name === 'toggle-aside') return openParams();
        if (name === 'clear-chat') return clearChat();
        if (name === 'new-chat') return newChat();
        if (name === 'send') {
          if (state.streaming) { stopStreaming(); return; }
          const input = $('#composer-input');
          return sendMessage(input ? input.value : '');
        }
        if (name === 'reset-params') {
          state.temp = 0.7; state.topP = 0.95; state.thinking = '自动';
          const system = $('#system-prompt'); if (system) system.value = '';
          syncComposerChips();
          $$('[data-thinking]').forEach((b) => b.classList.toggle('is-active', b.dataset.thinking === '自动'));
          toast('已恢复默认参数', 'info', 1600);
          return;
        }
        if (name === 'save-settings') return saveSettings(action.dataset.restart === 'true');
        if (name === 'discard-settings') return discardSettings();
        if (name === 'reset-settings') return resetSettings();
        if (name === 'check-update') return checkUpdate();
        if (name === 'restore-runtime') return restoreRuntime();
        if (name === 'open-models-folder') return toast('已在访达中打开 ~/.flashcat/models', 'info', 1800);
        if (name === 'import-model') return fakeImport();
        if (name === 'use-custom-model') return useCustomModel();
        if (name === 'copy-logs') return copyLogs();
        if (name === 'clear-logs') {
          if (!state.logs.length) return;
          state.logs = [];
          renderLogs();
          toast('日志已清空', 'info');
          return;
        }
        if (name === 'open-log') return toast('已在访达中显示 server.log', 'info', 1800);
        if (name === 'copy-command') {
          return copyText($('#command-preview code')?.textContent || '', '已复制启动命令');
        }
        return;
      }
    });

    // 主题
    $('#theme-toggle')?.addEventListener('click', toggleTheme);

    // 顶部命令面板按钮与输入
    $('#palette')?.addEventListener('click', (event) => {
      if (event.target === $('#palette')) closePalette();
      const item = event.target.closest('.palette-item');
      if (item) runPalette(Number(item.dataset.paletteIndex));
    });
    $('#palette-input')?.addEventListener('input', (event) => {
      paletteIndex = 0;
      renderPalette(event.target.value);
    });

    // 弹窗
    $('#modal')?.addEventListener('click', (event) => {
      if (event.target === $('#modal')) { closeModal(null); return; }
      if (event.target.closest('[data-modal-cancel]')) { closeModal(null); return; }
      if (event.target.closest('[data-modal-confirm]')) { closeModal('confirm'); return; }
      if (event.target.closest('[data-modal-secondary]')) { closeModal('secondary'); return; }
      if (event.target.closest('[data-modal-close]')) closeModal(null);
    });

    // 日志
    $('#log-search')?.addEventListener('input', (event) => {
      state.logQuery = event.target.value;
      renderLogs(true);
    });
    $$('[data-level]').forEach((btn) => btn.addEventListener('click', () => {
      $$('[data-level]').forEach((b) => b.classList.remove('is-active'));
      btn.classList.add('is-active');
      state.logLevel = btn.dataset.level;
      renderLogs(true);
    }));
    $('#autoscroll')?.addEventListener('click', () => {
      state.autoscroll = !state.autoscroll;
      const btn = $('#autoscroll');
      btn.classList.toggle('is-on', state.autoscroll);
      btn.setAttribute('aria-checked', String(state.autoscroll));
      if (state.autoscroll) scrollLogsToEnd();
      toast(state.autoscroll ? '已开启自动滚动' : '已关闭自动滚动', 'info', 1400);
    });
    $('#log-pause')?.addEventListener('click', () => setLogPaused(!state.logPaused));

    // 模型筛选和搜索
    $$('[data-model-filter]').forEach((btn) => btn.addEventListener('click', () => {
      $$('[data-model-filter]').forEach((b) => b.classList.remove('is-active'));
      btn.classList.add('is-active');
      state.modelFilter = btn.dataset.modelFilter;
      renderModels();
    }));
    $('#model-search')?.addEventListener('input', (event) => {
      state.modelQuery = event.target.value;
      renderModels();
    });
    $('#dropzone')?.addEventListener('click', fakeImport);
    $('#dropzone')?.addEventListener('keydown', (event) => {
      if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); fakeImport(); }
    });
    $('#custom-model')?.addEventListener('keydown', (event) => {
      if (event.key === 'Enter') useCustomModel();
    });

    // 参数面板里的模型选择
    $('#aside-model')?.addEventListener('change', (event) => useModel(event.target.value));

    // 对话参数
    $('#temp-range')?.addEventListener('input', (event) => {
      state.temp = Number(event.target.value);
      syncComposerChips();
    });
    $('#topp-range')?.addEventListener('input', (event) => {
      state.topP = Number(event.target.value);
      syncComposerChips();
    });
    $$('[data-thinking]').forEach((btn) => btn.addEventListener('click', () => {
      $$('[data-thinking]').forEach((b) => b.classList.remove('is-active'));
      btn.classList.add('is-active');
      state.thinking = btn.dataset.thinking;
      syncComposerChips();
    }));
    $('#system-prompt')?.addEventListener('input', (event) => { state.systemPrompt = event.target.value; });

    // 对话输入
    const input = $('#composer-input');
    input?.addEventListener('input', () => {
      input.style.height = 'auto';
      input.style.height = `${Math.min(150, input.scrollHeight)}px`;
    });
    input?.addEventListener('keydown', (event) => {
      if (event.isComposing || event.keyCode === 229) return;
      if (event.key === 'Enter' && !event.shiftKey && !event.altKey) {
        event.preventDefault();
        if (state.streaming) return;
        sendMessage(input.value);
      }
    });

    // 设置左侧导航
    $$('[data-scroll]').forEach((btn) => btn.addEventListener('click', () => {
      const target = document.getElementById(btn.dataset.scroll);
      if (!target) return;
      $$('[data-scroll]').forEach((b) => b.classList.remove('is-active'));
      btn.classList.add('is-active');
      target.scrollIntoView({ behavior: 'smooth', block: 'start' });
    }));

    // 图表范围
    $$('[data-range]').forEach((btn) => btn.addEventListener('click', () => {
      $$('[data-range]').forEach((b) => b.classList.remove('is-active'));
      btn.classList.add('is-active');
      state.chartRange = Number(btn.dataset.range);
      renderChart();
    }));

    // 键盘
    document.addEventListener('keydown', (event) => {
      const meta = event.metaKey || event.ctrlKey;
      const palette = $('#palette');
      const paletteOpen = palette && !palette.hidden;
      const modalOpen = $('#modal') && !$('#modal').hidden;

      if (paletteOpen) {
        if (event.key === 'Escape') { event.preventDefault(); closePalette(); return; }
        if (event.key === 'ArrowDown') { event.preventDefault(); movePalette(1); return; }
        if (event.key === 'ArrowUp') { event.preventDefault(); movePalette(-1); return; }
        if (event.key === 'Enter') { event.preventDefault(); runPalette(paletteIndex); return; }
      }
      if (modalOpen && event.key === 'Escape') { event.preventDefault(); closeModal(null); return; }
      if (event.key === 'Escape') {
        if (!$('#chat-aside')?.hidden) { openParams(false); return; }
      }
      if (meta && event.key.toLowerCase() === 'k') { event.preventDefault(); paletteOpen ? closePalette() : openPalette(); return; }
      if (meta && event.key === ',') { event.preventDefault(); go('settings'); return; }
      if (meta && event.key === '\\') { event.preventDefault(); toggleSidebar(); return; }
      if (meta && ['1', '2', '3', '4', '5'].includes(event.key)) {
        event.preventDefault();
        go(['overview', 'chat', 'models', 'logs', 'settings'][Number(event.key) - 1]);
        return;
      }
      if (meta && event.key.toLowerCase() === 'f') {
        if (state.page === 'models') { event.preventDefault(); $('#model-search')?.focus(); }
        else if (state.page === 'logs') { event.preventDefault(); $('#log-search')?.focus(); }
      }
    });

    // 尺寸变化
    if (window.ResizeObserver) {
      const ro = new ResizeObserver(() => {
        if (state.page === 'overview') renderChart();
      });
      const wrap = $('#chart-wrap');
      if (wrap) ro.observe(wrap);
    } else {
      window.addEventListener('resize', () => { if (state.page === 'overview') renderChart(); });
    }

    // 浏览器 hash 前进/后退
    window.addEventListener('hashchange', () => {
      const page = location.hash.replace('#', '');
      if (page && page !== state.page) go(page, { silent: true });
    });

    // 页面级 IntersectionObserver 高亮设置导航
    if ('IntersectionObserver' in window) {
      const observer = new IntersectionObserver((entries) => {
        entries.forEach((entry) => {
          if (!entry.isIntersecting) return;
          const id = entry.target.id;
          $$('[data-scroll]').forEach((b) => b.classList.toggle('is-active', b.dataset.scroll === id));
        });
      }, { rootMargin: '-20% 0px -70% 0px' });
      $$('.settings-card').forEach((card) => observer.observe(card));
    }
  }

  /* ------------------------------------------------------------------ 初始化 */

  function init() {
    // 初始状态
    const params = new URLSearchParams(location.search);
    const forcedTheme = params.get('theme');
    const stored = storage.get('flashcat-theme');
    const prefersDark = window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches;
    applyTheme(forcedTheme || stored || (prefersDark ? 'dark' : 'light'), false);

    seedHistory();
    seedLogs();
    state.messages = initialMessages();
    state.systemPrompt = '';

    initSettings();
    storeInitialSettings();

    const aside = $('#aside-model');
    if (aside) {
      aside.innerHTML = installedModels().map((m) => `<option value="${esc(m.id)}">${esc(m.short)}</option>`).join('');
      aside.value = state.modelId;
    }
    $$('[data-tip]').forEach((el) => { if (!el.title) el.title = el.dataset.tip; });

    applySidebar(state.sidebarCollapsed, false);
    bindEvents();
    syncService();
    syncComposerChips();
    updateModelChrome();
    updateLogCounts();
    updateCommandPreview();
    renderModels();
    renderChat();
    renderLogs();
    bindChartHover();
    setService('running');

    const page = location.hash.replace('#', '');
    go(PAGE_NAMES[page] ? page : 'overview', { silent: false });
    raf(() => { renderChart(); scrollChatToBottom(true); });

    setInterval(tick, 1200);
    setInterval(() => { if (state.service === 'running' && !state.logPaused) addLiveLog(); }, 2600);
  }

  function storeInitialSettings() {
    state.savedSettings = collectSettings();
    clearDirty();
    applySettings({ ...state.savedSettings, model: state.modelId });
    clearDirty();
    updateCommandPreview();
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();
