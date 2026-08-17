/**
 * 支付/报名 GraphQL 错误翻译层（P1 兜底）。
 *
 * 背景：AshGraphql mutation 的 errors[0].message 是后端域错误文案（英文），
 * 全站多处在 role=alert 直接透传原文。本层把已知后端错误码/错误模式映射为
 * 人话；未知一律走调用方兜底，不透传 GraphQL 原文。
 *
 * 覆盖的错误源（backend/lib/cgc_2046/{events/enrollment.ex,payments/order.ex}
 * domain_error_message + Ecto unique_constraint「has already been taken」）。
 */

type ErrorSource = string | null | undefined;

const KNOWN: Array<[RegExp, string]> = [
  // Ecto unique_constraint（createEnrollment 撞唯一索引：同一目标已有活跃报名）
  [/has already been taken/, "你已有待支付订单，请关闭后重新打开继续支付。"],
  // 报名已离开 payment_pending（已支付/已取消/已过期）
  [
    /enrollment is not awaiting payment/,
    "报名状态已变化（已支付或已取消），请重新报名或查看我的报名。",
  ],
  // 报名不存在 / 他人报名（不泄露存在性）
  [/enrollment does not exist/, "报名不存在或已被处理，请查看我的报名。"],
  // 已处理过的报名/订单（幂等保护）
  [
    /enrollment has already been processed/,
    "该报名已处理完成，请查看我的报名。",
  ],
  [/order has already been processed/, "该订单已处理，请刷新查看状态。"],
  // 未签约渠道（adapter 密钥缺失 → {:error, :provider_not_configured} 落
  // inspect 兜底，message 为裸原子）
  [/provider_not_configured/, "该支付渠道暂未开通，请选择其他方式。"],
  // 名额 / 报名截止
  [/capacity is full/, "名额已满，报名已截止。"],
  [
    /target is not open or registration deadline passed/,
    "报名已截止或活动未开放。",
  ],
  // 邀请码
  [/invite code is required/, "该报名需要邀请码，请输入后提交。"],
  [/invite quota is unavailable/, "邀请名额已用完，请联系组织者。"],
  // 收费档位
  [
    /a price tier is required for paid enrollment/,
    "该报名为收费项，请先选择价格档位。",
  ],
  [
    /selected price tier is not available/,
    "所选档位已过期或不可用，请重新选择。",
  ],
  // 入参缺 enrollmentId
  [/enrollment_id is required/, "缺少报名信息，请重新发起报名。"],
];

/**
 * 将 GraphQL 错误 message 翻译为人话。匹配已知模式返回映射文案；
 * 未匹配返回 fallback（不透传原文）。
 */
export function translatePaymentError(
  raw: ErrorSource,
  fallback: string,
): string {
  if (!raw) return fallback;
  const msg = raw.trim().toLowerCase();
  for (const [re, text] of KNOWN) {
    if (re.test(msg)) return text;
  }
  return fallback;
}
