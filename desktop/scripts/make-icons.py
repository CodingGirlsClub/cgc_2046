#!/usr/bin/env python3
"""从 Web 品牌竖版 logo 生成桌面端 App 图标全套资产。

源文件：web/public/brand/cgc_logo_orange_white.png（橙底 + 白色火焰 mark +
CODING GIRLS CLUB 竖版 lockup）。
输出：
- crates/app/icons/brand/cgc-logo-vertical.png  登录页完整 logo
- crates/app/icons/brand/cgc-badge-128.png      顶栏 32px 品牌 badge
- crates/app/icons/app/icon.png                  1024 圆角母版
- crates/app/icons/app/{16,32,64,128,256,512}.png
- crates/app/icons/app/icon.icns                 macOS
- crates/app/icons/app/icon.ico                  Windows
- 同步 dist/程序媛汇.app/Contents/Resources/icon.icns（如存在）

小尺寸的 mark-only（系统托盘 / 历史行 / agent 选择器）继续使用
crates/app/icons/{32x32,128x128}.png：14–18px 下完整 wordmark 不可读。
顶栏有 32px 空间，使用 brand/cgc-badge-128.png；Agent 面板 16px 用 mark-only。
"""

from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parent
SRC = REPO / "web/public/brand/cgc_logo_orange_white.png"
ICONS = ROOT / "crates/app/icons"
APP_ICONS = ICONS / "app"
BRAND = ICONS / "brand"
DIST_ICNS = ROOT / "dist/程序媛汇.app/Contents/Resources/icon.icns"
HORIZONTAL_SRC = REPO / "web/public/brand/A.svg"
HORIZONTAL_OUT = BRAND / "cgc-logo-horizontal.png"
BADGE_SRC = BRAND / "cgc-badge.svg"
BADGE_OUT = BRAND / "cgc-badge-128.png"
BADGE_SIZE = 128

MASTER = 1024
RADIUS = 190
SIZES = (16, 32, 64, 128, 256, 512, 1024)
# 与 App 图标同比例（190 / 1024）；32px 显示时约 6px 圆角。
BADGE_RADIUS = round(BADGE_SIZE * RADIUS / MASTER)


def rounded_master(src: Path) -> Image.Image:
    logo = Image.open(src).convert("RGB").resize((MASTER, MASTER), Image.LANCZOS)
    mask = Image.new("L", (MASTER, MASTER), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, MASTER, MASTER), radius=RADIUS, fill=255
    )
    out = Image.new("RGBA", (MASTER, MASTER), (0, 0, 0, 0))
    out.paste(logo, (0, 0), mask)
    return out


def main() -> int:
    if not SRC.is_file():
        print(f"missing brand source: {SRC}", file=sys.stderr)
        return 1
    APP_ICONS.mkdir(parents=True, exist_ok=True)
    BRAND.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(SRC, BRAND / "cgc-logo-vertical.png")

    # 登录页用横向 lockup（mark + CODING GIRLS CLUB）；A.svg 是矢量源。
    if HORIZONTAL_SRC.is_file():
        try:
            subprocess.run(
                ["rsvg-convert", "-w", "900", "-h", "260", str(HORIZONTAL_SRC),
                 "-o", str(HORIZONTAL_OUT)],
                check=True,
            )
        except FileNotFoundError:
            print("warning: rsvg-convert not found; keep existing horizontal logo")

    # 顶栏 32px badge：竖版 lockup + App 图标同比例圆角。
    if BADGE_SRC.is_file():
        try:
            with tempfile.TemporaryDirectory() as tmp:
                raw = Path(tmp) / "cgc-badge-raw.png"
                subprocess.run(
                    ["rsvg-convert", "-w", str(BADGE_SIZE), "-h", str(BADGE_SIZE),
                     str(BADGE_SRC), "-o", str(raw)],
                    check=True,
                )
                badge = Image.open(raw).convert("RGBA")
                mask = Image.new("L", (BADGE_SIZE, BADGE_SIZE), 0)
                ImageDraw.Draw(mask).rounded_rectangle(
                    (0, 0, BADGE_SIZE, BADGE_SIZE), radius=BADGE_RADIUS, fill=255
                )
                out = Image.new("RGBA", (BADGE_SIZE, BADGE_SIZE), (0, 0, 0, 0))
                out.paste(badge, (0, 0), mask)
                out.save(BADGE_OUT)
        except FileNotFoundError:
            print("warning: rsvg-convert not found; keep existing badge")

    master = rounded_master(SRC)
    master.save(APP_ICONS / "icon.png")
    for size in SIZES:
        master.resize((size, size), Image.LANCZOS).save(APP_ICONS / f"{size}.png")

    iconset = APP_ICONS / "icon.iconset"
    if iconset.exists():
        shutil.rmtree(iconset)
    iconset.mkdir()
    for points, scale in ((16, 1), (16, 2), (32, 1), (32, 2), (128, 1),
                          (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)):
        size = points * scale
        name = f"icon_{points}x{points}{'@2x' if scale == 2 else ''}.png"
        master.resize((size, size), Image.LANCZOS).save(iconset / name)
    subprocess.run(
        ["iconutil", "-c", "icns", str(iconset), "-o", str(APP_ICONS / "icon.icns")],
        check=True,
    )
    shutil.rmtree(iconset)

    master.save(
        APP_ICONS / "icon.ico",
        sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)],
    )

    if DIST_ICNS.parent.is_dir():
        shutil.copyfile(APP_ICONS / "icon.icns", DIST_ICNS)
        print(f"updated {DIST_ICNS}")
    print(f"generated app icons -> {APP_ICONS}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
