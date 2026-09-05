#!/bin/bash
# check_env.sh —— issue-video 技能环境自检
# 逐项检查依赖，打印 ✓/✗ + 修复提示；任一 ✗ 则整体退出码 1。
# 用法：./check_env.sh [logo_path]
#   logo_path 缺省为本 skill 自带资产 assets/cgc_logo_orange_white.svg（随包分发）。
# 全绿时输出 LOGO_PATH / LOGO_H_PATH 两行绝对路径——抄进 scene.py 常量区。

SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
LOGO_PATH="${1:-$SKILL_DIR/assets/cgc_logo_orange_white.svg}"
LOGO_H_PATH="$SKILL_DIR/assets/cgc_logo_horizontal.png"
TEXBIN="/Library/TeX/texbin"

fail=0

ok()   { printf "✓ %s\n" "$1"; }
bad()  { printf "✗ %s\n" "$1"; printf "  → 修复：%s\n" "$2"; fail=1; }

# --- manim（uv tool 装在 ~/.local/bin，可能不在 PATH）---
if command -v manim >/dev/null 2>&1; then
    ok "manim: $(command -v manim)"
elif [ -x "$HOME/.local/bin/manim" ]; then
    ok "manim: $HOME/.local/bin/manim（不在 PATH，但能直接跑）"
else
    bad "manim 不可执行" "uv tool install manim"
fi

# --- edge-tts ---
if command -v edge-tts >/dev/null 2>&1; then
    ok "edge-tts: $(command -v edge-tts)"
elif [ -x "$HOME/.local/bin/edge-tts" ]; then
    ok "edge-tts: $HOME/.local/bin/edge-tts（不在 PATH，但能直接跑）"
else
    bad "edge-tts 不可执行" "uv tool install edge-tts"
fi

# --- fish-audio（默认 TTS 引擎；key 只读不打印，永不外泄）---
if [ -n "$FISH_AUDIO_API_KEY" ]; then
    if [ -n "$FISH_AUDIO_VOICE_ID" ]; then
        ok "fish-audio（默认）: 已启用（声音 id=$FISH_AUDIO_VOICE_ID）"
    else
        ok "fish-audio（默认）: 已启用（未设 FISH_AUDIO_VOICE_ID，用平台默认声音）"
    fi
else
    echo "○ fish-audio（默认）未启用：未设 FISH_AUDIO_API_KEY，TTS 退回 edge-tts"
fi

# --- ffmpeg ---
if command -v ffmpeg >/dev/null 2>&1; then
    ok "ffmpeg: $(command -v ffmpeg)"
else
    bad "ffmpeg 不可执行" "brew install ffmpeg"
fi

# --- LaTeX 链：latex + dvisvgm（texbin 可能不在 PATH，检查覆盖该目录）---
if command -v latex >/dev/null 2>&1; then
    ok "latex: $(command -v latex)"
elif [ -x "$TEXBIN/latex" ]; then
    ok "latex: $TEXBIN/latex（不在 PATH；渲染前 export PATH=\"$TEXBIN:\$PATH\"）"
else
    bad "latex 不存在" "安装 MacTeX（brew install --cask mactex 或官网包）"
fi

if command -v dvisvgm >/dev/null 2>&1; then
    ok "dvisvgm: $(command -v dvisvgm)"
elif [ -x "$TEXBIN/dvisvgm" ]; then
    ok "dvisvgm: $TEXBIN/dvisvgm（不在 PATH；渲染前 export PATH=\"$TEXBIN:\$PATH\"）"
else
    # 缺它 MathTex/Tex 整条路堵死（latex→dvi→dvisvgm→SVG 链断）
    bad "dvisvgm 不可用（MathTex 会被堵死）" "sudo tlmgr install dvisvgm"
fi

# --- logo 素材（方形：末场品牌卡；横排：包装层右下角标）---
if [ -f "$LOGO_PATH" ]; then
    ok "logo: $LOGO_PATH"
else
    bad "logo 素材不存在：$LOGO_PATH" "skill 包应自带 assets/cgc_logo_orange_white.svg；或传参：./check_env.sh <logo_path>"
fi

if [ -f "$LOGO_H_PATH" ]; then
    ok "横排 logo: $LOGO_H_PATH"
else
    bad "横排 logo 素材不存在：$LOGO_H_PATH" "skill 包应自带 assets/cgc_logo_horizontal.png（包装层右下角标用）"
fi

echo
if [ "$fail" -eq 0 ]; then
    echo "环境就绪：可以跑 manim 渲染 + TTS（默认 fish-audio，兜底 edge-tts）+ ffmpeg 后期。"
    echo
    echo "品牌素材绝对路径（随安装位置变，别手猜）："
    echo "  LOGO_PATH（方形）→ 抄进 scene.py 常量区，末场品牌卡用"
    echo "  LOGO_H_PATH（横排）→ 第 6 步角标 ffmpeg 命令用"
    echo "  LOGO_PATH = \"$LOGO_PATH\""
    echo "  LOGO_H_PATH = \"$LOGO_H_PATH\""
    exit 0
else
    echo "存在缺失项，按上面的修复提示处理后重跑本脚本。"
    exit 1
fi
