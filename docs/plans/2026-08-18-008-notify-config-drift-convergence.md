# 通知配置面漂移收敛（issue #231）：learning_stagnation prod 静默失败修复 + 三面键集锚定

> 来源：issue #231 + advisor10 评审发现（PR #207 评审链）+ 005 registry 计划 D5「config 面只加 D7 双射锚定，不做跨面收敛」的后续项。
> 状态：待人工批准（sop plan mode）
> 日期：2026-08-18

## 目标

修复一个已实锤的 prod 静默失败：`learning_stagnation` 模板键在 `config.exs` 声明、`@notification_types` registry 锚定（活跃场景），但 `runtime.exs`（prod 块）**未注入**——Elixir config 同 key 整体覆盖 → prod 该场景 `{:error, :template_not_configured}` 静默失败（不崩 boot）。同时把「三面键集一致」变成 CI 强制断言，防止复发。

### Out of scope（005 D5 已拍板 + issue 范围）

- **event_reminder 幽灵键**：前端订阅场景键、后端三端均无——005 D5 已裁定「仅记录为 advisory，前端删键或后端补键是产品决策，不塞本 PR」，维持不修
- NotificationFanout / NotificationService / Miniprogram.Client 主体——005 D5「不收边界」，不动
- 前端订阅弹窗场景、订阅模板前端 env 面（CGC_* 是前端构建面，语义独立，仅文档措辞修正）
- 平台后台申请模板 ID（运维动作，部署时）

## Current-state 证据（2026-08-18 develop 核实）

- `backend/config/config.exs:66-106` — `:miniprogram_templates` 三端各 **10 键**（含 `learning_stagnation`，dev/test 占位）：approval_result / approval_reminder / enrollment_submitted / enrollment_completed / speaker_accepted / speaker_completed / learning_stagnation / payment_succeeded / refund_succeeded / refund_failed
- `backend/config/runtime.exs:147-184` — prod 块三端各 **9 键**，`learning_stagnation` **零注入**（grep = 0）；模板段 `fetch_env!` 计数 27（config 应为 30）
- `backend/lib/cgc_2046/workers/notification_worker.ex:106` — registry `@notification_types` 含 `template_key: "learning_stagnation"`（活跃：`stale` 条目 {WorkflowRun, :running} 停滞提醒）
- 传播链（prod）：`learning_progress_worker.ex:187` 发送 → `notification_worker.ex` registry 映射 → `notification_service.ex:36-37` template_id 查空 → `{:error, :template_not_configured}` → **静默失败**（Oban 重试耗尽丢弃）
- **D7 双射测试缺口**：`backend/test/cgc_2046/workers/notification_worker_test.exs:52-78` 只锚 `Application.get_env(:miniprogram_templates)`（config.exs 编译期值）↔ registry——**不覆盖 runtime.exs prod 块**，故上述漂移 CI 全绿（漂移已存在但测试看不见）
- 文档措辞：`miniprogram/e2e/DOUYIN_REDNOTE_CHECKLIST.md:12`「小红书走服务通知，无需模板 ID」——真实语义是「前端无授权弹窗无需**前端**模板 ID」；后端服务通知仍需 `XHS_MP_TEMPLATE_*` 9 键 `fetch_env!`（缺一 boot 崩）。措辞歧义会误导运维少配 xhs 键

## 设计

| 决策 | 方案 | 理由 |
|---|---|---|
| learning_stagnation 处置 | **runtime.exs 补注入三端 3 键**（WECHAT/TT/XHS_MP_TEMPLATE_LEARNING_STAGNATION，`fetch_env!`） | registry 已锚该场景为活跃（005 D7 测试），后端应能下发；补键让 prod 恢复真实发送；「场景降级」= 删 registry 条目 + 停 worker 场景，是产品决策且改动面更大，不选 |
| 复发防护 | **D7 双射测试扩展到 runtime.exs prod 键集** | 当前测试看不见 prod 面漂移；扩展后三面（registry / config.exs / runtime.exs prod）一致成为 CI 强制，任何一面删键/漏配即红 |
| xhs 文档措辞 | 修正 DOUYIN checklist:12 表述 | 消除运维误读（前端无弹窗 ≠ 后端无需配置） |
| event_reminder | 维持 005 advisory，仅文档注记 | 005 D5 已拍板，产品决策不塞本 PR |

**拒绝的替代**：场景降级（删 registry 条目 + 停 worker 路径）——learning_stagnation 是已交付的活跃功能（停滞提醒），降级是产品行为回退；「只在文档记录不修 runtime」——漂移保留且无 CI 锚，复发风险不消除。

## 影响面

- 后端修改：`backend/config/runtime.exs`（+3 键，`fetch_env!`）
- 后端测试：`backend/test/cgc_2046/workers/notification_worker_test.exs`（双射测试扩展 runtime 键集锚定）
- 文档：`miniprogram/e2e/DOUYIN_REDNOTE_CHECKLIST.md:12`（措辞修正）；CONTEXT.md「通知类型」词条可选补一句「runtime prod 键集 = registry 键集（D7 锚定）」
- 运维影响：**上线新增 3 个 env**（WECHAT_MP_TEMPLATE_LEARNING_STAGNATION / TT_MP_TEMPLATE_LEARNING_STAGNATION / XHS_MP_TEMPLATE_LEARNING_STAGNATION），缺失即 boot 失败（fetch_env! 语义，fail-fast 优于静默）
- 无数据库变更、无 schema 变更、无生产数据写入

## Phases（测试先行，每 phase 独立可验证）

### P1 双射测试扩展（先红）
测试先行：`notification_worker_test.exs` 双射测试（:52-78）增加 **runtime prod 面锚定**——用与 config.exs 相同的方式读 `runtime.exs` 的 prod 块（`System.get_env` 不可行，测试读源码文件解析键名或抽取共享键集常量），断言 `runtime_keys == config_keys == registry_keys`。**先写测试看红**（当前 runtime 缺 learning_stagnation，断言必失败），证明测试真能抓住漂移。
实现提示：runtime.exs 的 prod 块在 `config_env() == :prod` 分支——测试不能直接读 runtime env（test env 不执行 prod 块）。方案：a) 测试解析 `runtime.exs` 文本提取 `*_MP_TEMPLATE_*` env 键名集合（静态断言源码，防漏配）；b) 或抽一个共享的「键集常量」模块（config.exs 与 runtime.exs 都用它定义键集，测试锚该常量）。**推荐 b**（常量单点：`backend/lib/cgc_2046/notification_template_keys.ex`，`@keys` 列表 + 三端前缀，config/runtime 用它生成 map 键，测试断言 `Map.keys(config map) == Keys.list()` 且 runtime 文本/常量一致）。若 b 需要改 config.exs 结构（风险小，两文件同 commit），按实际选 a 或 b 并在报告说明。
验证：`MIX_ENV=test mix test test/cgc_2046/workers/notification_worker_test.exs` 先红（当前漂移被抓住）后转绿（P2 补键后）。

### P2 runtime.exs 补 learning_stagnation（转绿）
`backend/config/runtime.exs` 三端各补一行：
`"learning_stagnation" => System.fetch_env!("WECHAT_MP_TEMPLATE_LEARNING_STAGNATION")`（tt/xhs 同理，前缀 TT_/XHS_）。
验证：P1 测试转绿；`grep -c learning_stagnation runtime.exs` = 3；模板段 `fetch_env!` 计数 27 → 30。

### P3 文档措辞 + 收尾
DOUYIN_REDNOTE_CHECKLIST.md:12 改：「小红书走服务通知——前端无授权弹窗，**无需前端模板 ID**；但后端服务通知仍需配置 `XHS_MP_TEMPLATE_*`（9 键，`fetch_env!` 缺一 boot 失败）」。CONTEXT.md「通知类型」词条若存在补一句 runtime 锚定说明。
全量自查：`mix format --check-formatted` + `mix compile --warnings-as-errors` + `MIX_ENV=test mix test` ×2 seeds 全绿。

## 检查与回滚

- 构建/运行时：全量 mix test 两 seeds；CI 4 job 预期全绿
- 功能：learning_stagnation prod 路径从 `:template_not_configured` 恢复为真实发送（依赖部署时 env 配置）
- 安全：无新凭据处理（新增 env 是模板 ID，非密钥）；fetch_env! 缺失 fail-fast（比静默好，明确运维责任）
- 回滚：纯增量（runtime.exs 3 行 + 测试 + 文档）——`git revert` 单 PR 可回；回滚后 prod 回到静默失败旧态（可接受，因为那是现状）
- 并发：无

## Signoff criteria

- P1 红→绿轨迹在报告记录（证明测试真锁漂移）
- runtime.exs learning_stagnation = 3、fetch_env! 计数 30
- 全量 mix test 两 seeds 绿；DOUYIN checklist 措辞修正落档
- PR 经独立评审 PASS 后合并

## 待人工决策（批准本计划即视为按推荐执行）

- **D-1**：learning_stagnation 补注入（推荐——registry 已锚活跃场景，补键恢复真实发送；新增 3 个上线 env 由运维清单承载）vs 场景降级（删 registry 条目，产品行为回退，不推荐）
- **D-2**：xhs checklist 措辞修正（推荐——消除运维误读，纯文档）vs 不改（保留歧义，不推荐）
