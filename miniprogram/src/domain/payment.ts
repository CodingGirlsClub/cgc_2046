import type { EnrollmentStatus } from './models'

/**
 * 缴费闭环小程序端纯逻辑（plan 024 U12/KTD10）。
 *
 * 轮询/倒计时与 web 端（web/lib/payment.ts）共用逻辑形状——端内各自实现
 * （plan Approach 明示），语义契约一致：2s 间隔 × 30s 总窗（15 次），终态即停，
 * 超窗转手动刷新态。
 *
 * - JSAPI 参数映射（R13）：createOrder metadata.credential（JsonString）→
 *   Taro.requestPayment 的 payment 参数（timeStamp/nonceStr/package/signType/
 *   paySign 五键，后端 wechat_jsapi 凭据 pay_params 直映射）。
 * - myOrders 订单状态（R16 状态展示）：报名卡按 enrollment 状态渲染缴费态。
 */

/* ---------------- 轮询（R14：2s×30s，成功即停；与 web 同契约） ---------------- */

export const POLL_INTERVAL_MS = 2_000
export const POLL_TOTAL_MS = 30_000

/** 轮询推进的订单状态（终态即停；pending 继续） */
export type OrderPollStatus =
  | 'pending'
  | 'paid'
  | 'refunding'
  | 'refunded'
  | 'refund_failed'
  | 'cancelled'
  | 'expired'

const POLL_TERMINAL: Record<string, true> = {
  paid: true,
  refunding: true,
  refunded: true,
  refund_failed: true,
  cancelled: true,
  expired: true
}

export interface PollDecision {
  /** 继续下一轮 */
  continue: boolean
  /** 累计耗时是否已超窗（超窗即转手动刷新态） */
  expiredWindow: boolean
  /** 下一轮延迟；continue=false 时为 null */
  delayMs: number | null
}

/** 轮询决策：elapsed + status → 是否继续 / 是否超窗（纯函数，fake timers 面） */
export function nextPollTick(elapsedMs: number, status: OrderPollStatus): PollDecision {
  const expiredWindow = elapsedMs >= POLL_TOTAL_MS

  if (POLL_TERMINAL[status]) {
    return { continue: false, expiredWindow, delayMs: null }
  }
  if (expiredWindow) {
    return { continue: false, expiredWindow: true, delayMs: null }
  }
  return { continue: true, expiredWindow: false, delayMs: POLL_INTERVAL_MS }
}

/* ---------------- JSAPI 凭据 → Taro.requestPayment 参数（R13） ---------------- */

/** Taro.requestPayment 的 payment 参数（微信 JSAPI 五键契约） */
export interface RequestPaymentArgs {
  timeStamp: string
  nonceStr: string
  package: string
  signType: string
  paySign: string
}

export type PaymentCredentialDispatch =
  | { mode: 'jsapi'; args: RequestPaymentArgs }
  | { mode: 'unsupported'; reason: string }

/**
 * createOrder metadata.credential → requestPayment 参数。
 * 后端凭据形状（U4 契约）：`%{"type" => "jsapi", "pay_params" => %{appId,
 * timeStamp, nonceStr, package, signType, paySign}}`——五键直映射（appId 由
 * 微信侧注入，不进 payment 参数）。JsonString 或对象均可入。
 */
export function mapPaymentCredential(credential: unknown): PaymentCredentialDispatch {
  const parsed = typeof credential === 'string' ? parseJson(credential) : credential
  if (!parsed || typeof parsed !== 'object') {
    return { mode: 'unsupported', reason: '支付凭据缺失' }
  }

  const outer = parsed as Record<string, unknown>
  if (outer.type !== 'jsapi') {
    return { mode: 'unsupported', reason: '非小程序支付凭据' }
  }

  const params = outer.pay_params
  if (!params || typeof params !== 'object') {
    return { mode: 'unsupported', reason: '支付参数缺失' }
  }

  const p = params as Record<string, unknown>
  const timeStamp = p.timeStamp
  const nonceStr = p.nonceStr
  const pkg = p.package
  const signType = p.signType
  const paySign = p.paySign

  if (
    typeof timeStamp !== 'string' || !timeStamp ||
    typeof nonceStr !== 'string' || !nonceStr ||
    typeof pkg !== 'string' || !pkg ||
    typeof signType !== 'string' || !signType ||
    typeof paySign !== 'string' || !paySign
  ) {
    return { mode: 'unsupported', reason: '支付参数不完整' }
  }

  return { mode: 'jsapi', args: { timeStamp, nonceStr, package: pkg, signType, paySign } }
}

/* ---------------- 倒计时（R6：expire_at，mm:ss） ---------------- */

export function countdownText(nowMs: number, expireAt: string | null | undefined): string {
  if (!expireAt) return '—'
  const end = new Date(expireAt).getTime()
  if (Number.isNaN(end)) return '—'
  const remain = end - nowMs
  if (remain <= 0) return '已过期'
  const totalSec = Math.floor(remain / 1000)
  const mm = Math.floor(totalSec / 60)
  const ss = totalSec % 60
  return `${String(mm).padStart(2, '0')}:${String(ss).padStart(2, '0')}`
}

/* ---------------- 价格档位（R1/R2：availablePriceTiers JsonString 数组） ---------------- */

export interface PriceTier {
  id: string
  name: string
  amountCents: number
}

/** 可售档位逐项解析（后端已过滤过期档）；非法项静默丢弃 */
export function parsePriceTiers(raw: string[] | null | undefined): PriceTier[] {
  if (!Array.isArray(raw)) return []

  return raw.flatMap((item) => {
    const parsed = parseJson(item)
    if (!parsed || typeof parsed !== 'object') return []
    const t = parsed as Record<string, unknown>
    if (typeof t.id !== 'string' || typeof t.name !== 'string') return []
    if (typeof t.amount_cents !== 'number' || !Number.isFinite(t.amount_cents)) return []
    return [{ id: t.id, name: t.name, amountCents: t.amount_cents }]
  })
}

/* ---------------- 展示格式化（单源，页面一律 import） ---------------- */

/** 分 → 元（两位小数，R20 存储一律分） */
export function formatAmount(cents: number): string {
  return (cents / 100).toFixed(2)
}

/** 订单状态词表（my-enrollments 缴费态 + order-pay 页共用） */
export const ORDER_STATUS_LABEL: Record<string, string> = {
  pending: '待支付',
  paid: '已支付',
  refunding: '退款中',
  refunded: '已退款',
  refund_failed: '退款失败',
  cancelled: '已取消',
  expired: '已过期'
}

/** 报名缴费态词表（my-enrollments 卡片，payment_pending 新态） */
export const PAYMENT_STATUS_LABEL: Record<string, string> = {
  payment_pending: '待支付',
  paid: '已支付',
  refunding: '退款中',
  refunded: '已退款'
}

// 收费报名提交后的落地页：weapp 进支付页（weapp 用户不经此函数到结果页）；
// 裁剪端（tt/xhs）无小程序内支付，回结果页——结果页渲染 payment_pending 待支付
// 分支（裁剪端附网页端支付引导）；weapp 落到结果页时该分支亦作兜底。
export function paymentLandingUrl(enrollmentId: string, isWeapp: boolean): string {
  if (isWeapp) return `/pages/order-pay/index?enrollmentId=${enrollmentId}`
  return `/pages/enrollment-result/index?id=${enrollmentId}`
}

/** 报名结果页文案（enrollment-result 状态→文案映射；payment_pending 含裁剪端网页端支付引导） */
export interface EnrollmentResultCopy {
  title: string
  subtitle: string
}

export function enrollmentResultCopy(status: EnrollmentStatus, isWeapp: boolean): EnrollmentResultCopy {
  if (status === 'pending') {
    return {
      title: '等待审批',
      subtitle: '组织者会在审批截止前处理，你可以在「我的报名」查看倒计时。'
    }
  }
  if (status === 'payment_pending') {
    return {
      title: `${PAYMENT_STATUS_LABEL.payment_pending} · 名额已保留，请尽快完成支付`,
      subtitle: isWeapp
        ? '名额已保留，请尽快完成支付。'
        : '请在网页端完成支付（本端暂不支持支付调起）。'
    }
  }
  return { title: '报名成功', subtitle: '名额已经确认，记得按时参加。' }
}

function parseJson(raw: string): unknown {
  try {
    return JSON.parse(raw)
  } catch {
    return null
  }
}
