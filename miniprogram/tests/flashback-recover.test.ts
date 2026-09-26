import assert from 'node:assert/strict'
import test from 'node:test'
import {
  RECOVER_COPY,
  RECOVER_LINK_ERRORS,
  canClaimRecover,
  canSendRecover,
  canVerifyRecover,
  recoverChannel,
  recoverDoneText
} from '../src/domain/flashback-recover.ts'
import { errorCopy } from '../src/domain/error-copy.ts'

// #932 小程序内找回：已登录但没匹配到档案的人，凭当年报名用的邮箱找回——找回邮件里的
// 链接贴回来，绑定到当前账号。判据下沉 domain（页面无渲染测试）。

test('通道：含 @ 走邮件；手机号找回暂停 → 不成通道（面板就地提示填邮箱）；空白不可发', () => {
  assert.equal(recoverChannel(' someone@example.com '), 'email')
  assert.equal(recoverChannel('139 0000 0011'), null)
  assert.equal(recoverChannel('   '), null)
})

test('保留的手机通道：打开开关时手机号按发码走', () => {
  assert.equal(recoverChannel('139 0000 0011', true), 'phone')
  assert.equal(recoverChannel('someone@example.com', true), 'email')
})

test('面向用户的找回文案不出现手机号（暂停期间前端不显示）', () => {
  for (const key of ['entry', 'lead', 'identifierPlaceholder', 'send', 'emailRequired', 'linkSentHint', 'linkHint', 'pasteEntry'] as const) {
    assert.doesNotMatch(RECOVER_COPY[key], /手机/, key)
  }
})

test('贴链接：有内容且不在提交中；链接失效三态各有找回口径的文案', () => {
  assert.equal(canClaimRecover(' https://example.com/flashback/enter?token=fb_x ', false), true)
  assert.equal(canClaimRecover('   ', false), false)
  assert.equal(canClaimRecover('fb_x', true), false)
  for (const code of ['flashback_token_not_found', 'flashback_token_claimed', 'flashback_token_revoked']) {
    assert.match(RECOVER_LINK_ERRORS[code] ?? '', /链接/, code)
  }
})

test('发送：有内容且不在提交中；验证：验证码至少 4 位（与 web 找回表单同口径）', () => {
  assert.equal(canSendRecover('13900000011', false), true)
  assert.equal(canSendRecover('13900000011', true), false)
  assert.equal(canSendRecover('', false), false)
  assert.equal(canVerifyRecover(' 123 ', false), false)
  assert.equal(canVerifyRecover('1234', false), true)
  assert.equal(canVerifyRecover('123456', true), false)
})

test('完成文案按找到的张数', () => {
  assert.equal(recoverDoneText(1), '找到了你的 1 张卡，已经绑到你现在登录的账号。')
  assert.equal(recoverDoneText(2), '找到了你的 2 张卡，已经绑到你现在登录的账号。')
})

test('错误码文案：验证码与限流与 web 同文案；号码或卡属于别的账号给出明确下一步', () => {
  assert.equal(errorCopy('invalid_or_expired_code'), '验证码不对或已过期，请重试。')
  assert.equal(errorCopy('flashback_recover_rate_limited'), '找回尝试过于频繁，请一小时后再试。')
  assert.match(errorCopy('flashback_recover_account_conflict') ?? '', /另一个账号/)
})
