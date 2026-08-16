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

function parseJson(raw: string): unknown {
  try {
    return JSON.parse(raw)
  } catch {
    return null
  }
}
