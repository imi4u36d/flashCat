#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 wangzhuo
#
# 架构守卫：把已经成立的分层规则变成 CI 能拦的检查。
#
# 只检查能机器判定的部分。新增例外必须写进本文件的 allowlist 并说明原因；
# 规则只随结构收敛而加严，不因为一次赶工而放宽。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCES="$ROOT/native/Sources/FlashCat"
CORE="$SOURCES/Core"
UI="$SOURCES/UI"
fail=0

# 1. Core 不依赖 UI 框架。Core 将来会抽成独立的 FlashCatCore target，
#    这一条是那次拆分的前提。
if matches=$(find "$CORE" -name '*.swift' \
    -exec grep -HEn '^import (SwiftUI|AppKit|AVFoundation|AVKit)$' {} +); then
    if [ -n "$matches" ]; then
        echo "$matches"
        echo "error: Sources/FlashCat/Core 不得 import UI 框架" >&2
        fail=1
    fi
fi

# 2. Core 不直接耦合装配根。两处历史例外：
#    - Models/DownloadCenter.swift：下载进程终止回调里回到主 actor 收尾；
#    - Logs/LogFeedService.swift：历史写盘失败的静态入口。
#    两者都计划在 FlashCatCore target 拆分时改成注入；新代码不得再加例外。
if matches=$(find "$CORE" -name '*.swift' \
    ! -path '*/Models/DownloadCenter.swift' \
    ! -path '*/Logs/LogFeedService.swift' \
    -exec grep -HEn 'AppState\.shared|AppState\(|: AppState\b|-> AppState\b' {} + \
    | grep -vE ':[0-9]+:[[:space:]]*///'); then
    if [ -n "$matches" ]; then
        echo "$matches"
        echo "error: Sources/FlashCat/Core 不得引用 AppState" >&2
        fail=1
    fi
fi

# 3. 装配根的行数预算。新逻辑应当进 store / orchestrator，而不是加回 AppState。
APP_STATE="$SOURCES/Composition/AppState.swift"
if [ -f "$APP_STATE" ]; then
    app_state_lines=$(wc -l < "$APP_STATE" | tr -d ' ')
    if [ "$app_state_lines" -gt 900 ]; then
        echo "error: AppState.swift 现有 $app_state_lines 行，预算 900；新逻辑请放进 store 或编排对象" >&2
        fail=1
    fi
fi

# 4. 视图不直接订阅子 store 的双向绑定（当前契约是 @ObservedObject 读 state.x）。
if matches=$(find "$UI" -name '*.swift' -exec grep -HEn '\$state\.' {} +); then
    if [ -n "$matches" ]; then
        echo "$matches"
        echo "error: UI 层不应出现 \$state. 双向绑定" >&2
        fail=1
    fi
fi

# 5. UI 不直接做网络 / 文件系统操作。取数与落盘属于 store / service，
#    视图只消费结果；这条已经是零，新增命中直接阻断。
if matches=$(find "$UI" -name '*.swift' \
    -exec grep -HEn 'URLSession|FileManager\.default|Process\(' {} +); then
    if [ -n "$matches" ]; then
        echo "$matches"
        echo "error: UI 层不得直接发网络请求或读写文件" >&2
        fail=1
    fi
fi

# 6. 报告项：超过 800 行的文件，便于下一轮按职责拆。
echo "== 超过 800 行的 Swift 文件 =="
find "$SOURCES" -name '*.swift' -exec wc -l {} + \
    | awk '$2 != "total" && $1 > 800 { print }' \
    | sort -rn \
    | head -15

if [ "$fail" -ne 0 ]; then
    exit 1
fi

echo "architecture: OK"
