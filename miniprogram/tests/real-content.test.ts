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

  it('未知 badge 值 fail-closed（同 parseEnrollmentPolicy 纪律）', async () => {
    mocks.graphqlRequest.mockResolvedValue({
      getEvent: { ...EVENT_RECORD, enrollmentBadge: 'legacy' }
    })
    const api = new RealMiniProgramApi()
    await expect(api.getContent('event', 'event-1')).rejects.toThrow(/未知报名标签/)
  })
})
