import { beforeEach, describe, expect, it, vi } from 'vitest'

// U7（R15/R3/KTD1）：mapContent 对 startsAt/endsAt/venue/enrollmentBadge 的透传与解析。
// 展示兜底（空值→待定）的纯逻辑在 tests/domain.test.ts；本文件锁「record → CatalogItem」边界。

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

const EVENT_RECORD = {
  id: 'event-1',
  workspaceId: 'ws-1',
  title: 'Python 工作坊',
  researchRequirements: null,
  status: 'open',
  workflowRunId: null,
  enrollmentPolicy: 'open',
  capacity: 30,
  confirmedCount: 3,
  registrationDeadline: null,
  pricingEnabled: false,
  availablePriceTiers: [],
  startsAt: '2026-08-25T06:00:00Z',
  endsAt: '2026-08-26T10:00:00Z',
  venue: '{"country":"中国","province":"北京市","city":"北京","district":"海淀区"}',
  enrollmentBadge: 'starting_soon'
}

beforeEach(() => {
  vi.clearAllMocks()
  mocks.isAuthenticationError.mockReturnValue(false)
})

describe('getContent 新字段透传（mapContent）', () => {
  it('event 有值：startsAt/endsAt/venue 原样透传，badge 解析为枚举', async () => {
    mocks.graphqlRequest.mockResolvedValue({ getEvent: EVENT_RECORD })
    const api = new RealMiniProgramApi()
    const item = await api.getContent('event', 'event-1')
    expect(item.startsAt).toBe(EVENT_RECORD.startsAt)
    expect(item.endsAt).toBe(EVENT_RECORD.endsAt)
    expect(item.venue).toBe(EVENT_RECORD.venue)
    expect(item.enrollmentBadge).toBe('starting_soon')
  })

  it('event 空值：时间/venue 透传 null（展示层兜底「时间待定」「地点待定」），badge=enrolling', async () => {
    mocks.graphqlRequest.mockResolvedValue({
      getEvent: { ...EVENT_RECORD, startsAt: null, endsAt: null, venue: null, enrollmentBadge: 'enrolling' }
    })
    const api = new RealMiniProgramApi()
    const item = await api.getContent('event', 'event-1')
    expect(item.startsAt).toBeNull()
    expect(item.endsAt).toBeNull()
    expect(item.venue).toBeNull()
    expect(item.enrollmentBadge).toBe('enrolling')
  })

  it('部分空：有时间无 venue → venue 为 null、时间保留', async () => {
    mocks.graphqlRequest.mockResolvedValue({
      getEvent: { ...EVENT_RECORD, venue: null }
    })
    const api = new RealMiniProgramApi()
    const item = await api.getContent('event', 'event-1')
    expect(item.startsAt).toBe(EVENT_RECORD.startsAt)
    expect(item.venue).toBeNull()
  })

  it('course 无 venue 槽：恒为 null（R3，不渲染位置槽）', async () => {
    const { venue: _venue, ...courseRecord } = EVENT_RECORD
    mocks.graphqlRequest.mockResolvedValue({
      getCourse: { ...courseRecord, id: 'course-1', enrollmentBadge: 'full' }
    })
    const api = new RealMiniProgramApi()
    const item = await api.getContent('course', 'course-1')
    expect(item.kind).toBe('course')
    expect(item.venue).toBeNull()
    expect(item.enrollmentBadge).toBe('full')
  })

  it('closed badge 按后端派生值透传', async () => {
    mocks.graphqlRequest.mockResolvedValue({
      getEvent: { ...EVENT_RECORD, enrollmentBadge: 'closed' }
    })
    const api = new RealMiniProgramApi()
    const item = await api.getContent('event', 'event-1')
    expect(item.enrollmentBadge).toBe('closed')
  })

  it('未知 badge 值 fail-closed（同 parseEnrollmentPolicy 纪律）', async () => {
    mocks.graphqlRequest.mockResolvedValue({
      getEvent: { ...EVENT_RECORD, enrollmentBadge: 'legacy' }
    })
    const api = new RealMiniProgramApi()
    await expect(api.getContent('event', 'event-1')).rejects.toThrow(/未知报名标签/)
  })
})

describe('getCatalog 公开条目平铺（X2：无工作台身份投影）', () => {
  it('两个来源的公开条目各自独立渲染（不按 workspace 折叠去重）', async () => {
    mocks.graphqlRequest.mockResolvedValue({
      listEvents: { results: [{ ...EVENT_RECORD }] },
      listCourses: { results: [{ ...EVENT_RECORD, id: 'course-9', enrollmentBadge: 'enrolling' }] }
    })
    const api = new RealMiniProgramApi()
    const items = await api.getCatalog()
    expect(items).toHaveLength(2)
    expect(items.map(({ id }) => id)).toEqual(['event-1', 'course-9'])
  })

  it('CatalogItem 无 workspaceName 字段（KD5 匿名口径，不引入工作台身份）', async () => {
    mocks.graphqlRequest.mockResolvedValue({
      listEvents: { results: [{ ...EVENT_RECORD }] },
      listCourses: { results: [] }
    })
    const api = new RealMiniProgramApi()
    const [item] = await api.getCatalog()
    expect(item).not.toHaveProperty('workspaceName')
    expect(item).not.toHaveProperty('workspaceId')
  })
})

// #355 P1-3：详情查询同文档带出 myEnrollment（匿名/未报名 → null，在场即已报名态）
describe('getContent myEnrollment 投影（#355 P1-3）', () => {
  it('活跃报名在场 → 解析为 MyEnrollmentState（status fail-closed 解析）', async () => {
    mocks.graphqlRequest.mockResolvedValue({
      getEvent: EVENT_RECORD,
      myEnrollment: { id: 'enr-1', status: 'pending', approvalDeadline: '2026-09-06T00:00:00Z' }
    })
    const api = new RealMiniProgramApi()
    const item = await api.getContent('event', 'event-1')
    expect(item.myEnrollment).toEqual({
      id: 'enr-1',
      status: 'pending',
      approvalDeadline: '2026-09-06T00:00:00Z'
    })
  })

  it('匿名/未报名 → null（详情页回落「立即报名」）', async () => {
    mocks.graphqlRequest.mockResolvedValue({ getEvent: EVENT_RECORD, myEnrollment: null })
    const api = new RealMiniProgramApi()
    const item = await api.getContent('event', 'event-1')
    expect(item.myEnrollment).toBeNull()
  })

  it('目录面（getCatalog）恒无 myEnrollment（匿名目录口径）', async () => {
    mocks.graphqlRequest.mockResolvedValue({
      listEvents: { results: [{ ...EVENT_RECORD }] },
      listCourses: { results: [] }
    })
    const api = new RealMiniProgramApi()
    const [item] = await api.getCatalog()
    expect(item.myEnrollment).toBeNull()
  })
})

// #355 P1-4：结果页按 id 回查单条报名
describe('getEnrollment 按 id 回查（#355 P1-4）', () => {
  it('命中 → EnrollmentSummary（kind/targetId/title 从记录派生）', async () => {
    mocks.getAuthToken.mockReturnValue('token-1')
    mocks.graphqlRequest.mockResolvedValue({
      enrollments: {
        results: [{
          id: 'enr-1',
          workspaceId: 'ws-1',
          eventId: 'event-1',
          courseId: null,
          userId: 'user-1',
          status: 'confirmed',
          targetTitle: 'Python 工作坊',
          approvalDeadline: null,
          rejectionReason: null,
          approvedAt: '2026-09-05T00:00:00Z',
          expiredAt: null,
          cancelledAt: null
        }]
      }
    })
    const api = new RealMiniProgramApi()
    const enrollment = await api.getEnrollment('enr-1')
    expect(enrollment).toEqual({
      id: 'enr-1',
      workspaceId: 'ws-1',
      targetId: 'event-1',
      kind: 'event',
      title: 'Python 工作坊',
      status: 'confirmed',
      approvalDeadline: null,
      rejectionReason: null
    })
  })

  it('查无（记录不存在/跨账号）→ null', async () => {
    mocks.getAuthToken.mockReturnValue('token-1')
    mocks.graphqlRequest.mockResolvedValue({ enrollments: { results: [] } })
    const api = new RealMiniProgramApi()
    expect(await api.getEnrollment('enr-404')).toBeNull()
  })

  it('未登录（无 token）→ 直接 null，不发查询', async () => {
    mocks.getAuthToken.mockReturnValue('')
    const api = new RealMiniProgramApi()
    expect(await api.getEnrollment('enr-1')).toBeNull()
    expect(mocks.graphqlRequest).not.toHaveBeenCalled()
  })
})
