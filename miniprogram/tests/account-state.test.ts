import { beforeEach, describe, expect, it, vi } from 'vitest'
import * as accountState from '../src/state/accountState'

const KEY = {
  activeUser: 'cgc.active_user_id',
  lastEnrollment: 'cgc.last_enrollment',
  pendingScene: 'cgc.pending_scene',
  legacyNotifications: 'cgc.local_notifications',
  notifA: 'cgc.local_notifications.user-a',
  notifB: 'cgc.local_notifications.user-b'
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
  it('A/B 两账号通知互不可见', () => {
    accountState.activateAccount('user-a')
    accountState.appendLocalNotification('A 标题', 'A 内容')
    expect(accountState.readLocalNotifications()).toEqual([
      expect.objectContaining({ title: 'A 标题', body: 'A 内容' })
    ])

    accountState.activateAccount('user-b')
    expect(accountState.readLocalNotifications()).toEqual([])
    accountState.appendLocalNotification('B 标题', 'B 内容')
    expect(accountState.readLocalNotifications()).toEqual([
      expect.objectContaining({ title: 'B 标题' })
    ])

    // 切回 A：A 的 namespaced 通知仍在，B 的不可见
    accountState.activateAccount('user-a')
    expect(accountState.readLocalNotifications()).toEqual([
      expect.objectContaining({ title: 'A 标题' })
    ])
    expect(mocks.storage.has(KEY.notifB)).toBe(true)
  })

  it('切换账号清 lastEnrollment，首次激活不清', () => {
    mocks.storage.set(KEY.lastEnrollment, 'e1')
    accountState.activateAccount('user-a')
    expect(mocks.storage.has(KEY.lastEnrollment)).toBe(true)
    accountState.activateAccount('user-b')
    expect(mocks.storage.has(KEY.lastEnrollment)).toBe(false)
  })

  it('旧全局通知 key 不可读且激活时被清', () => {
    mocks.storage.set(KEY.legacyNotifications, [
      { id: '1', title: 'legacy', body: 'x', createdAt: '', read: false }
    ])
    // 无 active user：不读 legacy
    expect(accountState.readLocalNotifications()).toEqual([])
    accountState.activateAccount('user-a')
    expect(mocks.storage.has(KEY.legacyNotifications)).toBe(false)
    expect(accountState.readLocalNotifications()).toEqual([])
  })

  it('无 active user 时 append 不写任何通知 key', () => {
    accountState.appendLocalNotification('孤儿', '无主')
    expect(mocks.storage.has(KEY.legacyNotifications)).toBe(false)
    expect(mocks.storage.has(KEY.notifA)).toBe(false)
    expect(mocks.storage.has(KEY.notifB)).toBe(false)
  })

  it('通知最新在前且最多 50 条', () => {
    accountState.activateAccount('user-a')
    for (let i = 1; i <= 55; i++) accountState.appendLocalNotification(`标题${i}`, `内容${i}`)
    const list = accountState.readLocalNotifications()
    expect(list.length).toBe(50)
    expect(list[0].title).toBe('标题55')
    expect(list[49].title).toBe('标题6')
  })
})

describe('clearAccountState 与 pendingScene 边界', () => {
  it('默认保留 pending scene，删除 active user 通知/ID/legacy/lastEnrollment', () => {
    accountState.activateAccount('user-a')
    accountState.appendLocalNotification('A', 'B')
    mocks.storage.set(KEY.pendingScene, 's1')
    mocks.storage.set(KEY.lastEnrollment, 'e1')

    accountState.clearAccountState()
    expect(mocks.storage.has(KEY.notifA)).toBe(false)
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
