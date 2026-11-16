# 移动端跑本地小模型

目标：手机上不联网也能对话，模型随 App 分发或首次启动下载，端上 0.6B–1.7B 量化模型出字。

## 结论先行

| 问题 | 答案 |
| --- | --- |
| 引擎 | **llama.cpp**（GGUF）。同一份 C/C++ 能上 Metal（iOS）与 arm64 CPU（Android），是这个组合里唯一不用写两套推理代码的选择 |
| 手机能跑多大 | q4_k_m 量化下 0.6B 约 400MB、1.7B 约 1.1GB。**默认 0.6B**，1.7B 只在 ≥6GB RAM 的机器上开放 |
| 速度预期 | A17/A18 上 0.6B q4 约 25–40 tok/s；骁龙 8 Gen 2/3 约 18–30 tok/s；1.7B 大致减半。低于 8 tok/s 就该降级到 0.6B |
| 包体 | 模型**不放进安装包**。Play 的 base APK 上限 200MB，App Store 对可执行包也有硬限制；走首次启动下载 |
| 放哪 | Android `context.filesDir/models`；iOS `Application Support/models`（都要排除 iCloud 备份，否则 400MB 会拖垮同步） |
| 怎么绑 | 自建 `llama-cpp-sys` 式的 FFI + 一个 `LlamaBackend` 实现 `engine.rs` 里已有的 `Backend` trait |

`MockBackend` 与真后端是同一个接口，所以接引擎这一步**不动**命令层、事件层、并发槽与取消逻辑。

## 为什么不是别的

- **MLX**：只在 Apple Silicon 上跑，Android 没有，等于两套后端。
- **MNN / NCNN**：Android 侧成熟，但 iOS 上要另写 Metal delegate，模型格式还得转换，失去 GGUF 生态。
- **ONNX Runtime GenAI**：包体大（+40MB 起），移动端量化算子覆盖不如 ggml。
- **Core ML**：iOS 最快，但 Android 完全没有，且模型要转 `.mlpackage`，一条链两个世界。

llama.cpp 的代价是**编译**：Android 要 NDK 交叉编译，iOS 要把 `ggml-metal.metal` 打进 bundle。一次性的。

## 编译

### Android（arm64-v8a）

```bash
export NDK_HOME=$HOME/Library/Android/sdk/ndk/29.0.14206865
export CC_aarch64_linux_android=$NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/bin/aarch64-linux-android26-clang
export CXX_aarch64_linux_android=${CC_aarch64_linux_android}++
export AR_aarch64_linux_android=$NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-ar
```

`Cargo.toml` 里用 `cmake` crate 拉起 llama.cpp，关键 flag：

```
-DGGML_OPENMP=OFF            # NDK 里没有 libomp，开着必然链接失败
-DGGML_LLAMAFILE=OFF
-DGGML_CPU_ARM_ARCH=armv8.2-a+dotprod+fp16
-DLLAMA_CURL=OFF             # 模型下载由 Rust 侧做，不要第二个 HTTP 栈
-DCMAKE_TOOLCHAIN_FILE=$NDK_HOME/build/cmake/android.toolchain.cmake
-DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-26
```

`libflashcat_lib.so` 静态链接 llama.cpp，`jniLibs/arm64-v8a/` 里只多出一个 so（约 +3–4MB）。
armv7 不编——0.6B 在 32 位上跑不动，装得上也没意义。

### iOS（device + simulator）

```bash
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
```

```
-DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON   # 把 metal shader 编进二进制，省掉 bundle 资源
-DGGML_ACCELERATE=ON
-DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_OSX_ARCHITECTURES=arm64
```

`GGML_METAL_EMBED_LIBRARY=ON` 很关键：否则要在 `tauri.conf.json` 的 `bundle.resources`
里手动带 `ggml-metal.metal`，而 Xcode 的 bundle 结构与 Tauri 的资源拷贝时机很容易对不上，
表现是运行时空指针崩在 `ggml_metal_init`。

## 接入形状

`engine.rs` 已经定义了：

```rust
pub trait Backend: Send + Sync {
    fn name(&self) -> &'static str;
    fn status(&self) -> EngineState;
    fn models(&self) -> Vec<ModelCard>;
    fn generate(&self, req: ChatRequest, run: Arc<Run>) -> Receiver<Delta>;
}
```

`LlamaBackend` 要做的事，按顺序：

1. **惰性加载**：第一次 `generate` 时才 `llama_model_load_from_file`（mmap，不占 RSS 峰值）；
   之后常驻，换模型才卸载。加载 0.6B 约 0.4–1.2s，这段时间 UI 用 `Delta::Thinking` 之外的
   状态灯表示，别让输入框卡住。
2. **采样**：`temperature` / `top_p` / `max_tokens` 从 `ChatRequest` 直接映射到 sampler chain；
   `thread_id` 用来挂多轮 KV cache（同一会话复用 prefix，省一半 prefill）。
3. **取消**：每个 token 前查 `run.cancelled.load(Relaxed)`，命中就 `llama_batch_free` 并退出。
   `chat_cancel` 已经把 `AtomicBool` 置上了，引擎侧只要读。
4. **输出**：`Delta::Text(String)` 逐 token 发，不做缓冲——`chat:delta` 事件本身很便宜，
   前端 `patch()` 只改最后一条消息。真要省 IPC，按 16ms 合并一次（60fps 一帧一个事件）。
5. **线程数**：Android 取 `PerformanceHintManager::getPreferredThreadPoolSize()`（没有就 `min(4, cores/2)`）；
   iOS Metal 走 GPU，`n_threads` 设 2–4 只影响 prefill。

## 模型分发

```
首次启动 → 引导页（选 0.6B / 1.7B）→ 下载器（断点续传 + SHA256 + 进度）
        → filesDir/models/qwen3-0.6b-q4km.gguf → list_models 出现 installed: true → 可对话
```

- 下载用 Rust 侧 reqwest + `Range` 续传，别用 WebView 的 fetch（移动端内存翻倍，还会被 WKWebView 的缓存策略坑）。
- 校验：文件大小 + SHA256 前缀比对，失败删除重下，不要留半个文件在目录里。
- 已装模型要有「卸载」，否则 6GB 的手机会被两个模型塞满。
- 桌面端同理，只是默认目录换成 `~/Library/Application Support/dev.flashcat/flashcat/models`。

## 验收线

- 0.6B q4，iOS A 系列：首字 ≤ 500ms，出字 ≥ 20 tok/s，连续 1000 token 不触发降频。
- Android 中端（骁龙 7 系）：首字 ≤ 900ms，出字 ≥ 12 tok/s。
- 后台切回来不重载模型（进程活着），内存峰值 < 1.2GB。
- 断网飞行模式下可完整对话一轮。
