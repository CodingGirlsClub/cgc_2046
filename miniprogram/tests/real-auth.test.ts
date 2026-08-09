import { beforeEach, describe, expect, it, vi } from 'vitest'

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
  readLocalNotifications: vi.fn(),
  currentPlatform: vi.fn()
}))

vi.mock('../src/api/client', () => ({
  getAuthToken: mocks.getAuthToken,
  setAuthToken: mocks.setAuthToken,
  graphqlRequest: mocks.graphqlRequest,
  isAuthenticationError: mocks.isAuthenticationError
}))

vi.mock('../src/api/operations', () => ({
  SessionQueryDocument: 'SESSION_QUERY',
  SignInWithPlatformMutationDocument: 'SIGN_IN_MUTATION',
  SignOutMutationDocument: 'SIGN_OUT_MUTATION',
  CatalogQueryDocument: 'CATALOG',
  EventDetailQueryDocument: 'EVENT_DETAIL',
  CourseDetailQueryDocument: 'COURSE_DETAIL',
  MyEnrollmentsQueryDocument: 'MY_ENROLLMENTS',
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
