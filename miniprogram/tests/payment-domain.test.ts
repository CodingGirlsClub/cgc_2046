import assert from 'node:assert/strict'
import test from 'node:test'
import { BusinessError } from '../src/api/business-error.ts'
import {
  ORDER_STATUS_LABEL,
  PAYMENT_STATUS_LABEL,
  canRequestPayment,
  cancelConfirmCopy,
  countdownText,
  createOrderSelfHealsToConsent,
  depositPayNotice,
  cancelRefundRuleText,
  enrollmentPaymentText,
  enrollmentResultCopy,
  formatAmount,
  mapPaymentCredential,
  nextPollTick,
  parsePriceTiers,
  paymentBlockCopy,
  paymentLandingUrl,
  preCreateDepositGate,
  parseOrderKind,
  positiveAmountOrNull,
  POLL_INTERVAL_MS,
  POLL_TOTAL_MS
} from '../src/domain/payment.ts'
import { parseEnrollmentStatus } from '../src/domain/format.ts'

const jsapiCredential = JSON.stringify({
  type: 'jsapi',
  pay_params: {
    appId: 'wx-123',
    timeStamp: '1723800000',
    nonceStr: 'nonce-abc',
    package: 'prepay_id=wx123456',
    signType: 'RSA',
    paySign: 'sig-value'
  }
})

test('payParams → requestPayment 参数映射：五键直映射，appId 不进参数', () => {
  const dispatch = mapPaymentCredential(jsapiCredential)
  assert.equal(dispatch.mode, 'jsapi')
  if (dispatch.mode !== 'jsapi') return
  assert.deepEqual(dispatch.args, {
    timeStamp: '1723800000',
    nonceStr: 'nonce-abc',
    package: 'prepay_id=wx123456',
    signType: 'RSA',
    paySign: 'sig-value'
  })
  assert.equal('appId' in dispatch.args, false)
})

test('凭据异常分支：非 jsapi / 缺 pay_params / 缺键 / 坏 JSON → unsupported 不 throw', () => {
  assert.deepEqual(mapPaymentCredential(JSON.stringify({ type: 'qr_code' })), {
    mode: 'unsupported',
    reason: '非小程序支付凭据'
  })
  assert.deepEqual(mapPaymentCredential(JSON.stringify({ type: 'jsapi' })), {
    mode: 'unsupported',
    reason: '支付参数缺失'
  })
  // 缺 paySign
  const broken = JSON.parse(jsapiCredential) as Record<string, { paySign?: string }>
  delete (broken.pay_params as Record<string, unknown>).paySign
  const dispatch = mapPaymentCredential(JSON.stringify(broken))
  assert.equal(dispatch.mode, 'unsupported')
  assert.equal(dispatch.reason, '支付参数不完整')
  // 对象直传 / null / 坏 JSON
  assert.equal(mapPaymentCredential(null).mode, 'unsupported')
  assert.equal(mapPaymentCredential('not-json').mode, 'unsupported')
  // 对象直传等价
  assert.equal(
    mapPaymentCredential(JSON.parse(jsapiCredential) as unknown).mode,
    'jsapi'
  )
})

test('轮询契约与 web 端一致：2s×30s，pending 持续、终态即停、超窗手动态', () => {
  assert.equal(POLL_INTERVAL_MS, 2000)
  assert.equal(POLL_TOTAL_MS, 30000)

  // pending 未到窗：继续 + 2s 延迟
  for (const elapsed of [0, 2000, 8000, 28000]) {
    assert.deepEqual(nextPollTick(elapsed, 'pending'), {
      continue: true,
      expiredWindow: false,
      delayMs: 2000
    })
  }
  // 到窗：停 + 超窗
  assert.deepEqual(nextPollTick(30000, 'pending'), {
    continue: false,
    expiredWindow: true,
    delayMs: null
  })
  // 终态即停（任意时刻）
  for (const status of ['paid', 'refunded', 'expired', 'cancelled'] as const) {
    const tick = nextPollTick(0, status)
    assert.equal(tick.continue, false)
    assert.equal(tick.delayMs, null)
  }
})

test('倒计时：mm:ss 渲染与过期态', () => {
  const expireAt = '2026-08-16T12:00:00Z'
  assert.equal(countdownText(Date.parse('2026-08-16T11:59:30Z'), expireAt), '00:30')
  assert.equal(countdownText(Date.parse('2026-08-16T11:41:05Z'), expireAt), '18:55')
  assert.equal(countdownText(Date.parse('2026-08-16T12:00:01Z'), expireAt), '已过期')
  assert.equal(countdownText(0, null), '—')
  assert.equal(countdownText(0, 'not-a-date'), '—')
})

test('档位解析：availablePriceTiers JsonString 数组，非法项丢弃', () => {
  const raw = [
    JSON.stringify({ id: 't1', name: '早鸟', amount_cents: 9900 }),
    JSON.stringify({ id: 't2', name: '标准', amount_cents: 19900 }),
    'broken',
    JSON.stringify({ id: 't3' })
  ]
  assert.deepEqual(parsePriceTiers(raw), [
    { id: 't1', name: '早鸟', amountCents: 9900 },
    { id: 't2', name: '标准', amountCents: 19900 }
  ])
  assert.deepEqual(parsePriceTiers(null), [])
})

// #687：脏金额（缺失/0/负/非整数分/null）不丢档——amountCents 落 null，
// 渲染层据此「金额待定」+ 禁选；只有缺身份（id/name）才整档丢弃。
test('档位金额脏 → 档位保留 amountCents null（positiveAmountOrNull 判据，#687）', () => {
  const raw = [
    JSON.stringify({ id: 't-clean', name: '标准', amount_cents: 19900 }),
    JSON.stringify({ id: 't-missing', name: '缺额档' }),
    JSON.stringify({ id: 't-zero', name: '零档', amount_cents: 0 }),
    JSON.stringify({ id: 't-neg', name: '负档', amount_cents: -100 }),
    JSON.stringify({ id: 't-frac', name: '非整档', amount_cents: 0.4 }),
    JSON.stringify({ id: 't-null', name: '空额档', amount_cents: null })
  ]
  assert.deepEqual(parsePriceTiers(raw), [
    { id: 't-clean', name: '标准', amountCents: 19900 },
    { id: 't-missing', name: '缺额档', amountCents: null },
    { id: 't-zero', name: '零档', amountCents: null },
    { id: 't-neg', name: '负档', amountCents: null },
    { id: 't-frac', name: '非整档', amountCents: null },
    { id: 't-null', name: '空额档', amountCents: null }
  ])
})

test('金额分→元两位小数；订单/缴费状态词表覆盖 plan R16 状态面', () => {
  assert.equal(formatAmount(19900), '199.00')
  assert.equal(formatAmount(1), '0.01')

  assert.equal(ORDER_STATUS_LABEL.pending, '待支付')
  assert.equal(ORDER_STATUS_LABEL.paid, '已支付')
  assert.equal(ORDER_STATUS_LABEL.refunded, '已退款')
  assert.equal(PAYMENT_STATUS_LABEL.payment_pending, '待支付')
  assert.equal(PAYMENT_STATUS_LABEL.paid, '已支付')
  assert.equal(PAYMENT_STATUS_LABEL.refunded, '已退款')
})

// ── U11（R10）：详情页缴费块三态文案 ──

test('缴费块三态：免费/收费/押金各一态，押金态含「未到场不退」且不并列档位与「免费」', () => {
  const tiers = [{ id: 't1', name: '早鸟', amountCents: 9900 }]

  assert.deepEqual(
    paymentBlockCopy({ pricingEnabled: false, depositEnabled: false, depositAmountCents: null, priceTiers: [] }),
    { title: '缴费', amountText: '免费', tiers: [], notes: [] }
  )

  const pricing = paymentBlockCopy({
    pricingEnabled: true,
    depositEnabled: false,
    depositAmountCents: null,
    priceTiers: tiers
  })
  assert.equal(pricing.amountText, '收费')
  assert.deepEqual(pricing.tiers, tiers)
  // 无可售档兜底（既有详情页文案不回归）
  assert.deepEqual(
    paymentBlockCopy({ pricingEnabled: true, depositEnabled: false, depositAmountCents: null, priceTiers: [] }).notes,
    ['当前无可售档位，请联系组织者。']
  )

  const deposit = paymentBlockCopy({
    pricingEnabled: false,
    depositEnabled: true,
    depositAmountCents: 6900,
    priceTiers: tiers
  })
  assert.equal(deposit.amountText, '押金 ¥ 69.00（到场退）')
  assert.equal(deposit.amountText.includes('免费'), false)
  assert.deepEqual(deposit.tiers, [])
  assert.equal(deposit.notes.some((note) => note.includes('未到场不退')), true)

  // 金额缺失（后端校验兜底）：降级为**不表态**（#675：与 web #627 同一句），也不并列「免费」
  assert.equal(
    paymentBlockCopy({ pricingEnabled: false, depositEnabled: true, depositAmountCents: null, priceTiers: [] })
      .amountText,
    '押金（金额待定）'
  )

  // 0/负数/非整数分同守卫（后端校验 min 1，纯合同对齐）：不表态——绝不显示 ¥0.00
  for (const invalid of [0, -500, 0.4]) {
    const amountText = paymentBlockCopy({
      pricingEnabled: false,
      depositEnabled: true,
      depositAmountCents: invalid,
      priceTiers: []
    }).amountText
    assert.equal(amountText, '押金（金额待定）')
    assert.equal(amountText.includes('¥0'), false)
  }
})

// ── #675：金额守卫迁到缴费域后的小程序端单源 ──

test('positiveAmountOrNull：只有正整数算有效金额，脏值（0/负/小数分/非数值）一律 null', () => {
  for (const dirty of [null, undefined, 0, -1, -500, 0.4, 0.5, Number.NaN, Number.POSITIVE_INFINITY]) {
    assert.equal(positiveAmountOrNull(dirty as number | null | undefined), null)
  }
  // 字符串金额不是契约内输入（GraphQL Int），不得被当数字放过
  assert.equal(positiveAmountOrNull('6900' as unknown as number), null)
  assert.equal(positiveAmountOrNull(1), 1)
  assert.equal(positiveAmountOrNull(6900), 6900)
  // 0.4 经 formatAmount 会渲染成 ¥0.00——这正是守卫必须挡它的原因（可复现）
  assert.equal(formatAmount(0.4), '0.00')
})

test('报名状态解析：payment_pending 是合法白名单值，不抛错（plan 006 回归钉）', () => {
  assert.equal(parseEnrollmentStatus('payment_pending'), 'payment_pending')
  // 既有白名单值不回归
  assert.equal(parseEnrollmentStatus('pending'), 'pending')
  assert.equal(parseEnrollmentStatus('confirmed'), 'confirmed')
  // 未知值仍 fail-closed
  assert.throws(() => parseEnrollmentStatus('bogus'), /未知报名状态/)
})

test('收费报名落地页：weapp 进支付页，裁剪端回结果页（plan 006 平台守卫）', () => {
  assert.equal(
    paymentLandingUrl('enr-1', true),
    '/pages/order-pay/index?enrollmentId=enr-1'
  )
  assert.equal(
    paymentLandingUrl('enr-1', false),
    '/pages/enrollment-result/index?id=enr-1'
  )
})

test('报名结果页文案：payment_pending 按平台分派（裁剪端中性、wechat 催付）', () => {
  // 裁剪端（tt/xhs）无端内支付：只陈述事实——既不引导去网页端（零导流），
  // 也不催「请尽快完成支付」（本端没有可完成支付的入口）
  for (const platform of ['tt', 'xhs'] as const) {
    const copy = enrollmentResultCopy('payment_pending', platform)
    assert.deepEqual(copy, {
      title: '待支付 · 名额已为你保留',
      subtitle: '缴费报名暂未在本端开放。'
    })
    assert.ok(!`${copy.title}${copy.subtitle}`.includes('网页端'))
    assert.ok(!`${copy.title}${copy.subtitle}`.includes('请尽快完成支付'))
  }
  // wechat 兜底：无网页端引导文案
  assert.deepEqual(enrollmentResultCopy('payment_pending', 'wechat'), {
    title: '待支付 · 名额已保留，请尽快完成支付',
    subtitle: '名额已保留，请尽快完成支付。'
  })
  // 既有 pending/confirmed 文案不回归
  assert.equal(enrollmentResultCopy('pending', 'tt').title, '等待审批')
  assert.equal(enrollmentResultCopy('confirmed', 'tt').title, '报名成功')
})

test('报名卡缴费文案：payment_pending 在裁剪端不催付（与结果页同口径）', () => {
  // 存量待支付报名（P0 前在裁剪端创建、或同手机号在微信端创建）会出现在裁剪端「我的报名」
  assert.equal(
    enrollmentPaymentText({ id: 'e1', status: 'payment_pending' }, [], 'xhs'),
    '缴费状态：待支付 · 名额已为你保留'
  )
  assert.equal(
    enrollmentPaymentText({ id: 'e1', status: 'payment_pending' }, [], 'tt'),
    '缴费状态：待支付 · 名额已为你保留'
  )
  // 微信端（缺省）维持催付——端内有「去支付」
  assert.equal(
    enrollmentPaymentText({ id: 'e1', status: 'payment_pending' }),
    '缴费状态：待支付 · 名额已保留，请尽快完成支付'
  )
})

test('取消弹窗文案：payment_pending 作废待支付订单，不提退款', () => {
  assert.equal(
    cancelConfirmCopy({ status: 'payment_pending', paymentMode: 'pricing', hasPaidOrder: false }),
    '取消后将释放名额并作废待支付订单，此操作不可恢复。'
  )
})

test('取消弹窗文案：押金场已付 → 通用句（自动退款承诺由卡片常驻规则行承载，弹窗不重复）', () => {
  // 后端 cancel action 截止前自助取消同事务 CAS paid→refunding 并入队退款——
  // 弹窗若再说「不会自动退款」即与行为相反（本修复的反例）
  assert.equal(
    cancelConfirmCopy({ status: 'confirmed', paymentMode: 'deposit', hasPaidOrder: true }),
    '取消后名额将即时释放，此操作不可恢复。'
  )
})

test('取消弹窗文案：定价场已付单 → 明示报名费全额退回（#543）；模式不可得 → 联系组织者', () => {
  // #543：定价场活动开始前自助取消，后端同事务全额退款
  assert.equal(
    cancelConfirmCopy({ status: 'confirmed', paymentMode: 'pricing', hasPaidOrder: true }),
    '取消后名额将即时释放，报名费将全额原路退回（活动开始前取消），此操作不可恢复。'
  )
  // 模式不可得（null）但存在已付单：不承诺自动退款
  assert.equal(
    cancelConfirmCopy({ status: 'confirmed', paymentMode: null, hasPaidOrder: true }),
    '取消后名额将即时释放，此操作不可恢复。已支付款项不会自动退款，请联系组织者发起退款。'
  )
})

test('取消弹窗文案：无已付单（免费/免缴/押金未付）→ 通用句', () => {
  for (const paymentMode of ['free', 'pricing', 'deposit', null] as const) {
    assert.equal(
      cancelConfirmCopy({ status: 'confirmed', paymentMode, hasPaidOrder: false }),
      '取消后名额将即时释放，此操作不可恢复。'
    )
  }
  assert.equal(
    cancelConfirmCopy({ status: 'pending', paymentMode: 'free', hasPaidOrder: false }),
    '取消后名额将即时释放，此操作不可恢复。'
  )
})

test('押金退改规则常驻行：仅押金场出行（与 web depositRefundRule 逐字一致）', () => {
  // #543：定价场常驻行 = 活动开始前全额退；押金场维持 #587 口径
  assert.equal(cancelRefundRuleText('deposit'), '押金：截止前取消全额退；截止后不退。')
  assert.equal(cancelRefundRuleText('pricing'), '报名费：活动开始前取消全额退；开始后不退。')
  assert.equal(cancelRefundRuleText('free'), null)
  assert.equal(cancelRefundRuleText(null), null)
})

// ── U1 小程序落点：押金场资金动作前的明示 + 显式同意 ──

test('押金支付前文案：金额行与详情页缴费块单源，必含不退明示与勾选文案', () => {
  const notice = depositPayNotice(6900)
  assert.equal(notice.amountText, '押金 ¥ 69.00（到场退）')
  assert.equal(notice.forfeitText, '未到场不退。')
  assert.equal(
    notice.ackLabel,
    '押金以到场为退还条件：到场核销后原路退回，未到场不予退还。'
  )
  // 单源钉：同一出口出两处文案，杜绝详情页与支付页口径漂移
  assert.equal(
    notice.amountText,
    paymentBlockCopy({
      pricingEnabled: false,
      depositEnabled: true,
      depositAmountCents: 6900,
      priceTiers: []
    }).amountText
  )

  // 脏金额（缺失/非正/非整数分）→ 不表态，绝不显示 ¥0.00（#675 与 web #627 同句）
  for (const invalid of [null, 0, -500, 0.4]) {
    const amountText = depositPayNotice(invalid).amountText
    assert.equal(amountText, '押金（金额待定）')
    assert.equal(amountText.includes('¥0'), false)
  }
})

test('支付门判据：押金单未勾选不放行；一般报名单零回归；无订单一律不放行', () => {
  const base = { ack: false, hasCredential: true, paying: false }
  const deposit = { orderKind: 'deposit' } as const
  const enrollment = { orderKind: 'enrollment' } as const

  // 押金单：勾选是硬门（资金动作前的显式同意）
  assert.equal(canRequestPayment({ ...base, order: deposit }), false)
  assert.equal(canRequestPayment({ ...base, order: deposit, ack: true }), true)

  // 一般报名单（定价）：不受 ack 影响，行为零回归
  assert.equal(canRequestPayment({ ...base, order: enrollment }), true)
  assert.equal(canRequestPayment({ ...base, order: enrollment, ack: true }), true)

  // 订单未就绪：没有可支付的东西（不给可支付假象）
  assert.equal(canRequestPayment({ ...base, order: null, ack: true }), false)

  // 既有门不回归：凭据未就绪 / 调起中
  assert.equal(canRequestPayment({ ...base, order: enrollment, hasCredential: false }), false)
  assert.equal(canRequestPayment({ ...base, order: deposit, ack: true, paying: true }), false)
})

// ── #727 创单前门：勾选 → 创单（带同意）→ 支付 ──

test('创单前门判据：押金场 required + 报名快照金额；非押金/读不到不拦', () => {
  // 押金场：出门（非 null），金额取报名快照（与后端下单实付同源）
  const depositGate = preCreateDepositGate({
    paymentMode: 'deposit',
    depositAmountCents: 6900
  })
  assert.equal(depositGate?.amountText, '押金 ¥ 69.00（到场退）')
  assert.equal(depositGate?.forfeitText, '未到场不退。')

  // 押金场 + 脏快照（缺失/0/负/非整数分）：门照常，金额待定，绝不 ¥0
  for (const dirty of [null, 0, -1, 6900.5]) {
    const gate = preCreateDepositGate({ paymentMode: 'deposit', depositAmountCents: dirty })
    assert.equal(gate?.amountText, '押金（金额待定）')
    assert.equal(gate?.amountText.includes('¥0'), false)
  }

  // 定价/免费场：不出门（零回归）
  for (const mode of ['pricing', 'free', null] as const) {
    assert.equal(preCreateDepositGate({ paymentMode: mode, depositAmountCents: 6900 }), null)
  }

  // 报名读不到（null）：不出门，交后端权威闸兜底（fail-open 有界）
  assert.equal(preCreateDepositGate(null), null)
})

// ── #751-② 创单失败自愈：consent_required 转披露+勾选，其余落可重试错误态 ──

test('创单自愈判定：BusinessError(code=order_deposit_consent_required) 命中，其余不命中', () => {
  // 命中：mutationError 抛出的形状（文案 + code）
  assert.equal(
    createOrderSelfHealsToConsent(
      new BusinessError('押金支付需先阅读并同意押金条款', 'order_deposit_consent_required')
    ),
    true
  )

  // 不命中：其他业务码 / 普通错误（网络/会话）/ 非对象
  assert.equal(
    createOrderSelfHealsToConsent(
      new BusinessError('报名状态已变化', 'order_not_payment_pending')
    ),
    false
  )
  assert.equal(createOrderSelfHealsToConsent(new Error('下单失败')), false)
  assert.equal(createOrderSelfHealsToConsent('order_deposit_consent_required'), false)
  assert.equal(createOrderSelfHealsToConsent(null), false)
})

test('订单口径解析：只认后端两个值，未知值上抛（资金门判据不得猜方向）', () => {
  assert.equal(parseOrderKind('deposit'), 'deposit')
  assert.equal(parseOrderKind('enrollment'), 'enrollment')
  // 未知值 fail-closed：猜错方向 = 押金单零披露付款
  assert.throws(() => parseOrderKind('bogus'), /未知订单口径/)
  assert.throws(() => parseOrderKind(''), /未知订单口径/)
})
