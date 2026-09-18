import type { RequestDocument } from 'graphql-request'
// 相对 + 显式 .ts：mockTransport 同时被 node --experimental-strip-types 直接加载
// （tests/mock-transport.test.ts），该 runner 不认 `@/` 别名；Taro 侧同款先例
// 见 src/domain/entry.ts 的 './share-route.ts'。
import { venueCityDistrictText } from '../domain/format.ts'

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
// （押金字段为例外：仅详情查询请求，样例记录带着供详情/报名链使用——列表面
// 不渲染缴费槽，多带两键不影响）。
const DEPOSIT_AMOUNT_CENTS = 6900
const CHECK_IN_CODE = '042317'

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
    enrollmentBadge: 'starting_soon',
    // 成班投影样例（阶段1）：short_by → 详情页/Initiative 卡片都渲染「还差 3 人成班」；
    // initiativeId 让 event-detail 的「所属倡导活动」回链有落点
    qualificationBadge: 'short_by',
    shortBy: 3,
    initiativeId: 'initiative-1',
    // #538 公开主理人投影样例：一行有 displayName、一行 null 回退 memberNumber，
    // 详情页渲染「本场主理人：主讲小援 · CGC-9A3F2C」（与真机 [JsonString!] 同形）
    publicModerators: [
      JSON.stringify({ display_name: '主讲小援', member_number: 'CGC-000001' }),
      JSON.stringify({ display_name: null, member_number: 'CGC-9A3F2C' })
    ]
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
    enrollmentBadge: 'enrolling',
    // 无成班需求的活动 → badge=open；详情页按 web 口径隐藏该徽章（阶段1 回归面）
    qualificationBadge: 'open',
    shortBy: null,
    initiativeId: null
  },
  {
    id: 'event-deposit',
    title: '押金场 · 线下共学',
    status: 'open',
    enrollmentPolicy: 'open',
    registrationDeadline: new Date(Date.now() + 48 * 3_600_000).toISOString(),
    pricingEnabled: false,
    availablePriceTiers: [],
    // 押金场（U11 样例）：详情页缴费块「押金 ¥69.00（到场退）」+「未到场不退」，
    // 报名落 payment_pending（零档位选择，走既有 paymentLandingUrl 支付）
    depositEnabled: true,
    depositAmountCents: DEPOSIT_AMOUNT_CENTS,
    minAge: 18,
    startsAt: new Date(Date.now() + 5 * 24 * 3_600_000).toISOString(),
    endsAt: new Date(Date.now() + (5 * 24 + 2) * 3_600_000).toISOString(),
    venue: JSON.stringify({ country: '中国', province: '上海市', city: '上海', district: '徐汇区' }),
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

// 阶段1：Initiative 公开投影 fixture（发现页卡片 + 详情页 + event-detail 回链）。
// id 与 event-1 的 initiativeId 对应——回链据此把场次挂回倡导活动。
const initiativeCard = {
  id: 'initiative-1',
  name: '1024 程序员节',
  slug: 'python-1024',
  hashtag: '#1024',
  description: '跨城市的开源共学周，把同一套课程带到十个城市。',
  status: 'open',
  windowStartsAt: new Date(Date.now() + 7 * 24 * 3_600_000).toISOString(),
  windowEndsAt: new Date(Date.now() + 21 * 24 * 3_600_000).toISOString()
}

// Initiative 卡片里的场次：派生徽章 + 留档（不取原始计数/成员字段，与查询同源）
const initiativeEvent = {
  id: 'event-1',
  slug: 'python-workshop',
  title: 'Python 入门工作坊',
  status: 'open',
  startsAt: records[0].startsAt,
  endsAt: records[0].endsAt,
  registrationDeadline: records[0].registrationDeadline,
  venue: records[0].venue,
  archived: false,
  qualificationBadge: 'short_by',
  shortBy: 3,
  // 参与条件（#627）：押金三态 + 年龄门槛存在性（与后端公开投影同键）
  paymentMode: 'deposit',
  deposit: { enabled: true, amountCents: 6900, refundableOnCheckIn: true },
  minAge: 18,
  priceRangeMinCents: null
}

interface MockOrder {
  id: string
  enrollmentId: string
  status: string
  amountCents: number
  expireAt: string
  transactionId: string | null
  /** 与后端 order_kind/2 同规则：押金场开则 deposit，否则 enrollment */
  orderKind: 'enrollment' | 'deposit'
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
  insertedAt: string
  /** 6 位核销码（KTD5：仅 confirmed 报名由后端返回；置前导零验证字符串口径） */
  checkInCode: string | null
  /** 目标缴费模式（后端 Enrollment.paymentMode 计算字段同规则：押金 > 定价 > 免费） */
  paymentMode: string | null
  /** #727 押金快照金额（后端 Enrollment.depositAmountCents 计算字段同规则：非押金场 null） */
  depositAmountCents: number | null
  /** #617 目标开始时间（后端 Enrollment.startsAt 计算字段同规则：从目标记录取） */
  startsAt: string | null
  /** #617 目标场地：后端 Enrollment.venue 同形 = Venue.text/1 文本化 city+district */
  venue: string | null
  /** 报名截止时间（ISO8601；null = 无截止） */
  registrationDeadline: string | null
}

let loggedIn = false
let enrollment: MockEnrollment | null = null
let order: MockOrder | null = null
let orderStatusOverride: string | null = null
// #508-A：核销幂等标记（同一报名第二次核销 → already； enrollment 重置时随之复位）
let checkedIn = false

// ── 志愿者招募（R20/R21）mock 态：一人一档 + 一人一批一份申请 ────────────────
// 与后端语义对齐的最小投影：批次恒有 open（空态分支由 e2e 脚本改 mock 也走不到，
// 见 e2e 的招募路径说明）；档案与申请在登录后才可见（getWorkspace 需登录）。
const RECRUITMENT_WORKSPACE = { id: workspace.id, name: workspace.name }
let resumeProfile: {
  id: string
  fullName: string
  contactEmail: string
  weeklyHours: number | null
  skills: string[]
  fileName: string | null
  fileContentType: string | null
  fileSize: number | null
  uploadedAt: string | null
} | null = null
let volunteerApplications: Array<Record<string, unknown>> = []

const recruitmentCohort = {
  id: 'cohort-1',
  name: '第 1 批 · 首批志愿者招募',
  applyDeadlineAt: new Date(Date.now() + 21 * 24 * 3_600_000).toISOString(),
  startsAt: new Date(Date.now() + 30 * 24 * 3_600_000).toISOString(),
  endsAt: null,
  status: 'open'
}

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

  if (document.includes('query PublicInitiatives')) return { publicInitiatives: [initiativeCard] }
  if (document.includes('query PublicInitiative(')) {
    if (values.slug !== initiativeCard.slug) return { publicInitiative: null }
    return {
      publicInitiative: {
        ...initiativeCard,
        cityCount: 1,
        eventCount: 1,
        confirmedCount: 1,
        qualifiedEventCount: 1,
        cities: [{ city: '北京', events: [initiativeEvent] }]
      }
    }
  }

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
  if (document.includes('query EventModerationScope')) {
    // #508-A：成员面探测——登录即视为 workspace-1 成员（owner），活动存在即给 scope；
    // 未登录按匿名口径返回 null（真实端是 forbidden_field 整查询报错，real.ts 同归 false）
    const record = records.find(({ id }) => id === values.id) ?? null
    return {
      getEvent: loggedIn && record ? { id: record.id, workspaceId: workspace.id } : null
    }
  }
  if (document.includes('query EventModerators(')) {
    // 主理人列表（#558 后续）：mock 用户即 owner（manage 分支先行命中），
    // 列表恒含本人——非管理角色主理人的「我在列表」分支由 real 层单测覆盖
    return { eventModerators: loggedIn ? [{ userId: 'user-1' }] : [] }
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
    // #510 年龄门控（后端 action 语义的 mock 投影）：min_age 非空的目标未带
    // ageConfirmed=true → 业务错误（与 check-in 三分支同款 errors 形状）
    const ageGateTarget = records.find(
      (record) => record.id === eventId && 'minAge' in record && typeof record.minAge === 'number'
    )
    if (ageGateTarget && input.ageConfirmed !== true) {
      return {
        createEnrollment: {
          result: null,
          errors: [
            {
              message: 'age confirmation is required for this enrollment',
              code: 'enrollment_age_confirmation_required'
            }
          ]
        }
      }
    }
    // 收费/押金路径 → payment_pending（R5/KTD2：定价场 tierId 在场；押金场零档位）
    const requiresPayment =
      (typeof input.tierId === 'string' && input.tierId !== '') ||
      records.some((record) => 'depositEnabled' in record && record.depositEnabled === true && record.id === eventId)
    const status = requiresPayment ? 'payment_pending' : eventId === 'event-1' ? 'pending' : 'confirmed'
    // 缴费模式/截止时间从目标记录推导（与后端 payment_mode 计算同规则：押金 > 定价 > 免费）
    const target = [...records, course].find(({ id }) => id === (eventId ?? courseId))
    const paymentMode =
      target && 'depositEnabled' in target && target.depositEnabled === true
        ? 'deposit'
        : target?.pricingEnabled === true
          ? 'pricing'
          : 'free'
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
      cancelledAt: null,
      insertedAt: new Date().toISOString(),
      // 生成时点 = create（KTD5）——confirmed 才出示，故仅免缴直通有码
      checkInCode: status === 'confirmed' ? CHECK_IN_CODE : null,
      paymentMode,
      // #727：押金快照金额（与后端 Enrollment.depositAmountCents 同源口径——
      // 报名提交时物化；非押金场 null）。order-pay 创单前披露的金额源
      depositAmountCents:
        paymentMode === 'deposit' && target && 'depositAmountCents' in target
          ? (target.depositAmountCents ?? null)
          : null,
      // #617：与后端 Enrollment 计算字段同形——startsAt 直接取目标记录；
      // venue 必须文本化为 city+district（读面契约是 Venue.text 结果，不是
      // 目标记录里的 JsonString；course 无 venue 槽 → null）
      startsAt: target?.startsAt ?? null,
      venue: venueCityDistrictText(target && 'venue' in target ? target.venue : null),
      registrationDeadline: target?.registrationDeadline ?? null
    }
    checkedIn = false
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
      enrollment = {
        ...enrollment,
        status: 'confirmed',
        approvalDeadline: null,
        approvedAt: new Date().toISOString(),
        checkInCode: enrollment.checkInCode ?? CHECK_IN_CODE
      }
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
    const targetRecord = records.find(({ id }) => id === enrollment?.eventId)
    // 押金单金额 = 目标场押金（R2 单源，零改动的下单链在此被 mock 忠实复现）；
    // orderKind 与后端 order_kind/2 同规则（押金场开 → deposit）——支付页的押金
    // 同意门以它为准，mock 漏带字段会被 parseOrderKind fail-closed 抓住
    const depositOrder =
      targetRecord && 'depositEnabled' in targetRecord && targetRecord.depositEnabled === true
    const input = (values.input ?? {}) as Record<string, unknown>
    // #727 押金同意门（后端 action 语义的 mock 投影，同 #510 年龄门）：押金单
    // 未带 depositConsent=true → 业务错误（与真实后端同 code，前端文案表命中）
    if (depositOrder && input.depositConsent !== true) {
      return {
        createOrder: {
          result: null,
          errors: [
            {
              message: 'deposit consent is required before creating a deposit order',
              code: 'order_deposit_consent_required'
            }
          ],
          metadata: null
        }
      }
    }
    order = {
      id: 'order-1',
      enrollmentId: String(input.enrollmentId ?? ''),
      status: 'pending',
      amountCents: depositOrder ? DEPOSIT_AMOUNT_CENTS : 19900,
      expireAt: new Date(Date.now() + 2 * 3_600_000).toISOString(),
      transactionId: null,
      orderKind: depositOrder ? 'deposit' : 'enrollment'
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
  // ── 志愿者招募（R20/R21）：slug 解析 → 批次 / 档案 / 申请 ──────────────────
  if (document.includes('query RecruitmentWorkspace')) {
    // getWorkspace 需登录（策略 actor_present）——匿名按未授权口径返回 null，
    // 真端是 GraphQL 错误 → real.ts 的 resolveRecruitmentWorkspaceId 早退在
    // 登录检查上（这里只是兜底不给跨租户数据）
    return { getWorkspace: loggedIn ? RECRUITMENT_WORKSPACE : null }
  }
  if (document.includes('query CurrentRecruitmentCohort')) {
    return { currentRecruitmentCohort: loggedIn ? recruitmentCohort : null }
  }
  if (document.includes('query MyResumeProfile')) {
    return { myResumeProfile: loggedIn ? resumeProfile : null }
  }
  if (document.includes('query MyVolunteerApplications')) {
    return { myVolunteerApplications: loggedIn ? volunteerApplications : [] }
  }
  if (document.includes('mutation UpsertResumeProfile')) {
    const input = values.input as Record<string, unknown>
    const skills = Array.isArray(input.skills) ? (input.skills as string[]) : resumeProfile?.skills ?? []
    resumeProfile = {
      // 一人一档：二次 upsert 更新同一行（保留已上传的文件元数据）
      id: resumeProfile?.id ?? 'resume-profile-1',
      fullName: String(input.fullName ?? ''),
      contactEmail: String(input.contactEmail ?? ''),
      weeklyHours: typeof input.weeklyHours === 'number' ? input.weeklyHours : null,
      skills,
      fileName: resumeProfile?.fileName ?? null,
      fileContentType: resumeProfile?.fileContentType ?? null,
      fileSize: resumeProfile?.fileSize ?? null,
      uploadedAt: resumeProfile?.uploadedAt ?? null
    }
    return { upsertResumeProfile: { result: resumeProfile, errors: [] } }
  }
  if (document.includes('mutation UploadResumeFile')) {
    const input = values.input as Record<string, unknown>
    // 先建档再上传（U2 契约：档案缺失 → resume_profile_not_found）
    if (!resumeProfile) {
      return {
        uploadResumeFile: {
          result: null,
          errors: [
            { message: 'resume profile not found', code: 'resume_profile_not_found' }
          ]
        }
      }
    }
    // 大小以**实际解码字节数**为准（与后端同规则）：base64 长度 → 原始字节数
    const content = typeof input.contentBase64 === 'string' ? input.contentBase64 : ''
    resumeProfile = {
      ...resumeProfile,
      fileName: String(input.fileName ?? ''),
      fileContentType: String(input.contentType ?? ''),
      fileSize: Math.floor((content.length * 3) / 4),
      uploadedAt: new Date().toISOString()
    }
    return { uploadResumeFile: { result: resumeProfile, errors: [] } }
  }
  if (document.includes('mutation CreateVolunteerApplication')) {
    const input = values.input as Record<string, unknown>
    const cohortId = String(input.cohortId ?? '')
    if (cohortId !== recruitmentCohort.id) {
      return {
        createVolunteerApplication: {
          result: null,
          errors: [
            { message: 'recruitment cohort not found', code: 'volunteer_application_cohort_not_found' }
          ]
        }
      }
    }
    // 同批一份（后端 unique_per_cohort 的 mock 投影，AE2 数据面）
    if (volunteerApplications.some((row) => row.cohortId === cohortId)) {
      return {
        createVolunteerApplication: {
          result: null,
          errors: [
            {
              message: 'volunteer application already submitted for this cohort',
              code: 'volunteer_application_already_submitted'
            }
          ]
        }
      }
    }
    const application = {
      id: `volunteer-application-${volunteerApplications.length + 1}`,
      cohortId,
      position: String(input.position ?? ''),
      city: typeof input.city === 'string' ? input.city : null,
      heardAboutUs: typeof input.heardAboutUs === 'string' ? input.heardAboutUs : null,
      hasInternalReferrer: input.hasInternalReferrer === true,
      message: typeof input.message === 'string' ? input.message : null,
      status: 'submitted',
      rejectionReason: null,
      assignedEventId: null,
      assignmentNote: null,
      assignedAt: null
    }
    volunteerApplications = [application, ...volunteerApplications]
    return { createVolunteerApplication: { result: application, errors: [] } }
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
  if (document.includes('mutation CheckInEnrollment')) {
    // #508-A：核销三分支（成功/重复/错码）。幂等由 checkedIn 标记承担——同一
    // 报名第二次核销稳定返回 already（后端唯一索引语义的 mock 投影）
    const code = typeof values.code === 'string' ? values.code : ''
    const current = enrollment
    const canCheckIn =
      loggedIn &&
      current?.status === 'confirmed' &&
      current.eventId === values.eventId &&
      current.checkInCode === code
    if (!canCheckIn || !current) {
      return {
        checkInEnrollment: {
          enrollmentId: null,
          checkedInAt: null,
          method: null,
          depositRefund: null,
          errors: [{ message: 'check-in code is invalid for this event', code: 'attendance_invalid_code' }]
        }
      }
    }
    if (checkedIn) {
      return {
        checkInEnrollment: {
          enrollmentId: null,
          checkedInAt: null,
          method: null,
          depositRefund: null,
          errors: [{ message: 'this enrollment has already been checked in', code: 'attendance_already_checked_in' }]
        }
      }
    }
    checkedIn = true
    // 押金单已付 → 核销即退（KTD6 分派表的 mock 投影）；无单/免费场 → null
    const depositRefund =
      order?.enrollmentId === current.id && order.status === 'paid' ? 'refunding' : null
    return {
      checkInEnrollment: {
        enrollmentId: current.id,
        checkedInAt: new Date().toISOString(),
        method: typeof values.method === 'string' ? values.method : 'manual',
        depositRefund,
        errors: []
      }
    }
  }

  throw new Error(`E2E GraphQL mock 未处理该 operation：${document.slice(0, 80)}`)
}

export function mockGraphQLRequest<TData>(document: RequestDocument, variables: object): TData {
  return responseFor(String(document), variables) as TData
}
