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

顶栏使用 32px 品牌 badge（`BRAND_BADGE_SIZE`，`crates/app/icons/brand/cgc-badge-128.png`，
竖版 lockup + App 图标同比例圆角，由 `make-icons.py` 从 `icons/brand/cgc-badge.svg`
生成）。Agent 面板 header 的 native / ACP 图标统一 16px mark-only
（`AGENT_HEADER_ICON_SIZE`，对齐 Zed `IconSize::Medium`）；历史行 / agent 选择器
14px（`AGENT_ROW_ICON_SIZE`，Zed `IconSize::Small`），系统托盘继续用 32×32 mark-only。
14–18px 下完整 wordmark 不可读，所以 Agent 面板不放 badge。
登录页使用 `crates/app/icons/brand/cgc-logo-horizontal.png`（A.svg 横向
lockup），不要用竖版方图撑高标题区。
