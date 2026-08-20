# Plan 2026-08-20-009 · #219：权限上线签核包起草

## 背景

#208 权限审计线的最终 gate。`docs/signoff/` 仅 1 份签核（Slice E）；MCP 鉴权、确认流、RBAC 契约、前端门控均无签核；7 份权限相关 plan（017-023）代码已落地、语义变更无人签收。#215/#217 已合并（blocker 清零），签核内容已收敛定稿。

## 决策

- 单一签核文档 `docs/signoff/2026-08-20-002-permissions-launch.md`，frontmatter 对齐既有模板（title/type/date/status: pending-signoff/reference/topic）。
- **数据从代码/测试生成，不手写**：MCP 15 工具矩阵从 `server.ex` + `wrapper_gate_test.exs` 转录；RBAC 矩阵从 `priv/rbac_contract.json` 转录；每条带 file:line/PR 溯源。
- 三档阅读结构（用户已确认）：第一档必读（豁免确认 + plan 语义补签 + 工具面边界确认，checkbox）；第二档抽查（矩阵/CI 链接）；第三档可略（转录性内容）。
- 签收协议：用户改 checkbox + 签名行 → agent commit → 关 #219；异议走 #219 评论。

## 实施单元

### U1 文档骨架 + 六部分

1. **Executive Summary**：审计来源（2026-08-18 四路 scout + 后续收敛线）、当前状态（全部 blocker 已关）、签收范围声明。
2. **MCP 15 工具授权矩阵**（第一档/第二档）：工具 ×（meta 声明 / 鉴权链 / 确认流 / 审计 / 测试），从 wrapper_gate_test.exs 豁免名单 + server.ex 生成；D7 工具面边界确认段（明确不进 MCP 的：update_join_policy/删除类/create_agent/create_workflow/reply_learner_question——#211 裁决落文）。含确认流语义（TTL 10min/并发恰一次/失败回滚/auto_approve 未实现声明）。
3. **RBAC 8 能力矩阵**（第二档）：从 rbac_contract.json 转录五角色 × 八能力 + golden-file 双端守卫说明（CI --check + web contract test）+ manage_events 刚收敛的说明（#261）。
4. **前端门控清单**（第三档）：页面 ×（myAbilities 消费 / AdminGuard / 后端兜底 policy），转录自审计；标注 #215 后内容管理域已切能力。
5. **已知豁免/偏差清单**（第一档，重点）：MCP membership 门不认 platform_admin；join_request_not_found 存在性探测 tradeoff（#260）；token 闲置过期客户端时钟展示（#257）；连接 token 无固定 TTL（滚动过期 #222）；ToolCallLog 承担审计（AgentRun 不落地 #211 裁决 2/3）；#217 后的旁路读取真实分布。
6. **7 份 plan 语义摘要**（第一档）：017 member 退役 / 018 平台管理员只读 / 019 activity 加固 / 020 learner 输出环 / 021 slice E 收口 / 022 email CD / 023 小修——每份 3-5 行语义变更摘要 + PR/commit 溯源。

### U2 证据链

- 每部分末尾 Evidence 段：测试文件清单 + 本签名时点 CI run 链接（PR #260/#261 checks 或 develop 最新 run）。
- 附 Roster 段（对齐 Slice E 模板）。

### U3 issue 侧

- PR 合并后在 #219 评论：文档路径 + 三档阅读指引 + 签收方式（改 checkbox + 签名 → 回复 agent 收尾）。
- label ready-for-agent → ready-for-human。

## 验收标准

1. 文档六部分齐全，15 工具 × 5 列矩阵完整无 TBD。
2. 每条第一档签收项有证据链接；豁免清单含上述 6 条已知项。
3. 数字与代码一致：15 工具（server.ex）、8 能力（rbac_contract.json）、五角色。
4. backend format/compile/test 全绿（纯文档线，零代码改动）+ `mix cgc2046.gen_rbac_contract --check` 过（转录一致性旁证）。
5. #219 评论就绪、label 已转 ready-for-human。

## 非目标

- 不改任何代码/测试（纯文档 PR）。
- 不代替用户签收（checkbox 留空）。
- 不重跑全量审计（复用四轮 scout + advisor 存量证据）。

## 风险

| 风险 | 缓解 |
|---|---|
| 手写矩阵与代码漂移 | U1 从测试/golden-file 转录 + advisor09 逐格核对 |
| plan 摘要失真（017-023 未重读） | writer 必须读每份 plan 的决策段再摘要，禁抄 issue 标题 |
| 豁免清单遗漏 | 6 条已知项 + advisor09 对照历轮 advisory 补漏 |

## 关联

Issue #219（目标）；前置 #209/#211/#214/#215/#217 全 MERGED；审计源 `agent://McpToolAuth` 等四 scout + #208 body。
