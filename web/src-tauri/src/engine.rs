//! 推理后端的抽象与运行注册表。
//!
//! 为什么用线程 + `std::sync::mpsc` 而不是 async：llama.cpp 的 `llama_decode`
//! 本身就是阻塞的，套一层 async 只会把阻塞点藏进调度器。一次生成一条线程，
//! 取消用 `AtomicBool`，事件用通道回到命令层再 `emit` 给前端——四个平台同一套。

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::mpsc::{self, Receiver};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use crate::model::{
    ChatRequest, Delta, EngineState, EngineStatus, ModelCard, IS_MOBILE,
};

/// 一次生成的可取消句柄。
pub struct Run {
    pub id: String,
    cancelled: AtomicBool,
}

impl Run {
    fn new(id: &str) -> Self {
        Self { id: id.to_string(), cancelled: AtomicBool::new(false) }
    }
    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::Relaxed);
    }
    pub fn is_cancelled(&self) -> bool {
        self.cancelled.load(Ordering::Relaxed)
    }
}

/// 推理后端。换 llama.cpp 时只需新增一个实现，命令层与前端不动。
pub trait Backend: Send + Sync {
    fn name(&self) -> &'static str;
    fn status(&self) -> EngineStatus;
    fn models(&self) -> Vec<ModelCard>;
    /// 起一条线程跑一次生成，把增量推到返回的通道；`run` 用于查询取消。
    fn generate(&self, req: ChatRequest, run: Arc<Run>) -> Receiver<Delta>;
}

/// 运行注册表：负责 run_id 分配、取消、超量拒绝。
pub struct Engine {
    backend: Arc<dyn Backend>,
    runs: Mutex<HashMap<String, Arc<Run>>>,
    seq: AtomicU32,
}

/// 同时最多两条生成（桌面可能一边聊一边跑批），移动端只留一条。
fn max_concurrent() -> usize {
    if IS_MOBILE {
        1
    } else {
        2
    }
}

impl Engine {
    pub fn new() -> Self {
        Self {
            backend: Arc::new(MockBackend::default()),
            runs: Mutex::new(HashMap::new()),
            seq: AtomicU32::new(0),
        }
    }

    pub fn status(&self) -> EngineStatus {
        self.backend.status()
    }

    pub fn models(&self) -> Vec<ModelCard> {
        self.backend.models()
    }

    /// 返回 `Err` 时前端应当把文案直接展示给用户（已经是人话）。
    pub fn start(&self, req: ChatRequest) -> Result<(Arc<Run>, Receiver<Delta>), String> {
        let mut runs = self.runs.lock().expect("runs 锁中毒");
        if runs.len() >= max_concurrent() {
            return Err("已有生成在进行，请先停止或等待完成".into());
        }
        let n = self.seq.fetch_add(1, Ordering::Relaxed) + 1;
        let run = Arc::new(Run::new(&format!("run-{n:04}")));
        let rx = self.backend.generate(req, run.clone());
        runs.insert(run.id.clone(), run.clone());
        Ok((run, rx))
    }

    pub fn cancel(&self, run_id: &str) -> bool {
        match self.runs.lock().expect("runs 锁中毒").get(run_id) {
            Some(run) => {
                run.cancel();
                true
            }
            None => false,
        }
    }

    /// 生成线程退出时由转发线程调用，防止注册表无限增长。
    pub fn release(&self, run_id: &str) {
        self.runs.lock().expect("runs 锁中毒").remove(run_id);
    }
}

impl Default for Engine {
    fn default() -> Self {
        Self::new()
    }
}

// ---------------------------------------------------------------------------
// Mock 后端
// ---------------------------------------------------------------------------

/// 假的推理后端：把真实的事件节奏（首字延迟、思考流、正文流、用量结算）走一遍，
/// 让前端在权重下载器与 llama.cpp 落地之前就接终态协议。
///
/// 应答内容刻意包含标题、粗体、列表、行内代码与围栏代码块，用于回归渲染器。
pub struct MockBackend {
    models: Vec<ModelCard>,
}

impl Default for MockBackend {
    fn default() -> Self {
        Self { models: catalog() }
    }
}

impl Backend for MockBackend {
    fn name(&self) -> &'static str {
        "mock"
    }

    fn status(&self) -> EngineStatus {
        EngineStatus {
            backend: self.name().to_string(),
            state: EngineState::Ready,
            model_id: Some("qwen3-0.6b-q4km".into()),
            resident_mb: 412,
            tokens_per_sec: Some(38.4),
            quantization: Some("Q4_K_M".into()),
        }
    }

    fn models(&self) -> Vec<ModelCard> {
        self.models.clone()
    }

    fn generate(&self, req: ChatRequest, run: Arc<Run>) -> Receiver<Delta> {
        let (tx, rx) = mpsc::channel::<Delta>();
        let model_id = req.model_id.clone().unwrap_or_else(|| "qwen3-0.6b-q4km".into());
        let prompt = req.message.clone();
        let run_id = run.id.clone();
        // 这三个字段现在不改变生成结果，但必须走一遍：它们是前后端协议的一部分，
        // 接上 llama.cpp 之前先保证「前端传什么，后端确实收到什么」。
        let thread_id = req.thread_id.clone();
        let turns = req.history.len();
        let temperature = req.temperature.unwrap_or(0.7);
        // max_tokens 按「一 token ≈ 4 字符」折算成字符上限，真后端直接用它截断。
        let char_cap = req.max_tokens.map(|n| n as usize * 4).unwrap_or(usize::MAX);

        thread::Builder::new()
            .name(format!("mock-gen-{run_id}"))
            .spawn(move || {
                let started = Instant::now();
                let mut first_token: Option<Instant> = None;

                // 首字延迟：真实引擎在 120–400ms 之间，这里取 180ms 作基线。
                thread::sleep(Duration::from_millis(180));

                let thinking = format!(
                    "用户问的是「{}」。先判断是本地能力问题还是通用问答，再把答案组织成可复制的结构。",
                    clip(&prompt, 40)
                );
                let _ = (&thread_id, turns, temperature);
                if !emit_all(&tx, &run, &run_id, thinking, Kind::Thinking) {
                    return;
                }
                if first_token.is_none() {
                    first_token = Some(Instant::now());
                }

                let mut answer = answer_for(&prompt);
                if answer.chars().count() > char_cap {
                    answer = answer.chars().take(char_cap).collect();
                }
                let mut produced = 0u32;
                for chunk in chunks(&answer, 3) {
                    if run.is_cancelled() {
                        break;
                    }
                    if !emit(&tx, Delta::Text { run_id: run_id.clone(), delta: chunk }) {
                        return;
                    }
                    produced += 1;
                    // 桌面 ~55 字/秒，移动端慢一档，模拟小模型的真实体感。
                    thread::sleep(Duration::from_millis(if IS_MOBILE { 26 } else { 18 }));
                    if first_token.is_none() {
                        first_token = Some(Instant::now());
                    }
                }

                let total_ms = started.elapsed().as_millis() as u32;
                let output_tokens = (answer.chars().count() as f32 / 1.6) as u32;
                let input_tokens = (prompt.chars().count() as f32 / 1.5) as u32 + 12;
                let first_ms = first_token
                    .map(|t| t.duration_since(started).as_millis() as u32)
                    .unwrap_or(total_ms);
                let secs = (total_ms.max(1) as f32) / 1000.0;

                let _ = tx.send(Delta::Usage {
                    run_id: run_id.clone(),
                    input_tokens,
                    output_tokens,
                    first_token_ms: first_ms,
                    total_ms,
                    tokens_per_sec: (output_tokens as f32 / secs * 10.0).round() / 10.0,
                    model_id,
                });
                let _ = tx.send(Delta::Done { run_id });
                let _ = produced;
            })
            .expect("无法创建生成线程");

        rx
    }
}

enum Kind {
    Thinking,
}

fn emit_all(
    tx: &mpsc::Sender<Delta>,
    run: &Run,
    run_id: &str,
    text: String,
    kind: Kind,
) -> bool {
    for chunk in chunks(&text, 2) {
        if run.is_cancelled() {
            return false;
        }
        let delta = match kind {
            Kind::Thinking => Delta::Thinking { run_id: run_id.to_string(), delta: chunk },
        };
        if !emit(tx, delta) {
            return false;
        }
        thread::sleep(Duration::from_millis(16));
    }
    true
}

fn emit(tx: &mpsc::Sender<Delta>, delta: Delta) -> bool {
    tx.send(delta).is_ok()
}

/// 按字符切块，绝不切断 UTF-8 码点。
fn chunks(text: &str, size: usize) -> Vec<String> {
    let chars: Vec<char> = text.chars().collect();
    chars.chunks(size).map(|c| c.iter().collect()).collect()
}

fn clip(text: &str, max: usize) -> String {
    if text.chars().count() <= max {
        text.to_string()
    } else {
        let head: String = text.chars().take(max).collect();
        format!("{head}…")
    }
}

fn answer_for(prompt: &str) -> String {
    format!(
        "这是 **MockBackend** 的应答，用来验证流式管线，不代表模型能力。\n\n\
### 现在这条链路上有什么\n\n\
- 命令层：`chat_start` 起一条线程，增量经 `chat:delta` 事件回到 WebView；\n\
- 取消：`chat_cancel` 置位后，生成线程在下一次 `is_cancelled` 处退出；\n\
- 用量：结束时会补一条 `usage`，带首字延迟与 tok/s。\n\n\
```rust\n\
let (run, rx) = engine.start(req)?;\n\
for delta in rx {{ app.emit(\"chat:delta\", delta)?; }}\n\
```\n\n\
你刚问的是「{q}」。换成真实权重后，这段文字会由 llama.cpp 逐 token 解码，\
前端一行都不用改；移动端把同一份权重放进应用沙盒，走 mmap 直接映射。",
        q = clip(prompt, 60)
    )
}

/// 首启目录：移动端只保留 4bit 且 ≤1.7B 的条目，避免用户在手机上点到大模型。
fn catalog() -> Vec<ModelCard> {
    let all = ["macos", "windows", "linux"];
    let portable = ["macos", "windows", "linux", "ios", "android"];
    vec![
        ModelCard {
            id: "qwen3-0.6b-q4km".into(),
            name: "Qwen3 0.6B".into(),
            family: "qwen3".into(),
            params_b: 0.6,
            quantization: "Q4_K_M".into(),
            size_mb: 412,
            context: 32_768,
            tags: vec!["chat".into()],
            platforms: portable.to_vec(),
            installed: true,
            note: Some("手机默认档，1.2GB 内存内可跑".into()),
        },
        ModelCard {
            id: "qwen3-1.7b-q4km".into(),
            name: "Qwen3 1.7B".into(),
            family: "qwen3".into(),
            params_b: 1.7,
            quantization: "Q4_K_M".into(),
            size_mb: 1_120,
            context: 32_768,
            tags: vec!["chat".into()],
            platforms: portable.to_vec(),
            installed: false,
            note: Some("手机高档位，建议 8GB 内存以上".into()),
        },
        ModelCard {
            id: "llama-3.2-1b-q4km".into(),
            name: "Llama 3.2 1B".into(),
            family: "llama".into(),
            params_b: 1.0,
            quantization: "Q4_K_M".into(),
            size_mb: 808,
            context: 131_072,
            tags: vec!["chat".into()],
            platforms: portable.to_vec(),
            installed: false,
            note: None,
        },
        ModelCard {
            id: "qwen3-8b-q4km".into(),
            name: "Qwen3 8B".into(),
            family: "qwen3".into(),
            params_b: 8.0,
            quantization: "Q4_K_M".into(),
            size_mb: 4_920,
            context: 32_768,
            tags: vec!["chat".into()],
            platforms: all.to_vec(),
            installed: false,
            note: Some("桌面档，16GB 内存起步".into()),
        },
        ModelCard {
            id: "qwen3-embedding-0.6b".into(),
            name: "Qwen3 Embedding 0.6B".into(),
            family: "qwen3".into(),
            params_b: 0.6,
            quantization: "F16".into(),
            size_mb: 1_190,
            context: 32_768,
            tags: vec!["embedding".into()],
            platforms: all.to_vec(),
            installed: false,
            note: None,
        },
    ]
}
