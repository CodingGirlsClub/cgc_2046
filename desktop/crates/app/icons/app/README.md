# App 图标（完整品牌 logo）

母版来自 `web/public/brand/cgc_logo_orange_white.png`（橙色底 + 白色火焰
mark + `CODING GIRLS CLUB` 竖版 lockup），由 `desktop/scripts/make-icons.py`
生成：

```bash
cd desktop
python3 scripts/make-icons.py
```

- `icon.icns` / `icon.ico` / `icon.png`：macOS / Windows / 通用安装包图标；
- `16.png` … `1024.png`：按尺寸拆分的 PNG；
- 同步更新 `dist/程序媛汇.app/Contents/Resources/icon.icns`（gitignored）。

顶栏与 Agent 面板 header 有 32px 空间，使用 `crates/app/icons/brand/cgc-badge-128.png`
（竖版 lockup + App 图标同比例圆角），由 `make-icons.py` 从
`icons/brand/cgc-badge.svg` 生成；`BRAND_BADGE_SIZE` 是唯一尺寸来源。

系统托盘 / 历史行 / agent 小头像继续使用 `crates/app/icons/32x32.png`
与 `128x128.png` 的 mark-only 版本：14–18px 下完整 wordmark 不可读。
登录页使用 `crates/app/icons/brand/cgc-logo-horizontal.png`（A.svg 横向
lockup），不要用竖版方图撑高标题区。
