// 账号切换 / 退出登录的客户端持久键处置口径（#1079）：先写错判据示例，后钉住铁律。
// 判据三类（互斥、MECE）：
// - wish-draft 按 owner 前缀清（userId / 'guest'）——下一账号看不到自己的/上一账号的愿望草稿；
// - 闪念间入口意图与访客圈选按精确名清；
// - 交接协议键（login-handoff）与 pendingScene 不在内（防撤断扫码→登录交接）。
import assert from 'node:assert/strict'
import { describe, test } from 'node:test'

import { isAccountWipeKey } from '../src/domain/account.ts'

describe('退出登录键口径（#1079 账号切换隔离）', () => {
  test('愿望草稿按 owner 前缀清（userId / guest）', () => {
    assert.equal(isAccountWipeKey('cgc.wish-draft.user-a'), true)
    assert.equal(isAccountWipeKey('cgc.wish-draft.guest'), true)
    assert.equal(isAccountWipeKey('cgc.wish-draft.'), true)
  })

  test('闪念间入口意图与访客圈选按精确名清', () => {
    assert.equal(isAccountWipeKey('cgc.flashback_entry_intent'), true)
    assert.equal(isAccountWipeKey('cgc.flashback_last_guest_quote'), true)
  })

  test('交接协议键/pendingScene 不在内（防撤断扫码→登录交接）', () => {
    assert.equal(isAccountWipeKey('cgc.wish-draft.login-handoff'), false)
    assert.equal(isAccountWipeKey('cgc.pending_scene'), false)
    // 其他账号状态键（token / lastEnrollment / 通知缓存）由 clearAccountState 语义持有
    assert.equal(isAccountWipeKey('cgc.auth_token'), false)
    assert.equal(isAccountWipeKey('cgc.last_enrollment'), false)
  })

  test('非 cgc 键 / 无关前缀不受影响', () => {
    assert.equal(isAccountWipeKey('cgc.e2e.wish-reminder-result'), false)
    assert.equal(isAccountWipeKey(''), false)
    assert.equal(isAccountWipeKey('other'), false)
  })
})
