import type {
  AdmitMemberByTokenMutation,
  AdmitMemberByTokenMutationVariables,
  ApproveJoinRequestMutation,
  ApproveJoinRequestMutationVariables,
  CancelEnrollmentMutation,
  CancelEnrollmentMutationVariables,
  CatalogQuery,
  CatalogQueryVariables,
  ConfirmEnrollmentMutation,
  ConfirmEnrollmentMutationVariables,
  CreateOrderMutation,
  CreateOrderMutationVariables,
  CourseDetailQuery,
  CourseDetailQueryVariables,
  CreateEnrollmentMutation,
  CreateEnrollmentMutationVariables,
  EventDetailQuery,
  EventDetailQueryVariables,
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
import {
  AdmitMemberByTokenMutationDocument,
  ApproveJoinRequestMutationDocument,
  CancelEnrollmentMutationDocument,
  CreateOrderMutationDocument,
  MyOrdersQueryDocument,
  OrderStatusQueryDocument,
  CatalogQueryDocument,
  ConfirmEnrollmentMutationDocument,
  CourseDetailQueryDocument,
  CreateEnrollmentMutationDocument,
  EventDetailQueryDocument,
  GenerateMiniProgramCodeMutationDocument,
  GrantConsentMutationDocument,
  MyEnrollmentsQueryDocument,
  RejectEnrollmentMutationDocument,
  RejectJoinRequestMutationDocument,
  SessionQueryDocument,
  SignOutMutationDocument,
  SignInWithPlatformMutationDocument
} from './operations'
import { parseEnrollmentBadge, parseEnrollmentPolicy, parseEnrollmentStatus } from '@/domain/format'
import { errorCopy } from '@/domain/error-copy'
import { parsePriceTiers } from '@/domain/payment'
import type { CreatedOrder, OrderStatus, OrderSummary } from '@/domain/models'
import type {
  AdmitResult,
  ApprovalSummary,
  CatalogItem,
  ContentKind,
  EnrollmentForm,
  EnrollmentSummary,
  MiniProgramApi,
  MiniProgramCode,
  NotificationItem,
  PlatformPhonePayload,
  SessionSnapshot,
  SubscriptionScenario,
  WorkspaceSummary
} from '@/domain/models'
import { currentPlatform } from '@/platform'
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
type ContentRecord = EventRecord | CourseRecord

function mapContent(record: ContentRecord, kind: ContentKind): CatalogItem {
  return {
    id: record.id,
    kind,
    title: record.title,
    enrollmentPolicy: parseEnrollmentPolicy(record.enrollmentPolicy),
    registrationDeadline: record.registrationDeadline,
    pricingEnabled: record.pricingEnabled === true,
    priceTiers: parsePriceTiers(record.availablePriceTiers),
    startsAt: record.startsAt,
    endsAt: record.endsAt,
    venue: 'venue' in record ? record.venue : null,
    enrollmentBadge: parseEnrollmentBadge(record.enrollmentBadge)
  }
}
function parseOrderStatus(value: string): OrderStatus {
  if (
    value === 'pending' || value === 'paid' || value === 'refunding' ||
    value === 'refunded' || value === 'refund_failed' || value === 'cancelled' ||
    value === 'expired'
  ) return value
  throw new Error(`服务端返回未知订单状态：${value}`)
}

function mutationError(errors: Array<{ message?: string | null; code?: string | null }>): never {
  // code 命中 → 中文文案；未命中 join message（通用兜底，拿不到 code 的场景用）
  const copy = errors.map(({ code }) => errorCopy(code)).find(Boolean)
  if (copy) throw new Error(copy)
  throw new Error(errors.map(({ message }) => message).filter(Boolean).join('；') || '操作失败')
}


export class RealMiniProgramApi implements MiniProgramApi {
  async getCatalog(): Promise<CatalogItem[]> {
    const data = await graphqlRequest<CatalogQuery, CatalogQueryVariables>(CatalogQueryDocument, { first: 50 })
    const events = (data.listEvents?.results ?? []).map((record) => mapContent(record, 'event'))
    const courses = (data.listCourses?.results ?? []).map((record) => mapContent(record, 'course'))
    return [...events, ...courses]
  }

  async getContent(kind: ContentKind, id: string): Promise<CatalogItem> {
    if (kind === 'event') {
      const data = await graphqlRequest<EventDetailQuery, EventDetailQueryVariables>(
        EventDetailQueryDocument,
        { id }
      )
      if (!data.getEvent) throw new Error('活动不存在或不可访问')
      return mapContent(data.getEvent, 'event')
    }
    const data = await graphqlRequest<CourseDetailQuery, CourseDetailQueryVariables>(
      CourseDetailQueryDocument,
      { id }
    )
    if (!data.getCourse) throw new Error('课程不存在或不可访问')
    return mapContent(data.getCourse, 'course')
  }

  async getSession(): Promise<SessionSnapshot> {
    try {
      return await this.fetchSession()
    } catch (error) {
      // 统一降级未登录快照:session 是装饰,任何失败都不该拖死公开目录
      // (模拟器残留坏 token → Forbidden → 发现页 Promise.all 全挂的真机事故)。
      // 认证错误 client.ts 已清 token;服务端返回非认证 errors(如 forbidden)
      // → token 可疑,清掉防反复炸;纯网络失败(未到达服务端)→ 保留 token。
      if (!isAuthenticationError(error)) {
        if (error instanceof GraphQLRequestError && error.errors.length > 0) {
          clearExpiredAuthentication()
        } else {
          clearWorkspaceTab()
          clearAccountState()
        }
      }
      return { user: null, workspaces: [], approvals: [] }
    }
  }

  // 内部 throw 语义版:signIn 的 hydration 回滚依赖失败可抛。
  private async fetchSession(): Promise<SessionSnapshot> {
    if (!getAuthToken()) {
      clearWorkspaceTab()
      // 保留 pending scene（clearPendingScene 默认 false），扫码→登录交接继续
      clearAccountState()
      return { user: null, workspaces: [], approvals: [] }
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
      approvals
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
    if (!session.user) return []
    const data = await graphqlRequest<MyEnrollmentsQuery, MyEnrollmentsQueryVariables>(
      MyEnrollmentsQueryDocument,
      { userId: session.user.id, first: 100 }
    )
    return (data.enrollments?.results ?? []).map((enrollment) => ({
      id: enrollment.id,
      workspaceId: enrollment.workspaceId,
      targetId: enrollment.eventId ?? enrollment.courseId ?? '',
      kind: enrollment.eventId ? 'event' : 'course',
      title: enrollment.targetTitle ?? '报名项目',
      status: parseEnrollmentStatus(enrollment.status),
      approvalDeadline: enrollment.approvalDeadline,
      rejectionReason: enrollment.rejectionReason
    }))
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
      rejectionReason: null
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
    const data = await graphqlRequest<AdmitMemberByTokenMutation, AdmitMemberByTokenMutationVariables>(
      AdmitMemberByTokenMutationDocument,
      { scene }
    )
    if (!data.admitMemberByToken) throw new Error('邀请码无效或已过期')
    return {
      workspaceId: data.admitMemberByToken.workspaceId,
      workspaceName: data.admitMemberByToken.workspaceName ?? '工作台'
    }
  }

  async getNotifications(): Promise<NotificationItem[]> {
    return readLocalNotifications()
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
        transactionId: null
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
      transactionId: data.orderStatus.transactionId
    }
  }

  async getMyOrders(): Promise<OrderSummary[]> {
    const session = await this.getSession()
    if (!session.user) return []
    const data = await graphqlRequest<MyOrdersQuery, MyOrdersQueryVariables>(
      MyOrdersQueryDocument,
      {}
    )
    const rank: Record<string, number> = {
      pending: 0, paid: 1, refunding: 2, refund_failed: 3,
      refunded: 4, cancelled: 5, expired: 6
    }
    return (data.myOrders?.results ?? [])
      .map((order) => ({
        id: order.id,
        enrollmentId: order.enrollmentId,
        status: parseOrderStatus(order.status),
        amountCents: order.amountCents,
        expireAt: order.expireAt,
        transactionId: null
      }))
      // 非终态优先(一 enrollment 至多一非终态单,U1 不变量),终态单按同序稳定输出
      .sort((a, b) => (rank[a.status] ?? 9) - (rank[b.status] ?? 9))
  }
}
