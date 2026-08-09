import type {
  AdmitMemberByTokenMutation,
  AdmitMemberByTokenMutationVariables,
  ApproveJoinRequestMutation,
  ApproveJoinRequestMutationVariables,
  CatalogQuery,
  CatalogQueryVariables,
  ConfirmEnrollmentMutation,
  ConfirmEnrollmentMutationVariables,
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
import { getAuthToken, graphqlRequest, isAuthenticationError, setAuthToken } from './client'
import {
  AdmitMemberByTokenMutationDocument,
  ApproveJoinRequestMutationDocument,
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
import { parseEnrollmentPolicy, parseEnrollmentStatus, schemaFieldsFromJson } from '@/domain/format'
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

type ContentRecord = NonNullable<NonNullable<CatalogQuery['listEvents']>['results']>[number]

function mapContent(record: ContentRecord, kind: ContentKind): CatalogItem {
  return {
    id: record.id,
    kind,
    workspaceId: record.workspaceId,
    workspaceName: '公开工作台',
    title: record.title,
    enrollmentPolicy: parseEnrollmentPolicy(record.enrollmentPolicy),
    capacity: record.capacity,
    confirmedCount: record.confirmedCount,
    registrationDeadline: record.registrationDeadline,
    schemaFields: schemaFieldsFromJson(record.researchRequirements)
  }
}

function mutationError(errors: Array<{ message?: string | null }>): never {
  throw new Error(errors.map(({ message }) => message).filter(Boolean).join('；') || '操作失败')
}

function readPayload(raw: string): Record<string, unknown> {
  try {
    return JSON.parse(raw) as Record<string, unknown>
  } catch {
    return {}
  }
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
    if (!getAuthToken()) {
      clearWorkspaceTab()
      // 保留 pending scene（clearPendingScene 默认 false），扫码→登录交接继续
      clearAccountState()
      return { user: null, workspaces: [], approvals: [] }
    }
    let data: SessionQuery
    try {
      data = await graphqlRequest<SessionQuery, SessionQueryVariables>(SessionQueryDocument, {})
    } catch (error) {
      if (isAuthenticationError(error)) return { user: null, workspaces: [], approvals: [] }
      throw error
    }
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
    if (!payload.loginCode || !payload.encryptedData || !payload.iv) {
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
        encryptedData: payload.encryptedData,
        iv: payload.iv
      },
      { captureAuthCookie: true }
    )
    if (!getAuthToken()) throw new Error('登录成功但未收到 Bearer token，请检查响应 cookie 契约')
    try {
      return await this.getSession()
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
    return (data.enrollments?.results ?? []).map((enrollment) => {
      const payload = readPayload(enrollment.submissionPayload)
      return {
        id: enrollment.id,
        workspaceId: enrollment.workspaceId,
        targetId: enrollment.eventId ?? enrollment.courseId ?? '',
        kind: enrollment.eventId ? 'event' : 'course',
        title: typeof payload.targetTitle === 'string' ? payload.targetTitle : '报名项目',
        status: parseEnrollmentStatus(enrollment.status),
        approvalDeadline: enrollment.approvalDeadline,
        rejectionReason: enrollment.rejectionReason
      }
    })
  }

  async createEnrollment(form: EnrollmentForm): Promise<EnrollmentSummary> {
    const session = await this.getSession()
    if (!session.user) throw new Error('请先登录')
    const input: CreateEnrollmentMutationVariables['input'] = {
      userId: session.user.id,
      submissionPayload: JSON.stringify({
        name: form.name,
        email: form.email,
        reason: form.reason,
        targetTitle: form.target.title
      }),
      inviteCode: form.inviteCode || undefined,
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
}
