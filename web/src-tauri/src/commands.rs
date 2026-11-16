//! Tauri 命令层：只做校验与转发。业务逻辑在 `engine`，数据形状在 `model`。
//!
//! 事件名统一 `chat:delta`，载荷见 [`Delta`]。前端无论桌面还是移动端都走同一套
//! `invoke` + `listen`，没有平台分支——平台差异只在后端实现里。

use tauri::{AppHandle, Emitter, Manager, State};

use crate::engine::Engine;
use crate::model::{
    AppInfo, ChatRequest, EngineStatus, ModelCard, SystemInfo, IS_MOBILE, PLATFORM,
};

#[tauri::command]
pub fn app_info(app: AppHandle, engine: State<'_, Engine>) -> AppInfo {
    let pkg = app.package_info();
    AppInfo {
        name: pkg.name.clone(),
        version: pkg.version.to_string(),
        platform: PLATFORM,
        arch: std::env::consts::ARCH,
        mobile: IS_MOBILE,
        model_dir: engine.model_dir(),
    }
}

#[tauri::command]
pub fn system_info() -> SystemInfo {
    SystemInfo {
        cpu_count: std::thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or(4),
        platform: PLATFORM,
        // 真实加速器要等 llama.cpp 后端初始化后才知道，这里先给平台默认值。
        accelerator: accelerator().to_string(),
    }
}

fn accelerator() -> &'static str {
    if cfg!(target_os = "macos") || cfg!(target_os = "ios") {
        "metal"
    } else if cfg!(target_os = "android") {
        "nnapi"
    } else if cfg!(target_os = "windows") {
        "d3d12"
    } else {
        "cpu"
    }
}

#[tauri::command]
pub fn engine_status(engine: State<'_, Engine>) -> EngineStatus {
    engine.status()
}

#[tauri::command]
pub fn list_models(engine: State<'_, Engine>) -> Vec<ModelCard> {
    engine.models()
}

/// 起一次生成，立刻返回 run_id；增量通过 `chat:delta` 事件推送。
#[tauri::command]
pub fn chat_start(
    app: AppHandle,
    engine: State<'_, Engine>,
    req: ChatRequest,
) -> Result<String, String> {
    let (run, rx) = engine.start(req)?;
    let run_id = run.id.clone();
    crate::logfile::line("INFO", &format!("chat start run={run_id}"));

    let handle = app.clone();
    let id = run_id.clone();
    std::thread::Builder::new()
        .name(format!("chat-forward-{id}"))
        .spawn(move || {
            // 通道关闭即生成线程结束；转发线程随之退出并摘掉注册表条目。
            let mut count = 0usize;
            let mut chars = 0usize;
            let mut first_at: Option<std::time::Instant> = None;
            let mut usage = String::new();
            for delta in rx {
                match &delta {
                    crate::model::Delta::Text { delta, .. } => chars += delta.chars().count(),
                    crate::model::Delta::Usage { output_tokens, tokens_per_sec, first_token_ms, .. } => {
                        usage = format!(" tokens={output_tokens} tps={tokens_per_sec:.1} first={first_token_ms}ms");
                    }
                    _ => {}
                }
                if first_at.is_none() {
                    // 第一条增量到前端的时刻，是「引擎在算」还是「在等引擎」的分界线。
                    first_at = Some(std::time::Instant::now());
                    let kind = match &delta {
                        crate::model::Delta::Thinking { .. } => "thinking",
                        crate::model::Delta::Text { .. } => "text",
                        crate::model::Delta::Usage { .. } => "usage",
                        crate::model::Delta::Done { .. } => "done",
                        crate::model::Delta::Error { .. } => "error",
                    };
                    crate::logfile::line("INFO", &format!("chat first delta kind={kind} run={id}"));
                }
                if let Err(err) = handle.emit("chat:delta", &delta) {
                    crate::logfile::line("ERROR", &format!("chat emit failed: {err}"));
                    break;
                }
                count += 1;
            }
            // 有了这两行，四端「到底有没有出字」不用看屏幕也能判断。
            crate::logfile::line(
                "INFO",
                &format!("chat end run={id} deltas={count} chars={chars}{usage}"),
            );
            if let Some(engine) = handle.try_state::<Engine>() {
                engine.release(&id);
            }
        })
        .map_err(|e| format!("无法创建事件转发线程：{e}"))?;

    Ok(run_id)
}

/// 前端日志回传。移动端没有 devtools，崩溃与告警只能靠这条命令落到
/// stdout（iOS 走 Xcode 控制台，Android 走 logcat），顺带充当启动自检。
#[tauri::command]
pub fn log_frontend(level: String, message: String) {
    let tag = match level.as_str() {
        "error" => "ERROR",
        "warn" => "WARN",
        "debug" => "DEBUG",
        _ => "INFO",
    };
    crate::logfile::line(tag, &message);
}

/// 预热权重（异步、可重复调用；已经加载过就立刻返回）。
#[tauri::command]
pub fn engine_warm(engine: State<'_, Engine>) {
    engine.warm();
}

#[tauri::command]
pub fn chat_cancel(engine: State<'_, Engine>, run_id: String) -> bool {
    engine.cancel(&run_id)
}
