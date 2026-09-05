import type { RequestDocument } from 'graphql-request'

const workspace = {
  id: 'workspace-1',
  slug: 'beijing-cgc',
  name: '北京 CGC',
  joinPolicy: 'request',
  myRoleNames: ['owner'],
  myMembershipId: 'membership-1',
  canAccess: true,
  myAbilities: ['view_workspace', 'manage_members'],
  memberCount: 128
}

// 公开发现面 mock 记录（F2）：字段 = 匿名白名单，与 operations.ts 查询一致
const records = [
  {
    id: 'event-1',
    title: 'Python 入门工作坊',
    status: 'open',
    enrollmentPolicy: 'request',
    registrationDeadline: new Date(Date.now() + 72 * 3_600_000).toISOString(),
    pricingEnabled: false,
    availablePriceTiers: [],
    startsAt: new Date(Date.now() + 3 * 24 * 3_600_000).toISOString(),
    endsAt: new Date(Date.now() + (3 * 24 + 2) * 3_600_000).toISOString(),
    venue: JSON.stringify({ country: '中国', province: '北京市', city: '北京', district: '海淀区' }),
    enrollmentBadge: 'starting_soon'
  },
  {
    id: 'event-open',
    title: '周末开源分享会',
    status: 'open',
    enrollmentPolicy: 'open',
    registrationDeadline: null,
    pricingEnabled: false,
    availablePriceTiers: [],
    // 时间/地点未定：详情页走「时间待定」「地点待定」兜底（R3）
    startsAt: null,
    endsAt: null,
    venue: null,
    enrollmentBadge: 'enrolling'
  }
]

const course = {
  id: 'course-1',
  title: '社区组织者成长课',
  status: 'open',
  enrollmentPolicy: 'invite_only',
  registrationDeadline: null,
  pricingEnabled: false,
  availablePriceTiers: [],
  // 课程无 venue 槽（R3）；开课时间已定、结课未定（部分空）
  startsAt: new Date(Date.now() + 30 * 24 * 3_600_000).toISOString(),
  endsAt: null,
  enrollmentBadge: 'enrolling'
}

interface MockOrder {
  id: string
  enrollmentId: string
  status: string
  amountCents: number
  expireAt: string
  transactionId: string | null
}

interface MockEnrollment {
  id: string
  workspaceId: string
  eventId: string | null
  courseId: string | null
  userId: string
  status: string
  submissionPayload: string
  approvalDeadline: string | null
  rejectionReason: string | null
  approvedAt: string | null
  expiredAt: string | null
  cancelledAt: string | null
}

let loggedIn = false
let enrollment: MockEnrollment | null = null
let order: MockOrder | null = null
let orderStatusOverride: string | null = null

// 与后端 Enrollment.active_statuses 同口径（pending/payment_pending/confirmed）
const ACTIVE_STATUSES: Record<string, true> = {
  pending: true,
  payment_pending: true,
  confirmed: true
}

/** e2e 钩子:测试脚本推进订单态(支付完成模拟) */
export function __setOrderStatus(status: string | null): void {
  orderStatusOverride = status
}

function variablesRecord(variables: object): Record<string, unknown> {
  return variables as Record<string, unknown>
}

// #355 P1-3：登录且在目标上有活跃报名 → myEnrollment 投影（后端活跃集口径）
function myEnrollmentFor(kind: 'event' | 'course', offeringId: string) {
  if (!loggedIn || !enrollment) return null
  const targetId = kind === 'event' ? enrollment.eventId : enrollment.courseId
  if (targetId !== offeringId || !ACTIVE_STATUSES[enrollment.status]) return null
  return {
    id: enrollment.id,
    status: enrollment.status,
    approvalDeadline: enrollment.approvalDeadline
  }
}



function responseFor(document: string, variables: object): unknown {
  const values = variablesRecord(variables)

  if (document.includes('query Catalog')) {
    // #355 P2-10：CatalogSearch 带 title ilike `%kw%` 过滤变量（大小写不敏感 includes 语义）
    const filter = values.eventFilter ?? values.courseFilter
    let keyword: string | null = null
    if (filter && typeof filter === 'object' && 'title' in filter) {
      const title = filter.title
      if (title && typeof title === 'object' && 'ilike' in title && typeof title.ilike === 'string') {
        keyword = title.ilike.replace(/%/g, '').toLowerCase()
      }
    }
    const matches = (title: string) => !keyword || title.toLowerCase().includes(keyword)
    return {
      listEvents: { results: records.filter(({ title }) => matches(title)) },
      listCourses: { results: [course].filter(({ title }) => matches(title)) }
    }
  }
  if (document.includes('query EventDetail')) {
    return {
      getEvent: records.find(({ id }) => id === values.id) ?? null,
      myEnrollment: myEnrollmentFor('event', String(values.id ?? ''))
    }
  }
  if (document.includes('query CourseDetail')) {
    return {
      getCourse: values.id === course.id ? course : null,
      myEnrollment: myEnrollmentFor('course', String(values.id ?? ''))
    }
  }
  if (document.includes('query Enrollment(')) {
    return {
      enrollments: {
        results: loggedIn && enrollment && enrollment.id === values.id ? [enrollment] : []
      }
    }
  }
  if (document.includes('query Session')) {
    // 审批行 contextTitle 查表键（与后端 enrich 的 offering 标题装配同构）
    const targetId = enrollment?.eventId ?? enrollment?.courseId ?? null
    return {
      me: loggedIn
        ? {
            id: 'user-1',
            email: 'cheng@example.com',
            displayName: '小程',
            memberNumber: 'CGC-000001',
            joinedAt: new Date().toISOString(),
            isPlatformAdmin: false
          }
        : null,
      meWorkspaces: loggedIn ? [workspace] : [],
      myPendingApprovals: loggedIn && enrollment?.status === 'pending'
        ? [{
            id: enrollment.id,
            kind: 'enrollment',
            workspaceId: enrollment.workspaceId,
            userId: enrollment.userId,
            eventId: enrollment.eventId,
            courseId: enrollment.courseId,
            status: enrollment.status,
            approvalDeadline: enrollment.approvalDeadline,
            requesterName: '小程',
            // 与后端 enrich 的 offering 标题装配同构：按 event/course id 查标题
            contextTitle: [...records, course].find(
              ({ id }) => id === targetId
            )?.title ?? null,
            tierName: null,
            amount: null
          }]
        : []
    }
  }
  if (document.includes('query MyEnrollments')) {
    return { enrollments: { results: loggedIn && enrollment ? [enrollment] : [] } }
  }
  if (document.includes('mutation SignInWithPlatform')) {
    loggedIn = true
    return { signInWithPlatform: { id: 'user-1', email: 'cheng@example.com', isPlatformAdmin: false } }
  }
  if (document.includes('mutation SignOut')) {
    loggedIn = false
    return { signOut: true }
  }
  if (document.includes('mutation CreateEnrollment')) {
    const input = values.input as Record<string, unknown>
    const eventId = typeof input.eventId === 'string' ? input.eventId : null
    const courseId = typeof input.courseId === 'string' ? input.courseId : null
    // 收费路径(tierId 在场)→ payment_pending(R5:占位后待支付)
    const paid = typeof input.tierId === 'string' && input.tierId
    const status = paid ? 'payment_pending' : eventId === 'event-1' ? 'pending' : 'confirmed'
    enrollment = {
      id: 'enrollment-1',
      workspaceId: workspace.id,
      eventId,
      courseId,
      userId: 'user-1',
      status,
      submissionPayload: String(input.submissionPayload ?? '{}'),
      approvalDeadline: status === 'pending'
        ? new Date(Date.now() + 12 * 3_600_000).toISOString()
        : null,
      rejectionReason: null,
      approvedAt: null,
      expiredAt: null,
      cancelledAt: null
    }
    return { createEnrollment: { result: enrollment, errors: [] } }
  }
  if (document.includes('mutation CancelEnrollment')) {
    if (enrollment) {
      enrollment = {
        ...enrollment,
        status: 'cancelled',
        cancelledAt: new Date().toISOString()
      }
    }
    return { cancelEnrollment: { result: enrollment, errors: [] } }
  }
  if (document.includes('mutation ConfirmEnrollment')) {
    if (enrollment) {
      enrollment = { ...enrollment, status: 'confirmed', approvalDeadline: null, approvedAt: new Date().toISOString() }
    }
    return { confirmEnrollment: { result: enrollment, errors: [] } }
  }
  if (document.includes('mutation RejectEnrollment')) {
    const input = values.input as Record<string, unknown> | undefined
    if (enrollment) {
      enrollment = {
        ...enrollment,
        status: 'rejected',
        approvalDeadline: null,
        rejectionReason: typeof input?.rejectionReason === 'string' ? input.rejectionReason : null
      }
    }
    return { rejectEnrollment: { result: enrollment, errors: [] } }
  }
  if (document.includes('mutation ApproveJoinRequest')) {
    return { approveJoinRequest: { result: { id: values.id, status: 'approved', approvedAt: new Date().toISOString() }, errors: [] } }
  }
  if (document.includes('mutation RejectJoinRequest')) {
    return { rejectJoinRequest: { result: { id: values.id, status: 'rejected', rejectionReason: null }, errors: [] } }
  }
  if (document.includes('mutation GrantConsent')) {
    return { grantMiniProgramNotificationConsent: 1 }
  }
  if (document.includes('mutation GenerateMiniProgramCode')) {
    return {
      generateMiniProgramCode: {
        invitationId: 'invitation-1',
        platform: 'wechat',
        scene: `mock_scene_${values.workspaceId}`,
        codeBase64: '',
        expiresAt: new Date(Date.now() + 24 * 3_600_000).toISOString()
      }
    }
  }
  if (document.includes('mutation CreateOrder')) {
    // e2e 边界(#172):止于订单生成 + JSAPI 凭据返回,不模拟支付完成
    order = {
      id: 'order-1',
      enrollmentId: String((values.input as Record<string, unknown>).enrollmentId ?? ''),
      status: 'pending',
      amountCents: 19900,
      expireAt: new Date(Date.now() + 2 * 3_600_000).toISOString(),
      transactionId: null
    }
    return {
      createOrder: {
        result: order,
        errors: [],
        metadata: {
          credential: JSON.stringify({
            type: 'jsapi',
            pay_params: {
              appId: 'wx-mock',
              timeStamp: String(Math.floor(Date.now() / 1000)),
              nonceStr: 'mock-nonce',
              package: 'prepay_id=mock123',
              signType: 'RSA',
              paySign: 'mock-sign'
            }
          })
        }
      }
    }
  }
  if (document.includes('query OrderStatus')) {
    return {
      orderStatus: order
        ? { ...order, status: orderStatusOverride ?? order.status }
        : null
    }
  }
  if (document.includes('query MyOrders')) {
    return { myOrders: { results: loggedIn && order ? [order] : [] } }
  }
  if (document.includes('mutation AdmitMemberByToken')) {
    return {
      admitMemberByToken: {
        id: 'invitation-1',
        workspaceId: workspace.id,
        workspaceName: workspace.name,
        status: 'accepted',
        acceptedAt: new Date().toISOString()
      }
    }
  }

  throw new Error(`E2E GraphQL mock 未处理该 operation：${document.slice(0, 80)}`)
}

export function mockGraphQLRequest<TData>(document: RequestDocument, variables: object): TData {
  return responseFor(String(document), variables) as TData
}
