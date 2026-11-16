use std::process::Command;

fn main() {
    let target_os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();

    // llama.cpp 的 ggml 在 apple 平台用 Accelerate 做向量运算、用 Metal 做 GPU 后端，
    // 但它被编进同一个静态库里再链接，cargo 不会自动带这些框架。
    // 少了这几行，桌面 .app / iOS .app 会在最后一步报 `_vDSP_*` 未定义。
    if target_os == "macos" || target_os == "ios" {
        for framework in ["Accelerate", "Metal", "MetalKit", "Foundation"] {
            println!("cargo:rustc-link-lib=framework={framework}");
        }
    }

    // objc2 的可用性检查（`___isPlatformVersionAtLeast`）在 compiler-rt 里，
    // 而 rustc 链接时没有把 clang 的内建库目录带进来。问一下 clang 就知道在哪。
    if target_os == "macos" {
        if let Ok(out) = Command::new("clang").arg("-print-runtime-dir").output() {
            let dir = String::from_utf8_lossy(&out.stdout).trim().to_string();
            if !dir.is_empty() {
                println!("cargo:rustc-link-search=native={dir}");
                println!("cargo:rustc-link-lib=static=clang_rt.osx");
            }
        }
    }

    tauri_build::build();
}
