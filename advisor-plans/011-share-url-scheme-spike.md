# Plan 011: 【Design/Spike】微信原生分享 + URL Scheme 深链——定义契约、验证配额模型、产出决策清单

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `advisor-plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 048c9f8..HEAD -- miniprogram/src/pages/event-detail/ miniprogram/src/app.tsx backend/lib/cgc_2046/miniprogram/ backend/lib/cgc_2046_web/graphql_schema.ex`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M（调查 + 原型 + 契约定义，非全量实现）
- **Risk**: LOW（spike 产物是决策文档 + 可选原型；不直接上生产路径）
- **Depends on**: advisor-plans/008-miniprogram-wechat-sdk-adoption.md（`WechatClient`
  宿主是其复用前提）
- **Category**: direction
- **Planned at**: commit `048c9f8`, 2026-08-18

## Why this matters

微信端的获客链路目前只有一个断裂的二维码（plan 008 修码的落页）。微信生态里转化率
最高的三个入口——**聊天卡片分享、朋友圈、外部深链（短信/邮件/网页拉起）**——前端
**一个都没接**（全仓 grep `useShareAppMessage|onShareAppMessage|showShareMenu` 零命中，
2026-08-18 核实）。前两个是纯前端 API（wx 分享挂载），零后端成本；第三个（URL Scheme）
后端已具备全部前置：wechat_sdk 的 `WeChat.MiniProgram.UrlScheme.create_scheme/3`
现成可用，且 scene 消费链路（扫码 → `app.tsx` useLaunch → pendingScene → join 页）已过
真机验收。前次审计的 D03 方向（advisor-plans/README.md:68）已建议此项且被搁置——
SDK 引入后成本进一步下降。

这是 **design/spike plan**：目标是把「分享卡片字段契约、scheme 配额模型、裁剪端红线
边界」调查清楚并定义 API，产出一份可执行的决策文档。**不是**全量实现计划。

## Current state

- 分享面现状：
  - `miniprogram/src/pages/event-detail/index.tsx:56-105` — 详情页有公开内容
    （title/description/schemaFields）与报名 CTA，**无任何分享挂载**。
  - Taro 4 的分享挂载方式：`Taro.useShareAppMessage(callback)`（React hooks 版），
    callback 返回 `{ title, path, imageUrl? }`。当前零使用。
- 深链面现状：
  - scene 链路（已验收）：扫码进小程序 → `miniprogram/src/app.tsx:7-12`
    （useLaunch 解析 query.scene → 存 pendingScene → navigateTo join）→
    `miniprogram/src/pages/join/index.tsx:27-45`（一次性消费 admitMember）。
    **注意**：这条链路消费的是 Workspace 邀请 scene（admit 语义）。活动分享的
    scene 语义不同（navigate 到 event-detail + enroll），**不能复用 join 消费逻辑**。
  - SDK：`WeChat.MiniProgram.UrlScheme.create_scheme(client, jump_wxa, expire_time)` →
    POST /wxa/generatescheme；`jump_wxa = %{path: ..., query: ...}`；
    `expire_time` 为 Unix 秒（到期失效）或 nil（永久）。返回
    `{"openlink": "weixin://dl/business/?t=XXX"}`。
    官方限制（SDK moduledoc 转述）：仅国内非个人主体；到期失效 scheme 的有效期
    上限与生成频率配额需在 spike 中核实（官方文档「获取 URL scheme 码」页）。
- 后端前置：
  - `Cgc2046.Miniprogram.Client`（plan 008 后含 `WechatClient.fetch()` SDK 宿主）。
  - GraphQL 面先例：`generateMiniProgramCode` mutation（`backend/lib/cgc_2046_web/graphql_schema.ex`
    中，用 `grep -n "generateMiniProgramCode" backend/lib/cgc_2046_web/graphql_schema.ex` 定位）。
- 产品红线（不可违背，来自 advisor-plans rejected 区与 CI 门禁）：
  - 裁剪端（tt/xhs）**零跨端导流**：分享文案/路径不得出现其他平台字样；
    `miniprogram/scripts/check-no-diversion.mjs` + CI `check:diversion` 是 fail-closed 门禁。
  - 分享 API 不抽象成伪统一跨端 API（D03 原话「裁剪端只采用各自平台原生挂载」）——
    weapp 用 `useShareAppMessage`，tt/xhs 各自原生分享 API 或不做。
- 上架主体约束：URL Scheme 仅国内非个人主体可用（ICP 清单显示主体为非个人，
  `docs/合规上架/ICP备案材料清单.md` 可交叉确认）；分享无此限制。

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| 分享 API 使用面 | `grep -rn "useShareAppMessage\|onShareAppMessage\|showShareMenu" miniprogram/src/` | 现状零命中（实现后命中新代码） |
| scheme SDK 面 | `grep -n "create_scheme" backend/deps/wechat/lib/wechat/mini_program/url_scheme.ex` | 定位函数 |
| 前端类型 | `cd miniprogram && pnpm typecheck` | exit 0 |
| 前端测试 | `cd miniprogram && pnpm test:unit` | 全绿 |

## Scope

**In scope**（spike 产物）:
- `docs/01-定稿设计/微信分享与深链-spike结论.md`（新建，主要交付物）
- `miniprogram/src/pages/event-detail/index.tsx`（**仅限** spike 原型：分享挂载 hook，
  若 spike 决定保留）
- `backend/lib/cgc_2046/miniprogram/url_scheme.ex`（**仅限** spike 原型：SDK 薄封装）
- 对应测试文件（若写原型）

**Out of scope**:
- 任何 tt/xhs 分享实现（spike 只定义边界，不实现）。
- join/admit scene 链路改动。
- 短信/邮件渠道的发送本身（scheme 生成只提供 link）。
- 朋友圈分享素材后台（imageUrl 用现有详情图或默认截图即可）。

## Git workflow

- Branch: `advisor/011-share-scheme-spike`
- Commit style 先例：`spike(share): 微信分享+URL Scheme 契约定义与配额核实 (#NNN)`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: 调查并成文——配额/有效期/裁剪端边界

写 `docs/01-定稿设计/微信分享与深链-spike结论.md`，必须包含以下每节的**核实结论**
（来源：SDK 源码 + 微信官方文档 developers.weixin.qq.com 对应页；每条结论标注来源链接；
查不到官方明文的标 `未核实——上线前必须确认`）：

1. **分享卡片契约**：`useShareAppMessage` 在 event-detail 的字段（title 截断长度、
   path 格式 `pages/event-detail/index?id=...`、imageUrl 尺寸比例）；转发到朋友圈
   （onShareTimeline）是否需要单独挂载、裁剪端等价 API 是否存在。
2. **URL Scheme 配额模型**：`generatescheme` 的调用频率限制（官方 QPS/日配额数字）、
   到期失效 scheme 的最长有效期、永久 scheme 的数量上限、`is_expire`/`expire_type`
   参数的准确语义（对照 SDK 只暴露了 `expire_time` 整数——确认 SDK 覆盖是否够用，
   不够则记录需要绕过 SDK 直调的点）。
3. **scene/query 双轨**：scheme 的 `jump_wxa.query` 与小程序码的 `scene` 在冷启动与
   热启动（小程序已打开再点 link）下的进参差异（`wx.getLaunchOptionsSync` vs
   `wx.onAppShow`——现有 `app.tsx` 只处理 useLaunch 冷启动；前次审计 F05 的
   「前台恢复」缺口在此场景是否复发，给出结论）。
4. **裁剪端红线边界**：tt/xhs 各自的原生分享 API 名称、是否允许分享到「外站」、
   零导流门禁对新分享文案的覆盖方式（新文案是否会被 `check-no-diversion.mjs`
   扫到——该脚本只扫产物里的平台字样，分享 title 运行时来自服务端数据，确认
   门禁边界并写明「分享文案的合规责任在服务端字段」还是需要补门禁）。
5. **安全**：scheme 的 query 参数会被客户端拿到——确认分享/scheme 路径不携带
   token/邀请凭据等敏感值（对照 join scene 的一次性消费设计）。

**Verify**: 文档存在且五节各含至少一条带来源链接的结论（或明确的「未核实」标记）。

### Step 2: spike 原型（可选实现，验证契约可用）

仅当 Step 1 的结论支持（无硬阻断）：

1. `backend/lib/cgc_2046/miniprogram/url_scheme.ex`：

```elixir
defmodule Cgc2046.Miniprogram.UrlScheme do
  @moduledoc """
  微信 URL Scheme 生成（spike）：活动分享深链。

  仅 wechat；jump path = pages/event-detail/index，query = id（无敏感值）。
  配额策略（按 spike 结论定）：默认到期失效（活动结束时间 + 缓冲），
  同 (event_id) 复用同一 scheme（存储决策见 spike 文档 §6）。
  """
  alias Cgc2046.Miniprogram.WechatClient

  @spec create_event_link(String.t(), expires_at :: DateTime.t() | nil) ::
          {:ok, String.t()} | {:error, term()}
  def create_event_link(event_id, expires_at \\ nil) do
    with {:ok, client} <- WechatClient.fetch(),
         {:ok, %Tesla.Env{status: 200, body: %{"openlink" => link}}} <-
           WeChat.MiniProgram.UrlScheme.create_scheme(
             client,
             %{path: "/pages/event-detail/index", query: "id=#{event_id}"},
             expires_at && DateTime.to_unix(expires_at)
           ) do
      {:ok, link}
    else
      {:ok, %Tesla.Env{status: 200, body: %{"errcode" => code, "errmsg" => msg}}} ->
        {:error, {:platform_rejected, code, msg}}

      error -> {:error, {:scheme_failed, error}}
    end
  end
end
```

2. `event-detail/index.tsx` 挂分享（Taro hooks）：

```tsx
  Taro.useShareAppMessage(() => ({
    title: <详情 title，截断规则按 spike 文档>,
    path: `/pages/event-detail/index?id=${id}`
  }))
```

3. 测试：url_scheme 模块按 plan 008 的 Tesla.Mock 模式（成功/errcode 两例）；
   event-detail 的分享 hook 不写单测（Taro hooks 环境外，E2E mock 已覆盖页面渲染）。

**Verify**: `cd backend && mix test test/cgc_2046/miniprogram/url_scheme_test.exs` 全绿；
`cd miniprogram && pnpm typecheck && pnpm test:unit` 全绿。

### Step 3: 决策清单收尾

spike 文档末尾追加「决策清单」节——每项一条：默认到期策略、同 event 复用与否、
朋友圈是否 v1、裁剪端是否 v1、是否需要 GraphQL mutation 面（或仅内部触发）。
标出哪些项需要 product owner 拍板（不可自行决定）。

**Verify**: 文档含「决策清单」节且产品决策项 ≥2 条被明确标出。

## Test plan

- spike 原型的 url_scheme_test.exs（成功 openlink / errcode 保真两例，Tesla.Mock）。
- 不新增页面测试（分享 hook 无 CI 可验证面；真机验证记录进 spike 文档的「真机核实」节，
  与 REAL_DEVICE_CHECKLIST.md 的体例一致）。

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `docs/01-定稿设计/微信分享与深链-spike结论.md` 存在，五节结论 + 决策清单齐备
- [ ] （若做原型）`mix test` 与 `pnpm test:unit` 全绿
- [ ] `pnpm check:diversion` exit 0（新增文案若含平台字样会被门禁拦——保持零导流）
- [ ] `git status` 无 in-scope 外改动；`advisor-plans/README.md` 状态行已更新
      （status 写 `DONE` 并注明「spike 完成，实现待拍板」或直接 DONE）

## STOP conditions

Stop and report back (do not improvise) if:

- plan 008 未合入（WechatClient 不存在）→ 原型部分跳过，文档部分照常完成。
- 官方文档显示 URL Scheme 对本小程序主体类型不开放（个人主体）→ 原型跳过，
  文档记录阻断原因（ICP 清单显示非个人主体，但以官方后台实际权限为准）。
- scheme 配额结论是「无法复用、每次生成」（高配额成本）→ 停在文档层，
  不做原型，把成本模型写进决策清单。
- `useShareAppMessage` 在当前 Taro 4.2.1 版本的类型定义缺失（typecheck 报错且
  无 @types 补救）→ 记录版本约束，跳过前端原型。

## Maintenance notes

- spike 文档是后续实现计划的输入——实现计划应引用其决策清单的拍板结果，
  不要绕过重新调查。
- event-detail 分享 path 与 `paymentLandingUrl`（plan 006）同属「页面路径契约」，
  改 app.config.ts 页面名时两处都要看。
- 若 spike 结论支持 scheme 复用，存储设计（DB 字段 vs cache）在实现计划里定，
  本计划不做存储。
