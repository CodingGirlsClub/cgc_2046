import { beforeEach, expect, it, vi } from 'vitest'
const mocks = vi.hoisted(() => ({ request: vi.fn(), storage: new Map<string, unknown>(), cacheWriteFailure: false }))
vi.mock('@tarojs/taro', () => ({ default: {
  request: mocks.request,
  getStorageSync: (key: string) => mocks.storage.get(key),
  setStorageSync: (key: string, value: unknown) => {
    if (mocks.cacheWriteFailure && key.startsWith('cgc.notification_feed.v1.')) throw new Error('synthetic cache write failure')
    mocks.storage.set(key, value)
  },
  removeStorageSync: (key: string) => mocks.storage.delete(key)
} }))
vi.mock('../src/platform', () => ({ currentPlatform: () => 'wechat' }))
import { RealMiniProgramApi } from '../src/api/real'
import { activateAccount, clearAccountState } from '../src/state/accountState'
import { GraphQLRequestError, getAuthToken, setAuthToken } from '../src/api/client'

interface HttpFixture { statusCode: number; data: unknown; header: Record<string, unknown>; cookies: string[] }

function httpData(data: unknown) { return { statusCode: 200, data: { data }, header: {}, cookies: [] } }
const row = { id: 'server-a', type: 'enrollment_completed', title: '报名成功', body: '活动已确认', insertedAt: new Date().toISOString(), readAt: null, deepLink: '/pages/my-enrollments/index' }
const response = { notificationFeed: { results: [row], endKeyset: 'cursor-a' } }
beforeEach(() => { mocks.storage.clear(); mocks.request.mockReset(); mocks.cacheWriteFailure = false; setAuthToken('local-session'); clearAccountState(); activateAccount('account-a') })

it('reads authoritative feed, then uses only same-account cache for transport rejection', async () => {
  const api = new RealMiniProgramApi()
  mocks.request.mockResolvedValueOnce(httpData(response))
  const server = await api.getNotifications()
  expect(server.source).toBe('server')
  expect(server.items).toEqual([{ id: row.id, type: row.type, title: row.title, body: row.body, createdAt: row.insertedAt, readAt: null, deepLink: row.deepLink }])
  mocks.request.mockRejectedValueOnce(new TypeError('request:fail network offline'))
  const cached = await api.getNotifications()
  expect(cached.source).toBe('cache')
  expect(cached.items).toEqual(server.items)
  mocks.request.mockResolvedValueOnce({ statusCode: 200, data: { errors: [{ message: 'forbidden', code: 'forbidden' }] }, header: {}, cookies: [] })
  await expect(api.getNotifications()).rejects.toBeInstanceOf(GraphQLRequestError)
})

it.each([{ envelope: null }, { envelope: 'not an envelope' }, { envelope: 42 }, { envelope: [] }, { envelope: true }])('HTTP 200 invalid envelope $envelope never masquerades as a cached success', async ({ envelope }) => {
  const api = new RealMiniProgramApi()
  mocks.request.mockResolvedValueOnce(httpData(response))
  const old = await api.getNotifications()
  mocks.request.mockResolvedValueOnce({ statusCode: 200, data: envelope, header: {}, cookies: [] })
  await expect(api.getNotifications()).rejects.toMatchObject({ name: 'GraphQLRequestError', statusCode: 200 })
  expect(getAuthToken()).toBe('local-session')
  mocks.request.mockRejectedValueOnce({ errMsg: 'request:fail offline' })
  expect((await api.getNotifications()).items).toEqual(old.items)
})

it('valid new server feed remains authoritative when optional cache persistence fails', async () => {
  const api = new RealMiniProgramApi()
  mocks.request.mockResolvedValueOnce(httpData(response))
  await api.getNotifications()
  const latest = { ...row, id: 'server-new', title: '活动改期', body: '活动已改至新的时间。' }
  mocks.cacheWriteFailure = true
  mocks.request.mockResolvedValueOnce(httpData({ notificationFeed: { results: [latest], endKeyset: null } }))
  const result = await api.getNotifications()
  expect(result.source).toBe('server')
  expect(result.items.map(item => item.id)).toEqual(['server-new'])
  expect(result.items[0].body).toBe(latest.body)
})

it('confirmed server readAt survives an optional cache-write failure', async () => {
  const api = new RealMiniProgramApi()
  mocks.request.mockResolvedValueOnce(httpData(response))
  await api.getNotifications()
  const readAt = '2026-10-04T09:00:00.123456Z'
  mocks.cacheWriteFailure = true
  mocks.request.mockResolvedValueOnce(httpData({ markNotificationRead: { result: { ...row, readAt }, errors: [] } }))
  const marked = await api.markNotificationRead(row.id)
  expect(marked.id).toBe(row.id)
  expect(marked.readAt).toBe(readAt)
})

it('HTTP 401 never returns cache success and clears only its own account', async () => {
  const api = new RealMiniProgramApi()
  mocks.request.mockResolvedValueOnce(httpData(response))
  await api.getNotifications()
  mocks.request.mockResolvedValueOnce({ statusCode: 401, data: null, header: {}, cookies: [] })
  await expect(api.getNotifications()).rejects.toBeInstanceOf(Error)
  expect(getAuthToken()).toBe(null)
  expect(mocks.storage.has('cgc.notification_feed.v1.account-a')).toBe(false)
})

it('a late logout of A cannot clear the newer B session or account state', async () => {
  const { promise, resolve } = Promise.withResolvers<HttpFixture>()
  mocks.request.mockImplementationOnce(() => promise)
  const api = new RealMiniProgramApi()
  const pending = api.signOut()
  setAuthToken('newer-local-session')
  activateAccount('account-b')
  resolve(httpData({ signOut: true }))
  await pending
  expect(mocks.storage.get('cgc.active_user_id')).toBe('account-b')
  expect(getAuthToken()).toBe('newer-local-session')
})

it('logout clears local session and feed before a delayed acknowledgement', async () => {
  const api = new RealMiniProgramApi()
  mocks.request.mockResolvedValueOnce(httpData(response))
  await api.getNotifications()
  const { promise, resolve } = Promise.withResolvers<HttpFixture>()
  mocks.request.mockImplementationOnce(() => promise)
  const pending = api.signOut()
  try {
    expect(getAuthToken()).toBe(null)
    expect(mocks.storage.has('cgc.active_user_id')).toBe(false)
    expect(mocks.storage.has('cgc.notification_feed.v1.account-a')).toBe(false)
  } finally { resolve(httpData({ signOut: true })); await pending }
})

it('a late failed session refresh cannot revoke the newer account', async () => {
  const { promise, resolve } = Promise.withResolvers<HttpFixture>()
  mocks.request.mockImplementationOnce(() => promise)
  const pending = new RealMiniProgramApi().getSession()
  setAuthToken('newer-local-session')
  activateAccount('account-b')
  resolve({ statusCode: 200, data: { errors: [{ message: 'old forbidden', code: 'forbidden' }] }, header: {}, cookies: [] })
  expect((await pending).authExpired).toBe(false)
  expect(getAuthToken()).toBe('newer-local-session')
  expect(mocks.storage.get('cgc.active_user_id')).toBe('account-b')
})

it('a replacement session cannot reuse the old verified account before hydration', async () => {
  const api = new RealMiniProgramApi()
  mocks.request.mockResolvedValueOnce(httpData(response))
  await api.getNotifications()
  setAuthToken('replacement-local-session')
  expect(mocks.storage.has('cgc.active_user_id')).toBe(false)
  expect(mocks.storage.has('cgc.notification_feed.v1.account-a')).toBe(false)
  await expect(api.getNotifications()).rejects.toBeInstanceOf(Error)
})

it('malformed feed data is a contract error, not a cache fallback', async () => {
  const api = new RealMiniProgramApi()
  mocks.request.mockResolvedValueOnce(httpData(response))
  await api.getNotifications()
  mocks.request.mockResolvedValueOnce(httpData({ notificationFeed: { results: {} } }))
  await expect(api.getNotifications()).rejects.toBeInstanceOf(GraphQLRequestError)
})

it('a same-ID notification accepted after retention cannot inherit the old readAt', async () => {
  vi.useFakeTimers()
  try {
    vi.setSystemTime(new Date('2026-09-01T12:00:00Z'))
    const api = new RealMiniProgramApi()
    const old = { ...row, insertedAt: '2026-09-01T12:00:00Z' }
    mocks.request.mockResolvedValueOnce(httpData({ notificationFeed: { results: [old], endKeyset: null } }))
    await api.getNotifications()
    mocks.request.mockResolvedValueOnce(httpData({ markNotificationRead: { result: { ...old, readAt: '2026-09-01T12:01:00Z' }, errors: [] } }))
    await api.markNotificationRead(old.id)
    vi.setSystemTime(new Date('2026-10-04T12:00:00Z'))
    mocks.request.mockResolvedValueOnce(httpData({ notificationFeed: { results: [{ ...old, insertedAt: '2026-10-04T12:00:00Z' }], endKeyset: null } }))
    expect((await api.getNotifications()).items[0].readAt).toBe(null)
  } finally { vi.useRealTimers() }
})

it('a network-only session refresh preserves the account-scoped offline feed', async () => {
  const api = new RealMiniProgramApi()
  mocks.request.mockResolvedValueOnce(httpData(response))
  await api.getNotifications()
  mocks.request.mockRejectedValueOnce({ errMsg: 'request:fail offline' })
  expect((await api.getSession()).authExpired).toBe(false)
  mocks.request.mockRejectedValueOnce({ errMsg: 'request:fail offline' })
  expect((await api.getNotifications()).source).toBe('cache')
})

it('late session hydration cannot reactivate the previous account', async () => {
  const { promise, resolve } = Promise.withResolvers<HttpFixture>()
  mocks.request.mockImplementationOnce(() => promise)
  const pending = new RealMiniProgramApi().getSession()
  activateAccount('account-b')
  resolve(httpData({ me: { id: 'account-a', displayName: 'A' }, meWorkspaces: [], myPendingApprovals: [] }))
  expect((await pending).user).toBe(null)
  expect(mocks.storage.get('cgc.active_user_id')).toBe('account-b')
})

it('discards late transport responses after account switching or logout without writing a cache', async () => {
  for (const change of [() => activateAccount('account-b'), () => clearAccountState()]) {
    activateAccount('account-a')
    const { promise, resolve: finish } = Promise.withResolvers<HttpFixture>()
    mocks.request.mockImplementationOnce(() => promise)
    const pending = new RealMiniProgramApi().getNotifications()
    change()
    finish(httpData(response))
    await expect(pending).rejects.toThrow('账号已变化')
    expect(mocks.storage.has('cgc.notification_feed.v1.account-b')).toBe(false)
    expect(mocks.storage.has('cgc.notification_feed.v1.account-a')).toBe(false)
  }
})

it('mark-read uses server timestamp, preserves it through a late unread refresh, and empty success clears cache', async () => {
  const api = new RealMiniProgramApi()
  mocks.request.mockResolvedValueOnce(httpData(response))
  await api.getNotifications()
  const { promise, resolve: finish } = Promise.withResolvers<HttpFixture>()
  mocks.request.mockImplementationOnce(() => promise)
  const refreshing = api.getNotifications()
  const readAt = '2026-10-04T09:00:00.123456Z'
  mocks.request.mockResolvedValueOnce(httpData({ markNotificationRead: { result: { ...row, readAt }, errors: [] } }))
  expect((await api.markNotificationRead(row.id)).readAt).toBe(readAt)
  finish(httpData(response))
  expect((await refreshing).items[0].readAt).toBe(readAt)
  mocks.request.mockResolvedValueOnce(httpData({ notificationFeed: { results: [], endKeyset: null } }))
  expect((await api.getNotifications()).items).toEqual([])
  mocks.request.mockRejectedValueOnce({ errMsg: 'request:fail offline' })
  expect((await api.getNotifications()).items).toEqual([])
})
