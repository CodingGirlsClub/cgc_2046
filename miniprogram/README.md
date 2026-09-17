# 程序媛汇 · 微信小程序

CGC-2046 微信端，Taro 4 + React 18 + TypeScript。单码库三端构建：**weapp 全量端**（微信，4 Tab）+ **tt / xhs 裁剪端**（抖音 / 小红书，2 Tab 漏斗，页面表见 `src/app.config.ts`）。

工程约定、验证命令、e2e 纪律见 [AGENTS.md](./AGENTS.md)；面向用户的更新记录见 [CHANGELOG.md](./CHANGELOG.md)。

## 功能清单（weapp 全量端）

| 页面 | 功能 |
| --- | --- |
| `discover` 发现 | 公开活动 / 课程（Initiative）浏览、筛选 |
| `initiative-detail` / `event-detail` | 活动与课程详情、报名入口、好友分享卡片、slug / scene 深链冷启动直达 |
| `login` | 手机号快速登录（`getPhoneNumber` code 契约） |
| `register-form` / `enrollment-result` | 报名表单（open / request / invite_only 三策略 + 年龄门槛）与结果页 |
| `order-pay` | 定价 / 押金支付；押金单支付前强制「押金 ¥xx（到场退）+ 未到场不退」同意门 |
| `my-enrollments` 我的报名 | 报名记录、审批倒计时、自助取消（含取消截止时间与押金自动退款披露） |
| `check-in` | 主理人扫码核销（现场管理）+ 参与者出示核销 QR |
| `workspace` 工作台 | 审批待办（通过 / 拒绝）、跨工作台待办（需 `manage_members`） |
| `join` | 邀请码 / 批次码加入 workspace |
| `profile` 我的 | 个人信息、退出登录 |
| `privacy` | 隐私政策与个人信息处理规则（微信审核硬要求） |
| `openclacky` | OpenClacky 安装与连接指引（纯指引，无执行能力） |

裁剪端（tt / xhs）只保留漏斗页：发现、详情、登录、报名、我的报名、加入。

## 发版流程（微信端）

CI 只做质量门（`pnpm check:ci`），**不上传小程序**；版本更新是人工链路：

1. **版本号**：单源 = 本目录 `package.json` 的 `version`。发版前把它改成目标版本，CHANGELOG 补条目，与代码变更同 PR。
2. **门禁**：`pnpm check:ci` 全绿（CI 已跑则以 PR 绿记录为准）。
3. **构建**：`pnpm build:weapp`，产物 `dist/weapp/`（不入库）。
4. **上传**（生成开发版本）：
   - CLI：`wechatide upload --project <本目录绝对路径> --upload-version <version> --desc "<一句话>"`
   - 或微信开发者工具打开本目录点「上传」。
   - 真实 AppID 只写工具本地 `project.private.config.json`（不入库）；上传后 `git status` 确认 tracked `project.config.json` 未被改动。
5. **提审**：MP 后台（mp.weixin.qq.com）→ 版本管理 → 开发版本可先设体验版 → 提交审核。
6. **发布**：审核通过后后台手动「全量发布」。
7. **发布后验证**：`e2e/REAL_DEVICE_CHECKLIST.md` 的「发布后验证批次」（scheme 冷/热启动、扫码加入全流程、slug 深链）——这些依赖线上正式版，发版后必须补验并落档。
