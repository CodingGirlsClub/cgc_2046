import type { EnrollmentStatus, EnrollmentSummary, OrderKind, OrderSummary } from './models'

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
 * - myOrders 订单状态（R16 状态展示）：报名卡按 enrollment 状态渲染缴费态
 *   （含押金链新增的 forfeited / refund_failed）。
 * - 缴费块三态文案（R10 押金）：详情页免费 / 收费 / 押金共用单一缴费槽，押金态
 *   必含「未到场不退」——R10「报名流程内明示」在小程序的最小落点（详情页承担）。
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
  | 'forfeited'

const POLL_TERMINAL: Record<string, true> = {
  paid: true,
  refunding: true,
  refunded: true,
  refund_failed: true,
  cancelled: true,
  expired: true,
  forfeited: true
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
  expired: '已过期',
  forfeited: '未到场不退'
}

/** 报名缴费态词表（my-enrollments 卡片，payment_pending 新态） */
export const PAYMENT_STATUS_LABEL: Record<string, string> = {
  payment_pending: '待支付',
  paid: '已支付',
  refunding: '退款中',
  refunded: '已退款',
  // 押金链新增：forfeited 是平台首个「终态且不退」，refund_failed 是渠道退款失败
  // （保留报名等待重试）——两者都必须上卡，否则押金去向在学员侧无声消失。
  forfeited: '押金未退（未到场）',
  refund_failed: '退款失败，平台处理中'
}

/** confirmed 报名卡可展示的订单状态白名单（白名单外不出缴费行：expired/cancelled 是作废单，pending 无缴费事实） */
const CARD_ORDER_STATUSES: Record<string, true> = {
  paid: true,
  refunding: true,
  refunded: true,
  forfeited: true,
  refund_failed: true
}

/** 报名名下「有缴费事实」的订单（白名单过滤；缴费文案与 M7 付费卡触点判据共用）。 */
function cardOrdersOf(
  enrollmentId: string,
  orders: readonly Pick<OrderSummary, 'enrollmentId' | 'status'>[]
): Pick<OrderSummary, 'enrollmentId' | 'status'>[] {
  return orders.filter((order) => order.enrollmentId === enrollmentId && CARD_ORDER_STATUSES[order.status])
}

/**
 * M7 付费卡触点判据（#683）：缴费事实报名的 id 集（一次 O(orders) 预分组，
 * 页面 useMemo 后逐卡 O(1) 查 `paidIds.has(id)`）。**不看 enrollment.status**——
 * 退款落定时报名可能已 cancelled，卡上仍应能补订阅授权（配额结转）。
 */
export function paidEnrollmentIds(
  orders: readonly Pick<OrderSummary, 'enrollmentId' | 'status'>[]
): ReadonlySet<string> {
  return new Set(orders.filter((order) => CARD_ORDER_STATUSES[order.status]).map((order) => order.enrollmentId))
}

/**
 * 报名卡缴费文案（R16，单源）：payment_pending 由报名状态自身表达（待支付 + 名额
 * 保留提示）；confirmed 报名只认白名单订单状态（已支付/退款中/已退款/押金未退/
 * 退款失败）——同报名重入多单时取序列中最后一条白名单单，作废单（expired/
 * cancelled）被白名单挡掉不遮蔽真实缴费态；其余（免费/免缴无订单、非 confirmed）
 * → null，页面据此不出缴费行。
 */
export function enrollmentPaymentText(
  enrollment: Pick<EnrollmentSummary, 'id' | 'status'>,
  orders: readonly Pick<OrderSummary, 'enrollmentId' | 'status'>[] = []
): string | null {
  if (enrollment.status === 'payment_pending') {
    return `缴费状态：${PAYMENT_STATUS_LABEL.payment_pending} · 名额已保留，请尽快完成支付`
  }
  if (enrollment.status !== 'confirmed') return null

  const statuses = cardOrdersOf(enrollment.id, orders)
  const latest = statuses[statuses.length - 1]
  return latest ? `缴费状态：${PAYMENT_STATUS_LABEL[latest.status]}` : null
}

/**
 * 取消报名确认弹窗正文（单源；与后端 cancel action 行为逐句对齐）：
 * - payment_pending：释放名额 + 作废待支付订单（无缴费事实，不提退款）。
 * - 押金场已付：截止前自助取消由后端同事务自动退款（enqueue_self_cancel_refunds
 *   CAS paid→refunding 并入队），弹窗不重复承诺——退款规则以卡片常驻行
 *   （「押金：截止前取消全额退；截止后不退。」）为准，与 web participations 同形态。
 * - 定价场已付单：活动开始前自助取消由后端同事务自动全额退款（#543，锚
 *   starts_at），弹窗明示「报名费将全额原路退回」；规则以卡片常驻行为准，
 *   与 web participations 同形态。
 * - 模式不可得的遗留已付单：只释放名额、不触发退款（refundOrder 是组织者
 *   入口），明示联系组织者。
 * - 其余（免费/免缴无订单）：通用句。
 */
export function cancelConfirmCopy(input: {
  status: EnrollmentStatus
  paymentMode: EnrollmentSummary['paymentMode']
  hasPaidOrder: boolean
}): string {
  if (input.status === 'payment_pending') {
    return '取消后将释放名额并作废待支付订单，此操作不可恢复。'
  }
  // #543：定价场已付——活动开始前自助取消，报名费全额原路退回
  if (input.hasPaidOrder && input.paymentMode === 'pricing') {
    return '取消后名额将即时释放，报名费将全额原路退回（活动开始前取消），此操作不可恢复。'
  }
  if (input.hasPaidOrder && input.paymentMode !== 'deposit') {
    return '取消后名额将即时释放，此操作不可恢复。已支付款项不会自动退款，请联系组织者发起退款。'
  }
  return '取消后名额将即时释放，此操作不可恢复。'
}

/**
 * 取消退款规则常驻行（与 web participations 逐字一致；免费场/模式不可得 → null 不出行）。
 * #543：定价场锚活动开始时间（开始前全额退）；押金场锚报名截止（#587）。
 */
export function cancelRefundRuleText(paymentMode: EnrollmentSummary['paymentMode']): string | null {
  if (paymentMode === 'deposit') return '押金：截止前取消全额退；截止后不退。'
  if (paymentMode === 'pricing') return '报名费：活动开始前取消全额退；开始后不退。'
  return null
}

/* ---------------- 押金场支付前同意（资金动作门） ---------------- */

/**
 * 展示金额守卫（#627 引入，本模块为小程序端单源；#675 收敛到此）：
 * **只有正整数**算有效金额，缺失 / 0 / 负 / **小数分** / 非数值一律 null——调用方据此退化
 * 为不表态形态（押金 →「押金（金额待定）」），**绝不显示 ¥0 / ¥0.00**。
 *
 * `Number.isInteger` 是必要的一半：后端以「分」为整数单位，`0.4` 经 `formatAmount`
 * 会四舍五入成 `¥0.00`（实测）——与 web `lib/payment.ts#positiveAmountOrNull` 同判据。
 * 后端已按同判据降级（`Offering.deposit_amount_cents/1`，#586），此处是展示层兜底。
 */
export function positiveAmountOrNull(cents: number | null | undefined): number | null {
  return typeof cents === 'number' && Number.isInteger(cents) && cents > 0 ? cents : null
}

/**
 * 押金金额行（单源）：详情页缴费块与支付页同意块共用同一出口，杜绝两处口径漂移。
 * 脏金额（缺失/0/负/非整数分）→ 不表态「押金（金额待定）」（与 web #627/#675 同一句），
 * 绝不显示 ¥0.00。
 */
function depositAmountLine(amountCents: number | null): string {
  const cents = positiveAmountOrNull(amountCents)
  return cents === null ? '押金（金额待定）' : `押金 ¥${formatAmount(cents)}（到场退）`
}

/** 押金场支付前同意块文案（与 web checkout.depositForfeit / depositAckLabel 同口径） */
export interface DepositPayNotice {
  /** 金额行：「押金 ¥69.00（到场退）」 */
  amountText: string
  /** 不退明示；常显，不随勾选隐藏 */
  forfeitText: string
  /** 勾选文案（付款前的显式确认） */
  ackLabel: string
}

export function depositPayNotice(amountCents: number | null): DepositPayNotice {
  return {
    amountText: depositAmountLine(amountCents),
    forfeitText: '未到场不退。',
    ackLabel: '押金以到场为退还条件：到场核销后原路退回，未到场不予退还。'
  }
}

/**
 * 订单口径解析（后端 `Order.order_kind`，Schema 为 `String!`）。未知值上抛而非
 * 静默降级：资金动作门以它为判据，猜错方向就是「押金单零披露付款」。
 */
export function parseOrderKind(value: string): OrderKind {
  if (value === 'enrollment' || value === 'deposit') return value
  throw new Error(`服务端返回未知订单口径：${value}`)
}

/**
 * 「立即支付」门判据（纯函数；页面只做渲染与调起）：
 * - 押金单（`orderKind === 'deposit'`）：未勾选同意一律不放行（资金动作前的显式
 *   同意，对齐 web 收银框 U1）。
 * - 一般报名单（'enrollment'）：凭据就绪即可支付，零改动。
 * - 订单未就绪（null）：不放行——没有订单就没有可支付的东西。
 *
 * 判据取**订单口径快照**而非活动的实时缴费配置：活动随时可改配置，这一笔不会，
 * 用户同意的是这一笔。
 */
export function canRequestPayment(input: {
  order: Pick<OrderSummary, 'orderKind'> | null
  ack: boolean
  hasCredential: boolean
  paying: boolean
}): boolean {
  if (input.paying || !input.hasCredential || input.order === null) return false
  return input.order.orderKind !== 'deposit' || input.ack
}

/* ---------------- Event 详情缴费块（R10：免费 / 收费 / 押金 单一缴费槽） ---------------- */

/** 详情页缴费块三态文案（R10 单一缴费槽：免费 / 收费 ¥xx / 押金 ¥xx（到场退）） */
export interface PaymentBlockCopy {
  /** 块标题 */
  title: string
  /** 金额行：「免费」/「收费」/「押金 ¥69.00（到场退）」 */
  amountText: string
  /** 定价态档位行；押金/免费态恒空（三态互斥——押金场绝不并列档位） */
  tiers: PriceTier[]
  /** 退改预期说明行；押金态必含「未到场不退」 */
  notes: string[]
}

/**
 * 详情页缴费块文案（R10）。押金态：金额可缺（后端校验要求正金额，缺额/脏值时降级为
 * 「押金（金额待定）」不出价——绝不显示 ¥0.00），且说明行明示「未到场不退」；
 * 定价态透传档位（金额在档位行上，无可售档时给出联系组织者兜底）；免费态仅「免费」。
 */
export function paymentBlockCopy(input: {
  pricingEnabled: boolean
  depositEnabled: boolean
  depositAmountCents: number | null
  priceTiers: PriceTier[]
}): PaymentBlockCopy {
  if (input.depositEnabled) {
    return { title: '缴费', amountText: depositAmountLine(input.depositAmountCents), tiers: [], notes: ['到场核销后原路退回；未到场不退。'] }
  }
  if (input.pricingEnabled) {
    return {
      title: '缴费',
      amountText: '收费',
      tiers: input.priceTiers,
      notes: input.priceTiers.length === 0
        ? ['当前无可售档位，请联系组织者。']
        : ['提交报名后请在限定时间内完成支付。']
    }
  }
  return { title: '缴费', amountText: '免费', tiers: [], notes: [] }
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
