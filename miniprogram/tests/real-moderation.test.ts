import { beforeEach, describe, expect, it, vi } from 'vitest'

// #558 后续：canModerateEvent 的入口门判定——Owner/Admin（session 角色）∨
// 我在 eventModerators 列表（非管理角色主理人）。普通成员读列表 forbidden →
// false；匿名/非成员探测不到 workspaceId → false。

const mocks = vi.hoisted(() => ({
  getAuthToken: vi.fn(),
  setAuthToken: vi.fn(),
  graphqlRequest: vi.fn(),
  isAuthenticationError: vi.fn(),
  clearWorkspaceTab: vi.fn(),
  rememberWorkspaceTab: vi.fn(),
  activateAccount: vi.fn(),
  clearAccountState: vi.fn(),
  appendLocalNotification: vi.fn(),
  readLocalNotifications: vi.fn()
}))

vi.mock('../src/api/client', () => ({
  getAuthToken: mocks.getAuthToken,
  setAuthToken: mocks.setAuthToken,
  graphqlRequest: mocks.graphqlRequest,
  isAuthenticationError: mocks.isAuthenticationError,
  GraphQLRequestError: class GraphQLRequestError extends Error {
    constructor(
      message: string,
      public statusCode: number,
      public errors: Array<{ message: string; code?: string }> = []
    ) {
      super(message)
    }
  }
}))

vi.mock('../src/api/operations', () => ({
  SessionQueryDocument: 'SESSION_QUERY',
  EventModerationScopeQueryDocument: 'MODERATION_SCOPE',
  EventModeratorsQueryDocument: 'EVENT_MODERATORS'
}))

vi.mock('../src/state/workspaceTab', () => ({
  clearWorkspaceTab: mocks.clearWorkspaceTab,
  rememberWorkspaceTab: mocks.rememberWorkspaceTab
}))

// real.ts 引用的 state 模块都 import @tarojs/taro（vitest 里缺构建期全局量）：与 accountState 一样整块 mock
vi.mock('../src/state/silentLogin', () => ({
  silentLoginAllowed: () => true,
  setSilentLoginAllowed: () => undefined
}))

vi.mock('../src/state/accountState', () => ({
  activateAccount: mocks.activateAccount,
  clearAccountState: mocks.clearAccountState,
  appendLocalNotification: mocks.appendLocalNotification,
  readLocalNotifications: mocks.readLocalNotifications
}))

// @/platform 顶层 import Taro（runtime 在 node 测试态不可用）——mock 掉
vi.mock('../src/platform', () => ({ currentPlatform: () => 'wechat' }))

import { RealMiniProgramApi } from '../src/api/real'

const SESSION_BASE = {
  me: { id: 'user-1', email: 'mod@example.com', displayName: '主理人', memberNumber: null },
  myPendingApprovals: []
}

function sessionWith(roleNames: string[]) {
  return {
    ...SESSION_BASE,
    meWorkspaces: [
      {
        id: 'ws-1',
        slug: 'cgc',
        name: 'CGC',
        joinPolicy: 'open',
        myRoleNames: roleNames,
        myMembershipId: 'm-1',
        canAccess: true,
        myAbilities: [],
        memberCount: 10
      }
    ]
  }
}

/** 按文档标签分派 graphqlRequest 返回值 */
function stubRequests(opts: {
  roleNames: string[]
  scope?: 'ok' | 'null' | 'throw'
  moderators?: string[] | 'throw'
}) {
  mocks.graphqlRequest.mockImplementation((doc: string, variables: Record<string, unknown>) => {
    if (doc === 'SESSION_QUERY') return Promise.resolve(sessionWith(opts.roleNames))
    if (doc === 'MODERATION_SCOPE') {
      if (opts.scope === 'throw') return Promise.reject(new Error('forbidden_field'))
      if (opts.scope === 'null') return Promise.resolve({ getEvent: null })
      return Promise.resolve({ getEvent: { id: variables.id, workspaceId: 'ws-1' } })
    }
    if (doc === 'EVENT_MODERATORS') {
      if (opts.moderators === 'throw') return Promise.reject(new Error('forbidden'))
      return Promise.resolve({
        eventModerators: (opts.moderators ?? []).map((userId) => ({ userId }))
      })
    }
    return Promise.reject(new Error(`unexpected doc: ${doc}`))
  })
}

describe('canModerateEvent（#558 后续：主理人入口门）', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    mocks.getAuthToken.mockReturnValue('token-1')
    mocks.isAuthenticationError.mockReturnValue(false)
    mocks.readLocalNotifications.mockReturnValue([])
  })

  it('未登录 → false（不发任何请求）', async () => {
    mocks.getAuthToken.mockReturnValue(null)
    const api = new RealMiniProgramApi()

    expect(await api.canModerateEvent('evt-1')).toBe(false)
    expect(mocks.graphqlRequest).not.toHaveBeenCalled()
  })

  it('Owner/Admin 角色 → true（只发 scope 探测，不查主理人列表）', async () => {
    stubRequests({ roleNames: ['owner'] })
    const api = new RealMiniProgramApi()

    expect(await api.canModerateEvent('evt-1')).toBe(true)
    const docs = mocks.graphqlRequest.mock.calls.map((call) => call[0])
    expect(docs).toContain('MODERATION_SCOPE')
    expect(docs).not.toContain('EVENT_MODERATORS')
  })

  it('非管理角色 + 我在主理人列表 → true（两查询都发）', async () => {
    stubRequests({ roleNames: ['learner'], moderators: ['user-1'] })
    const api = new RealMiniProgramApi()

    expect(await api.canModerateEvent('evt-1')).toBe(true)
    const docs = mocks.graphqlRequest.mock.calls.map((call) => call[0])
    expect(docs).toContain('EVENT_MODERATORS')
  })

  it('非管理角色 + 我不在列表 → false', async () => {
    stubRequests({ roleNames: ['learner'], moderators: ['someone-else'] })
    const api = new RealMiniProgramApi()

    expect(await api.canModerateEvent('evt-1')).toBe(false)
  })

  it('普通成员读列表 forbidden（throw）→ false', async () => {
    stubRequests({ roleNames: ['learner'], moderators: 'throw' })
    const api = new RealMiniProgramApi()

    expect(await api.canModerateEvent('evt-1')).toBe(false)
  })

  it('scope 探测失败（非成员/匿名/活动不存在）→ false', async () => {
    stubRequests({ roleNames: ['owner'], scope: 'throw' })
    const api = new RealMiniProgramApi()
    expect(await api.canModerateEvent('evt-1')).toBe(false)

    stubRequests({ roleNames: ['owner'], scope: 'null' })
    expect(await api.canModerateEvent('evt-2')).toBe(false)
  })
})
