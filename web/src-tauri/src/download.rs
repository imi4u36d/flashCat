//! 应用内下载权重。
//!
//! 为什么必须有：手机装上 APK 之后没有任何办法把 400MB 的 gguf 放进沙盒，
//! 让用户学 adb push 等于没交付。这里用一条阻塞线程 + 通道来下载，四端同一套：
//! 进度通过 `model:download` 事件回前端，取消用 `AtomicBool`。
//!
//! 先写 `<name>.part` 再改名：下载中断时目录里不会留下一个「看起来能用、
//! 加载时才炸」的半个 gguf（模型页扫描的是 `*.gguf`，`.part` 不会被选中）。

use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use serde::Serialize;
use tauri::{AppHandle, Emitter};

/// 进度事件。`total` 为 0 表示服务端没给 Content-Length。
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DownloadProgress {
    pub name: String,
    pub received: u64,
    pub total: u64,
    pub done: bool,
    pub cancelled: bool,
    pub error: Option<String>,
}

#[derive(Default)]
pub struct Downloads {
    /// `Some` 表示正在下载；手机带宽和磁盘都有限，同一时刻只允许一个。
    current: Mutex<Option<Arc<AtomicBool>>>,
}

impl Downloads {
    fn begin(&self) -> Option<Arc<AtomicBool>> {
        let mut guard = self.current.lock().ok()?;
        if guard.is_some() {
            return None;
        }
        let flag = Arc::new(AtomicBool::new(false));
        *guard = Some(flag.clone());
        Some(flag)
    }

    fn finish(&self) {
        if let Ok(mut guard) = self.current.lock() {
            *guard = None;
        }
    }

    /// 返回是否真的取消了一个在跑的任务。
    pub fn cancel(&self) -> bool {
        let flag = self.current.lock().ok().and_then(|g| g.clone());
        match flag {
            Some(f) => {
                f.store(true, Ordering::Relaxed);
                true
            }
            None => false,
        }
    }
}

fn safe_name(name: &str) -> Result<&str, String> {
    let ok = name.ends_with(".gguf")
        && !name.contains('/')
        && !name.contains('\\')
        && !name.starts_with('.')
        && name.len() < 200;
    if ok {
        Ok(name)
    } else {
        Err(format!("文件名不合法：{name}（必须是 xxx.gguf，不能带路径）"))
    }
}

fn emit(app: &AppHandle, p: &DownloadProgress) {
    if let Err(e) = app.emit("model:download", p) {
        crate::logfile::line("ERROR", &format!("emit model:download 失败：{e}"));
    }
}

/// 起一条线程下载。立刻返回；结果全部通过事件通知。
pub fn start(
    app: AppHandle,
    dir: &Path,
    url: &str,
    name: &str,
    downloads: Arc<Downloads>,
) -> Result<(), String> {
    let name = safe_name(name)?.to_string();
    if !url.starts_with("https://") {
        return Err("只允许 https 下载".to_string());
    }
    if !dir.exists() {
        std::fs::create_dir_all(dir).map_err(|e| format!("建目录失败：{e}"))?;
    }
    let flag = downloads
        .begin()
        .ok_or_else(|| "已有下载在进行，先等它完成或取消".to_string())?;

    let part: PathBuf = dir.join(format!("{name}.part"));
    let final_path: PathBuf = dir.join(&name);
    let url = url.to_string();
    let thread_name = name.clone();

    crate::logfile::line("INFO", &format!("download start {name} <- {url}"));
    std::thread::Builder::new()
        .name("model-download".into())
        .spawn(move || {
            let result = run(&app, &url, &part, &final_path, &name, &flag);
            match &result {
                Ok(()) => crate::logfile::line("INFO", &format!("download done {name}")),
                Err(e) => crate::logfile::line("WARN", &format!("download fail {name}: {e}")),
            }
            downloads.finish();
            let cancelled = flag.load(Ordering::Relaxed);
            let (received, total, done, error) = match result {
                Ok(()) => (final_size(&final_path), 0, true, None),
                Err(e) => (0, 0, false, Some(e)),
            };
            emit(&app, &DownloadProgress {
                name: thread_name,
                received,
                total,
                done,
                cancelled,
                error,
            });
        })
        .map_err(|e| format!("起下载线程失败：{e}"))?;
    Ok(())
}

fn final_size(path: &Path) -> u64 {
    std::fs::metadata(path).map(|m| m.len()).unwrap_or(0)
}

fn run(
    app: &AppHandle,
    url: &str,
    part: &Path,
    final_path: &Path,
    name: &str,
    flag: &AtomicBool,
) -> Result<(), String> {
    let mut resp = ureq::get(url).call().map_err(|e| format!("请求失败：{e}"))?;
    let total = resp
        .headers()
        .get("content-length")
        .and_then(|v| v.to_str().ok())
        .and_then(|s| s.parse::<u64>().ok())
        .unwrap_or(0);
    let mut reader = resp.body_mut().as_reader();
    let mut file =
        std::fs::File::create(part).map_err(|e| format!("建临时文件失败：{e}"))?;

    let mut buf = vec![0u8; 256 * 1024];
    let mut received: u64 = 0;
    let mut last_emit = std::time::Instant::now();
    let mut last_bytes: u64 = 0;

    loop {
        if flag.load(Ordering::Relaxed) {
            drop(file);
            let _ = std::fs::remove_file(part);
            return Err("已取消".to_string());
        }
        let n = match reader.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => n,
            Err(e) => {
                drop(file);
                let _ = std::fs::remove_file(part);
                return Err(format!("读取出错：{e}"));
            }
        };
        file.write_all(&buf[..n]).map_err(|e| format!("写入失败：{e}"))?;
        received += n as u64;

        // 每 200ms 或每 8MB 报一次：手机上 JS 侧每秒几十次 setState 会掉帧。
        if last_emit.elapsed().as_millis() >= 200 || received - last_bytes >= 8 * 1024 * 1024 {
            last_emit = std::time::Instant::now();
            last_bytes = received;
            emit(app, &DownloadProgress {
                name: name.to_string(),
                received,
                total,
                done: false,
                cancelled: false,
                error: None,
            });
        }
    }

    file.flush().map_err(|e| format!("落盘失败：{e}"))?;
    drop(file);
    if total > 0 && received != total {
        let _ = std::fs::remove_file(part);
        return Err(format!("文件不完整：{received}/{total} 字节"));
    }
    std::fs::rename(part, final_path).map_err(|e| format!("改名失败：{e}"))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::safe_name;

    #[test]
    fn accepts_plain_gguf_names() {
        assert!(safe_name("Qwen3-0.6B-Q4_K_M.gguf").is_ok());
        assert!(safe_name("a.gguf").is_ok());
    }

    /// 文件名最终会拼进目录，任何带路径分隔符的输入都是目录穿越。
    #[test]
    fn rejects_paths_and_traversal() {
        assert!(safe_name("../evil.gguf").is_err());
        assert!(safe_name("a/b.gguf").is_err());
        assert!(safe_name("a\\b.gguf").is_err());
        assert!(safe_name(".hidden.gguf").is_err());
    }

    /// 后缀是唯一的类型校验：别的扩展名会被 llama.cpp 当权重打开然后失败。
    #[test]
    fn rejects_wrong_extension_and_empty() {
        assert!(safe_name("model.bin").is_err());
        assert!(safe_name("model").is_err());
        assert!(safe_name("").is_err());
        assert!(safe_name("model.gguf.part").is_err());
    }

    #[test]
    fn rejects_absurdly_long_names() {
        let long = format!("{}.gguf", "a".repeat(200));
        assert!(safe_name(&long).is_err());
    }
}
