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
  MyOrdersQueryDocument: 'MY_ORDERS',
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
  CreateOrderMutationDocument: 'CREATE_ORDER'
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
import { enrollmentScheduleText, enrollmentVenueText } from '../src/domain/format'

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
  // 详情查询形状（U11）：列表查询不带押金字段（匿名白名单与 web PUBLIC_LIST_* 同源）
  depositEnabled: false,
  depositAmountCents: null,
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
  it.each(['closed', 'cancelled'])('留档 Event 的 %s 状态透传，详情据此隐藏报名动作', async (status) => {
    mocks.graphqlRequest.mockResolvedValue({
      getEvent: { ...EVENT_RECORD, status, enrollmentBadge: 'closed' }
    })
    const item = await new RealMiniProgramApi().getContent('event', 'event-1')
    expect(item.status).toBe(status)
  })

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

// U11（R10）：押金场映射——详情查询带 depositEnabled/depositAmountCents，
// 列表匿名查询不带（字段缺失按免费态映射，不抛错）
describe('押金字段映射（U11/R10）', () => {
  it('押金场：depositEnabled/depositAmountCents 透传，档位保持空（三态互斥）', async () => {
    mocks.graphqlRequest.mockResolvedValue({
      getEvent: { ...EVENT_RECORD, depositEnabled: true, depositAmountCents: 6900 }
    })
    const item = await new RealMiniProgramApi().getContent('event', 'event-deposit')
    expect(item.depositEnabled).toBe(true)
    expect(item.depositAmountCents).toBe(6900)
    expect(item.pricingEnabled).toBe(false)
    expect(item.priceTiers).toEqual([])
  })

  it('押金开启但缺额：不编造金额（null，展示层降级不出价）', async () => {
    mocks.graphqlRequest.mockResolvedValue({
      getEvent: { ...EVENT_RECORD, depositEnabled: true, depositAmountCents: null }
    })
    const item = await new RealMiniProgramApi().getContent('event', 'event-deposit')
    expect(item.depositEnabled).toBe(true)
    expect(item.depositAmountCents).toBeNull()
  })
  // #510：年龄门槛映射——详情查询带 minAge（course 查询无该槽 → null）
  it('年龄门槛：minAge 透传；查询缺省 → null（无门槛）', async () => {
    mocks.graphqlRequest.mockResolvedValue({
      getEvent: { ...EVENT_RECORD, minAge: 18 }
    })
    const gated = await new RealMiniProgramApi().getContent('event', 'event-age')
    expect(gated.minAge).toBe(18)

    mocks.graphqlRequest.mockResolvedValue({
      getEvent: { ...EVENT_RECORD }
    })
    const open = await new RealMiniProgramApi().getContent('event', 'event-open')
    expect(open.minAge).toBeNull()
  })

  it('免费场回归：记录无押金字段 → 免费态（depositEnabled=false / 金额 null）', async () => {
    const { depositEnabled: _depositEnabled, depositAmountCents: _depositAmountCents, ...freeRecord } = EVENT_RECORD
    mocks.graphqlRequest.mockResolvedValue({ getEvent: freeRecord })
    const item = await new RealMiniProgramApi().getContent('event', 'event-1')
    expect(item.depositEnabled).toBe(false)
    expect(item.depositAmountCents).toBeNull()
    expect(item.pricingEnabled).toBe(false)
  })

  it('定价场回归：档位解析与收费标记不变，押金恒关闭', async () => {
    const tier = JSON.stringify({ id: 't1', name: '标准', amount_cents: 19900 })
    mocks.graphqlRequest.mockResolvedValue({
      getEvent: { ...EVENT_RECORD, pricingEnabled: true, availablePriceTiers: [tier] }
    })
    const item = await new RealMiniProgramApi().getContent('event', 'event-priced')
    expect(item.pricingEnabled).toBe(true)
    expect(item.priceTiers).toEqual([{ id: 't1', name: '标准', amountCents: 19900 }])
    expect(item.depositEnabled).toBe(false)
    expect(item.depositAmountCents).toBeNull()
  })
})

// #727：createOrder 的押金同意字段（条件携带，与 #510 ageConfirmed 同款）——
// 非押金单负载逐字不变；押金单必须 true（后端 fail-closed 复核）
describe('createOrder 押金同意字段（#727）', () => {
  const orderResult = {
    createOrder: {
      result: {
        id: 'order-1',
        enrollmentId: 'enr-1',
        provider: 'wechat_jsapi',
        outTradeNo: 'CGC1',
        amountCents: 6900,
        status: 'pending',
        expireAt: '2026-09-12T02:00:00Z',
        orderKind: 'deposit'
      },
      errors: [],
      metadata: { credential: null }
    }
  }

  it('押金已同意 → input 带 depositConsent: true', async () => {
    mocks.graphqlRequest.mockResolvedValue(orderResult)
    const api = new RealMiniProgramApi()

    const created = await api.createOrder('enr-1', true)

    expect(created.order.orderKind).toBe('deposit')
    expect(mocks.graphqlRequest).toHaveBeenCalledWith('CREATE_ORDER', {
      input: { enrollmentId: 'enr-1', provider: 'wechat_jsapi', depositConsent: true }
    })
  })

  it('未同意/非押金 → 不带 depositConsent 键（零回归负载）', async () => {
    mocks.graphqlRequest.mockResolvedValue(orderResult)
    const api = new RealMiniProgramApi()

    await api.createOrder('enr-1')

    expect(mocks.graphqlRequest).toHaveBeenCalledWith('CREATE_ORDER', {
      input: { enrollmentId: 'enr-1', provider: 'wechat_jsapi' }
    })
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
          cancelledAt: null,
          insertedAt: '2026-09-01T08:00:00Z',
          checkInCode: '042317',
          paymentMode: 'deposit',
          depositAmountCents: 6900,
          // #617：startsAt = ISO；venue = 后端已文本化的 city+district
          // （Venue.text/1，非 JsonString——见 graphql_enrollment_my_query_test.exs）
          startsAt: '2026-09-12T02:00:00Z',
          venue: '北京市海淀区',
          registrationDeadline: '2026-09-10T12:00:00Z'
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
      rejectionReason: null,
      insertedAt: '2026-09-01T08:00:00Z',
      checkInCode: '042317',
      paymentMode: 'deposit',
      depositAmountCents: 6900,
      startsAt: '2026-09-12T02:00:00Z',
      venue: '北京市海淀区',
      registrationDeadline: '2026-09-10T12:00:00Z'
    })
  })

  // #617 负向：后端对无时间/线上场返回 null → DTO 必须是 null（不是 undefined），
  // 卡片据 null 不渲染空行
  it('#617 无时间/无地点 → startsAt/venue 归一为 null', async () => {
    mocks.getAuthToken.mockReturnValue('token-1')
    mocks.graphqlRequest.mockResolvedValue({
      enrollments: {
        results: [{
          id: 'enr-2',
          workspaceId: 'ws-1',
          eventId: null,
          courseId: 'course-1',
          userId: 'user-1',
          status: 'confirmed',
          targetTitle: '线上课程',
          approvalDeadline: null,
          rejectionReason: null,
          approvedAt: null,
          expiredAt: null,
          cancelledAt: null,
          insertedAt: '2026-09-01T08:00:00Z',
          checkInCode: null,
          paymentMode: 'free',
          startsAt: null,
          venue: null,
          registrationDeadline: null
        }]
      }
    })
    const api = new RealMiniProgramApi()
    const enrollment = await api.getEnrollment('enr-2')
    expect(enrollment?.kind).toBe('course')
    expect(enrollment?.startsAt).toBeNull()
    expect(enrollment?.venue).toBeNull()
    // 展示层据此不渲染：无值即无行
    expect(enrollmentScheduleText('course', enrollment?.startsAt ?? null)).toBeNull()
    expect(enrollmentVenueText(enrollment?.venue ?? null)).toBeNull()
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

// U11（R11/R16）：「我的报名」卡面数据源 —— 核销码 + 押金单终态
describe('getEnrollments 核销码与押金终态（U11/R11/R16）', () => {
  const session = {
    me: {
      id: 'user-1',
      email: 'cheng@example.com',
      displayName: '小程',
      memberNumber: null,
      joinedAt: null,
      isPlatformAdmin: false
    },
    meWorkspaces: [],
    myPendingApprovals: []
  }
  const enrollmentRecord = (overrides: Record<string, unknown>) => ({
    id: 'enr-1',
    workspaceId: 'ws-1',
    eventId: 'event-deposit',
    courseId: null,
    userId: 'user-1',
    status: 'confirmed',
    targetTitle: '押金场 · 线下共学',
    approvalDeadline: null,
    rejectionReason: null,
    approvedAt: '2026-09-05T00:00:00Z',
    expiredAt: null,
    cancelledAt: null,
    insertedAt: '2026-09-01T08:00:00Z',
    checkInCode: null,
    ...overrides
  })

  it('confirmed 报名带 6 位码，payment_pending 无码（后端门控的端内忠实映射）', async () => {
    mocks.getAuthToken.mockReturnValue('token-1')
    mocks.graphqlRequest
      .mockResolvedValueOnce(session)
      .mockResolvedValueOnce({
        enrollments: {
          results: [
            enrollmentRecord({ checkInCode: '042317' }),
            enrollmentRecord({ id: 'enr-2', status: 'payment_pending' })
          ]
        }
      })
    const items = await new RealMiniProgramApi().getEnrollments()
    expect(items.map(({ id, checkInCode }) => [id, checkInCode])).toEqual([
      ['enr-1', '042317'],
      ['enr-2', null]
    ])
  })

  it('forfeited 押金单进入 myOrders（未知状态 fail-closed 曾会整表抛错）', async () => {
    mocks.getAuthToken.mockReturnValue('token-1')
    mocks.graphqlRequest
      .mockResolvedValueOnce(session)
      .mockResolvedValueOnce({
        myOrders: {
          results: [
            {
              id: 'order-1',
              enrollmentId: 'enr-1',
              provider: 'wechat_jsapi',
              status: 'forfeited',
              amountCents: 6900,
              expireAt: '2026-09-20T00:00:00Z',
              orderKind: 'deposit'
            }
          ]
        }
      })
    const orders = await new RealMiniProgramApi().getMyOrders()
    expect(orders).toEqual([
      {
        id: 'order-1',
        enrollmentId: 'enr-1',
        status: 'forfeited',
        amountCents: 6900,
        expireAt: '2026-09-20T00:00:00Z',
        transactionId: null,
        orderKind: 'deposit'
      }
    ])
  })

  // #617：卡面时间/地点行的数据源就是本读面
  it('#617 列表读面回带 startsAt/venue（缺字段曾是改期通知无权威落点的根因）', async () => {
    mocks.getAuthToken.mockReturnValue('token-1')
    mocks.graphqlRequest.mockResolvedValueOnce(session).mockResolvedValueOnce({
      enrollments: {
        results: [
          enrollmentRecord({
            startsAt: '2026-09-12T02:00:00Z',
            venue: '上海市徐汇区'
          })
        ]
      }
    })
    const [item] = await new RealMiniProgramApi().getEnrollments()
    expect(item?.startsAt).toBe('2026-09-12T02:00:00Z')
    expect(item?.venue).toBe('上海市徐汇区')
    // 渲染层据 DTO 直接出两行（文案单源在 domain）
    expect(enrollmentScheduleText(item!.kind, item!.startsAt)).toContain('活动时间：')
    expect(enrollmentVenueText(item!.venue)).toBe('地点：上海市徐汇区')
  })

  // #617 第二处 EnrollmentSummary 构造点（typecheck 曾在此拦下漏改）：
  // create 回包不选 startsAt/venue。startsAt 与 form.target 同形 → 本地取；
  // venue 形态不同（JsonString vs 文本）→ 与 checkInCode 同款给 null，不伪造。
  it('#617 createEnrollment 的 DTO：startsAt 取 form.target，venue 恒 null（形态不同不伪造）', async () => {
    mocks.getAuthToken.mockReturnValue('token-1')
    mocks.graphqlRequest
      .mockResolvedValueOnce({ getEvent: EVENT_RECORD })
      .mockResolvedValueOnce(session)
      .mockResolvedValueOnce({
        createEnrollment: {
          result: {
            id: 'enr-9',
            workspaceId: 'ws-1',
            eventId: 'event-1',
            courseId: null,
            userId: 'user-1',
            status: 'confirmed',
            approvalDeadline: null,
            insertedAt: '2026-09-01T08:00:00Z'
          },
          errors: []
        }
      })
    const api = new RealMiniProgramApi()
    const target = await api.getContent('event', 'event-1')
    const created = await api.createEnrollment({ target })
    expect(created.startsAt).toBe(EVENT_RECORD.startsAt)
    // EVENT_RECORD.venue 是 JsonString；读面契约要文本 → 不能原样透传
    expect(created.venue).toBeNull()
  })
})
