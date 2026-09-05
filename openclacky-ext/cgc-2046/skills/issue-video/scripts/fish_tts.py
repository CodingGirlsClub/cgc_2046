#!/usr/bin/env python3
"""fish_tts.py — Fish Audio TTS，一场一条口播。

用法：
    python3 fish_tts.py <口播文本文件> <输出.mp3>

环境变量：
    FISH_AUDIO_API_KEY   必填（fish.audio 后台申请；脚本永不打印/落盘该值）
    FISH_AUDIO_VOICE_ID  可选，tutor 在 fish.audio 克隆或收藏的声音 id；
                         不设则用平台默认声音
    FISH_AUDIO_MODEL     可选，请求 header 的模型 id（默认 s2-pro）

零第三方依赖（只用标准库），口播文本走文件传入，避免 shell/JSON 双重转义。
"""
import json
import os
import sys
import tempfile
import urllib.error
import urllib.request

API_URL = "https://api.fish.audio/v1/tts"


def main() -> None:
    if len(sys.argv) != 3:
        sys.exit("用法: fish_tts.py <口播文本文件> <输出.mp3>")
    text_path, out_path = sys.argv[1], sys.argv[2]

    key = os.environ.get("FISH_AUDIO_API_KEY")
    if not key:
        sys.exit("缺环境变量 FISH_AUDIO_API_KEY（见 SKILL.md 第 3 步）")

    with open(text_path, encoding="utf-8") as f:
        text = f.read().strip()
    if not text:
        sys.exit(f"口播文本为空: {text_path}")

    body = {"text": text, "format": "mp3"}
    voice = os.environ.get("FISH_AUDIO_VOICE_ID")
    if voice:
        body["reference_id"] = voice
    # Fish Audio OpenAPI 把 model 定义为请求 header，不是 JSON body 字段。
    model = os.environ.get("FISH_AUDIO_MODEL", "s2-pro")

    req = urllib.request.Request(
        API_URL,
        data=json.dumps(body).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json",
            "model": model,
        },
        method="POST",
    )
    tmp_path = None
    try:
        output_dir = os.path.dirname(os.path.abspath(out_path))
        prefix = f".{os.path.basename(out_path)}."
        with tempfile.NamedTemporaryFile(
            mode="wb", dir=output_dir, prefix=prefix, suffix=".tmp", delete=False
        ) as output:
            tmp_path = output.name
            with urllib.request.urlopen(req, timeout=180) as resp:
                while chunk := resp.read(1 << 16):
                    output.write(chunk)

        os.replace(tmp_path, out_path)
        tmp_path = None
    except urllib.error.HTTPError as e:
        sys.exit(f"Fish Audio TTS 失败: HTTP {e.code}")
    except (urllib.error.URLError, OSError, TimeoutError) as e:
        sys.exit(f"Fish Audio TTS 失败: {type(e).__name__}")
    finally:
        if tmp_path:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass

    print(f"ok: {out_path} ({os.path.getsize(out_path)} bytes)")


if __name__ == "__main__":
    main()
