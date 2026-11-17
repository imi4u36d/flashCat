//! FlashCat 的跨端外壳。
//!
//! 分层（自上而下，依赖单向）：
//! - `commands`：只做参数校验、事件转发，不含业务逻辑；
//! - `engine`：推理后端抽象（`Backend` trait）+ 运行注册表（取消、并发上限）；
//! - `model`：前后端共享的数据形状，serde 一律 camelCase，与 TS 侧逐字段对齐。
//!
//! 首轮只有 `MockBackend`：它把「思考 → 正文 → 用量」的真实事件节奏跑通，
//! 让前端接的是终态协议而不是假数据。接入 llama.cpp 时只新增一个 `Backend`
//! 实现并在 `Engine::new` 里换掉，前端与命令层不动。

mod commands;
mod download;
mod engine;
#[cfg(feature = "llama")]
mod llama;
mod logfile;
mod model;

use engine::Engine;
use tauri::Manager;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        // 页面加载是「WebView 起来了、CSP 没打死资源」的唯一可靠信号。
        .setup(|app| {
            // 桌面端被人从 Finder 拉起来时 stdout 是 /dev/null，日志必须落盘。
            if let Ok(dir) = app.path().app_log_dir() {
                logfile::init(dir);
            }
            let model_dir = app.path().app_data_dir().ok().map(|d| d.join("models"));
            if let Some(dir) = model_dir.as_ref() {
                let _ = std::fs::create_dir_all(dir);
            }
            app.manage(Engine::new(model_dir));
            app.manage(std::sync::Arc::new(download::Downloads::default()));
            logfile::line(
                "INFO",
                &format!(
                    "boot {} {} platform={} mobile={}",
                    app.package_info().name,
                    app.package_info().version,
                    model::PLATFORM,
                    model::IS_MOBILE
                ),
            );
            Ok(())
        })
        .on_page_load(|window, payload| {
            logfile::line("INFO", &format!("page {:?} {}", payload.event(), payload.url()));
            let _ = window;
        })
        .invoke_handler(tauri::generate_handler![
            commands::app_info,
            commands::system_info,
            commands::engine_status,
            commands::list_models,
            commands::chat_start,
            commands::chat_cancel,
            commands::log_frontend,
            commands::engine_warm,
            commands::download_model,
            commands::cancel_download,
            commands::select_model,
            commands::delete_model,
        ])
        .run(tauri::generate_context!())
        .expect("FlashCat 启动失败");
}
