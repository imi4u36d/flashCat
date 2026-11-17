# 交付状态

更新时间：2026-11-17 · 版本 0.3.4

## 已交付并验证

| 平台 | 产物 | 验证方式 |
| --- | --- | --- |
| macOS (Apple Silicon) | `release/FlashCat_0.3.4_aarch64.dmg` | 挂载后启动 dmg 内的 .app，日志 `boot FlashCat 0.3.4 platform=macos mobile=false` → `page Finished tauri://localhost` → `shell ready · macos/aarch64 · backend=llama.cpp` |
| Android (arm64) | `release/FlashCat-0.3.4-arm64.apk` | release keystore 签名；`adb install` 到 Android 14 模拟器，启动后 `boot … platform=android mobile=true`、`engine llama.cpp models=1`、截图见 `docs/preview/23-android-033.png` |
| iOS (真机, arm64) | `release/FlashCat-0.3.4-ios.ipa` | `xcrun devicectl device install app` 安装成功；首次启动需在「设置 → 通用 → VPN 与设备管理」信任 `Apple Development: wxwzmail@163.com`（7 天有效） |
| iOS 模拟器 | 构建产物在 `src-tauri/gen/apple/build/arm64-sim/` | 模拟器启动、流式输出、安全区检查通过 |

产物都在 `web/release/`（已 gitignore，不进仓库）。

| Linux arm64 | `release/FlashCat_0.3.4_arm64.deb` | 在 colima(ubuntu:24.04) 容器内 `pnpm tauri build`；`dpkg-deb -I` 校验 Package=flash-cat / Version=0.3.4 / Arch=arm64 / Depends=libwebkit2gtk-4.1-0,libgtk-3-0，内含 `usr/bin/flashcat` 9.5MB |

## 未交付

| 项 | 原因 | 下一步 |
| --- | --- | --- |
| Windows 安装包 | 需要 Windows 主机（MSVC + WebView2 + LLVM） | 在目标机器执行 `powershell -ExecutionPolicy Bypass -File scripts\build-windows.ps1`（先 `-Lite` 排打包链路） |
| Linux x86_64 包 | 本机 colima 是 arm64 虚拟机，只能产出 arm64 deb（已出）；x86_64 另需 qemu 架构或 CI `ubuntu-24.04` | 在 x86_64 Linux 或 CI 上重跑 `web/scripts/linux-build.sh` |
| iOS 真机长期可用 | 开发签名 7 天过期 | 换 TestFlight / App Store 分发，或每年重签 |

## 平台边界（不要混）

- **桌面（macOS/Windows/Linux）**：七页全量；扫三个权重根（自己的 + `Application Support/flashCat/models` + `Splash/models`）；默认 `max_tokens=512`；上下文 4096。
- **手机（iOS/Android）**：只有「对话 / 模型 / 设置」三页；只扫沙盒 `models/`；默认 `max_tokens=192`；上下文 2048；外观跟随系统；抽屉 = 对话历史；动作表 / 长按复制 / 安全区让位。
- 旧库扫描是 `#[cfg(target_os = "macos")]`，手机上不会出现「旧库」列表。

## 已知限制

- llama.cpp 只吃 GGUF；旧库里的 mlx / safetensors 权重列在模型页「旧库里的其它权重」里，但**不能直接加载**。
  实测结论：这些是 MLX 打包的**量化**权重（`config.json` 里逐层 `{"bits": 8, "group_size": 128, "mode": "affine"}`，
  模型名还带 `3bpw`/`6bpw`），`model_type` 也是 `qwen4_exp` 这类新架构，层名含
  `linear_attn.in_proj_qkv/z/a/b`、`mlp.shared_expert.*`、`mtp.layers.0.*`。
  llama.cpp 的 `convert_hf_to_gguf.py` 不能直接读；要先反量化成 fp16 再转，且新架构大概率没有对应实现。
  **所以不做转换向导**：成本高、成功率低，转不动时用户更困惑。要让旧库可直接用，只能是保留旧引擎（MLX 运行时），
  那是另一条产品线，不在本次范围内。
- Android 模拟器无 GPU 加速，实测 1.2 tok/s 属于极端值，不代表真机。
- iOS 模拟器关闭 Metal（`gpu_layers=0`），否则首次每帧编 shader 会卡几分钟。

## 质量门

- `cargo clippy --all-targets`：0 warning
- `cargo test --lib`：9 passed
- `tsc --noEmit`：干净
