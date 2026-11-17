#!/usr/bin/env bash
# 给 release APK 签名并 zipalign，产出一个能直接 adb install 的包。
#
#   ./scripts/sign-android.sh                     # 用 build/outputs/apk 下最新的未签名包
#   ./scripts/sign-android.sh path/to/app.apk     # 指定输入
#   OUT=dist/FlashCat.apk ./scripts/sign-android.sh
#
# 签名材料放在 ~/.flashcat-keys/env.sh（不随仓库分发）：
#   FLASHCAT_KS / FLASHCAT_KS_ALIAS / FLASHCAT_KS_PASS
# 没有这个文件时会退回 debug 签名，仍然可安装，只是不能上架、不能覆盖升级正式包。

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
android_dir="$here/../src-tauri/gen/android"
sdk="${ANDROID_HOME:-$HOME/Library/Android/sdk}"

pick_build_tools() {
  ls -d "$sdk"/build-tools/* 2>/dev/null | sort -V | tail -1
}
build_tools="$(pick_build_tools)"
if [[ -z "$build_tools" ]]; then
  echo "找不到 build-tools，检查 ANDROID_HOME（当前 $sdk）" >&2
  exit 1
fi
zipalign="$build_tools/zipalign"
apksigner="$build_tools/apksigner"

in="${1:-}"
if [[ -z "$in" ]]; then
  # apk 目录下有 universal/ 与 arm64/ 等子目录，按时间取最新的未签名包。
  in="$(find "$android_dir/app/build/outputs/apk" -name '*-unsigned.apk' -print0 2>/dev/null |
    xargs -0 ls -t 2>/dev/null | head -1)"
fi
if [[ -z "$in" || ! -f "$in" ]]; then
  echo "没有可签名的 APK，先跑 pnpm tauri android build --apk --target aarch64" >&2
  exit 1
fi

name="$(basename "$in" .apk)"
name="${name%-unsigned}"
out="${OUT:-$android_dir/app/build/outputs/apk/release/$name-signed.apk}"
mkdir -p "$(dirname "$out")"
tmp="$(mktemp -t flashcat-align).apk"

echo "→ 对齐 $in"
"$zipalign" -f -p 4 "$in" "$tmp"

if [[ -f "$HOME/.flashcat-keys/env.sh" ]]; then
  # shellcheck disable=SC1091
  source "$HOME/.flashcat-keys/env.sh"
  echo "→ 签名（release keystore）"
  "$apksigner" sign \
    --ks "$FLASHCAT_KS" \
    --ks-key-alias "$FLASHCAT_KS_ALIAS" \
    --ks-pass "pass:$FLASHCAT_KS_PASS" \
    --key-pass "pass:$FLASHCAT_KS_PASS" \
    --min-sdk-version 26 \
    --out "$out" "$tmp"
else
  echo "→ 签名（debug keystore；想上架请先建 ~/.flashcat-keys/env.sh）"
  "$apksigner" sign --min-sdk-version 26 --out "$out" "$tmp"
fi

rm -f "$tmp"
"$apksigner" verify --print-certs "$out" | head -4
echo "✓ $out ($(du -h "$out" | cut -f1))"
