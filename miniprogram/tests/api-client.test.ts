import { beforeEach, describe, expect, it, vi } from 'vitest'
import type * as ClientApi from '../src/api/client'

const AUTH_TOKEN_KEY = 'cgc.auth_token'
const WORKSPACE_KEY = 'cgc.workspace_tab_visible'
// fixture token 用明显的测试串，绝不落真实 cookie/credential
const FIXTURE_TOKEN = 'fixture-token-abc'

const mocks = vi.hoisted(() => {
  const storage = new Map<string, unknown>()
  return {
    storage,
    request: vi.fn(),
    getStorageSync: vi.fn(),
    setStorageSync: vi.fn(),
    removeStorageSync: vi.fn(),
    trigger: vi.fn(),
    on: vi.fn(),
    off: vi.fn()
  }
})

vi.mock('@tarojs/taro', () => ({
  default: {
    request: mocks.request,
    getStorageSync: mocks.getStorageSync,
    setStorageSync: mocks.setStorageSync,
    removeStorageSync: mocks.removeStorageSync,
    eventCenter: { trigger: mocks.trigger, on: mocks.on, off: mocks.off }
  }
}))

let client: typeof ClientApi

function okResponse(data: unknown, header: Record<string, unknown> = {}, cookies: string[] = []) {
  return { statusCode: 200, data: { data }, header, cookies }
}

function httpResponse(statusCode: number, body: unknown = { data: null }, header: Record<string, unknown> = {}, cookies: string[] = []) {
  return { statusCode, data: body, header, cookies }
}

// 动态 import 是刻意为之：client.ts 在模块加载时把 storage token 读入 module-level
// 变量，每个测试必须 resetModules 后重新加载才能隔离认证状态（测试用例加载边界）。
async function loadClient() {
  vi.resetModules()
  client = await import('../src/api/client')
  return client
}

beforeEach(async () => {
  mocks.storage.clear()
  vi.clearAllMocks()
  // restoreMocks 会在每个 test 前清空实现，这里重新注入 mock 实现
  mocks.request.mockImplementation(() => Promise.reject(new Error('request not stubbed')))
  mocks.getStorageSync.mockImplementation((key: string) => mocks.storage.get(key))
  mocks.setStorageSync.mockImplementation((key: string, value: unknown) => {
    mocks.storage.set(key, value)
  })
  mocks.removeStorageSync.mockImplementation((key: string) => {
    mocks.storage.delete(key)
  })
  await loadClient()
})

describe('成功请求与 cookie 形态', () => {
  it('storage 初始 token 生成 Authorization；无 token 时不发送', async () => {
    mocks.storage.set(AUTH_TOKEN_KEY, FIXTURE_TOKEN)
    await loadClient()
    mocks.request.mockResolvedValue(okResponse({ ok: true }))
    await client.graphqlRequest('query { me { id } }', {})
    expect(mocks.request.mock.calls[0][0].header.Authorization).toBe(`Bearer ${FIXTURE_TOKEN}`)

    mocks.request.mockClear()
    mocks.storage.clear()
    await loadClient() // 空 storage 重新加载
    mocks.request.mockResolvedValue(okResponse({ ok: true }))
    await client.graphqlRequest('query { me { id } }', {})
    expect(mocks.request.mock.calls[0][0].header.Authorization).toBeUndefined()
  })

  it('captureAuthCookie 从 response.cookies 保存 token', async () => {
    mocks.request.mockResolvedValue(okResponse({ me: { id: 'u1' } }, {}, ['cgc_token=abc123; Path=/']))
    const data = await client.graphqlRequest('query Q { me { id } }', {}, { captureAuthCookie: true })
    expect(data).toEqual({ me: { id: 'u1' } })
    expect(client.getAuthToken()).toBe('abc123')
    expect(mocks.storage.get(AUTH_TOKEN_KEY)).toBe('abc123')
  })

  it('小写 set-cookie 字符串形式保存 token', async () => {
    mocks.request.mockResolvedValue(okResponse({ ok: true }, { 'set-cookie': 'cgc_token=from-lower-header; Path=/' }))
    await client.graphqlRequest('q', {}, { captureAuthCookie: true })
    expect(client.getAuthToken()).toBe('from-lower-header')
  })

  it('大写 Set-Cookie 数组形式保存 token', async () => {
    mocks.request.mockResolvedValue(
      okResponse({ ok: true }, { 'Set-Cookie': ['cgc_token=from-upper-header; Path=/'] })
    )
    await client.graphqlRequest('q', {}, { captureAuthCookie: true })
    expect(client.getAuthToken()).toBe('from-upper-header')
  })

  it('请求固定指向测试 endpoint，POST、timeout 15000、携带 query/variables', async () => {
    mocks.request.mockResolvedValue(okResponse({ ok: true }))
    await client.graphqlRequest('query Q($id: ID!) { event(id: $id) { id } }', { id: 'e1' })
    const options = mocks.request.mock.calls[0][0]
    expect(options.url).toBe('https://example.invalid/graphql')
    expect(options.method).toBe('POST')
    expect(options.timeout).toBe(15_000)
    expect(options.data).toEqual({
      query: 'query Q($id: ID!) { event(id: $id) { id } }',
      variables: { id: 'e1' }
    })
  })

  it('2xx data 返回调用方，不泄漏完整 response', async () => {
    mocks.request.mockResolvedValue(okResponse({ events: [] }, { 'x-server': 'internal' }, ['other=1']))
    const data = await client.graphqlRequest('q', {})
    expect(data).toEqual({ events: [] })
  })
})

describe('失败分类与状态清理', () => {
  it('HTTP 401 抛 GraphQLRequestError，清除 token 与 Workspace 可见性', async () => {
    mocks.storage.set(AUTH_TOKEN_KEY, FIXTURE_TOKEN)
    mocks.storage.set(WORKSPACE_KEY, true)
    await loadClient()
    mocks.request.mockResolvedValue(httpResponse(401))
    await expect(client.graphqlRequest('q', {})).rejects.toMatchObject({
      name: 'GraphQLRequestError',
      statusCode: 401
    })
    expect(client.getAuthToken()).toBeNull()
    expect(mocks.storage.has(AUTH_TOKEN_KEY)).toBe(false)
    expect(mocks.storage.has(WORKSPACE_KEY)).toBe(false)
  })

  it.each([
    ['code', 'unauthorized'],
    ['code', 'unauthenticated'],
    ['code', 'not_authenticated'],
    ['extensions.code', 'unauthorized'],
    ['extensions.code', 'unauthenticated'],
    ['extensions.code', 'not_authenticated']
  ])('GraphQL %s 为 %s 时清除认证状态', async (field, value) => {
    mocks.storage.set(AUTH_TOKEN_KEY, FIXTURE_TOKEN)
    await loadClient()
    const errors = [
      { message: 'denied', ...(field === 'code' ? { code: value } : { extensions: { code: value } }) }
    ]
    mocks.request.mockResolvedValue(httpResponse(200, { data: null, errors }))
    await expect(client.graphqlRequest('q', {})).rejects.toMatchObject({ name: 'GraphQLRequestError' })
    expect(client.getAuthToken()).toBeNull()
    expect(mocks.storage.has(AUTH_TOKEN_KEY)).toBe(false)
  })

  it('HTTP 500 抛错但保留现有 token', async () => {
    mocks.storage.set(AUTH_TOKEN_KEY, FIXTURE_TOKEN)
    await loadClient()
    mocks.request.mockResolvedValue(httpResponse(500))
    await expect(client.graphqlRequest('q', {})).rejects.toMatchObject({ statusCode: 500 })
    expect(client.getAuthToken()).toBe(FIXTURE_TOKEN)
  })

  it('普通 GraphQL validation error 抛错但保留 token', async () => {
    mocks.storage.set(AUTH_TOKEN_KEY, FIXTURE_TOKEN)
    await loadClient()
    mocks.request.mockResolvedValue(
      httpResponse(200, { data: null, errors: [{ message: 'validation failed', code: 'validation' }] })
    )
    await expect(client.graphqlRequest('q', {})).rejects.toMatchObject({ name: 'GraphQLRequestError' })
    expect(client.getAuthToken()).toBe(FIXTURE_TOKEN)
  })

  it('2xx 无 errors 但缺 data 抛「服务端未返回数据」', async () => {
    mocks.request.mockResolvedValue(httpResponse(200, {}))
    await expect(client.graphqlRequest('q', {})).rejects.toThrow('服务端未返回数据')
  })

  it('Taro.request 网络 reject 原样传播并保留 token', async () => {
    mocks.storage.set(AUTH_TOKEN_KEY, FIXTURE_TOKEN)
    await loadClient()
    const networkError = new TypeError('Network request failed')
    mocks.request.mockRejectedValue(networkError)
    await expect(client.graphqlRequest('q', {})).rejects.toBe(networkError)
    expect(client.getAuthToken()).toBe(FIXTURE_TOKEN)
  })

  it('isAuthenticationError 对普通 Error 返回 false', () => {
    expect(client.isAuthenticationError(new Error('boom'))).toBe(false)
  })
})

describe('认证提交顺序（candidate cookie 只在成功响应后落盘）', () => {
  function authWrites(): Array<[string, unknown]> {
    return mocks.setStorageSync.mock.calls.filter(([key]) => key === AUTH_TOKEN_KEY)
  }

  it('401 携 cookie：candidate 从未写入 auth key，最终 token 为空', async () => {
    mocks.storage.set(AUTH_TOKEN_KEY, FIXTURE_TOKEN)
    await loadClient()
    const candidate = 'should-never-commit-401'
    mocks.request.mockResolvedValue(
      httpResponse(401, { data: null }, {}, [`cgc_token=${candidate}; Path=/`])
    )
    await expect(client.graphqlRequest('q', {}, { captureAuthCookie: true })).rejects.toMatchObject({
      statusCode: 401
    })
    expect(client.getAuthToken()).toBeNull()
    expect(authWrites().some(([, value]) => value === candidate)).toBe(false)
  })

  it('200 带 GraphQL auth error + cookie：不提交 candidate，并清旧认证状态', async () => {
    mocks.storage.set(AUTH_TOKEN_KEY, FIXTURE_TOKEN)
    await loadClient()
    const candidate = 'should-never-commit-auth-error'
    mocks.request.mockResolvedValue(
      httpResponse(
        200,
        { data: null, errors: [{ message: 'denied', code: 'unauthorized' }] },
        {},
        [`cgc_token=${candidate}; Path=/`]
      )
    )
    await expect(client.graphqlRequest('q', {}, { captureAuthCookie: true })).rejects.toMatchObject({
      name: 'GraphQLRequestError'
    })
    expect(client.getAuthToken()).toBeNull()
    expect(authWrites().some(([, value]) => value === candidate)).toBe(false)
  })

  it('200 带普通 GraphQL error + cookie：不提交 candidate，保留旧 token', async () => {
    mocks.storage.set(AUTH_TOKEN_KEY, FIXTURE_TOKEN)
    await loadClient()
    const candidate = 'should-never-commit-validation'
    mocks.request.mockResolvedValue(
      httpResponse(
        200,
        { data: null, errors: [{ message: 'validation failed', code: 'validation' }] },
        {},
        [`cgc_token=${candidate}; Path=/`]
      )
    )
    await expect(client.graphqlRequest('q', {}, { captureAuthCookie: true })).rejects.toMatchObject({
      name: 'GraphQLRequestError'
    })
    expect(client.getAuthToken()).toBe(FIXTURE_TOKEN)
    expect(authWrites().some(([, value]) => value === candidate)).toBe(false)
  })

  it('200 缺 data + cookie：不提交 candidate，保留旧 token', async () => {
    mocks.storage.set(AUTH_TOKEN_KEY, FIXTURE_TOKEN)
    await loadClient()
    const candidate = 'should-never-commit-empty-data'
    mocks.request.mockResolvedValue(
      httpResponse(200, {}, {}, [`cgc_token=${candidate}; Path=/`])
    )
    await expect(client.graphqlRequest('q', {}, { captureAuthCookie: true })).rejects.toThrow(
      '服务端未返回数据'
    )
    expect(client.getAuthToken()).toBe(FIXTURE_TOKEN)
    expect(authWrites().some(([, value]) => value === candidate)).toBe(false)
  })

  it('只有 2xx 无 errors 有 data 时才提交 candidate token', async () => {
    const candidate = 'commit-on-success'
    mocks.request.mockResolvedValue(okResponse({ ok: true }, {}, [`cgc_token=${candidate}; Path=/`]))
    const data = await client.graphqlRequest('q', {}, { captureAuthCookie: true })
    expect(data).toEqual({ ok: true })
    expect(client.getAuthToken()).toBe(candidate)
    expect(authWrites().some(([, value]) => value === candidate)).toBe(true)
  })
})
