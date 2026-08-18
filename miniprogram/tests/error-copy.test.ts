import assert from 'node:assert/strict'
import test from 'node:test'
import { errorCopy } from '../src/domain/error-copy.ts'

test('已知 code 返回中文文案', () => {
  assert.equal(errorCopy('enrollment_duplicate_active'), '你已有待支付订单，请关闭后重新打开继续支付。')
  assert.equal(errorCopy('order_provider_not_configured'), '该支付渠道暂未开通，请选择其他方式。')
})

test('每个 code 映射非空文案', () => {
  // 与 web/lib/payment-errors.ts 同表同文案（互指注释见模块头）
  const knownCodes = [
    'enrollment_duplicate_active',
    'enrollment_not_payment_pending',
    'order_enrollment_not_found',
    'enrollment_already_processed',
    'order_already_processed',
    'order_provider_not_configured',
    'enrollment_capacity_full_or_registration_closed',
    'enrollment_target_not_open_or_registration_closed',
    'enrollment_invite_code_required',
    'enrollment_invite_quota_unavailable',
    'enrollment_tier_id_required',
    'enrollment_tier_not_available',
    'order_enrollment_required'
  ]
  for (const code of knownCodes) {
    const copy = errorCopy(code)
    assert.ok(copy && copy.length > 0, `code ${code} 应有非空文案`)
  }
})

test('未知 code / null / undefined 返回 null（走兜底）', () => {
  assert.equal(errorCopy('some_unknown_code'), null)
  assert.equal(errorCopy(null), null)
  assert.equal(errorCopy(undefined), null)
  assert.equal(errorCopy(''), null)
})
