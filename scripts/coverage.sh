#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 wangzhuo
#
# 覆盖率门禁。两个口径分开报：
#   - Core domain：FlashCatCore 里去掉进程/安装驱动（EngineController、
#     EngineInstallCenter）。这两个类的生命周期由 EngineControllerPhaseTests
#     用真进程覆盖，剩下的分支需要真实 pack 与 HTTP，先不纳入门槛。
#   - Kit：纯领域层，门槛 80%。
# 单项数字都会打印；只对 domain 与 Kit 卡阈值，避免用“总体”掩盖某一块。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/native"

CORE_MIN="${CORE_MIN:-60}"
KIT_MIN="${KIT_MIN:-80}"

BIN="${COVERAGE_BIN:-}"
PROFILE="${COVERAGE_PROFILE:-}"
if [ -z "$BIN" ] || [ -z "$PROFILE" ]; then
    swift test --enable-code-coverage >/dev/null
    BIN="$(find .build -path '*Products/Debug/FlashCatTests.xctest/Contents/MacOS/FlashCatTests' | head -1)"
    PROFILE="$(find .build -name default.profdata | head -1)"
fi
[ -x "$BIN" ] || { echo "error: 找不到测试二进制；先跑 swift test --enable-code-coverage" >&2; exit 1; }
[ -f "$PROFILE" ] || { echo "error: 找不到覆盖率 profile" >&2; exit 1; }

# $1 = 源码前缀, $2 = 排除的正则（空表示不排除）
measure() {
    xcrun llvm-cov export "$BIN" -instr-profile "$PROFILE" -format=lcov 2>/dev/null \
        | awk -v prefix="$1" -v exclude="$2" '
            /^SF:/ {
                file = substr($0, 4)
                infile = (index(file, prefix) > 0)
                if (infile && exclude != "" && file ~ exclude) infile = 0
            }
            /^DA:/ && infile {
                split(substr($0, 4), parts, ",")
                total++
                if (parts[2] + 0 > 0) covered++
            }
            END {
                if (total == 0) { print "0 0 0.0"; exit }
                printf "%d %d %.1f\n", covered, total, covered * 100 / total
            }'
}

gate() {
    local name="$1" values="$2" min="$3"
    local covered total pct
    read -r covered total pct <<<"$values"
    echo "$name: ${pct}% ($covered/$total)"
    awk -v pct="$pct" -v min="$min" 'BEGIN { exit (pct + 0 >= min + 0) ? 0 : 1 }' \
        || { echo "error: $name 覆盖率低于门槛 ${min}%" >&2; return 1; }
}

core_all="$(measure "/Sources/FlashCatCore/" "")"
core_domain="$(measure "/Sources/FlashCatCore/" "FlashCatCore/(Engine/EngineController|Engine/EngineInstallCenter)\\.swift$")"
kit="$(measure "/Sources/FlashCatKit/" "")"

echo "FlashCatCore（全部）: $(echo "$core_all" | awk '{printf "%s%% (%s/%s)", $3, $1, $2}')"
status=0
gate "FlashCatCore domain" "$core_domain" "$CORE_MIN" || status=1
gate "FlashCatKit" "$kit" "$KIT_MIN" || status=1
exit "$status"
