//! 落盘日志。
//!
//! 被 LaunchServices 拉起的 `.app` 与手机端的 WebView 都没有一个能看 stdout 的终端，
//! 「白屏 / 连不上后端 / 模型没加载」这类问题只能靠一个文件来回答。这里刻意做得极简：
//!
//! - 标准输出照旧（`tauri dev`、`adb logcat`、`Console.app` 都能看到）；
//! - 同时追加到 `app_log_dir()/flashcat.log`（macOS 是 `~/Library/Logs/dev.flashcat.desktop/`，
//!   iOS 是 App 沙盒的 `Library/Logs/`，Android 是 `files/logs/`）；
//! - 不做级别过滤、不引入 `tracing`：调用点只有几处，多一个依赖不划算。
//!
//! 写入失败一律吞掉——日志写不出来不该让应用挂掉。

use std::fs::OpenOptions;
use std::io::Write;
use std::path::PathBuf;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

static SINK: Mutex<Option<PathBuf>> = Mutex::new(None);

/// 在 `setup` 里调用一次。目录不存在会创建；创建失败就退化为「只打 stdout」。
pub fn init(dir: PathBuf) {
    let _ = std::fs::create_dir_all(&dir);
    let path = dir.join("flashcat.log");
    match SINK.lock() {
        Ok(mut sink) => *sink = Some(path),
        Err(err) => *err.into_inner() = Some(path),
    }
}

/// 记一行。`level` 用 `INFO` / `WARN` / `ERROR` / `DEBUG`，和前端 `log_frontend` 对齐。
pub fn line(level: &str, message: &str) {
    println!("[{level}] {message}");

    let guard = match SINK.lock() {
        Ok(guard) => guard,
        Err(err) => err.into_inner(),
    };
    let Some(path) = guard.as_ref() else { return };
    if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(path) {
        let millis = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis())
            .unwrap_or(0);
        // 时间戳用毫秒整数：不引时间库，也够把一串日志按顺序排好。
        let _ = writeln!(file, "{millis} [{level}] {message}");
    }
}
