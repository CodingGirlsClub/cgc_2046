// 账号切换 / 退出登录的客户端持久键（#1079）——确定性键集（不枚举）。
//
// 判据：主动退出必须确定性清除「当前活跃账号 + guest」两个愿望草稿桶、与两条
// 闪念间 UI 意图/访客圈选；其余键（handoff 标记、pendingScene、通知缓存、token）
// 不在 wipe 职责内——handoff 按交接协议保留（draft 已删，marker 剩余无害）。
// 实现侧（state/accountState.ts）必须对以上每一键逐一 removeStorageSync，不得依赖
// `getStorageInfoSync().keys` 枚举——枚举失败会把草稿留着而不报错（本次 review 找到的根因）。
import assert from 'node:assert/strict'
import { describe, test } from 'node:test'

import { wipeAccountKeys } from '../src/domain/account.ts'

describe('退出登录确定性键集（#1079 账号切换隔离）', () => {
  test('活跃账号在场：current 账号草稿桶 + guest 草稿桶 + 两闪念间键', () => {
    const keys = wipeAccountKeys('user-a')
    assert.equal(keys.length, 4)
    assert.ok(keys.includes('cgc.wish-draft.user-a'))
    assert.ok(keys.includes('cgc.wish-draft.guest'))
    assert.ok(keys.includes('cgc.flashback_entry_intent'))
    assert.ok(keys.includes('cgc.flashback_last_guest_quote'))
  })

  test('无活跃账号（已在未登录态登出）：只删 guest 草稿桶 + 两闪念间键', () => {
    const keys = wipeAccountKeys(null)
    assert.equal(keys.length, 3)
    assert.ok(keys.includes('cgc.wish-draft.guest'))
    assert.ok(keys.includes('cgc.flashback_entry_intent'))
    assert.ok(keys.includes('cgc.flashback_last_guest_quote'))
  })

  test('login-handoff / pendingScene / 认证与通知缓存键不在内', () => {
    const keys = wipeAccountKeys('user-a')
    for (const excluded of [
      'cgc.wish-draft.login-handoff',
      'cgc.pending_scene',
      'cgc.auth_token',
      'cgc.last_enrollment',
      'cgc.active_user_id',
      'cgc.local_notifications'
    ]) {
      assert.ok(!keys.includes(excluded), `不应清理 ${excluded}`)
    }
  })

  test('键含义不漂：不同账号键独立（不是共享 guest 桶）', () => {
    const a = wipeAccountKeys('user-a')
    const b = wipeAccountKeys('user-b')
    assert.ok(!a.includes('cgc.wish-draft.user-b'))
    assert.ok(!b.includes('cgc.wish-draft.user-a'))
  })
})
