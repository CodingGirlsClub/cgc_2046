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
  AdmitMemberByTokenMutationDocument: 'ADMIT_MEMBER',
  FlashbackCapsuleQueryDocument: 'FLASHBACK_CAPSULE',
  FlashbackCreateWishMutationDocument: 'FLASHBACK_CREATE_WISH',
  FlashbackSetCardSharingMutationDocument: 'FLASHBACK_SET_CARD_SHARING',
  FlashbackSharedCardQueryDocument: 'FLASHBACK_SHARED_CARD'
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

import { RealMiniProgramApi, SessionExpiredError } from '../src/api/real'
import { BusinessError } from '../src/api/business-error'
import { FlashbackNotBoundError, FlashbackTokenInvalidError } from '../src/domain/models'

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
    expect(result).toEqual({ user: null, workspaces: [], approvals: [], authExpired: false })
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
    expect(result).toEqual({ user: null, workspaces: [], approvals: [], authExpired: true })
    expect(mocks.clearExpiredAuthentication).toHaveBeenCalled()
  })

  it('网络层失败(未到达服务端)→ 降级空 session 但保留 token', async () => {
    mocks.getAuthToken.mockReturnValue('good-token')
    mocks.graphqlRequest.mockRejectedValue(new Error('request:fail timeout'))
    const result = await new RealMiniProgramApi().getSession()
    // 网络瞬态（token 保留）不算掉线：下次加载自愈
    expect(result).toEqual({ user: null, workspaces: [], approvals: [], authExpired: false })
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
    // auth 错误 = 真掉线：快照带 authExpired 供 UI 渲染重登空态
    expect(result).toEqual({ user: null, workspaces: [], approvals: [], authExpired: true })
    expect(mocks.clearExpiredAuthentication).not.toHaveBeenCalled()
  })
})

describe('getEnrollments 掉线空态（#355 P0-2：掉线 ≠ 没有报名）', () => {
  it('曾有 token 但会话认证失败 → 拒绝 SessionExpiredError 而非静默 []', async () => {
    mocks.getAuthToken.mockReturnValue('expired-token')
    mocks.isAuthenticationError.mockReturnValue(true)
    mocks.graphqlRequest.mockRejectedValue(
      new mocks.GraphQLRequestError('unauthorized', 200, [{ message: 'unauthorized', code: 'unauthorized' }])
    )
    await expect(new RealMiniProgramApi().getEnrollments()).rejects.toBeInstanceOf(SessionExpiredError)
  })

  it('从未登录（无 token）→ 空数组，维持「还没有报名记录」空态', async () => {
    mocks.getAuthToken.mockReturnValue(null)
    await expect(new RealMiniProgramApi().getEnrollments()).resolves.toEqual([])
  })
})

describe('myPendingApprovals 审批摘要（#355 P0-1：盲批治理）', () => {
  it('映射 requesterName/contextTitle/tierName/amount，requesterName 缺省回退「未知用户」', async () => {
    mocks.getAuthToken.mockReturnValue('token')
    mocks.graphqlRequest.mockResolvedValue({
      me: SESSION_USER,
      meWorkspaces: [{
        id: 'ws-1', slug: 'beijing', name: '北京 CGC', joinPolicy: 'request',
        myRoleNames: ['owner'], myMembershipId: 'm-1', canAccess: true,
        myAbilities: ['manage_members'], memberCount: 2
      }],
      myPendingApprovals: [
        {
          id: 'ap-1', kind: 'enrollment', workspaceId: 'ws-1', userId: 'u-9',
          eventId: 'ev-1', courseId: null, status: 'pending', approvalDeadline: null,
          requesterName: 'Ada', contextTitle: 'Python 工作坊', tierName: null, amount: null
        },
        {
          id: 'ap-2', kind: 'sponsorship', workspaceId: 'ws-1', userId: 'u-10',
          eventId: null, courseId: null, status: 'pending', approvalDeadline: null,
          requesterName: null, contextTitle: null, tierName: '金牌赞助', amount: 3000
        }
      ]
    })
    const { approvals } = await new RealMiniProgramApi().getSession()
    expect(approvals[0]).toMatchObject({
      requesterName: 'Ada', contextTitle: 'Python 工作坊',
      tierName: null, amount: null, workspaceName: '北京 CGC'
    })
    expect(approvals[1]).toMatchObject({ requesterName: '未知用户', tierName: '金牌赞助', amount: 3000 })
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

describe('闪念间 capsule 错误映射与授权档回读（P1/P3）', () => {
  it('未登录 flashback_auth_required → SessionExpiredError（登录引导面可达）', async () => {
    mocks.graphqlRequest.mockRejectedValueOnce(
      new mocks.GraphQLRequestError('token or sign-in required', 200, [
        { message: 'token or sign-in required', code: 'flashback_auth_required' }
      ])
    )
    const api = new RealMiniProgramApi()

    await expect(api.getFlashbackCapsule()).rejects.toBeInstanceOf(SessionExpiredError)
  })

  it('HTTP 401 会话失效（isAuthenticationError 判定）→ SessionExpiredError', async () => {
    mocks.isAuthenticationError.mockReturnValue(true)
    mocks.graphqlRequest.mockRejectedValueOnce(new mocks.GraphQLRequestError('请求失败（HTTP 401）', 401, []))
    const api = new RealMiniProgramApi()

    await expect(api.getFlashbackCapsule()).rejects.toBeInstanceOf(SessionExpiredError)
  })

  it('登录未绑定 flashback_person_not_bound → FlashbackNotBoundError（既有行为回归）', async () => {
    mocks.graphqlRequest.mockRejectedValueOnce(
      new mocks.GraphQLRequestError('no archive bound', 200, [
        { message: 'no archive bound', code: 'flashback_person_not_bound' }
      ])
    )
    const api = new RealMiniProgramApi()

    await expect(api.getFlashbackCapsule()).rejects.toBeInstanceOf(FlashbackNotBoundError)
  })

  it('me.quoteLevel 原样透传（fail-closed parse 在 domain 层）', async () => {
    mocks.graphqlRequest.mockResolvedValueOnce({
      flashbackCapsule: {
        me: {
          id: 'p1',
          fullName: '王小明',
          surname: null,
          city: null,
          occupationThen: null,
          participation: 'attended',
          appliedAt: null,
          quoteLevel: 'anonymous',
          quote: null,
          today: null,
          answers: []
        },
      }
    })
    const api = new RealMiniProgramApi()

    const capsule = await api.getFlashbackCapsule()
    expect(capsule.me.quoteLevel).toBe('anonymous')
  })
})

// ── R20/F2 许愿额度被拒：mapped 错误携带 code（页面据此刷新额度，破死循环） ──

describe('flashbackCreateWish 错误映射（R20/F2：mapped 错误携带 code）', () => {
  it('flashback_wish_quota_exceeded → BusinessError：中文文案 + code 透传', async () => {
    mocks.graphqlRequest.mockRejectedValueOnce(
      new mocks.GraphQLRequestError('quota exceeded', 200, [
        { message: 'quota exceeded', code: 'flashback_wish_quota_exceeded' }
      ])
    )
    const api = new RealMiniProgramApi()

    const error = await api.flashbackCreateWish('想学 Rust', 'private').catch((e: unknown) => e)
    expect(error).toBeInstanceOf(BusinessError)
    expect((error as BusinessError).code).toBe('flashback_wish_quota_exceeded')
    expect((error as Error).message).toBe('今年许愿名额已用完（每年最多 3 条，删除不退还名额）。')
  })

  it('token 失效优先于 mutationError 映射（throwIfFlashbackTokenInvalid 既有优先级不变）', async () => {
    mocks.graphqlRequest.mockRejectedValueOnce(
      new mocks.GraphQLRequestError('token claimed', 200, [
        { message: 'token claimed', code: 'flashback_token_claimed' },
        { message: 'quota exceeded', code: 'flashback_wish_quota_exceeded' }
      ])
    )
    const api = new RealMiniProgramApi()

    await expect(api.flashbackCreateWish('想学 Rust', 'private')).rejects.toBeInstanceOf(FlashbackTokenInvalidError)
  })

  it('未知 code → 兜底 join message，不挂 code（非 BusinessError）', async () => {
    mocks.graphqlRequest.mockRejectedValueOnce(
      new mocks.GraphQLRequestError('something broke', 200, [
        { message: 'something broke', code: 'some_unknown_code' }
      ])
    )
    const api = new RealMiniProgramApi()

    const error = await api.flashbackCreateWish('想学 Rust', 'private').catch((e: unknown) => e)
    expect(error).toBeInstanceOf(Error)
    expect(error).not.toBeInstanceOf(BusinessError)
    expect((error as Error).message).toBe('something broke')
  })
})

// ── #771 卡片站外公开：写面失败语义 + 公开读面空态/雾面映射 ──────────────

describe('卡片站外公开写面（#771）', () => {
  it('mutation 未返回状态 → 抛错而不是当作成功（失败不得静默）', async () => {
    mocks.graphqlRequest.mockResolvedValueOnce({ flashbackSetCardSharing: null })
    const api = new RealMiniProgramApi()

    await expect(api.flashbackSetCardSharing(true)).rejects.toThrow('公开设置失败，请重试')
  })

  it('token 失效（flashback_token_claimed）→ 类型化错误，不返回成功态', async () => {
    mocks.graphqlRequest.mockRejectedValueOnce(
      new mocks.GraphQLRequestError('token claimed', 200, [
        { message: 'token claimed', code: 'flashback_token_claimed' }
      ])
    )
    const api = new RealMiniProgramApi()

    await expect(api.flashbackSetCardSharing(true, 'tk')).rejects.toBeInstanceOf(FlashbackTokenInvalidError)
  })

  it('开启成功 → 状态与预览映射（enabled 严格布尔，段结构原样）', async () => {
    mocks.graphqlRequest.mockResolvedValueOnce({
      flashbackSetCardSharing: {
        enabled: true,
        shareId: 'a'.repeat(48),
        preview: {
          displayName: '王**',
          city: '北京',
          appliedAt: '2014-01-11T13:06:00Z',
          answers: [
            { questionKey: 'self_intro', segments: [{ text: '', fog: true, len: 7 }, { text: '后来我成了程序员。', fog: false, len: 0 }] }
          ],
          today: [{ questionKey: 'today.now', segments: [{ text: '还在写代码', fog: false, len: 0 }] }]
        }
      }
    })
    const api = new RealMiniProgramApi()

    const state = await api.flashbackSetCardSharing(true)
    expect(state.enabled).toBe(true)
    expect(state.shareId).toBe('a'.repeat(48))
    expect(state.preview.displayName).toBe('王**')
    expect(state.preview.answers[0].segments).toEqual([
      { text: '', fog: true, len: 7 },
      { text: '后来我成了程序员。', fog: false, len: 0 }
    ])
    expect(state.preview.today[0].questionKey).toBe('today.now')
  })

  it('关闭成功但 shareId 保留 → 原样回读（不改 id 的口径由后端保证，前端不重生成）', async () => {
    mocks.graphqlRequest.mockResolvedValueOnce({
      flashbackSetCardSharing: { enabled: false, shareId: 'b'.repeat(48), preview: { displayName: '王**', answers: [], today: [] } }
    })
    const api = new RealMiniProgramApi()

    const state = await api.flashbackSetCardSharing(false)
    expect(state.enabled).toBe(false)
    expect(state.shareId).toBe('b'.repeat(48))
  })

  it('capsule.me.cardSharing 缺省（旧 fixture/旧后端）→ undefined，不伪造「已开」', async () => {
    mocks.graphqlRequest.mockResolvedValueOnce({
      flashbackCapsule: {
        me: {
          id: 'p1', fullName: '王小明', surname: null, city: null, occupationThen: null,
          participation: 'attended', appliedAt: null, quoteLevel: 'off', quote: null,
          today: null, answers: []
        }
      }
    })
    const capsule = await new RealMiniProgramApi().getFlashbackCapsule()
    expect(capsule.me.cardSharing).toBeUndefined()
  })
})

describe('公开卡读面（#771，匿名）', () => {
  it('null 是合法空态（未开启/不存在/已收回）→ 返回 null 而不抛错', async () => {
    mocks.graphqlRequest.mockResolvedValueOnce({ flashbackSharedCard: null })
    const api = new RealMiniProgramApi()

    await expect(api.getFlashbackSharedCard('deadbeef')).resolves.toBeNull()
    // 匿名面：不携带 token，variables 只有 shareId
    expect(mocks.graphqlRequest).toHaveBeenCalledWith('FLASHBACK_SHARED_CARD', { shareId: 'deadbeef' })
  })

  it('网络故障照常抛出（不吞成 null——空态与故障必须可分辨）', async () => {
    mocks.graphqlRequest.mockRejectedValueOnce(new Error('request:fail timeout'))
    const api = new RealMiniProgramApi()

    await expect(api.getFlashbackSharedCard('abc')).rejects.toThrow('request:fail timeout')
  })

  it('读面映射 fail-closed：fog 段即使被后端错误地带上 text 也丢弃（原文不出 DOM）', async () => {
    mocks.graphqlRequest.mockResolvedValueOnce({
      flashbackSharedCard: {
        displayName: '王**',
        city: null,
        appliedAt: null,
        answers: [
          {
            questionKey: 'self_intro',
            // 故意违规：fog 段带了原文（后端投影 bug / 契约漂移）
            segments: [{ text: '我在盛大做测试', fog: true, len: 7 }]
          }
        ],
        today: null
      }
    })
    const api = new RealMiniProgramApi()

    const card = await api.getFlashbackSharedCard('abc')
    expect(card?.answers[0].segments[0]).toEqual({ text: '', fog: true, len: 7 })
    expect(JSON.stringify(card)).not.toContain('我在盛大做测试')
  })

  it('读面映射：列表元素可空（SDL 未加 !）→ 先滤再映射，不炸不缩位', async () => {
    mocks.graphqlRequest.mockResolvedValueOnce({
      flashbackSharedCard: {
        displayName: '王**',
        answers: [null, { questionKey: 'os', segments: [null, { text: '当年我用 Windows', fog: false, len: 0 }] }],
        today: null
      }
    })
    const api = new RealMiniProgramApi()

    const card = await api.getFlashbackSharedCard('abc')
    expect(card?.answers).toHaveLength(1)
    expect(card?.answers[0].segments).toHaveLength(1)
    expect(card?.today).toEqual([])
  })
})
