import test from 'node:test'
import assert from 'node:assert/strict'
import {
  accountIdentifier,
  initialPasswordCenterState,
  passwordFormErrorCopy,
  passwordSubmitErrorCopy,
  reducePasswordCenter,
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

test('reducePasswordCenter：成功清空输入、重建表单并结束 busy', () => {
  let state = reducePasswordCenter(initialPasswordCenterState, {
    type: 'password_changed',
    value: 'longenough'
  })
  state = reducePasswordCenter(state, { type: 'confirmation_changed', value: 'longenough' })
  state = reducePasswordCenter(state, { type: 'submit_started' })
  assert.equal(state.busy, true)
  assert.equal(state.error, '')

  state = reducePasswordCenter(state, { type: 'submit_succeeded' })
  assert.equal(state.done, true)
  assert.equal(state.busy, false)
  assert.equal(state.password, '')
  assert.equal(state.confirmation, '')
  assert.equal(state.formKey, 1)
})

test('reducePasswordCenter：失败保留输入、结束 busy 并写入文案', () => {
  let state = reducePasswordCenter(initialPasswordCenterState, {
    type: 'password_changed',
    value: 'longenough'
  })
  state = reducePasswordCenter(state, { type: 'submit_started' })
  state = reducePasswordCenter(state, { type: 'submit_failed', message: '设置失败，请稍后重试' })

  assert.equal(state.busy, false)
  assert.equal(state.done, false)
  assert.equal(state.password, 'longenough')
  assert.equal(state.error, '设置失败，请稍后重试')
})

test('reducePasswordCenter：忘记原密码切到重设态并清掉成功/错误', () => {
  let state = reducePasswordCenter(initialPasswordCenterState, { type: 'submit_succeeded' })
  state = reducePasswordCenter(state, { type: 'submit_failed', message: 'x' })
  state = reducePasswordCenter(state, { type: 'reset_requested' })

  assert.equal(state.mode, 'reset')
  assert.equal(state.error, '')
  assert.equal(state.done, false)
})

test('reducePasswordCenter：加载失败只写错误', () => {
  const state = reducePasswordCenter(initialPasswordCenterState, {
    type: 'load_failed',
    message: '暂时无法加载账号信息，请重试。'
  })
  assert.equal(state.error, '暂时无法加载账号信息，请重试。')
  assert.equal(state.busy, false)
})
