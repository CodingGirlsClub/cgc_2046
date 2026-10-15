import { beforeEach, describe, expect, it, vi } from 'vitest'
import * as accountState from '../src/state/accountState'

const KEY = {
  activeUser: 'cgc.active_user_id',
  lastEnrollment: 'cgc.last_enrollment',
  pendingScene: 'cgc.pending_scene',
  legacyNotifications: 'cgc.local_notifications',
  notifA: 'cgc.local_notifications.user-a',
  notifB: 'cgc.local_notifications.user-b',
  feedA: 'cgc.notification_feed.v1.user-a',
  feedB: 'cgc.notification_feed.v1.user-b',
  flashbackToken: 'cgc.flashback_token',
  authToken: 'cgc.auth_token'
}

const mocks = vi.hoisted(() => {
  const storage = new Map<string, unknown>()
  return {
    storage,
    getStorageSync: vi.fn(),
    setStorageSync: vi.fn(),
    removeStorageSync: vi.fn()
  }
})

vi.mock('@tarojs/taro', () => ({
  default: {
    getStorageSync: mocks.getStorageSync,
    setStorageSync: mocks.setStorageSync,
    removeStorageSync: mocks.removeStorageSync
  }
}))

beforeEach(() => {
  mocks.storage.clear()
  vi.clearAllMocks()
  mocks.getStorageSync.mockImplementation((key: string) => mocks.storage.get(key))
  mocks.setStorageSync.mockImplementation((key: string, value: unknown) => {
    mocks.storage.set(key, value)
  })
  mocks.removeStorageSync.mockImplementation((key: string) => {
    mocks.storage.delete(key)
  })
})

describe('账号本地状态隔离', () => {
  it('A/B 缓存隔离且晚到 A 写入在切换与注销后失效', () => {
    const row = { id: 'server-a', type: 'event_reminder', title: '活动提醒', body: '活动即将开始', createdAt: new Date().toISOString(), readAt: null, deepLink: null }
    accountState.activateAccount('user-a')
    const a = accountState.captureAccountScope()!
    accountState.cacheNotificationFeed(a, [row])
    accountState.activateAccount('user-b')
    const b = accountState.captureAccountScope()!
    expect(accountState.cachedNotificationFeed(b)).toBe(null)
    accountState.cacheNotificationFeed(a, [{ ...row, body: '迟到的旧响应' }])
    accountState.activateAccount('user-a')
    expect(accountState.cachedNotificationFeed(accountState.captureAccountScope()!)).toEqual([row])
    accountState.clearAccountState()
    accountState.cacheNotificationFeed(a, [row])
    expect(mocks.storage.has(KEY.feedA)).toBe(false)
  })

  it('切换账号清 lastEnrollment，首次激活不清', () => {
    mocks.storage.set(KEY.lastEnrollment, 'e1')
    accountState.activateAccount('user-a')
    expect(mocks.storage.has(KEY.lastEnrollment)).toBe(true)
    accountState.activateAccount('user-b')
    expect(mocks.storage.has(KEY.lastEnrollment)).toBe(false)
  })

  it('不导入旧本机记录，过期和损坏缓存不可恢复', () => {
    mocks.storage.set(KEY.legacyNotifications, [{ id: 'old', title: '旧记录' }])
    mocks.storage.set(KEY.notifA, [{ id: 'old-account' }])
    accountState.activateAccount('user-a')
    const scope = accountState.captureAccountScope()!
    expect(mocks.storage.has(KEY.legacyNotifications)).toBe(false)
    expect(mocks.storage.has(KEY.notifA)).toBe(false)
    mocks.storage.set(KEY.feedA, { items: [{ id: 'bad' }], fetchedAt: new Date().toISOString() })
    expect(accountState.cachedNotificationFeed(scope)).toBe(null)
    expect(mocks.storage.has(KEY.feedA)).toBe(false)
  })
})

describe('clearAccountState 与 pendingScene 边界', () => {
  it('默认保留 pending scene，删除 active user 通知/ID/legacy/lastEnrollment', () => {
    accountState.activateAccount('user-a')
    accountState.cacheNotificationFeed(accountState.captureAccountScope()!, [])
    mocks.storage.set(KEY.pendingScene, 's1')
    mocks.storage.set(KEY.lastEnrollment, 'e1')

    accountState.clearAccountState()
    expect(mocks.storage.has(KEY.feedA)).toBe(false)
    expect(mocks.storage.has(KEY.activeUser)).toBe(false)
    expect(mocks.storage.has(KEY.legacyNotifications)).toBe(false)
    expect(mocks.storage.has(KEY.lastEnrollment)).toBe(false)
    expect(mocks.storage.has(KEY.pendingScene)).toBe(true)
  })

  it('clearPendingScene: true 时删除 pending scene', () => {
    mocks.storage.set(KEY.pendingScene, 's2')
    accountState.clearAccountState({ clearPendingScene: true })
    expect(mocks.storage.has(KEY.pendingScene)).toBe(false)
  })
})

describe('clearFlashbackLinkIdentity', () => {
  it('删除 cgc.flashback_token，不碰 cgc.auth_token / pending scene', () => {
    mocks.storage.set(KEY.flashbackToken, 'ft-1')
    mocks.storage.set(KEY.authToken, 'at-1')
    mocks.storage.set(KEY.pendingScene, 's1')

    accountState.clearFlashbackLinkIdentity()

    expect(mocks.storage.has(KEY.flashbackToken)).toBe(false)
    expect(mocks.storage.get(KEY.authToken)).toBe('at-1')
    expect(mocks.storage.get(KEY.pendingScene)).toBe('s1')
  })
})

describe('wipeAccountLocal（#1079 确定性清理）', () => {
  it('删 active+guest 两愿望草稿桶 + 两闪念间键，不碰 handoff/pending/token/其他账号草稿', () => {
    accountState.activateAccount('user-a')
    mocks.storage.set('cgc.wish-draft.user-a', { content: 'A 草稿' })
    mocks.storage.set('cgc.wish-draft.guest', { content: 'guest 草稿' })
    mocks.storage.set('cgc.wish-draft.login-handoff', { owner: null, requestId: 'r1' })
    mocks.storage.set('cgc.wish-draft.user-b', { content: 'B 草稿' })
    mocks.storage.set('cgc.flashback_entry_intent', 'welcome')
    mocks.storage.set('cgc.flashback_last_guest_quote', '"上一轮圈选"')
    mocks.storage.set(KEY.authToken, 'at-1')
    mocks.storage.set(KEY.pendingScene, 's1')
    mocks.storage.set('cgc.e2e.wish-reminder-result', 'denied')

    accountState.wipeAccountLocal()

    expect(mocks.storage.has('cgc.wish-draft.user-a')).toBe(false)
    expect(mocks.storage.has('cgc.wish-draft.guest')).toBe(false)
    expect(mocks.storage.has('cgc.flashback_entry_intent')).toBe(false)
    expect(mocks.storage.has('cgc.flashback_last_guest_quote')).toBe(false)
    expect(mocks.storage.get('cgc.wish-draft.user-b')).toEqual({ content: 'B 草稿' })
    expect(mocks.storage.get('cgc.wish-draft.login-handoff')).toEqual({ owner: null, requestId: 'r1' })
    expect(mocks.storage.get(KEY.authToken)).toBe('at-1')
    expect(mocks.storage.get(KEY.pendingScene)).toBe('s1')
    expect(mocks.storage.get('cgc.e2e.wish-reminder-result')).toBe('denied')
  })

  it('无活跃账号（未登录登出态）：只删 guest 桶 + 两闪念间键', () => {
    mocks.storage.set('cgc.wish-draft.user-a', { content: 'A' })
    mocks.storage.set('cgc.wish-draft.guest', { content: 'guest' })
    accountState.wipeAccountLocal()
    expect(mocks.storage.has('cgc.wish-draft.guest')).toBe(false)
    expect(mocks.storage.get('cgc.wish-draft.user-a')).toEqual({ content: 'A' })
  })

  it('removeStorageSync 抛错不吞——让调用方（signOut）感知失败', () => {
    accountState.activateAccount('user-a')
    mocks.storage.set('cgc.wish-draft.user-a', { content: 'A' })
    mocks.storage.set('cgc.wish-draft.guest', { content: 'guest' })
    mocks.removeStorageSync.mockImplementation(() => { throw new Error('io error') })
    expect(() => accountState.wipeAccountLocal()).toThrow('io error')
  })
})

describe('takePendingScene', () => {
  it('优先 route 参数，返回前清空持久 scene', () => {
    mocks.storage.set(KEY.pendingScene, 'persisted')
    expect(accountState.takePendingScene('from-route')).toBe('from-route')
    expect(mocks.storage.has(KEY.pendingScene)).toBe(false)
  })

  it('无 route 参数时读 storage 并清空；再取为空', () => {
    mocks.storage.set(KEY.pendingScene, 'persisted-2')
    expect(accountState.takePendingScene()).toBe('persisted-2')
    expect(mocks.storage.has(KEY.pendingScene)).toBe(false)
    expect(accountState.takePendingScene()).toBe('')
  })
})
