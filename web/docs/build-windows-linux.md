# 在 Windows / Linux 上自己出安装包

CI 工作流（`.github/workflows/app-release.yml`）可以出全部四端，但你需要的是**在本机出包**，
这份文档就是给那条路用的。macOS / Android / iOS 的步骤在 README 的「四端构建」里，这里只讲
Windows 与 Linux —— 它们和 macOS 的差别几乎全在**编译 llama.cpp 的工具链**上。

---

## Windows

### 一次装齐

1. **Visual Studio 2022 Build Tools**（不是完整 VS 也行）
   勾选「使用 C++ 的桌面开发」。Rust 的 MSVC 链接器、C/C++ 编译器、Windows SDK 都在这一项里。
2. **Rust**（MSVC 工具链）
   ```powershell
   winget install Rustlang.Rustup
   rustup default stable-msvc
   ```
3. **Node 22 + pnpm 12**
   ```powershell
   winget install OpenJS.NodeJS.LTS
   corepack enable
   corepack prepare pnpm@12 --activate
   ```
4. **CMake**：llama.cpp 由 `llama-cpp-sys-2` 用 CMake 从源码编。
   ```powershell
   winget install Kitware.CMake
   ```
   VS 自带的那份 CMake 也能用，但要保证 `cmake --version` 在 PATH 里能跑。
5. **LLVM（关键，最容易漏）**：`llama-cpp-sys-2` 用 `bindgen` 生成绑定，`bindgen` 需要 `libclang.dll`。
   ```powershell
   winget install LLVM.LLVM
   setx LIBCLANG_PATH "C:\Program Files\LLVM\bin"
   ```
   装完**重开一个终端**（`setx` 只对新进程生效）。
6. **WebView2 Runtime**：Windows 11 自带；Windows 10 若没有，装
   [Evergreen Runtime](https://developer.microsoft.com/microsoft-edge/webview2/)。

### 出包

```powershell
cd web
pnpm install
pnpm build                 # tsc --noEmit && vite build，产物进 dist/
pnpm tauri build           # 编 Rust + llama.cpp，出安装包
```

产物：

| 文件 | 说明 |
| --- | --- |
| `web\src-tauri\target\release\bundle\nsis\FlashCat_0.3.2_x64-setup.exe` | 双击安装的安装包 |
| `web\src-tauri\target\release\flashcat.exe` | 免安装，直接跑（依赖 WebView2） |

第一次会编译整个 llama.cpp（`target/release/build/llama-cpp-sys-2-*`），**10–20 分钟**很正常；
之后增量编译 1 分钟内。

### 后端行为（Windows 与 macOS 的差别）

- `gpu_layers()` 只在 Apple 平台给 999，Windows 上是 **0**，也就是**纯 CPU**（AVX2）。
  Qwen3-0.6B Q4_K_M 在 8 核桌面 CPU 上大致 20–60 tok/s；想上 GPU 需要自己开 CUDA/Vulkan 特性，
  见下一节。
- 上下文桌面端 4096、线程数封顶 10，和 macOS 相同。
- 权重目录：`%APPDATA%\dev.flashcat.desktop\models\`。最省事的做法是打开应用 → 模型页 → 下载
  （应用内下载走 HTTPS，不需要手动放文件）。

### 想开 GPU（可选）

`llama-cpp-2` 支持 CUDA / Vulkan / OpenCL 后端，本项目**默认没开**（开了就得在每台机器上装对应运行时）。
要开的话改 `web/src-tauri/Cargo.toml` 的非 Apple 分支：

```toml
[target.'cfg(not(any(target_os = "macos", target_os = "ios")))'.dependencies]
llama-cpp-2 = { version = "0.1.161", default-features = false, features = ["cuda"] }
```

CUDA 需要 NVIDIA 驱动 + CUDA Toolkit 12.x；Vulkan 需要显卡驱动里的 Vulkan 运行时。
改完 `pnpm tauri build`，再确认日志里 `shell ready · windows/x86_64 · backend=llama.cpp`。

### 常见报错

| 报错 | 原因 | 修法 |
| --- | --- | --- |
| `Unable to find libclang.dll` / `couldn't find libclang` | 没装 LLVM 或 `LIBCLANG_PATH` 没生效 | 装 LLVM，`setx LIBCLANG_PATH ...`，重开终端 |
| `cmake: command not found` | CMake 不在 PATH | 装 CMake 或用 VS 的 Developer PowerShell |
| `link.exe not found` | 没装 VS Build Tools 的 C++ 组件 | 装「使用 C++ 的桌面开发」 |
| `error: linker 'link.exe' not found` | Rust 装成了 GNU 工具链 | `rustup default stable-msvc` |
| 白屏 / 未加载 | 缺 WebView2 | 装 Evergreen Runtime |
| `failed to bundle project: NSIS not found` | 首次打包没下载到 NSIS | 重跑；或手动装 NSIS 3 并在 PATH 里 |

---

## Linux（Debian / Ubuntu）

```bash
sudo apt update
sudo apt install -y build-essential curl pkg-config libssl-dev \
  libwebkit2gtk-4.1-dev libayatana-appindicator3-dev librsvg2-dev \
  libxdo-dev cmake clang libclang-dev

# Rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"

# Node 22 + pnpm
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt install -y nodejs
corepack enable && corepack prepare pnpm@12 --activate

cd web
pnpm install
pnpm build
pnpm tauri build
```

产物：

- `web/src-tauri/target/release/bundle/deb/FlashCat_0.3.2_amd64.deb`
- `web/src-tauri/target/release/bundle/appimage/FlashCat_0.3.2_amd64.AppImage`

AppImage 运行需要 FUSE（`sudo apt install libfuse2`），或者 `./FlashCat.AppImage --appimage-extract-and-run`。

`clang` 与 `libclang-dev` 是给 `bindgen` 用的（就是 Windows 上 LLVM 那一项）；少了会在
`llama-cpp-sys-2` 的 build script 里报 `libclang` 找不到。

Linux 也是**纯 CPU**（`gpu_layers()=0`），线程数封顶 10。权重目录
`~/.local/share/dev.flashcat.desktop/models/`，同样建议用应用内下载。

---

## 出完包怎么验

不看屏幕也能判断后端有没有起来 —— 日志里这三行缺一不可：

```
boot FlashCat 0.3.2 platform=windows mobile=false
page Finished http://tauri.localhost/
shell ready · windows/x86_64 · v0.3.2 · backend=llama.cpp model=Qwen3-0.6B-Q4_K_M state=ready
```

第一行有、第二行没有 → 前端资源没打进去（`frontendDist` 或 `beforeBuildCommand` 的问题）。
前两行有、第三行没有 → JS 没执行到（CSP 或 WebView2 白屏）。
三行都有但 `backend=mock` → 权重目录里没有 `.gguf`，回到模型页下载。

日志文件位置（Windows）：`%LOCALAPPDATA%\dev.flashcat.desktop\logs\flashcat.log`。
