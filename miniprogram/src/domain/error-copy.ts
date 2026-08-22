/**
 * GraphQL 业务错误 code → 中文文案表（i18n Phase 0）。
 *
 * 后端业务错误经 BusinessError 携带稳定 code（`<resource>_<reason>` snake_case，
 * backend/lib/cgc_2046/errors/business_error.ex）。real.ts 的 createOrder /
 * createEnrollment 错误路径按 code 查本表，命中抛中文，未命中走 mutationError
 * 兜底（join 英文 message）。
 *
 * 与 web 同文案互指：web/lib/payment-errors.ts（i18n Phase 1+ 两端各自换
 * locale 消息文件时同步替换）。
 */

export const COPY: Record<string, string> = {
  // DB 故障统一 code（六文件共用；#241 F4）
  database_error: '服务暂时不可用，请稍后重试。',
  // 重复活跃报名（唯一约束冲突，含并发）
  enrollment_duplicate_active: '你已有待支付订单，请关闭后重新打开继续支付。',
  // 报名已离开 payment_pending（已支付/已取消/已过期）
  enrollment_not_payment_pending: '报名状态已变化（已支付或已取消），请重新报名或查看我的报名。',
  // createOrder 对 stale enrollment（已支付/取消/过期，F2）
  order_not_payment_pending: '报名状态已变化（已支付或已取消），请重新报名或查看我的报名。',
  // 已有活跃订单再下单（unique_active_order 部分索引冲突，含并发，F1）
  order_duplicate_active: '你已有待支付订单，请关闭后重新打开继续支付。',
  // 报名不存在 / 他人报名（不泄露存在性）
  order_enrollment_not_found: '报名不存在或已被处理，请查看我的报名。',
  // 已处理过的报名/订单（幂等保护）
  enrollment_already_processed: '该报名已处理完成，请查看我的报名。',
  order_already_processed: '该订单已处理，请刷新查看状态。',
  // 未签约渠道（adapter 密钥缺失）
  order_provider_not_configured: '该支付渠道暂未开通，请选择其他方式。',
  // 名额 / 报名截止
  enrollment_capacity_full_or_registration_closed: '名额已满，报名已截止。',
  enrollment_target_not_open_or_registration_closed: '报名已截止或活动未开放。',
  // 邀请码
  enrollment_invite_code_required: '该报名需要邀请码，请输入后提交。',
  enrollment_invite_quota_unavailable: '邀请名额已用完，请联系组织者。',
  // 收费档位
  enrollment_tier_id_required: '该报名为收费项，请先选择价格档位。',
  enrollment_tier_not_available: '所选档位已过期或不可用，请重新选择。',
  // 报名 reason 内容安全检查拒绝（plan 009；无平台字样，零导流）
  enrollment_content_rejected: '提交内容未通过安全检查，请修改后重试。',
  // 入参缺 enrollmentId
  order_enrollment_required: '缺少报名信息，请重新发起报名。'
}

/**
 * 按 code 查中文文案；无 code / 未知 code 返回 null（调用方走兜底）。
 */
export function errorCopy(code: string | null | undefined): string | null {
  if (!code) return null
  return COPY[code] ?? null
}
