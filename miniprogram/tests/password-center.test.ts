import test from 'node:test'
import assert from 'node:assert/strict'
import {
  accountIdentifier,
  passwordFormErrorCopy,
  passwordSubmitErrorCopy,
  shouldPromptPasswordSetup,
  validateNewPassword
} from '../src/domain/password-center.ts'

test('validateNewPassword rejects empty, short and mismatched input', () => {
  assert.equal(validateNewPassword('', ''), 'required')
  assert.equal(validateNewPassword('short', 'short'), 'too_short')
  assert.equal(validateNewPassword('longenough', 'different'), 'mismatch')
  assert.equal(validateNewPassword('longenough', 'longenough'), null)
})

test('passwordFormErrorCopy is user-facing Chinese', () => {
  assert.match(passwordFormErrorCopy('required'), /请输入/)
  assert.match(passwordFormErrorCopy('too_short'), /8/)
  assert.match(passwordFormErrorCopy('mismatch'), /不一致/)
})

test('passwordSubmitErrorCopy translates length errors and hides infra text', () => {
  assert.match(passwordSubmitErrorCopy('password must be at least 8 characters'), /8/)
  assert.equal(passwordSubmitErrorCopy('socket hang up'), '设置失败，请稍后重试')
  assert.equal(passwordSubmitErrorCopy(null), '设置失败，请稍后重试')
})

test('accountIdentifier always tells the user which account is being set', () => {
  assert.equal(accountIdentifier('138****8000'), '手机号 138****8000')
  assert.equal(accountIdentifier(null), '账号未绑定手机号')
})

test('shouldPromptPasswordSetup only fires on an explicit false', () => {
  assert.equal(shouldPromptPasswordSetup({ hasPassword: false }), true)
  assert.equal(shouldPromptPasswordSetup({ hasPassword: true }), false)
  assert.equal(shouldPromptPasswordSetup({}), false)
})
