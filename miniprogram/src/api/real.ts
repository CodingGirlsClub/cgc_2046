import type {
  AdmitMemberByTokenMutation,
  AdmitMemberByTokenMutationVariables,
  ApproveJoinRequestMutation,
  ApproveJoinRequestMutationVariables,
  CancelEnrollmentMutation,
  CancelEnrollmentMutationVariables,
  CatalogQuery,
  CatalogQueryVariables,
  CatalogSearchQuery,
  CatalogSearchQueryVariables,
  CheckInEnrollmentMutation,
  CheckInEnrollmentMutationVariables,
  ConfirmEnrollmentMutation,
  ConfirmEnrollmentMutationVariables,
  CreateOrderMutation,
  CreateOrderMutationVariables,
  CourseDetailQuery,
  CourseDetailQueryVariables,
  CreateEnrollmentMutation,
  CreateEnrollmentMutationVariables,
  EnrollmentQuery,
  EnrollmentQueryVariables,
  EventDetailQuery,
  EventDetailQueryVariables,
  EventModerationScopeQuery,
  EventModerationScopeQueryVariables,
  EventModeratorsQuery,
  EventModeratorsQueryVariables,
  FlashbackAdjustFogMutation,
  FlashbackAdjustFogMutationVariables,
  FlashbackCapsuleQuery,
  FlashbackCapsuleQueryVariables,
  FlashbackClaimMutation,
  FlashbackCreateWishMutation,
  FlashbackCreateWishMutationVariables,
  FlashbackEndorseWishMutation,
  FlashbackEndorseWishMutationVariables,
  FlashbackAddWishCommentMutation,
  FlashbackAddWishCommentMutationVariables,
  FlashbackDeleteWishMutation,
  FlashbackDeleteWishMutationVariables,
  FlashbackClaimMutationVariables,
  FlashbackEnterMutation,
  FlashbackEnterMutationVariables,
  FlashbackMarkRevealedMutation,
  FlashbackMarkRevealedMutationVariables,
  FlashbackPublicStatsQuery,
  FlashbackPublicStatsQueryVariables,
  FlashbackSendToWallMutation,
  FlashbackSendToWallMutationVariables,
  FlashbackSetQuoteLicenseMutation,
  FlashbackSetQuoteLicenseMutationVariables,
  FlashbackSubmitTodayMutation,
  FlashbackSubmitTodayMutationVariables,
  GenerateMiniProgramCodeMutation,
  GenerateMiniProgramCodeMutationVariables,
  GrantConsentMutation,
  GrantConsentMutationVariables,
  MyEnrollmentsQuery,
  MyEnrollmentsQueryVariables,
  MyOrdersQuery,
  MyOrdersQueryVariables,
  OrderStatusQuery,
  OrderStatusQueryVariables,
  RejectEnrollmentMutation,
  RejectEnrollmentMutationVariables,
  RejectJoinRequestMutation,
  RejectJoinRequestMutationVariables,
  SessionQuery,
  SessionQueryVariables,
  SignOutMutation,
  SignOutMutationVariables,
  SignInWithPlatformMutation,
  SignInWithPlatformMutationVariables
} from './generated/graphql'
import { clearExpiredAuthentication, getAuthToken, graphqlRequest, GraphQLRequestError, isAuthenticationError, setAuthToken } from './client'
import { FlashbackNotBoundError, FlashbackTokenInvalidError, type FlashbackTokenInvalidCode } from '@/domain/models'
import {
  AdmitMemberByTokenMutationDocument,
  ApproveJoinRequestMutationDocument,
  CancelEnrollmentMutationDocument,
  CheckInEnrollmentMutationDocument,
  CreateOrderMutationDocument,
  MyOrdersQueryDocument,
  OrderStatusQueryDocument,
  CatalogQueryDocument,
  CatalogSearchQueryDocument,
  ConfirmEnrollmentMutationDocument,
  CourseDetailQueryDocument,
  CreateEnrollmentMutationDocument,
  EnrollmentQueryDocument,
  EventDetailQueryDocument,
  EventModerationScopeQueryDocument,
  EventModeratorsQueryDocument,
  FlashbackAdjustFogMutationDocument,
  FlashbackAddWishCommentMutationDocument,
  FlashbackCapsuleQueryDocument,
  FlashbackClaimMutationDocument,
  FlashbackCreateWishMutationDocument,
  FlashbackDeleteWishMutationDocument,
  FlashbackEndorseWishMutationDocument,
  FlashbackEnterMutationDocument,
  FlashbackMarkRevealedMutationDocument,
  FlashbackPublicStatsQueryDocument,
  FlashbackSendToWallMutationDocument,
  FlashbackSetQuoteLicenseMutationDocument,
  FlashbackSubmitTodayMutationDocument,
  GenerateMiniProgramCodeMutationDocument,
  GrantConsentMutationDocument,
  MyEnrollmentsQueryDocument,
  RejectEnrollmentMutationDocument,
  RejectJoinRequestMutationDocument,
  SessionQueryDocument,
  SignOutMutationDocument,
  SignInWithPlatformMutationDocument
} from './operations'
import { parseEnrollmentBadge, parseEnrollmentPolicy, parseEnrollmentStatus, parsePaymentMode } from '@/domain/format'
import { errorCopy } from '@/domain/error-copy'
import { parseOrderKind, parsePriceTiers } from '@/domain/payment'
import { catalogSearchVariables } from './catalogFilter'
import type { CreatedOrder, OrderStatus, OrderSummary } from '@/domain/models'
import type {
  AdmitResult,
  ApprovalSummary,
  CatalogItem,
  CheckInMethod,
  CheckInOutcome,
  ContentKind,
  EnrollmentForm,
  EnrollmentSummary,
  FlashbackCapsule,
  FlashbackWish,
  FlashbackClaimResult,
  FlashbackEnterResult,
  FlashbackFogSpan,
  FlashbackPublicStats,
  MyEnrollmentState,
  MiniProgramApi,
  MiniProgramCode,
  NotificationItem,
  PlatformPhonePayload,
  SessionSnapshot,
  SubscriptionScenario,
  WorkspaceSummary
} from '@/domain/models'
import { currentPlatform } from '@/platform'
import { parseQualificationBadge } from '@/domain/initiative'
import { clearWorkspaceTab, rememberWorkspaceTab } from '@/state/workspaceTab'
import {
  activateAccount,
  appendLocalNotification,
  clearAccountState,
  readLocalNotifications
} from '@/state/accountState'

type EventRecord = NonNullable<NonNullable<CatalogQuery['listEvents']>['results']>[number]
type CourseRecord = NonNullable<NonNullable<CatalogQuery['listCourses']>['results']>[number]
// venue 仅 event 有槽（Course 无位置概念，R3）——两 record 形状在此分叉，故取并集
// 押金字段（U11）同理只在 event 上存在，且仅详情查询请求（匿名列表白名单与 web
// PUBLIC_LIST_* 同源，不含押金字段）→ 声明为可选，列表记录映射为免费态。
// initiativeId 同款：仅详情查询携带（列表记录 → null，不回链）。
type ContentRecord = (EventRecord | CourseRecord) &
  Partial<{
    depositEnabled: boolean | null
    depositAmountCents: number | null
    initiativeId: string | null
    minAge: number | null
  }>

// 详情查询同文档带出的 myEnrollment 子集（#355 P1-3；两 kind 形状一致）
type MyEnrollmentRecord = NonNullable<EventDetailQuery['myEnrollment']>
// enrollments 列表查询行（MyEnrollments/Enrollment 两查询同形状，#355 P1-4）
type EnrollmentRecord = NonNullable<NonNullable<MyEnrollmentsQuery['enrollments']>['results']>[number]

function mapMyEnrollment(record: MyEnrollmentRecord | null | undefined): MyEnrollmentState | null {
  if (!record) return null
  return {
    id: record.id,
    status: parseEnrollmentStatus(record.status),
    approvalDeadline: record.approvalDeadline ?? null
  }
}

function mapContent(record: ContentRecord, kind: ContentKind, myEnrollment: MyEnrollmentRecord | null | undefined): CatalogItem {
  return {
    id: record.id,
    kind,
    title: record.title,
    status: record.status,
    qualificationBadge: 'qualificationBadge' in record ? parseQualificationBadge(record.qualificationBadge) : null,
    shortBy: 'shortBy' in record && typeof record.shortBy === 'number' ? record.shortBy : null,
    enrollmentPolicy: parseEnrollmentPolicy(record.enrollmentPolicy),
    registrationDeadline: record.registrationDeadline,
    pricingEnabled: record.pricingEnabled === true,
    priceTiers: parsePriceTiers(record.availablePriceTiers),
    // 押金场：金额缺失不编造（enabled 但无额 → null，展示层降级不出价）
    depositEnabled: record.depositEnabled === true,
    depositAmountCents:
      record.depositEnabled === true && typeof record.depositAmountCents === 'number'
        ? record.depositAmountCents
        : null,
    // 年龄门槛（#510）：仅 event 查询携带；course 槽位缺省 → null（无门槛）
    minAge: 'minAge' in record && typeof record.minAge === 'number' ? record.minAge : null,
    startsAt: record.startsAt,
    endsAt: record.endsAt,
    venue: 'venue' in record ? record.venue : null,
    initiativeId: record.initiativeId ?? null,
    enrollmentBadge: parseEnrollmentBadge(record.enrollmentBadge),
    myEnrollment: mapMyEnrollment(myEnrollment)
  }
}

function mapEnrollment(enrollment: EnrollmentRecord): EnrollmentSummary {
  return {
    id: enrollment.id,
    workspaceId: enrollment.workspaceId,
    targetId: enrollment.eventId ?? enrollment.courseId ?? '',
    kind: enrollment.eventId ? 'event' : 'course',
    title: enrollment.targetTitle ?? '报名项目',
    status: parseEnrollmentStatus(enrollment.status),
    approvalDeadline: enrollment.approvalDeadline ?? null,
    rejectionReason: enrollment.rejectionReason ?? null,
    insertedAt: enrollment.insertedAt,
    checkInCode: enrollment.checkInCode ?? null,
    paymentMode: parsePaymentMode(enrollment.paymentMode ?? null),
    // #617：改期/开课提醒的权威落点——目标开始时间与场地原样透传
    startsAt: enrollment.startsAt ?? null,
    venue: enrollment.venue ?? null,
    registrationDeadline: enrollment.registrationDeadline ?? null
  }
}
function parseOrderStatus(value: string): OrderStatus {
  if (
    value === 'pending' || value === 'paid' || value === 'refunding' ||
    value === 'refunded' || value === 'refund_failed' || value === 'cancelled' ||
    value === 'expired' || value === 'forfeited'
  ) return value
  throw new Error(`服务端返回未知订单状态：${value}`)
}

// Action 卡四态 fail-closed：未知态落 done（终态只读，无写面风险）。
function mutationError(errors: Array<{ message?: string | null; code?: string | null }>): never {
  // code 命中 → 中文文案；未命中 join message（通用兜底，拿不到 code 的场景用）
  const copy = errors.map(({ code }) => errorCopy(code)).find(Boolean)
  if (copy) throw new Error(copy)
  throw new Error(errors.map(({ message }) => message).filter(Boolean).join('；') || '操作失败')
}

/** 登录已失效：曾有 token 但会话降级（#355 P0-2）。getEnrollments/getMyOrders
 * 以此拒绝代替静默 []，页面据「从未报名」与「掉线」两种空态分叉渲染。 */
export class SessionExpiredError extends Error {
  constructor(message = '登录已过期，请重新登录') {
    super(message)
    this.name = 'SessionExpiredError'
  }
}


/** 首程链接失效 code → 类型化错误（不存在/已注册/已删除三分支，KTD2/ADR-0015）；
 * capsule 与 enter 共用（token 面一切读写的失效语义同源）。 */
function throwIfFlashbackTokenInvalid(error: unknown): void {
  if (!(error instanceof GraphQLRequestError)) return
  const codes = error.errors.map((entry) => entry.code ?? entry.extensions?.code)
  const invalid = codes.find(
    (code): code is FlashbackTokenInvalidCode =>
      code === 'flashback_token_not_found' || code === 'flashback_token_claimed' || code === 'flashback_token_revoked'
  )
  if (invalid) throw new FlashbackTokenInvalidError(invalid)
}

export class RealMiniProgramApi implements MiniProgramApi {
  // #355 P2-10：keyword 非空走服务端 title ilike 过滤（catalogSearchVariables 构造
  // filter）；空关键词保持原 CatalogQueryDocument（无 filter 变量，行为不变）。
  async getCatalog(keyword?: string): Promise<CatalogItem[]> {
    const filters = catalogSearchVariables(keyword)
    const data = filters
      ? await graphqlRequest<CatalogSearchQuery, CatalogSearchQueryVariables>(CatalogSearchQueryDocument, {
          first: 50,
          eventFilter: filters.eventFilter,
          courseFilter: filters.courseFilter
        })
      : await graphqlRequest<CatalogQuery, CatalogQueryVariables>(CatalogQueryDocument, { first: 50 })
    // 发现页为匿名目录面：CatalogQuery 不带 myEnrollment（#355 P1-3 仅详情面）
    const events = (data.listEvents?.results ?? []).map((record) => mapContent(record, 'event', null))
    const courses = (data.listCourses?.results ?? []).map((record) => mapContent(record, 'course', null))
    return [...events, ...courses]
  }

  async getContent(kind: ContentKind, id: string): Promise<CatalogItem> {
    if (kind === 'event') {
      const data = await graphqlRequest<EventDetailQuery, EventDetailQueryVariables>(
        EventDetailQueryDocument,
        { id }
      )
      if (!data.getEvent) throw new Error('活动不存在或不可访问')
      return mapContent(data.getEvent, 'event', data.myEnrollment)
    }
    const data = await graphqlRequest<CourseDetailQuery, CourseDetailQueryVariables>(
      CourseDetailQueryDocument,
      { id }
    )
    if (!data.getCourse) throw new Error('课程不存在或不可访问')
    return mapContent(data.getCourse, 'course', data.myEnrollment)
  }

  async getSession(): Promise<SessionSnapshot> {
    try {
      return await this.fetchSession()
    } catch (error) {
      // 统一降级未登录快照:session 是装饰,任何失败都不该拖死公开目录
      // (模拟器残留坏 token → Forbidden → 发现页 Promise.all 全挂的真机事故)。
      // 认证错误 client.ts 已清 token;服务端返回非认证 errors(如 forbidden)
      // → token 可疑,清掉防反复炸;纯网络失败(未到达服务端)→ 保留 token。
      const serverError = error instanceof GraphQLRequestError && error.errors.length > 0
      if (!isAuthenticationError(error)) {
        if (serverError) clearExpiredAuthentication()
        else {
          clearWorkspaceTab()
          clearAccountState()
        }
      }
      // 掉线标记（#355 P0-2）：此 catch 只在「曾有 token」时进入（fetchSession
      // 无 token 早退）；auth/服务端错误已清 token = 登录失效。网络瞬态失败
      // （token 保留）不算掉线，下次加载自愈。
      const authExpired = isAuthenticationError(error) || serverError
      return { user: null, workspaces: [], approvals: [], authExpired }
    }
  }

  // 内部 throw 语义版:signIn 的 hydration 回滚依赖失败可抛。
  private async fetchSession(): Promise<SessionSnapshot> {
    if (!getAuthToken()) {
      clearWorkspaceTab()
      // 保留 pending scene（clearPendingScene 默认 false），扫码→登录交接继续
      clearAccountState()
      return { user: null, workspaces: [], approvals: [], authExpired: false }
    }
    const data: SessionQuery = await graphqlRequest<SessionQuery, SessionQueryVariables>(
      SessionQueryDocument,
      {}
    )
    const workspaces: WorkspaceSummary[] = data.meWorkspaces.map((workspace) => ({
      id: workspace.id,
      slug: workspace.slug,
      name: workspace.name,
      roleNames: workspace.myRoleNames ?? [],
      abilities: workspace.myAbilities ?? [],
      memberCount: workspace.memberCount
    }))
    const names = new Map(workspaces.map(({ id, name }) => [id, name]))
    const approvals: ApprovalSummary[] = data.myPendingApprovals.map((approval) => ({
      id: approval.id,
      kind: approval.kind,
      workspaceId: approval.workspaceId,
      workspaceName: names.get(approval.workspaceId) ?? '工作台',
      targetId: approval.eventId ?? approval.courseId,
      requesterName: approval.requesterName ?? '未知用户',
      contextTitle: approval.contextTitle ?? null,
      tierName: approval.tierName ?? null,
      amount: approval.amount ?? null,
      status: approval.status,
      approvalDeadline: approval.approvalDeadline
    }))
    rememberWorkspaceTab(workspaces)
    if (data.me) activateAccount(data.me.id)
    return {
      user: data.me
        ? {
            id: data.me.id,
            displayName: data.me.displayName ?? data.me.email?.split('@')[0] ?? 'CGC 用户',
            email: data.me.email,
            memberNumber: data.me.memberNumber
          }
        : null,
      workspaces,
      approvals,
      authExpired: false
    }
  }

  async signIn(payload: PlatformPhonePayload): Promise<SessionSnapshot> {
    // 契约：phoneCode（新）或 encryptedData+iv（legacy）二选一——与服务端
    // SignInPreparation.fetch_phone 的组合校验对齐，缺登录凭证必拒。
    // phoneCode 仅限 weapp/tt（服务端分别走 getuserphonenumber /
    // get_phone_number）；xhs 无服务端 code API，并存 code 字段剥离出契约
    // （advisor09 F1 gate 范围收窄至 xhs）
    const isNewPhonePlatform =
      process.env.TARO_ENV === 'weapp' || process.env.TARO_ENV === 'tt'
    const phoneCode = isNewPhonePlatform ? payload.code : undefined
    if (!payload.loginCode || (!phoneCode && (!payload.encryptedData || !payload.iv))) {
      throw new Error('平台登录参数不完整')
    }
    // 新登录事务：清旧 token/Workspace/账号状态，保留 pending scene（扫码→登录交接）
    setAuthToken(null)
    clearWorkspaceTab()
    clearAccountState()
    await graphqlRequest<SignInWithPlatformMutation, SignInWithPlatformMutationVariables>(
      SignInWithPlatformMutationDocument,
      {
        platform: currentPlatform(),
        code: payload.loginCode,
        ...(phoneCode ? { phoneCode } : {}),
        encryptedData: payload.encryptedData ?? null,
        iv: payload.iv ?? null
      },
      { captureAuthCookie: true }
    )
    if (!getAuthToken()) throw new Error('登录成功但未收到 Bearer token，请检查响应 cookie 契约')
    try {
      return await this.fetchSession()
    } catch (error) {
      // session hydration 失败：全量回滚，UI 显示失败与设备状态一致
      setAuthToken(null)
      clearWorkspaceTab()
      clearAccountState()
      throw error
    }
  }

  async signOut(): Promise<void> {
    try {
      if (getAuthToken()) {
        await graphqlRequest<SignOutMutation, SignOutMutationVariables>(SignOutMutationDocument, {})
      }
    } finally {
      setAuthToken(null)
      clearWorkspaceTab()
      clearAccountState({ clearPendingScene: true })
    }
  }

  async getEnrollments(): Promise<EnrollmentSummary[]> {
    const session = await this.getSession()
    if (!session.user) {
      // 掉线 ≠ 没有报名：拒绝而非静默 []，页面渲染「登录已过期」重登空态
      if (session.authExpired) throw new SessionExpiredError()
      return []
    }
    const data = await graphqlRequest<MyEnrollmentsQuery, MyEnrollmentsQueryVariables>(
      MyEnrollmentsQueryDocument,
      { userId: session.user.id, first: 100 }
    )
    return (data.enrollments?.results ?? []).map(mapEnrollment)
  }

  async getEnrollment(id: string): Promise<EnrollmentSummary | null> {
    // 未登录 → 查无（read policy 本人才可见；结果页据此走 storage 兜底链）
    if (!getAuthToken()) return null
    const data = await graphqlRequest<EnrollmentQuery, EnrollmentQueryVariables>(
      EnrollmentQueryDocument,
      { id }
    )
    const [record] = data.enrollments?.results ?? []
    return record ? mapEnrollment(record) : null
  }
  async cancelEnrollment(id: string): Promise<void> {
    const data = await graphqlRequest<CancelEnrollmentMutation, CancelEnrollmentMutationVariables>(
      CancelEnrollmentMutationDocument,
      { id }
    )
    if (data.cancelEnrollment.result) return
    if (data.cancelEnrollment.errors.some(({ code }) =>
      code === 'enrollment_already_processed'
    )) return
    mutationError(data.cancelEnrollment.errors)
  }
  async createEnrollment(form: EnrollmentForm): Promise<EnrollmentSummary> {
    const session = await this.getSession()
    if (!session.user) throw new Error('请先登录')
    // 对齐 web 一键报名:不传 submissionPayload(web 端本来就不传;
    // name/email/reason 三键经确认无任何读者)。
    const input: CreateEnrollmentMutationVariables['input'] = {
      userId: session.user.id,
      inviteCode: form.inviteCode || undefined,
      // 收费必传档(后端校验「收费项请先选择价格档位」)——此前漏传,
      // 免费活动测试从未暴露。
      tierId: form.tierId || undefined,
      // 年龄门槛确认（#510）：后端 action 权威门控，本端只在 minAge 非空时携带
      ...(form.target.minAge != null ? { ageConfirmed: form.ageConfirmed === true } : {}),
      ...(form.target.kind === 'event'
        ? { eventId: form.target.id }
        : { courseId: form.target.id })
    }
    const data = await graphqlRequest<CreateEnrollmentMutation, CreateEnrollmentMutationVariables>(
      CreateEnrollmentMutationDocument,
      { input }
    )
    const result = data.createEnrollment.result
    if (!result) mutationError(data.createEnrollment.errors)
    return {
      id: result.id,
      workspaceId: result.workspaceId,
      targetId: result.eventId ?? result.courseId ?? form.target.id,
      kind: form.target.kind,
      title: form.target.title,
      status: parseEnrollmentStatus(result.status),
      approvalDeadline: result.approvalDeadline,
      rejectionReason: null,
      insertedAt: result.insertedAt,
      // create 结果未选 checkInCode（结果页不出示码；出示面是「我的报名」，
      // 走 getEnrollments 重新取——押金报名落 payment_pending 本无码可出）
      checkInCode: null,
      // create 结果未选缴费模式/截止时间（两查询同形状仅列表/单条回查）——
      // 从报名目标本地推导，与后端 payment_mode 计算同规则（押金优先于定价）
      paymentMode: form.target.depositEnabled ? 'deposit' : form.target.pricingEnabled ? 'pricing' : 'free',
      // #617：create 结果同样未选 startsAt/venue。startsAt 与 form.target 同形
      // （都是供给物 starts_at 的 ISO 值）→ 本地取；venue 不行——读面契约是后端
      // 已文本化的 city+district，而 form.target.venue 是 JsonString，本地转换等于
      // 复刻 Venue.text/1（且结果页/本页都不渲染该字段）→ 与 checkInCode 同款，
      // 未选即 null，不给一个形态不同的值。
      startsAt: form.target.startsAt,
      venue: null,
      registrationDeadline: form.target.registrationDeadline
    }
  }

  private async confirmEnrollment(id: string): Promise<void> {
    const data = await graphqlRequest<ConfirmEnrollmentMutation, ConfirmEnrollmentMutationVariables>(
      ConfirmEnrollmentMutationDocument,
      { id }
    )
    if (!data.confirmEnrollment.result) mutationError(data.confirmEnrollment.errors)
    appendLocalNotification('审批已完成', '已通过该报名申请。')
  }

  private async rejectEnrollment(id: string, reason?: string): Promise<void> {
    const data = await graphqlRequest<RejectEnrollmentMutation, RejectEnrollmentMutationVariables>(
      RejectEnrollmentMutationDocument,
      { id, input: reason ? { rejectionReason: reason } : undefined }
    )
    if (!data.rejectEnrollment.result) mutationError(data.rejectEnrollment.errors)
    appendLocalNotification('审批已完成', reason ? `已拒绝该报名申请：${reason}` : '已拒绝该报名申请。')
  }

  async approvePending(approval: ApprovalSummary): Promise<void> {
    if (approval.kind === 'enrollment') return this.confirmEnrollment(approval.id)
    const data = await graphqlRequest<ApproveJoinRequestMutation, ApproveJoinRequestMutationVariables>(
      ApproveJoinRequestMutationDocument,
      { id: approval.id }
    )
    if (!data.approveJoinRequest.result) mutationError(data.approveJoinRequest.errors)
    appendLocalNotification('加入申请已通过', `${approval.workspaceName} 已接纳新成员。`)
  }

  async rejectPending(approval: ApprovalSummary, reason?: string): Promise<void> {
    if (approval.kind === 'enrollment') return this.rejectEnrollment(approval.id, reason)
    const data = await graphqlRequest<RejectJoinRequestMutation, RejectJoinRequestMutationVariables>(
      RejectJoinRequestMutationDocument,
      { id: approval.id, input: reason ? { rejectionReason: reason } : undefined }
    )
    if (!data.rejectJoinRequest.result) mutationError(data.rejectJoinRequest.errors)
    appendLocalNotification('加入申请未通过', reason || `${approval.workspaceName} 拒绝了加入申请。`)
  }

  async grantConsent(scenario: SubscriptionScenario): Promise<number> {
    const data = await graphqlRequest<GrantConsentMutation, GrantConsentMutationVariables>(
      GrantConsentMutationDocument,
      { platform: currentPlatform(), templateKey: scenario }
    )
    appendLocalNotification('订阅授权已记录', '平台会在对应业务节点发送一次服务通知。')
    return data.grantMiniProgramNotificationConsent ?? 0
  }

  async generateMiniProgramCode(workspaceId: string): Promise<MiniProgramCode> {
    const data = await graphqlRequest<
      GenerateMiniProgramCodeMutation,
      GenerateMiniProgramCodeMutationVariables
    >(GenerateMiniProgramCodeMutationDocument, { workspaceId, platform: currentPlatform() })
    if (!data.generateMiniProgramCode) throw new Error('小程序码生成失败')
    return data.generateMiniProgramCode
  }

  async admitMember(scene: string): Promise<AdmitResult> {
    try {
      const data = await graphqlRequest<AdmitMemberByTokenMutation, AdmitMemberByTokenMutationVariables>(
        AdmitMemberByTokenMutationDocument,
        { scene }
      )
      if (!data.admitMemberByToken) throw new Error('邀请码无效或已过期')
      return {
        workspaceId: data.admitMemberByToken.workspaceId,
        workspaceName: data.admitMemberByToken.workspaceName ?? '工作台'
      }
    } catch (error) {
      // 服务端业务错误英文透传防泄漏（review 发现的漏网）:按 code 映射中文;
      // code 顶层/extensions 双轨,与 isAuthenticationError 同读法。
      if (error instanceof GraphQLRequestError) {
        const code = error.errors[0]?.code ?? error.errors[0]?.extensions?.code
        if (code === 'invalid_scene') throw new Error('邀请码格式不正确')
        if (code === 'invalid_or_expired_scene') throw new Error('邀请码无效或已过期')
      }
      throw error
    }
  }

  // 核销入口门（#508-A）：workspace_id 是 Event field_policy 收窄字段——探测查询
  // 仅本 workspace 成员/平台管理员成功；匿名/非成员/网络失败一律 false（入口
  // 隐藏，不影响公开详情主流程）。判定 = Owner/Admin（session 角色，与后端
  // Moderators.can_moderate? 同口径）∨ 我在 eventModerators 列表（#558 后
  // 主理人恒为成员，探测与列表查询对他们都通；普通成员读列表 forbidden →
  // false）。真授权由后端 checkInEnrollment policy fail-closed 承担。
  async canModerateEvent(eventId: string): Promise<boolean> {
    const session = await this.getSession()
    if (!session.user) return false
    try {
      const data = await graphqlRequest<EventModerationScopeQuery, EventModerationScopeQueryVariables>(
        EventModerationScopeQueryDocument,
        { id: eventId }
      )
      const workspaceId = data.getEvent?.workspaceId
      if (!workspaceId) return false
      const isOwnerOrAdmin = session.workspaces.some((workspace) =>
        workspace.id === workspaceId &&
        workspace.roleNames.some((role) => role === 'owner' || role === 'admin')
      )
      if (isOwnerOrAdmin) return true

      // 非管理角色：查主理人列表（主理人可读；普通成员 forbidden → false）
      const moderators = await graphqlRequest<EventModeratorsQuery, EventModeratorsQueryVariables>(
        EventModeratorsQueryDocument,
        { workspaceId, eventId }
      )
      return moderators.eventModerators.some((row) => row.userId === session.user!.id)
    } catch {
      return false
    }
  }

  async checkInEnrollment(eventId: string, code: string, method: CheckInMethod): Promise<CheckInOutcome> {
    try {
      const data = await graphqlRequest<CheckInEnrollmentMutation, CheckInEnrollmentMutationVariables>(
        CheckInEnrollmentMutationDocument,
        { eventId, code, method }
      )
      const payload = data.checkInEnrollment
      if (payload?.enrollmentId) {
        return {
          kind: 'success',
          checkedInAt: payload.checkedInAt ?? null,
          depositRefund: payload.depositRefund ?? null
        }
      }
      // 业务失败进 payload.errors（手写 mutation 信封）；无 code 按码无效收敛
      // （后端对「不存在/非 confirmed/码不匹配」本就不区分，同桶不增枚举面）
      const businessCode = payload?.errors?.find((entry) => entry?.code)?.code ?? null
      if (businessCode === 'attendance_already_checked_in') return { kind: 'already' }
      if (businessCode === 'deposit_already_forfeited') return { kind: 'forfeited' }
      if (businessCode === 'attendance_rate_limited') return { kind: 'rate_limited' }
      return { kind: 'invalid' }
    } catch (error) {
      // forbidden（policy 拒绝在 resolve 之前）走顶层 errors；其余（网络/5xx）
      // 原样上抛——页面给「可原样重试」反馈，与业务失败不同桶
      if (error instanceof GraphQLRequestError) {
        const codes = error.errors.map((entry) => entry.code ?? entry.extensions?.code)
        if (codes.includes('forbidden')) return { kind: 'forbidden' }
        if (codes.includes('attendance_rate_limited')) return { kind: 'rate_limited' }
      }
      throw error
    }
  }

  async getNotifications(): Promise<NotificationItem[]> {
    return readLocalNotifications()
  }

  // ── 闪念间「我的」（U9/R28：会话腿——登录账号绑定档案） ──────────────

  // U4 愿望写操作:双入口 token,失效抛 FlashbackNotBoundError 由页面处理
  async flashbackCreateWish(content: string, visibility: 'private' | 'public', token?: string | null): Promise<void> {
    await graphqlRequest<FlashbackCreateWishMutation, FlashbackCreateWishMutationVariables>(
      FlashbackCreateWishMutationDocument,
      { content, visibility, token: token ?? null }
    ).catch((error: unknown) => {
      throwIfFlashbackTokenInvalid(error)
      throw error
    })
  }

  async flashbackEndorseWish(wishId: string, token?: string | null): Promise<number> {
    const data = await graphqlRequest<FlashbackEndorseWishMutation, FlashbackEndorseWishMutationVariables>(
      FlashbackEndorseWishMutationDocument,
      { wishId, token: token ?? null }
    ).catch((error: unknown) => {
      throwIfFlashbackTokenInvalid(error)
      throw error
    })
    return data.flashbackEndorseWish?.endorsementCount ?? 0
  }

  async flashbackAddWishComment(wishId: string, content: string, token?: string | null): Promise<void> {
    await graphqlRequest<FlashbackAddWishCommentMutation, FlashbackAddWishCommentMutationVariables>(
      FlashbackAddWishCommentMutationDocument,
      { wishId, content, token: token ?? null }
    ).catch((error: unknown) => {
      throwIfFlashbackTokenInvalid(error)
      throw error
    })
  }

  async flashbackDeleteWish(wishId: string, token?: string | null): Promise<void> {
    await graphqlRequest<FlashbackDeleteWishMutation, FlashbackDeleteWishMutationVariables>(
      FlashbackDeleteWishMutationDocument,
      { wishId, token: token ?? null }
    ).catch((error: unknown) => {
      throwIfFlashbackTokenInvalid(error)
      throw error
    })
  }

  async getFlashbackCapsule(city?: string | null, token?: string | null): Promise<FlashbackCapsule> {
    const data = await graphqlRequest<FlashbackCapsuleQuery, FlashbackCapsuleQueryVariables>(
      FlashbackCapsuleQueryDocument,
      { city: city ?? null, token: token ?? null }
    ).catch((error: unknown) => {
      // 首程链接失效（token 面）：类型化抛出，页面按三态渲染失效落地（KTD2）
      throwIfFlashbackTokenInvalid(error)
      if (error instanceof GraphQLRequestError) {
        // 登录账号没绑定档案（会话腿 miss）→ 引导态
        if (error.errors.some((entry) => (entry.code ?? entry.extensions?.code) === 'flashback_person_not_bound')) {
          throw new FlashbackNotBoundError()
        }
        // 未登录/会话失效（会话腿 code = flashback_auth_required，与后端
        // alumni_projection 同源）→ 登录引导而非错误面——对齐 getMyEnrollments/
        // getMyOrders 的 SessionExpiredError 先例（P1）
        if (
          isAuthenticationError(error) ||
          error.errors.some((entry) => (entry.code ?? entry.extensions?.code) === 'flashback_auth_required')
        ) {
          throw new SessionExpiredError()
        }
      }
      throw error
    })

    const capsule = data.flashbackCapsule
    if (!capsule) throw new Error('闪念间档案加载失败')

    return {
      me: {
        id: capsule.me.id,
        fullName: capsule.me.fullName,
        surname: capsule.me.surname ?? null,
        city: capsule.me.city ?? null,
        occupationThen: capsule.me.occupationThen ?? null,
        participation: capsule.me.participation === 'not_selected' ? 'not_selected' : 'attended',
        appliedAt: capsule.me.appliedAt ?? null,
        quoteLevel: capsule.me.quoteLevel,
        quote: capsule.me.quote ?? null,
        quoteQuestionKey: capsule.me.quoteQuestionKey ?? null,
        quoteSpan: capsule.me.quoteSpan
          ? { start: capsule.me.quoteSpan.start, len: capsule.me.quoteSpan.len }
          : null,
        quoteStats: capsule.me.quoteStats ? { likeCount: capsule.me.quoteStats.likeCount } : null,
        today: capsule.me.today
          ? {
              nowStatus: capsule.me.today.nowStatus ?? null,
              want: capsule.me.today.want ?? null,
              say: capsule.me.today.say ?? null,
              sentToWallAt: capsule.me.today.sentToWallAt ?? null
            }
          : null,
        answers: (capsule.me.answers ?? []).map((answer) => ({
          id: answer.id,
          questionKey: answer.questionKey,
          rawText: answer.rawText,
          fogSpans: (answer.fogSpans ?? []).map((span) => ({ start: span.start, len: span.len })),
          text: answer.text
        }))
      },
      archives: (capsule.archives ?? []).map((archive) => ({
        key: archive.key,
        name: archive.name ?? null,
        city: archive.city ?? null,
        occurredOn: archive.occurredOn ?? null,
        appliedCount: archive.appliedCount ?? null,
        attendedCount: archive.attendedCount ?? null,
        label: archive.label ?? null,
        isMine: archive.isMine,
        roster: (archive.roster ?? []).map((entry) => ({
          id: entry.id,
          surnameMasked: entry.surnameMasked,
          fullName: entry.fullName ?? null,
          appliedAt: entry.appliedAt ?? null,
          city: entry.city ?? null,
          occupationThen: entry.occupationThen ?? null,
          sentToWallAt: entry.sentToWallAt ?? null,
          today: entry.today
            ? {
                nowStatus: entry.today.nowStatus ?? null,
                want: entry.today.want ?? null,
                say: entry.today.say ?? null
              }
            : null,
          answers: (entry.answers ?? []).map((answer) => ({
            questionKey: answer.questionKey,
            segments: (answer.segments ?? []).map((segment) => ({
              text: segment.text,
              fog: segment.fog,
              len: segment.len
            }))
          }))
        }))
      })),
      futureEvents: (capsule.futureEvents ?? []).map((frame) => ({
        initiativeSlug: frame.initiativeSlug,
        initiativeName: frame.initiativeName,
        events: (frame.events ?? []).map((event) => ({
          id: event.id,
          slug: event.slug,
          title: event.title,
          city: event.city ?? null,
          startsAt: event.startsAt ?? null,
          capacity: event.capacity ?? null,
          confirmedCount: event.confirmedCount ?? 0,
          registrationDeadline: event.registrationDeadline ?? null
        }))
      })),
      publicWishes: (capsule.publicWishes ?? []).map(mapWish),
      myPrivateWishes: (capsule.myPrivateWishes ?? []).map(mapWish),
      cities: capsule.cities ?? []
    }
  }


  async flashbackSubmitToday(
    input: {
      nowStatus?: string | null
      want?: string | null
      need?: string | null
      say?: string | null
    },
    token?: string | null
  ): Promise<void> {
    await graphqlRequest<FlashbackSubmitTodayMutation, FlashbackSubmitTodayMutationVariables>(
      FlashbackSubmitTodayMutationDocument,
      { input, token: token ?? null }
    ).catch((error: unknown) => {
      throwIfFlashbackTokenInvalid(error)
      throw error
    })
  }

  async flashbackSetQuoteLicense(
    level: 'off' | 'anonymous' | 'credited',
    questionKey?: string | null,
    chosenQuoteSpan?: { start: number; len: number } | null
  ): Promise<void> {
    // R35 圈选：档位与区间一起提交——只传 level 会把既有 span 覆盖成 nil
    //（后端 update 按传入值覆盖），未圈选 = 不上墙。
    const data = await graphqlRequest<
      FlashbackSetQuoteLicenseMutation,
      FlashbackSetQuoteLicenseMutationVariables
    >(FlashbackSetQuoteLicenseMutationDocument, {
      level,
      questionKey: questionKey ?? null,
      chosenQuoteSpan: chosenQuoteSpan ?? null
    })
    if (!data.flashbackSetQuoteLicense) throw new Error('授权设置失败，请重试')
  }

  async flashbackAdjustFog(answerId: string, spans: FlashbackFogSpan[]): Promise<void> {
    await graphqlRequest<FlashbackAdjustFogMutation, FlashbackAdjustFogMutationVariables>(
      FlashbackAdjustFogMutationDocument,
      {
        answerId,
        spans: spans.map((span) => ({ start: span.start, len: span.len, reason: span.reason ?? 'owner' }))
      }
    )
  }

  // ── 首程 token 面（mp 版原型 F：旅程 → 长廊 → 场次；R1/R4-R11/R27） ──

  async flashbackEnter(token: string): Promise<FlashbackEnterResult> {
    const data = await graphqlRequest<FlashbackEnterMutation, FlashbackEnterMutationVariables>(
      FlashbackEnterMutationDocument,
      { token }
    ).catch((error: unknown) => {
      throwIfFlashbackTokenInvalid(error)
      throw error
    })
    const result = data.flashbackEnter
    if (!result) throw new Error('进入闪念间失败，请重试')
    return {
      line: result.line === 'dream' ? 'dream' : 'memory',
      profile: result.profile
        ? {
            fullName: result.profile.fullName,
            surname: result.profile.surname ?? null,
            city: result.profile.city ?? null,
            occupationThen: result.profile.occupationThen ?? null,
            participation: result.profile.participation === 'not_selected' ? 'not_selected' : 'attended',
            role: result.profile.role,
            appliedAt: result.profile.appliedAt ?? null,
            archive: result.profile.archive
              ? {
                  key: result.profile.archive.key,
                  name: result.profile.archive.name ?? null,
                  city: result.profile.archive.city ?? null,
                  occurredOn: result.profile.archive.occurredOn ?? null
                }
              : null,
            // codegen 列表元素可空（SDL 列表未加 !）：先滤再映射
            answers: (result.profile.answers ?? [])
              .filter((answer): answer is NonNullable<typeof answer> => answer != null)
              .map((answer) => ({
                id: answer.id,
                questionKey: answer.questionKey,
                rawText: answer.rawText,
                fogSpans: (answer.fogSpans ?? [])
                  .filter((span): span is NonNullable<typeof span> => span != null)
                  .map((span) => ({ start: span.start, len: span.len }))
              }))
          }
        : null,
      progress: result.progress
        ? {
            quoteLevel: result.progress.quoteLevel,
            maskedPhone: result.progress.maskedPhone ?? null,
            maskedEmail: result.progress.maskedEmail ?? null,
            today: result.progress.today
              ? {
                  nowStatus: result.progress.today.nowStatus ?? null,
                  want: result.progress.today.want ?? null,
                  say: result.progress.today.say ?? null,
                  sentToWallAt: result.progress.today.sentToWallAt ?? null
                }
              : null
          }
        : null
    }
  }

  async flashbackMarkRevealed(token: string): Promise<void> {
    await graphqlRequest<FlashbackMarkRevealedMutation, FlashbackMarkRevealedMutationVariables>(
      FlashbackMarkRevealedMutationDocument,
      { token }
    )
  }

  async flashbackSendToWall(token: string): Promise<void> {
    const data = await graphqlRequest<FlashbackSendToWallMutation, FlashbackSendToWallMutationVariables>(
      FlashbackSendToWallMutationDocument,
      { token }
    ).catch((error: unknown) => {
      throwIfFlashbackTokenInvalid(error)
      throw error
    })
    if (!data.flashbackSendToWall?.sentToWallAt) throw new Error('寄出失败，请重试')
  }

  async flashbackClaim(token?: string | null): Promise<FlashbackClaimResult> {
    const data = await graphqlRequest<FlashbackClaimMutation, FlashbackClaimMutationVariables>(
      FlashbackClaimMutationDocument,
      { token: token ?? null }
    ).catch((error: unknown) => {
      // 带 token 但链接已失效 → 类型化（页面提示链接已被账号接管）
      throwIfFlashbackTokenInvalid(error)
      if (error instanceof GraphQLRequestError) {
        if (
          isAuthenticationError(error) ||
          error.errors.some((entry) => (entry.code ?? entry.extensions?.code) === 'flashback_auth_required')
        ) {
          throw new SessionExpiredError()
        }
      }
      throw error
    })
    const result = data.flashbackClaim
    if (!result) throw new Error('收好失败，请重试')
    return {
      bound: result.bound,
      boundCount: result.boundCount,
      maskedPhone: result.maskedPhone ?? null
    }
  }

  async getFlashbackPublicStats(): Promise<FlashbackPublicStats> {
    const data = await graphqlRequest<FlashbackPublicStatsQuery, FlashbackPublicStatsQueryVariables>(
      FlashbackPublicStatsQueryDocument,
      {}
    )
    return {
      archives: (data.flashbackPublicStats?.archives ?? []).map((archive) => ({
        key: archive.key,
        name: archive.name ?? null,
        city: archive.city ?? null,
        occurredOn: archive.occurredOn ?? null,
        appliedCount: archive.appliedCount ?? null,
        attendedCount: archive.attendedCount ?? null,
        label: archive.label ?? null
      })),
      returnedCount: data.flashbackPublicStats?.returnedCount ?? 0,
      sentCount: data.flashbackPublicStats?.sentCount ?? 0
    }
  }

  async createOrder(enrollmentId: string): Promise<CreatedOrder> {
    const data = await graphqlRequest<CreateOrderMutation, CreateOrderMutationVariables>(
      CreateOrderMutationDocument,
      { input: { enrollmentId, provider: 'wechat_jsapi' } }
    )
    const result = data.createOrder.result
    if (!result) mutationError(data.createOrder.errors)
    return {
      order: {
        id: result.id,
        enrollmentId: result.enrollmentId,
        status: parseOrderStatus(result.status),
        amountCents: result.amountCents,
        expireAt: result.expireAt,
        transactionId: null,
        orderKind: parseOrderKind(result.orderKind)
      },
      credential: data.createOrder.metadata?.credential ?? null
    }
  }

  async getOrderStatus(orderId: string): Promise<OrderSummary> {
    const data = await graphqlRequest<OrderStatusQuery, OrderStatusQueryVariables>(
      OrderStatusQueryDocument,
      { id: orderId }
    )
    if (!data.orderStatus) throw new Error('订单不存在或不可访问')
    return {
      id: data.orderStatus.id,
      enrollmentId: '',
      status: parseOrderStatus(data.orderStatus.status),
      amountCents: data.orderStatus.amountCents,
      expireAt: data.orderStatus.expireAt,
      transactionId: data.orderStatus.transactionId,
      orderKind: parseOrderKind(data.orderStatus.orderKind)
    }
  }

  async getMyOrders(): Promise<OrderSummary[]> {
    const session = await this.getSession()
    if (!session.user) {
      if (session.authExpired) throw new SessionExpiredError()
      return []
    }
    const data = await graphqlRequest<MyOrdersQuery, MyOrdersQueryVariables>(
      MyOrdersQueryDocument,
      {}
    )
    const rank: Record<string, number> = {
      pending: 0, paid: 1, refunding: 2, refund_failed: 3,
      refunded: 4, cancelled: 5, expired: 6, forfeited: 7
    }
    return (data.myOrders?.results ?? [])
      .map((order) => ({
        id: order.id,
        enrollmentId: order.enrollmentId,
        status: parseOrderStatus(order.status),
        amountCents: order.amountCents,
        expireAt: order.expireAt,
        transactionId: null,
        orderKind: parseOrderKind(order.orderKind)
      }))
      // 非终态优先(一 enrollment 至多一非终态单,U1 不变量),终态单按同序稳定输出
      .sort((a, b) => (rank[a.status] ?? 9) - (rank[b.status] ?? 9))
  }
}


// 愿望映射（U1）：comments 遮罩姓与计数直传
function mapWish(wish: {
  id: string
  content: string
  city?: string | null
  wisherMasked?: string | null
  endorsementCount: number
  endorsedByMe: boolean
  mine: boolean
  comments?: Array<{ id: string; content: string; commenterMasked?: string | null; insertedAt: string }>
  insertedAt: string
}): FlashbackWish {
  return {
    id: wish.id,
    content: wish.content,
    city: wish.city ?? null,
    wisherMasked: wish.wisherMasked ?? null,
    endorsementCount: wish.endorsementCount ?? 0,
    endorsedByMe: wish.endorsedByMe ?? false,
    mine: wish.mine ?? false,
    comments: (wish.comments ?? []).map((c) => ({
      id: c.id,
      content: c.content,
      commenterMasked: c.commenterMasked ?? null,
      insertedAt: c.insertedAt
    })),
    insertedAt: wish.insertedAt
  }
}
