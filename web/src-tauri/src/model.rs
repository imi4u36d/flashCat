//! 前后端共享的数据形状。
//!
//! 规则：字段名走 camelCase，枚举走小写标签；任何新增字段都必须是可选的，
//! 以便旧前端连新后端时不至于整条命令失败（与原生版「未知枚举降级」一致）。

use serde::{Deserialize, Serialize};

/// 静态身份信息，前端用来决定要不要显示「桌面专属」的控件。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AppInfo {
    pub name: String,
    pub version: String,
    /// `macos` | `windows` | `linux` | `ios` | `android`
    pub platform: &'static str,
    pub arch: &'static str,
    pub mobile: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SystemInfo {
    pub cpu_count: usize,
    pub platform: &'static str,
    /// 加速后端的人话描述，例如 `metal` / `cuda` / `nnapi` / `cpu`。
    pub accelerator: String,
}

/// 状态机是前后端共享的契约：`Loading` / `Error` 由权重加载阶段产生，
/// mock 后端永远不会进入这两个状态，所以这里关掉 dead_code 检查。
#[allow(dead_code)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum EngineState {
    Idle,
    Loading,
    Ready,
    Error,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EngineStatus {
    pub backend: String,
    pub state: EngineState,
    pub model_id: Option<String>,
    pub resident_mb: u32,
    pub tokens_per_sec: Option<f32>,
    pub quantization: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelCard {
    pub id: String,
    pub name: String,
    pub family: String,
    pub params_b: f32,
    pub quantization: String,
    pub size_mb: u32,
    pub context: u32,
    /// `chat` | `vision` | `embedding` | `rerank`
    pub tags: Vec<String>,
    /// 该权重能跑的端；移动端只列 4 bit 且 ≤1.7B 的模型。
    pub platforms: Vec<&'static str>,
    pub installed: bool,
    pub note: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatMessage {
    pub role: String,
    pub content: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatRequest {
    pub thread_id: String,
    pub message: String,
    pub model_id: Option<String>,
    #[serde(default)]
    pub history: Vec<ChatMessage>,
    pub temperature: Option<f32>,
    pub max_tokens: Option<u32>,
}

/// 流式事件。`kind` 是判别式，前端 `switch (e.kind)` 即可。
#[derive(Debug, Clone, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Delta {
    #[serde(rename = "thinking")]
    Thinking { run_id: String, delta: String },
    #[serde(rename = "text")]
    Text { run_id: String, delta: String },
    #[serde(rename = "usage")]
    Usage {
        run_id: String,
        input_tokens: u32,
        output_tokens: u32,
        /// 首字延迟（毫秒），决定「跟手」体感，比总耗时更值得展示。
        first_token_ms: u32,
        total_ms: u32,
        tokens_per_sec: f32,
        model_id: String,
    },
    #[serde(rename = "done")]
    Done { run_id: String },
    /// 解码失败（权重被删、显存不足、mmap 失败）时由后端实现发出；
    /// mock 不会产生，但前端必须已经能渲染它。
    #[allow(dead_code)]
    #[serde(rename = "error")]
    Error { run_id: String, message: String },
}

/// 编译期就把平台确定下来，运行期不再判断，移动端能省掉一串字符串比较。
pub const PLATFORM: &str = if cfg!(target_os = "macos") {
    "macos"
} else if cfg!(target_os = "windows") {
    "windows"
} else if cfg!(target_os = "ios") {
    "ios"
} else if cfg!(target_os = "android") {
    "android"
} else {
    "linux"
};

pub const IS_MOBILE: bool = cfg!(any(target_os = "ios", target_os = "android"));
