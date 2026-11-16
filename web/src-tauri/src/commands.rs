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
pub fn app_info(app: AppHandle) -> AppInfo {
    let pkg = app.package_info();
    AppInfo {
        name: pkg.name.clone(),
        version: pkg.version.to_string(),
        platform: PLATFORM,
        arch: std::env::consts::ARCH,
        mobile: IS_MOBILE,
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

    let handle = app.clone();
    let id = run_id.clone();
    std::thread::Builder::new()
        .name(format!("chat-forward-{id}"))
        .spawn(move || {
            // 通道关闭即生成线程结束；转发线程随之退出并摘掉注册表条目。
            for delta in rx {
                let _ = handle.emit("chat:delta", &delta);
            }
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
    println!("[{tag}] {message}");
}

#[tauri::command]
pub fn chat_cancel(engine: State<'_, Engine>, run_id: String) -> bool {
    engine.cancel(&run_id)
}
