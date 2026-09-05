import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const mocks = vi.hoisted(() => ({
  getAuthToken: vi.fn(),
  setAuthToken: vi.fn(),
  graphqlRequest: vi.fn(),
  isAuthenticationError: vi.fn(),
  clearExpiredAuthentication: vi.fn(),
  clearWorkspaceTab: vi.fn(),
  rememberWorkspaceTab: vi.fn(),
  activateAccount: vi.fn(),
  clearAccountState: vi.fn(),
  appendLocalNotification: vi.fn(),
  readLocalNotifications: vi.fn(),
  currentPlatform: vi.fn(),
  // 与 src/api/client.ts 同构:real.ts instanceof 判定用(真模块有 Taro 副作用,不 importOriginal)
  GraphQLRequestError: class extends Error {
    statusCode: number
    errors: Array<{ message: string; code?: string }>
    constructor(message: string, statusCode = 0, errors: Array<{ message: string; code?: string }> = []) {
      super(message)
      this.name = 'GraphQLRequestError'
      this.statusCode = statusCode
      this.errors = errors
    }
  }
}))

vi.mock('../src/api/client', () => ({
  getAuthToken: mocks.getAuthToken,
  setAuthToken: mocks.setAuthToken,
  graphqlRequest: mocks.graphqlRequest,
  isAuthenticationError: mocks.isAuthenticationError,
  clearExpiredAuthentication: mocks.clearExpiredAuthentication,
  GraphQLRequestError: mocks.GraphQLRequestError
}))

vi.mock('../src/api/operations', () => ({
  SessionQueryDocument: 'SESSION_QUERY',
  SignInWithPlatformMutationDocument: 'SIGN_IN_MUTATION',
  SignOutMutationDocument: 'SIGN_OUT_MUTATION',
  CatalogQueryDocument: 'CATALOG',
  EventDetailQueryDocument: 'EVENT_DETAIL',
  CourseDetailQueryDocument: 'COURSE_DETAIL',
  MyEnrollmentsQueryDocument: 'MY_ENROLLMENTS',
  EnrollmentQueryDocument: 'ENROLLMENT_QUERY',
  CancelEnrollmentMutationDocument: 'CANCEL_ENROLLMENT',
  CreateEnrollmentMutationDocument: 'CREATE_ENROLLMENT',
  ConfirmEnrollmentMutationDocument: 'CONFIRM_ENROLLMENT',
  RejectEnrollmentMutationDocument: 'REJECT_ENROLLMENT',
  ApproveJoinRequestMutationDocument: 'APPROVE_JOIN',
  RejectJoinRequestMutationDocument: 'REJECT_JOIN',
  GrantConsentMutationDocument: 'GRANT_CONSENT',
  GenerateMiniProgramCodeMutationDocument: 'GENERATE_CODE',
  AdmitMemberByTokenMutationDocument: 'ADMIT_MEMBER'
}))

vi.mock('../src/state/workspaceTab', () => ({
  clearWorkspaceTab: mocks.clearWorkspaceTab,
  rememberWorkspaceTab: mocks.rememberWorkspaceTab
}))

vi.mock('../src/state/accountState', () => ({
  activateAccount: mocks.activateAccount,
  appendLocalNotification: mocks.appendLocalNotification,
  clearAccountState: mocks.clearAccountState,
  readLocalNotifications: mocks.readLocalNotifications
}))

vi.mock('../src/platform', () => ({
  currentPlatform: mocks.currentPlatform
}))

import { RealMiniProgramApi } from '../src/api/real'

const SESSION_USER = {
  id: 'u-42',
  displayName: 'Ada',
  email: 'ada@example.com',
  memberNumber: 'M1'
}

function sessionData() {
  return { me: SESSION_USER, meWorkspaces: [], myPendingApprovals: [] }
}

beforeEach(() => {
  vi.clearAllMocks()
  mocks.currentPlatform.mockReturnValue('weapp')
  mocks.isAuthenticationError.mockReturnValue(false)
})

describe('sign-in 两阶段事务', () => {
  it('mutation 成功得到 token，但 session hydration 失败 → token/Workspace/account 全回滚', async () => {
    mocks.getAuthToken.mockReturnValue('new-token')
    mocks.graphqlRequest.mockImplementation((doc: string) => {
      if (doc === 'SIGN_IN_MUTATION') return Promise.resolve({})
      if (doc === 'SESSION_QUERY') return Promise.reject(new Error('session hydration failed'))
      return Promise.resolve({})
    })
    const api = new RealMiniProgramApi()
    await expect(api.signIn({ loginCode: 'c', encryptedData: 'e', iv: 'i' })).rejects.toThrow(
      'session hydration failed'
    )
    // 回滚路径：token 置空、Workspace 与账号状态清理
    expect(mocks.setAuthToken).toHaveBeenCalledWith(null)
    expect(mocks.clearWorkspaceTab).toHaveBeenCalled()
    expect(mocks.clearAccountState).toHaveBeenCalled()
    expect(mocks.activateAccount).not.toHaveBeenCalled()
  })

  it('完整登录成功 → activateAccount 收到 session user ID，返回原 session', async () => {
    mocks.getAuthToken.mockReturnValue('new-token')
    mocks.graphqlRequest.mockImplementation((doc: string) => {
      if (doc === 'SIGN_IN_MUTATION') return Promise.resolve({})
      if (doc === 'SESSION_QUERY') return Promise.resolve(sessionData())
      return Promise.resolve({})
    })
    const api = new RealMiniProgramApi()
    const result = await api.signIn({ loginCode: 'c', encryptedData: 'e', iv: 'i' })
    expect(mocks.activateAccount).toHaveBeenCalledWith('u-42')
    expect(result.user?.id).toBe('u-42')
    // 事务开始清旧账号状态一次，成功后不触发回滚路径
    expect(mocks.clearAccountState).toHaveBeenCalledTimes(1)
  })
})

describe('signIn phoneCode 新契约变量形状', () => {
  afterEach(() => {
    vi.unstubAllEnvs()
  })

  it('phoneCode 在场（weapp 新契约）→ variables 含 phoneCode 且不含 encryptedData/iv', async () => {
    vi.stubEnv('TARO_ENV', 'weapp')
    mocks.getAuthToken.mockReturnValue('new-token')
    mocks.graphqlRequest.mockImplementation((doc: string) => {
      if (doc === 'SIGN_IN_MUTATION') return Promise.resolve({})
      if (doc === 'SESSION_QUERY') return Promise.resolve(sessionData())
      return Promise.resolve({})
    })
    const api = new RealMiniProgramApi()
    await api.signIn({ loginCode: 'c', code: 'pc-1' })

    const [, variables] = mocks.graphqlRequest.mock.calls.find(
      (call: unknown[]) => call[0] === 'SIGN_IN_MUTATION'
    ) as [string, Record<string, unknown>]
    expect(variables.phoneCode).toBe('pc-1')
    expect('encryptedData' in variables).toBe(true)
    expect(variables.encryptedData).toBeNull()
    expect(variables.iv).toBeNull()
  })

  it('tt：code 在场（抖音 ≥3.51.0 回调形状）→ variables 发 phoneCode 且 legacy 字段为 null', async () => {
    vi.stubEnv('TARO_ENV', 'tt')
    mocks.getAuthToken.mockReturnValue('new-token')
    mocks.graphqlRequest.mockImplementation((doc: string) => {
      if (doc === 'SIGN_IN_MUTATION') return Promise.resolve({})
      if (doc === 'SESSION_QUERY') return Promise.resolve(sessionData())
      return Promise.resolve({})
    })
    const api = new RealMiniProgramApi()
    await api.signIn({ loginCode: 'c', code: 'tt-callback-code' })

    const [, variables] = mocks.graphqlRequest.mock.calls.find(
      (call: unknown[]) => call[0] === 'SIGN_IN_MUTATION'
    ) as [string, Record<string, unknown>]
    expect(variables.phoneCode).toBe('tt-callback-code')
    expect(variables.encryptedData).toBeNull()
    expect(variables.iv).toBeNull()
  })

  it('xhs：code 与 encryptedData/iv 并存 → code 剥离出契约走 legacy（advisor09 F1 gate 收窄至 xhs）', async () => {
    // TARO_ENV stub 为 xhs：gate 关闭，回调里的 code 字段被剥离出契约
    vi.stubEnv('TARO_ENV', 'xhs')
    mocks.getAuthToken.mockReturnValue('new-token')
    mocks.graphqlRequest.mockImplementation((doc: string) => {
      if (doc === 'SIGN_IN_MUTATION') return Promise.resolve({})
      if (doc === 'SESSION_QUERY') return Promise.resolve(sessionData())
      return Promise.resolve({})
    })
    const api = new RealMiniProgramApi()
    await api.signIn({ loginCode: 'c', code: 'xhs-callback-code', encryptedData: 'e', iv: 'i' })

    const [, variables] = mocks.graphqlRequest.mock.calls.find(
      (call: unknown[]) => call[0] === 'SIGN_IN_MUTATION'
    ) as [string, Record<string, unknown>]
    expect(variables.phoneCode).toBeUndefined()
    expect(variables.encryptedData).toBe('e')
    expect(variables.iv).toBe('i')
  })

  it('xhs：只给 code（无 legacy 字段）→ 参数不完整拒绝，不发起 mutation', async () => {
    vi.stubEnv('TARO_ENV', 'xhs')
    const api = new RealMiniProgramApi()
    await expect(api.signIn({ loginCode: 'c', code: 'xhs-only-code' })).rejects.toThrow(
      '平台登录参数不完整'
    )
    expect(mocks.graphqlRequest).not.toHaveBeenCalled()
  })

  it('phoneCode 缺 + encryptedData/iv 齐（legacy）→ variables 不带 phoneCode 键值', async () => {
    mocks.getAuthToken.mockReturnValue('new-token')
    mocks.graphqlRequest.mockImplementation((doc: string) => {
      if (doc === 'SIGN_IN_MUTATION') return Promise.resolve({})
      if (doc === 'SESSION_QUERY') return Promise.resolve(sessionData())
      return Promise.resolve({})
    })
    const api = new RealMiniProgramApi()
    await api.signIn({ loginCode: 'c', encryptedData: 'e', iv: 'i' })

    const [, variables] = mocks.graphqlRequest.mock.calls.find(
      (call: unknown[]) => call[0] === 'SIGN_IN_MUTATION'
    ) as [string, Record<string, unknown>]
    expect(variables.phoneCode).toBeUndefined()
    expect(variables.encryptedData).toBe('e')
    expect(variables.iv).toBe('i')
  })

  it('phoneCode 与 legacy 都缺 → 参数不完整直接拒绝（不发起 mutation）', async () => {
    const api = new RealMiniProgramApi()
    await expect(api.signIn({ loginCode: 'c' })).rejects.toThrow('平台登录参数不完整')
    expect(mocks.graphqlRequest).not.toHaveBeenCalled()
  })
})

describe('sign-out 事务', () => {
  it('GraphQL sign-out reject → finally 仍清 token/Workspace/账号状态与 pending scene', async () => {
    mocks.getAuthToken.mockReturnValue('old-token')
    mocks.graphqlRequest.mockImplementation((doc: string) => {
      if (doc === 'SIGN_OUT_MUTATION') return Promise.reject(new Error('sign-out network failed'))
      return Promise.resolve({})
    })
    const api = new RealMiniProgramApi()
    await expect(api.signOut()).rejects.toThrow('sign-out network failed')
    expect(mocks.setAuthToken).toHaveBeenCalledWith(null)
    expect(mocks.clearWorkspaceTab).toHaveBeenCalled()
    expect(mocks.clearAccountState).toHaveBeenCalledWith({ clearPendingScene: true })
  })

  it('无 token 时 sign-out 不调用 GraphQL，仍清全部状态', async () => {
    mocks.getAuthToken.mockReturnValue(null)
    const api = new RealMiniProgramApi()
    await api.signOut()
    expect(mocks.graphqlRequest).not.toHaveBeenCalled()
    expect(mocks.clearAccountState).toHaveBeenCalledWith({ clearPendingScene: true })
  })
})

describe('getSession 匿名边界', () => {
  it('无 token → 匿名 snapshot，清残留账号但保留 pending scene', async () => {
    mocks.getAuthToken.mockReturnValue(null)
    const api = new RealMiniProgramApi()
    const result = await api.getSession()
    expect(result).toEqual({ user: null, workspaces: [], approvals: [] })
    expect(mocks.clearAccountState).toHaveBeenCalledWith()
    expect(mocks.clearWorkspaceTab).toHaveBeenCalled()
  })
})
describe('getSession 错误降级(真机事故回归:坏 token 不该拖死发现页)', () => {
  it('服务端非认证错误(如 forbidden)→ 降级空 session + 清坏 token', async () => {
    mocks.getAuthToken.mockReturnValue('stale-token')
    mocks.graphqlRequest.mockRejectedValue(
      new mocks.GraphQLRequestError('Forbidden', 200, [{ message: 'Forbidden' }])
    )
    const result = await new RealMiniProgramApi().getSession()
    expect(result).toEqual({ user: null, workspaces: [], approvals: [] })
    expect(mocks.clearExpiredAuthentication).toHaveBeenCalled()
  })

  it('网络层失败(未到达服务端)→ 降级空 session 但保留 token', async () => {
    mocks.getAuthToken.mockReturnValue('good-token')
    mocks.graphqlRequest.mockRejectedValue(new Error('request:fail timeout'))
    const result = await new RealMiniProgramApi().getSession()
    expect(result).toEqual({ user: null, workspaces: [], approvals: [] })
    expect(mocks.clearExpiredAuthentication).not.toHaveBeenCalled()
    expect(mocks.clearWorkspaceTab).toHaveBeenCalled()
    expect(mocks.clearAccountState).toHaveBeenCalledWith()
  })

  it('认证错误 → 降级空 session(token 由 client.ts 清,不重复清)', async () => {
    mocks.getAuthToken.mockReturnValue('expired-token')
    mocks.isAuthenticationError.mockReturnValue(true)
    mocks.graphqlRequest.mockRejectedValue(
      new mocks.GraphQLRequestError('unauthorized', 200, [{ message: 'unauthorized', code: 'unauthorized' }])
    )
    const result = await new RealMiniProgramApi().getSession()
    expect(result).toEqual({ user: null, workspaces: [], approvals: [] })
    expect(mocks.clearExpiredAuthentication).not.toHaveBeenCalled()
  })
})
describe('admitMember 错误中文化(后端英文消息不得透传 UI)', () => {
  it('invalid_or_expired_scene → 邀请码无效或已过期', async () => {
    mocks.graphqlRequest.mockRejectedValue(
      new mocks.GraphQLRequestError('Invitation has already been used or scene has expired', 200, [
        { message: 'Invitation has already been used or scene has expired', code: 'invalid_or_expired_scene' }
      ])
    )
    await expect(new RealMiniProgramApi().admitMember('X')).rejects.toThrow('邀请码无效或已过期')
  })

  it('invalid_scene → 邀请码格式不正确', async () => {
    mocks.graphqlRequest.mockRejectedValue(
      new mocks.GraphQLRequestError('Invalid scene', 200, [
        { message: 'Invalid scene', code: 'invalid_scene' }
      ])
    )
    await expect(new RealMiniProgramApi().admitMember('!!!')).rejects.toThrow('邀请码格式不正确')
  })

  it('未识别错误(如网络)→ 原样透传,不吞不译', async () => {
    mocks.graphqlRequest.mockRejectedValue(new Error('request:fail timeout'))
    await expect(new RealMiniProgramApi().admitMember('X')).rejects.toThrow('request:fail timeout')
  })
})



describe('cancel enrollment', () => {
  it('成功取消报名并传递 enrollment ID', async () => {
    mocks.graphqlRequest.mockResolvedValue({
      cancelEnrollment: {
        result: { id: 'enr-1', status: 'cancelled' },
        errors: []
      }
    })
    const api = new RealMiniProgramApi()

    await api.cancelEnrollment('enr-1')

    expect(mocks.graphqlRequest).toHaveBeenCalledWith('CANCEL_ENROLLMENT', { id: 'enr-1' })
  })

  it('already_processed 错误视为幂等成功', async () => {
    mocks.graphqlRequest.mockResolvedValue({
      cancelEnrollment: {
        result: null,
        errors: [{ code: 'enrollment_already_processed', message: '已处理' }]
      }
    })
    const api = new RealMiniProgramApi()

    await expect(api.cancelEnrollment('enr-1')).resolves.toBeUndefined()
  })
})
