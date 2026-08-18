import assert from 'node:assert/strict'
import test from 'node:test'
import {
  ORDER_STATUS_LABEL,
  PAYMENT_STATUS_LABEL,
  countdownText,
  formatAmount,
  mapPaymentCredential,
  nextPollTick,
  parsePriceTiers,
  paymentLandingUrl,
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
