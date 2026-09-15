# UAT Runbook：Event 押金制（真实渠道闭环）

- 日期：2026-09-15
- 范围：`docs/plans/2026-09-14-1357-feat-event-deposit-plan.md` 的 R1–R11 / AE1–AE8（U1–U12）
- 环境：本地 dev（backend :4000 或 :4001，web :3000 或 :3001），数据在 `cgc_2046_dev`

## 前置条件（当前**未满足**，这就是本 runbook 卡住的原因）

真实渠道闭环需要渠道密钥，本机目前**没有** `backend/.env`（只有 `.env.example`）：

```bash
cd backend && cp .env.example .env   # 填 WECHAT_PAY_* / ALIPAY_* 真实值，然后
direnv allow                          # .envrc 会 source .env（set -a 导出）
mix phx.server
```

密钥缺席时的表现已验证：`create_for_enrollment` 在渠道步骤 fail-closed，业务错误
`payment provider is not configured`（订单不落库、不产生渠道调用）。因此：

- 无密钥 → 只能跑到「报名落 `payment_pending` + 生成押金单金额」为止（见下「已自动验证」）。
- 有密钥 → 按下文步骤 3–6 走完真实微信支付、核销当场退与 no-show 结算。

## 已自动验证（2026-09-15，dev 环境实测）

| 项 | 结果 |
|---|---|
| 押金场报名进 `payment_pending`（用户报告的缺口） | ✅ 事件 `0d4657fb…`（open，押金 ¥69）报名后 status=payment_pending（不再直接 confirmed） |
| 报名创建即发 6 位核销码 | ✅ 同一报名 `check_in_code=222570` |
| 押金金额快照 | ✅ `submission_payload={"deposit_amount_cents" => 6900}`（改价不影响在途报名） |
| 下单金额源分派（不再走档位解析） | ✅ 走到渠道步骤才失败，未出现 `order_tier_not_found` |
| 无密钥时 fail-closed | ✅ `payment provider is not configured`，零订单残留 |
| 组织者缴费槽 | ✅ 编辑页 `data-mode=deposit`、文案「Fully refunded after on-site check-in; forfeited for no-shows.」、Initiative 锁死来源提示 |
| 押金场不被误判为免费场（本轮 review 修复） | ✅ 收款面板存在、`offering-free-status` 不出现 |
| no-show 结算锚点 | ✅ 已为 UAT 事件补 `ends_at=2026-09-22` 与 `registration_deadline=2026-09-20`（此前皆空） |

已落下的现场数据（可直接复用）：UAT 事件 `0d4657fb-152b-4b73-b388-0fcd29e37004`，
参与者 `uat_learner_b@cgc2046.uat` 有一条 `payment_pending` 报名（码 `222570`，无押金单）。

## 手动步骤（需要密钥 + 真人微信）

1. **注入密钥**：按上文前置条件建 `backend/.env` 并重启 backend（`direnv allow` 后 `mix phx.server`）。
2. **确认事件**：`/en/w/2046/events/0d4657fb-152b-4b73-b388-0fcd29e37004` 缴费槽为「押金 ¥69（到场退）」，无「免费」并列。
3. **参与者下单**：以 `uat_learner_b@cgc2046.uat` / `Uat2046!pass` 登录 → 该场报名 → 收银框显示 ¥69 →
   用**微信**扫码支付（native 渠道，DEV mock 开关需关闭）。
   预期：支付完成后报名落 `confirmed`，参与者页出现 6 位核销码 + 二维码（勿截图转发提示）。
4. **核销当场退**：以主理人/`uat-owner@cgc2046.local` 打开
   `/en/events/<slug 或 event id>/check-in?code=222570` → 「确认出示者本人在现场」→ Check in。
   预期：成功卡（仅押金场显示「押金退款已发起…」）→ 微信收到退款通知（原路退回，渠道到账按微信周期）；
   `attendances` 新增一行；订单 `paid → refunding → refunded`；**报名保持 confirmed、名额不释放**。
5. **重复核销**：同码再提交 → 「已核销」，不产生第二笔退款 job。
6. **no-show 路径**（可选，需改时钟）：把事件 `ends_at` 改到 49h 前并 `close` → 跑
   `mix run -e 'Cgc2046.Payments.Workers.DepositForfeitWorker.perform(%Oban.Job{})'`（或等 cron 10 分钟一拍）→
   未核销的 paid 押金单落 `forfeited`，管理面出现「未到场不退（平台收入）」统计卡。

## 观测面（人工核对时用）

- DB：`payments_orders(status, order_kind, amount_cents)`、`attendances`、`admin_action_logs(action)`
  （`attendance_check_in` / `attendance_refund` / `deposit_forfeit`）、`reconciliation_findings(rule)`。
- 管理面：`/en/w/2046/payments`（forfeited 卡）、事件编辑页收款面板（默认视图含 `forfeited`）。
- Oban：`deposit_forfeit` cron（`:maintenance`，每 10 分钟）。

## 已知不阻塞项（评审遗留，非本 runbook 步骤）

`ends_at` 可被改早触发批量没收（adversarial P1）、押金场可不填 `registration_deadline`（P2）、
静态二维码可转发（P2，已在文案缓释）、`forfeited` 无人工补救通道（P1）。详见 code review receipt。
