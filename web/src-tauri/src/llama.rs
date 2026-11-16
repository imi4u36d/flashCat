//! 真实的 llama.cpp 后端。
//!
//! 为什么在 `Backend` 里只做「加载 + 推流」两件事：命令层与前端已经按终态协议
//! （`thinking` / `text` / `usage` / `done` / `error`）写好，这里只要把 llama.cpp
//! 的输出翻译成同样的 `Delta`，四端就自动有了真推理。
//!
//! 几个刻意的选择：
//! - **不引入 tokio**：`llama_decode` 是同步阻塞的，套 async 只会把阻塞点藏起来；
//! - **一次生成一条线程、一个 context**：context 里的 KV cache 不能共享，
//!   而复用需要自己管缓存淘汰，收益远小于复杂度；
//! - **按 UTF-8 字节边界拼 token**：BPE 的一个 token 可能是半个汉字，
//!   直接 `String::from_utf8_lossy` 会把一个汉字拆成两个替换符；
//! - **思考内容单独走 `thinking`**：Qwen3 这类带 ` thinking` 的模板，前端有专门的折叠块。

use std::num::NonZeroU32;
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, Receiver};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Instant;

use llama_cpp_2::context::params::LlamaContextParams;
use llama_cpp_2::llama_backend::LlamaBackend;
use llama_cpp_2::llama_batch::LlamaBatch;
use llama_cpp_2::model::params::LlamaModelParams;
use llama_cpp_2::model::{LlamaChatMessage, LlamaModel};
use llama_cpp_2::sampling::LlamaSampler;

use crate::engine::{Backend, Run};
use crate::model::{ChatRequest, Delta, EngineState, EngineStatus, ModelCard, IS_MOBILE};

/// 上下文与批大小。移动端显存/内存都紧张，砍到 2k 上下文、256 批。
fn context_window() -> u32 {
    if IS_MOBILE {
        2048
    } else {
        4096
    }
}

fn batch_size() -> usize {
    if IS_MOBILE {
        256
    } else {
        512
    }
}

fn threads() -> i32 {
    let n = thread::available_parallelism().map(|n| n.get()).unwrap_or(4);
    // 解码线程超过物理核心只会互相抢时间片；移动端再留一核给系统。
    let cap = if IS_MOBILE { 4 } else { 10 };
    n.min(cap) as i32
}

pub struct LlamaChatBackend {
    dir: PathBuf,
    backend: Arc<LlamaBackend>,
    /// 只缓存「当前这一个」模型：换模型时旧的 Arc 自然释放，不需要淘汰策略。
    /// `Arc<Mutex<…>>` 是为了让生成线程能独立持有它，不必回借 `self`。
    loaded: Arc<Mutex<Option<Arc<Loaded>>>>,
}

struct Loaded {
    path: PathBuf,
    model: Arc<LlamaModel>,
    card: ModelCard,
}

impl LlamaChatBackend {
    /// `dir` 是权重目录；`None` 表示 llama.cpp 初始化失败（例如没编进 Metal），
    /// 这时返回 `Err`，由 `Engine` 决定回落到 mock 还是直接报错。
    pub fn new(dir: PathBuf) -> Result<Self, String> {
        let backend = LlamaBackend::init().map_err(|e| format!("llama.cpp 初始化失败：{e}"))?;
        Ok(Self { dir, backend: Arc::new(backend), loaded: Arc::new(Mutex::new(None)) })
    }

    fn scan(&self) -> Vec<ModelCard> {
        let Ok(entries) = std::fs::read_dir(&self.dir) else {
            return Vec::new();
        };
        let mut cards: Vec<ModelCard> = entries
            .filter_map(|e| e.ok())
            .map(|e| e.path())
            .filter(|p| p.extension().is_some_and(|x| x.eq_ignore_ascii_case("gguf")))
            .filter_map(|p| card_for(&p))
            .collect();
        cards.sort_by(|a, b| a.name.cmp(&b.name));
        cards
    }

    fn pick(&self, model_id: Option<&str>) -> Option<PathBuf> {
        let cards = self.scan();
        let want = model_id?;
        cards
            .iter()
            .find(|c| c.id == want)
            .and_then(|c| {
                self.dir
                    .read_dir()
                    .ok()?
                    .filter_map(|e| e.ok())
                    .map(|e| e.path())
                    .find(|p| p.file_stem().and_then(|s| s.to_str()) == Some(c.id.as_str()))
            })
            .or_else(|| self.default_model())
    }

    fn default_model(&self) -> Option<PathBuf> {
        self.scan()
            .into_iter()
            .next()
            .and_then(|c| self.dir.join(format!("{}.gguf", c.id)).canonicalize().ok())
    }

    /// 当前已加载的模型（状态查询用）。
    fn current(&self) -> Option<Arc<Loaded>> {
        self.loaded.lock().ok().and_then(|g| g.clone())
    }
}

/// 取（必要时加载）模型。自由函数而非方法：生成线程只拿到 `Arc` 克隆，
/// 不需要把 `&self` 送进线程（那样要么加生命周期，要么写得很难看）。
fn acquire(
    backend: &LlamaBackend,
    slot: &Mutex<Option<Arc<Loaded>>>,
    path: &Path,
) -> Result<Arc<Loaded>, String> {
    let guard = slot.lock().map_err(|_| "模型缓存锁中毒".to_string())?;
    if let Some(loaded) = guard.as_ref() {
        if loaded.path == path {
            return Ok(loaded.clone());
        }
    }
    drop(guard);

    let card = card_for(path).ok_or_else(|| format!("读不到权重：{}", path.display()))?;
    let params = LlamaModelParams::default().with_n_gpu_layers(gpu_layers());
    let model = LlamaModel::load_from_file(backend, path, &params)
        .map_err(|e| format!("加载 {} 失败：{e}", card.name))?;
    let loaded = Arc::new(Loaded { path: path.to_path_buf(), model: Arc::new(model), card });

    let mut guard = slot.lock().map_err(|_| "模型缓存锁中毒".to_string())?;
    *guard = Some(loaded.clone());
    Ok(loaded)
}

/// macOS/iOS 走 Metal，把全部层丢上 GPU；其它平台目前是纯 CPU。
///
/// 模拟器例外：iOS 模拟器里的 Metal 是转发到宿主 GPU 的，llama.cpp 的
/// 内核管线要在第一次用到时逐条编译，真机上几百毫秒、模拟器上能卡到分钟级
/// —— 表现就是「点了发送，一直 0 tok」。模拟器上退回 CPU 反而更快看到字。
fn is_simulator() -> bool {
    std::env::var_os("SIMULATOR_DEVICE_NAME").is_some()
        || std::env::var_os("SIMULATOR_UDID").is_some()
}

fn gpu_layers() -> u32 {
    if cfg!(any(target_os = "macos", target_os = "ios")) && !is_simulator() {
        999
    } else {
        0
    }
}

/// 从文件名推断元信息。GGUF 头里有更准的 `general.name` / 量化类型，
/// 但那要在加载后读；列表页不该为了排序去开 400MB 的文件，所以先用文件名。
fn card_for(path: &Path) -> Option<ModelCard> {
    let stem = path.file_stem()?.to_str()?.to_string();
    let size = std::fs::metadata(path).ok().map(|m| m.len()).unwrap_or(0);
    let lower = stem.to_ascii_lowercase();
    let quant = ["q8_0", "q6_k", "q5_k_m", "q4_k_m", "q4_0", "q3_k_m", "iq4_xs", "iq4_nl", "f16"]
        .iter()
        .find(|q| lower.contains(&q.replace('_', "")) || lower.contains(*q))
        .map(|q| q.to_ascii_uppercase())
        .unwrap_or_else(|| "GGUF".into());
    let params_b = ["0.6b", "0.8b", "1b", "1.5b", "1.7b", "3b", "4b", "7b", "8b"]
        .iter()
        .find(|p| lower.contains(*p))
        .map(|p| p.trim_end_matches('b').parse::<f32>().unwrap_or(0.0))
        .unwrap_or(0.0);
    let family = if lower.contains("qwen3") {
        "Qwen3"
    } else if lower.contains("qwen2") {
        "Qwen2"
    } else if lower.contains("llama") {
        "Llama"
    } else if lower.contains("gemma") {
        "Gemma"
    } else if lower.contains("phi") {
        "Phi"
    } else {
        "Local"
    };
    Some(ModelCard {
        id: stem.clone(),
        name: stem.clone(),
        family: family.to_string(),
        params_b,
        quantization: quant,
        size_mb: (size / (1024 * 1024)) as u32,
        context: context_window(),
        tags: vec!["chat".into()],
        platforms: vec!["macos", "windows", "linux", "ios", "android"],
        installed: true,
        note: None,
    })
}

impl Backend for LlamaChatBackend {
    fn name(&self) -> &'static str {
        "llama.cpp"
    }

    fn status(&self) -> EngineStatus {
        match self.current() {
            Some(l) => EngineStatus {
                backend: self.name().to_string(),
                state: EngineState::Ready,
                model_id: Some(l.card.id.clone()),
                resident_mb: l.card.size_mb,
                tokens_per_sec: None,
                quantization: Some(l.card.quantization.clone()),
            },
            None => EngineStatus {
                backend: self.name().to_string(),
                state: if self.scan().is_empty() { EngineState::Idle } else { EngineState::Ready },
                model_id: self.scan().first().map(|c| c.id.clone()),
                resident_mb: 0,
                tokens_per_sec: None,
                quantization: None,
            },
        }
    }

    fn models(&self) -> Vec<ModelCard> {
        self.scan()
    }

    fn warm(&self) {
        let Some(path) = self.default_model() else {
            return;
        };
        let backend = self.backend.clone();
        let cache = self.loaded.clone();
        std::thread::Builder::new()
            .name("llama-warm".into())
            .spawn(move || {
                let started = Instant::now();
                match acquire(&backend, &cache, &path) {
                    Ok(loaded) => crate::logfile::line(
                        "INFO",
                        &format!(
                            "warm ok model={} in {}ms",
                            loaded.card.id,
                            started.elapsed().as_millis()
                        ),
                    ),
                    Err(e) => crate::logfile::line("WARN", &format!("warm failed: {e}")),
                }
            })
            .ok();
    }

    fn generate(&self, req: ChatRequest, run: Arc<Run>) -> Receiver<Delta> {
        let (tx, rx) = mpsc::channel::<Delta>();
        let backend = self.backend.clone();
        let run_id = run.id.clone();
        let path = self
            .pick(req.model_id.as_deref())
            .or_else(|| self.default_model());

        // 加载要几秒，放到生成线程里做：命令层必须立刻返回 run_id，
        // 否则前端会把「还没开始」误判成卡死。
        let cache = self.loaded.clone();

        thread::Builder::new()
            .name(format!("llama-gen-{run_id}"))
            .spawn(move || {
                let started = Instant::now();
                let Some(path) = path else {
                    let _ = tx.send(Delta::Error {
                        run_id: run_id.clone(),
                        message: format!(
                            "没有找到 GGUF 权重。把 .gguf 放进 {} 再重试。",
                            "模型目录"
                        ),
                    });
                    let _ = tx.send(Delta::Done { run_id: run_id.clone() });
                    return;
                };

                let loaded = match acquire(&backend, &cache, &path) {
                    Ok(l) => l,
                    Err(message) => {
                        let _ = tx.send(Delta::Error { run_id: run_id.clone(), message });
                        let _ = tx.send(Delta::Done { run_id: run_id.clone() });
                        return;
                    }
                };

                if let Err(message) = decode_into(&backend, &loaded, &req, &run, &tx, &run_id, started)
                {
                    let _ = tx.send(Delta::Error { run_id: run_id.clone(), message });
                }
                let _ = tx.send(Delta::Done { run_id: run_id.clone() });
            })
            .expect("生成线程起不来");

        rx
    }
}

#[allow(clippy::too_many_arguments)]
fn decode_into(
    backend: &LlamaBackend,
    loaded: &Loaded,
    req: &ChatRequest,
    run: &Run,
    tx: &mpsc::Sender<Delta>,
    run_id: &str,
    started: Instant,
) -> Result<(), String> {
    let model = loaded.model.as_ref();
    let mut ctx = model
        .new_context(
            backend,
            LlamaContextParams::default()
                .with_n_ctx(NonZeroU32::new(context_window()))
                .with_n_batch(batch_size() as u32)
                .with_n_threads(threads())
                .with_n_threads_batch(threads()),
        )
        .map_err(|e| format!("创建 context 失败：{e}"))?;

    // 有 chat template 就用模型自己的（Qwen3 的模板里带 thinking 开关），
    // 没有就退化成最朴素的一问一答，至少不会整条命令失败。
    let mut messages: Vec<LlamaChatMessage> = Vec::new();
    for m in &req.history {
        messages.push(LlamaChatMessage::new(m.role.clone(), m.content.clone()).map_err(|e| e.to_string())?);
    }
    messages.push(LlamaChatMessage::new("user".into(), req.message.clone()).map_err(|e| e.to_string())?);

    let prompt = match model.chat_template(None) {
        Ok(tmpl) => model
            .apply_chat_template(&tmpl, &messages, true)
            .map_err(|e| format!("套用 chat template 失败：{e}"))?,
        Err(_) => format!("User: {}\nAssistant:", req.message),
    };

    let tokens = model.vocab().tokenize(prompt.as_bytes(), true, true);
    if tokens.is_empty() {
        return Err("提示词编码为空".into());
    }
    let input_tokens = tokens.len() as u32;

    let mut batch = LlamaBatch::new(batch_size(), 1);
    let mut pos: i32 = 0;
    for (i, chunk) in tokens.chunks(batch_size()).enumerate() {
        batch.clear();
        let last_chunk = i == tokens.len().div_ceil(batch_size()) - 1;
        for (j, token) in chunk.iter().enumerate() {
            let is_last = last_chunk && j == chunk.len() - 1;
            batch.add(*token, pos, &[0], is_last).map_err(|e| format!("batch 失败：{e}"))?;
            pos += 1;
        }
        ctx.decode(&mut batch).map_err(|e| format!("预填充失败：{e}"))?;
    }

    let temperature = req.temperature.unwrap_or(0.7).clamp(0.0, 2.0);
    // 手机上 1 tok ≈ 0.1–0.8 s（CPU 解码），默认给太长会变成「等一分钟」；
    // 桌面给足，反正用户随时能停。
    let default_max = if IS_MOBILE { 192 } else { 512 };
    let max_tokens = req.max_tokens.unwrap_or(default_max).min(4096) as usize;
    let n_vocab = model.n_vocab() as i32;
    let mut sampler = LlamaSampler::chain_simple([
        LlamaSampler::penalties(n_vocab, 64, 1.1, 0.0, 0.0),
        LlamaSampler::top_k(40),
        LlamaSampler::top_p(0.95, 1),
        LlamaSampler::temp(temperature),
        LlamaSampler::dist(0x5eed_1234),
    ]);

    let mut splitter = ThinkSplitter::default();
    let preview = std::env::var_os("FLASHCAT_LOG_PREVIEW").is_some();
    let mut pending = Vec::<u8>::new();
    let mut produced: u32 = 0;
    let mut first_token: Option<Instant> = None;

    loop {
        if run.is_cancelled() {
            break;
        }
        if produced as usize >= max_tokens {
            break;
        }
        let token = sampler.sample(&ctx, -1);
        sampler.accept(token);
        if model.vocab().is_eog(token) {
            break;
        }
        let piece = model.vocab().token_to_piece(token, false, None);
        pending.extend_from_slice(&piece);

        // 一个 token 可能是半个多字节字符：只发能完整解码的前缀。
        match std::str::from_utf8(&pending) {
            Ok(text) => {
                if !text.is_empty() {
                    if splitter.push(text, tx, run_id).is_err() {
                        return Ok(());
                    }
                    produced += 1;
                    first_token.get_or_insert_with(Instant::now);
                }
                pending.clear();
            }
            Err(e) => {
                let valid = e.valid_up_to();
                if valid > 0 {
                    let text = std::str::from_utf8(&pending[..valid]).unwrap_or_default();
                    if splitter.push(text, tx, run_id).is_err() {
                        return Ok(());
                    }
                    produced += 1;
                    first_token.get_or_insert_with(Instant::now);
                    pending.drain(..valid);
                }
            }
        }

        batch.clear();
        batch.add(token, pos, &[0], true).map_err(|e| format!("batch 失败：{e}"))?;
        pos += 1;
        ctx.decode(&mut batch).map_err(|e| format!("解码失败：{e}"))?;
    }
    splitter.flush(tx, run_id);

    // 手机上没有 devtools，也没有终端：出问题时要能确认「模型到底说了什么」。
    // 默认不记（模型输出可能含用户隐私），排查时用 FLASHCAT_LOG_PREVIEW=1 打开。
    if preview {
        let sample = splitter.head.clone();
        crate::logfile::line(
            "DEBUG",
            &format!(
                "answer thinking={} chars text={} chars preview={:?}",
                splitter.thinking_chars, splitter.text_chars, sample
            ),
        );
    }

    let total_ms = started.elapsed().as_millis() as u32;
    let first_ms = first_token.map(|t| (t - started).as_millis() as u32).unwrap_or(total_ms);
    let gen_ms = total_ms.saturating_sub(first_ms).max(1);
    let tps = produced as f32 * 1000.0 / gen_ms as f32;
    let _ = tx.send(Delta::Usage {
        run_id: run_id.to_string(),
        input_tokens,
        output_tokens: produced,
        first_token_ms: first_ms,
        total_ms,
        tokens_per_sec: tps,
        model_id: loaded.card.id.clone(),
    });
    Ok(())
}

/// 把思考段从正文里切出来，逐块发给前端。
///
/// 难点在标签可能被 token 边界切开（`</th` + `ink>`），所以要留一个
/// 最长「半个标签」的尾巴在手里，等下一个 token 补齐再判断。
/// 两种收尾标签都要认：Qwen3 用全角竖线的 `<｜end▁of▁thinking｜>`，
/// 其它模型常见的是普通 HTML 风格的收尾标签。
#[derive(Default)]
struct ThinkSplitter {
    open: bool,
    tail: String,
    thinking_chars: usize,
    text_chars: usize,
    /// 前 120 个正文字符，仅用于 `FLASHCAT_LOG_PREVIEW=1` 时的排查。
    head: String,
}

// 用 concat! 拼出来，而不是写整串字面量：这两种标签在编辑器/复制粘贴里
// 经常被全角化或吞掉一个字符，拼起来最不容易出错。
const OPEN: &str = concat!("<", "think", ">");
const CLOSE_PLAIN: &str = concat!("</", "think", ">");
const CLOSE_QWEN: &str = concat!("<｜end▁of▁", "thinking", "｜>");

fn close_tags() -> [&'static str; 2] {
    [CLOSE_PLAIN, CLOSE_QWEN]
}

impl ThinkSplitter {
    fn push(&mut self, text: &str, tx: &mpsc::Sender<Delta>, run_id: &str) -> Result<(), ()> {
        self.tail.push_str(text);
        loop {
            if self.open {
                // 收尾标签取「最早出现的那个」，避免先命中一个再回退。
                let hit = close_tags()
                    .iter()
                    .filter_map(|t| self.tail.find(t).map(|at| (at, *t)))
                    .min_by_key(|(at, _)| *at);
                match hit {
                    Some((at, tag)) => {
                        let before = self.tail[..at].to_string();
                        self.tail.drain(..at + tag.len());
                        self.emit(before, tx, run_id)?;
                        self.open = false;
                    }
                    None => {
                        let keep = close_tags()
                            .iter()
                            .map(|t| partial_tag_len(&self.tail, t))
                            .max()
                            .unwrap_or(0);
                        let cut = self.tail.len() - keep;
                        if cut == 0 {
                            return Ok(());
                        }
                        let ready = self.tail[..cut].to_string();
                        self.tail.drain(..cut);
                        return self.emit(ready, tx, run_id);
                    }
                }
            } else if let Some(at) = self.tail.find(OPEN) {
                let before = self.tail[..at].to_string();
                self.tail.drain(..at + OPEN.len());
                self.emit(before, tx, run_id)?;
                self.open = true;
            } else {
                let keep = partial_tag_len(&self.tail, OPEN);
                let cut = self.tail.len() - keep;
                if cut == 0 {
                    return Ok(());
                }
                let ready = self.tail[..cut].to_string();
                self.tail.drain(..cut);
                return self.emit(ready, tx, run_id);
            }
        }
    }

    fn flush(&mut self, tx: &mpsc::Sender<Delta>, run_id: &str) {
        if !self.tail.is_empty() {
            let rest = std::mem::take(&mut self.tail);
            let _ = self.emit(rest, tx, run_id);
        }
    }

    /// 注意用的是「推送时」的模式：思考段的文本要在 `open == true` 时发出去，
    /// 所以切换 `open` 必须发生在 emit 之后。
    fn emit(&mut self, text: String, tx: &mpsc::Sender<Delta>, run_id: &str) -> Result<(), ()> {
        if text.is_empty() {
            return Ok(());
        }
        if self.open {
            self.thinking_chars += text.chars().count();
        } else {
            self.text_chars += text.chars().count();
            if self.head.chars().count() < 120 {
                let room = 120 - self.head.chars().count();
                self.head.extend(text.chars().take(room));
            }
        }
        let delta = if self.open {
            Delta::Thinking { run_id: run_id.to_string(), delta: text }
        } else {
            Delta::Text { run_id: run_id.to_string(), delta: text }
        };
        tx.send(delta).map_err(|_| ())
    }
}

/// `s` 的结尾有多少字符可能是 `tag` 的前缀。
fn partial_tag_len(s: &str, tag: &str) -> usize {
    let max = tag.chars().count().min(s.chars().count());
    for len in (1..=max).rev() {
        let suffix: String = s.chars().skip(s.chars().count() - len).collect();
        if tag.starts_with(suffix.as_str()) {
            return suffix.len();
        }
    }
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    fn collect(chunks: &[&str]) -> (String, String) {
        let (tx, rx) = mpsc::channel();
        let mut s = ThinkSplitter::default();
        for c in chunks {
            let _ = s.push(c, &tx, "run");
        }
        s.flush(&tx, "run");
        drop(tx);
        let (mut thinking, mut text) = (String::new(), String::new());
        for d in rx {
            match d {
                Delta::Thinking { delta, .. } => thinking.push_str(&delta),
                Delta::Text { delta, .. } => text.push_str(&delta),
                _ => {}
            }
        }
        (thinking, text)
    }

    #[test]
    fn splits_thinking_from_answer() {
        let (t, a) = collect(&["<thi", "nk>想一下", CLOSE_QWEN, "答", "案"]);
        assert_eq!(t, "想一下");
        assert_eq!(a, "答案");
    }

    #[test]
    fn no_tag_is_all_text() {
        let (t, a) = collect(&["纯文本", "没有标签", " < 符号"]);
        assert!(t.is_empty());
        assert_eq!(a, "纯文本没有标签 < 符号");
    }
}
