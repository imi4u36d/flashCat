# flashCat / Windows 构建助手
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File scripts\build-windows.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\build-windows.ps1 -Lite
#
# -Lite 出的是「演示后端」安装器（不编译 llama.cpp），用来先确认打包链路通；
# 通过之后再跑一次不带 -Lite 的，出正式包。
#
# 依赖（缺哪个它会直接告诉你）：Node 22+/pnpm 12、Rust stable-msvc、CMake、
# LLVM（LIBCLANG_PATH 指向 bin）、WebView2 运行时。详见 docs/build-windows-linux.md。

param(
  [switch]$Lite,
  [switch]$SkipChecks
)

$ErrorActionPreference = "Stop"
$web = Split-Path -Parent $PSScriptRoot
Set-Location $web

function Fail($message) {
  Write-Host ""
  Write-Host "✗ $message" -ForegroundColor Red
  Write-Host "  详细步骤见 docs\build-windows-linux.md" -ForegroundColor DarkGray
  exit 1
}

if (-not $SkipChecks) {
  Write-Host "检查依赖…" -ForegroundColor Cyan

  foreach ($cmd in @("node", "pnpm", "cargo", "cmake")) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
      Fail "找不到 $cmd，先装它（docs\build-windows-linux.md 第一节）"
    }
  }

  $rustc = (& rustc -vV) 2>$null
  if ($rustc -notmatch "host: .*msvc") {
    Fail "rustc 不是 msvc 宿主（当前：$($rustc | Select-String 'host:')）。执行：rustup default stable-msvc"
  }

  if (-not $env:LIBCLANG_PATH) {
    $llvm = "C:\Program Files\LLVM\bin"
    if (Test-Path $llvm) {
      Write-Host "  提示：检测到 LLVM，但 LIBCLANG_PATH 未设置。本次临时使用该路径。" -ForegroundColor Yellow
      $env:LIBCLANG_PATH = $llvm
    } elseif (-not $Lite) {
      Fail "LIBCLANG_PATH 为空且找不到 C:\Program Files\LLVM\bin —— 正式包要 bindgen 编译 llama.cpp"
    }
  }

  $webview = Get-ItemProperty -Path "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}" -ErrorAction SilentlyContinue
  if (-not $webview) {
    Write-Host "  提示：没检测到 WebView2 运行时。Win10 可能要先装 Evergreen 运行时。" -ForegroundColor Yellow
  }
}

Write-Host ""
Write-Host "安装前端依赖…" -ForegroundColor Cyan
& pnpm install
if ($LASTEXITCODE -ne 0) { Fail "pnpm install 失败" }

Write-Host ""
Write-Host "构建前端…" -ForegroundColor Cyan
& pnpm build
if ($LASTEXITCODE -ne 0) { Fail "前端构建失败（tsc / vite 的报错在上面）" }

Write-Host ""
if ($Lite) {
  Write-Host "构建安装器（lite：不编译 llama.cpp）…" -ForegroundColor Cyan
  & pnpm tauri build -- --no-default-features
} else {
  Write-Host "构建安装器（完整：含 llama.cpp，首次要十几分钟）…" -ForegroundColor Cyan
  & pnpm tauri build
}

if ($LASTEXITCODE -ne 0) {
  Write-Host ""
  Write-Host "✗ 构建失败。" -ForegroundColor Red
  if (-not $Lite) {
    Write-Host "  想先确认打包链路是通的，可以跳过 llama.cpp 再跑一次：" -ForegroundColor Yellow
    Write-Host "    powershell -ExecutionPolicy Bypass -File scripts\build-windows.ps1 -Lite" -ForegroundColor Yellow
  }
  exit $LASTEXITCODE
}

Write-Host ""
Write-Host "✓ 完成。产物：" -ForegroundColor Green
Get-ChildItem -Path "src-tauri\target\release\bundle" -Recurse -Include *.exe, *.msi -ErrorAction SilentlyContinue |
  ForEach-Object { Write-Host ("  {0}  ({1:N1} MB)" -f $_.FullName, ($_.Length / 1MB)) }

if ($Lite) {
  Write-Host ""
  Write-Host "注意：这是 lite 包，对话页会显示「未装权重，当前是演示输出」，不会真的推理。" -ForegroundColor Yellow
  Write-Host "正式包请去掉 -Lite 再跑一次（需要 LLVM + CMake 就位）。" -ForegroundColor Yellow
}
