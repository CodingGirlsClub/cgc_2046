import { beforeEach, describe, expect, it, vi } from 'vitest'
import type * as RealApi from '../src/api/real'

/**
 * #1079 P2 回归守卫：真实链路 signOut（不清 mock setAuthToken / accountState）。
 *
 * 背景：real-auth.vitest.ts 同时 mock 了 ../src/api/client 与 ../src/state/accountState，
 * 其「wipe 先于 clearAccountState」断言在 setter 副作用（setAuthToken(null) →
 * clearAccountState()）引入后照样绿——mock 层没有真实副作用，顺序缺陷探测不到。
 * 本文件反过来：假设一整条 signOut 链上唯一允许替换的边界是
 *   1) @tarojs/taro 的 storage（Map 顶替）与
 *   2) GraphQL 网络边界（mockTransport 的 __E2E_MOCK__=false 真实请求的下一级）。
 * 其余全跑真实现：client.ts 的 setAuthToken / authToken 模块态、accountState.ts 的
 * activateAccount / clearAccountState / wipeAccountLocal、silentLogin、workspaceTab。
 *
 * 配方对齐 tests/api-client.vitest.ts：vi.resetModules + 动态 import，让 client.ts
 * 的模块级 authToken 读入保持每用例隔离。
 */

const KEY = {
  authToken: 'cgc.auth_token',
  activeUser: 'cgc.active_user_id',
  workspaceTab: 'cgc.workspace_tab_visible',
  silentLoginOff: 'cgc.silent_login_off',
  pendingScene: 'cgc.pending_scene',
  lastEnrollment: 'cgc.last_enrollment',
  flashbackToken: 'cgc.flashback_token'
} as const

const mocks = vi.hoisted(() => ({
  storage: new Map<string, unknown>(),
  // 只当「有了 token 后发出 signOut mutation」的哨兵；请求 body 详情属 api-client 契约层，不在这里钉。
  request: vi.fn()
}))

vi.mock('@tarojs/taro', () => ({
  default: {
    getStorageSync: (key: string) => mocks.storage.get(key),
    setStorageSync: (key: string, value: unknown) => { mocks.storage.set(key, value) },
    removeStorageSync: (key: string) => { mocks.storage.delete(key) },
    request: mocks.request,
    eventCenter: { trigger: vi.fn(), on: vi.fn(), off: vi.fn() }
  }
}))

let api: typeof RealApi

async function loadApi() {
  vi.resetModules()
  api = await import('../src/api/real')
  return api
}

/**
 * 初始化一次完整的静默登录态：A 账号激活 + 草稿 / 圈选 / token 全部落盘。
 * 任何后续 signOut 都必须在这个基线上把「户主侧」键清干净。
 */
function seedSignedInState(userId: string) {
  mocks.storage.set(KEY.activeUser, userId)
  mocks.storage.set(KEY.workspaceTab, 'workspace')
  mocks.storage.set(KEY.pendingScene, 's1')
  mocks.storage.set(KEY.lastEnrollment, 'e1')
  mocks.storage.set(KEY.flashbackToken, 'fb-token')
  mocks.storage.set(`cgc.wish-draft.${userId}`, { content: `${userId} 草稿` })
  mocks.storage.set('cgc.wish-draft.guest', { content: 'guest 草稿' })
  mocks.storage.set('cgc.wish-draft.user-b', { content: 'B 草稿' })
  mocks.storage.set('cgc.wish-draft.login-handoff', { owner: null, requestId: 'r1' })
  mocks.storage.set('cgc.flashback_entry_intent', 'welcome')
  mocks.storage.set('cgc.flashback_last_guest_quote', '"圈选"')
}

async function signOut() {
  const instance = new api.RealMiniProgramApi()
  await instance.signOut()
}

beforeEach(async () => {
  mocks.storage.clear()
  mocks.request.mockImplementation(() =>
    Promise.resolve({ statusCode: 200, data: { data: { signOut: true } }, header: {} })
  )
  // 模拟「模块加载前用户已登录」：client.ts 的模块级 authToken 只在 import 时读一次 storage。
  mocks.storage.set(KEY.authToken, 'token-user-a')
  await loadApi()
})

describe('signOut 真实链路清户主侧账号键（#1079 P2 回归守卫）', () => {
  it('A 退出：active + guest 草稿桶、两条闪念间残留全部清掉；B 草稿与 handoff 标记不动', async () => {
    seedSignedInState('user-a')

    await signOut()

    expect(mocks.request).toHaveBeenCalledOnce()
    expect(mocks.storage.has(`cgc.wish-draft.user-a`)).toBe(false)
    expect(mocks.storage.has('cgc.wish-draft.guest')).toBe(false)
    expect(mocks.storage.has('cgc.flashback_entry_intent')).toBe(false)
    expect(mocks.storage.has('cgc.flashback_last_guest_quote')).toBe(false)
    expect(mocks.storage.get('cgc.wish-draft.user-b')).toEqual({ content: 'B 草稿' })
    expect(mocks.storage.get('cgc.wish-draft.login-handoff')).toEqual({ owner: null, requestId: 'r1' })
    expect(mocks.storage.has(KEY.authToken)).toBe(false)
    expect(mocks.storage.has(KEY.activeUser)).toBe(false)
    expect(mocks.storage.has(KEY.flashbackToken)).toBe(false)
    expect(mocks.storage.has(KEY.lastEnrollment)).toBe(false)
    expect(mocks.storage.has(KEY.pendingScene)).toBe(false)
    expect(mocks.storage.has(KEY.workspaceTab)).toBe(false)
    expect(mocks.storage.get(KEY.silentLoginOff)).toBe('1')
  })

  it('未登录（无 token）也照常清 guest 桶与游客残留；静默登录关闭', async () => {
    mocks.storage.delete(KEY.authToken)
    mocks.storage.set('cgc.wish-draft.guest', { content: 'guest 草稿' })
    mocks.storage.set('cgc.flashback_entry_intent', 'welcome')
    mocks.storage.set('cgc.flashback_last_guest_quote', '"圈选"')

    await loadApi() // 未登录态下重新加载模块，authToken 为 null → 不发 signOut mutation
    const instance = new api.RealMiniProgramApi()
    await instance.signOut()

    expect(mocks.request).not.toHaveBeenCalled()
    expect(mocks.storage.has('cgc.wish-draft.guest')).toBe(false)
    expect(mocks.storage.has('cgc.flashback_entry_intent')).toBe(false)
    expect(mocks.storage.has('cgc.flashback_last_guest_quote')).toBe(false)
    expect(mocks.storage.get(KEY.silentLoginOff)).toBe('1')
  })

  it('草稿删除抛错：仍完成强制清理（token / account / 静默登录），错误最终抛回调用方', async () => {
    seedSignedInState('user-a')
    const failingTaro = await import('@tarojs/taro')
    const realRemove = failingTaro.default.removeStorageSync
    vi.mocked(failingTaro.default).removeStorageSync = ((key: string) => {
      if (key === 'cgc.wish-draft.user-a') throw new Error('storage removal failed')
      realRemove(key)
    }) as typeof realRemove

    const instance = new api.RealMiniProgramApi()
    await expect(instance.signOut()).rejects.toThrow('storage removal failed')

    expect(mocks.storage.has(KEY.authToken)).toBe(false)
    expect(mocks.storage.has(KEY.activeUser)).toBe(false)
    expect(mocks.storage.get(KEY.silentLoginOff)).toBe('1')
  })
})
