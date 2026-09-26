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
  CurrentRecruitmentCohortQuery,
  CurrentRecruitmentCohortQueryVariables,
  CreateVolunteerApplicationMutation,
  CreateVolunteerApplicationMutationVariables,
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
  FlashbackAdjustTodayFogMutation,
  FlashbackAdjustTodayFogMutationVariables,
  FlashbackCapsuleQuery,
  FlashbackCapsuleQueryVariables,
  FlashbackClaimMutation,
  FlashbackCreateWishMutation,
  FlashbackCreateWishMutationVariables,
  FlashbackEndorseWishMutation,
  FlashbackEndorseWishMutationVariables,
  FlashbackExpectWishMutation,
  FlashbackExpectWishMutationVariables,
  FlashbackCancelEndorseWishMutation,
  FlashbackCancelEndorseWishMutationVariables,
  FlashbackReportWishMutation,
  FlashbackReportWishMutationVariables,
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
  FlashbackArchivesQuery,
  FlashbackArchivesQueryVariables,
  FlashbackRetractMutation,
  FlashbackRetractMutationVariables,
  FlashbackDeletePreviewQuery,
  FlashbackDeletePreviewQueryVariables,
  FlashbackDeleteMutation,
  FlashbackDeleteMutationVariables,
  FlashbackRecoverMutation,
  FlashbackRecoverMutationVariables,
  FlashbackRecoverClaimForAccountMutation,
  FlashbackRecoverClaimForAccountMutationVariables,
  FlashbackRecoverVerifyForAccountMutation,
  FlashbackRecoverVerifyForAccountMutationVariables,
  FlashbackSetCardSharingMutation,
  FlashbackSetCardSharingMutationVariables,
  FlashbackSetQuoteLicenseMutation,
  FlashbackSetQuoteLicenseMutationVariables,
  FlashbackSharedCardQuery,
  FlashbackSharedCardQueryVariables,
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
  MyResumeProfileQuery,
  MyResumeProfileQueryVariables,
  MyVolunteerApplicationsQuery,
  MyVolunteerApplicationsQueryVariables,
  OrderStatusQuery,
  OrderStatusQueryVariables,
  RecruitmentWorkspaceQuery,
  RecruitmentWorkspaceQueryVariables,
  RejectEnrollmentMutation,
  RejectEnrollmentMutationVariables,
  RejectJoinRequestMutation,
  RejectJoinRequestMutationVariables,
  SessionQuery,
  SessionQueryVariables,
  SignOutMutation,
  SignOutMutationVariables,
  SignInWithPlatformMutation,
  SignInWithPlatformMutationVariables,
  SignInWithPlatformIdentityMutation,
  SignInWithPlatformIdentityMutationVariables,
  UploadResumeFileMutation,
  UploadResumeFileMutationVariables,
  UpsertResumeProfileMutation,
  UpsertResumeProfileMutationVariables
} from './generated/graphql'
import { BusinessError } from './business-error'
import { clearExpiredAuthentication, getAuthToken, graphqlRequest, GraphQLRequestError, isAuthenticationError, setAuthToken } from './client'
import { FlashbackNotBoundError, FlashbackTokenInvalidError, type FlashbackTokenInvalidCode } from '@/domain/models'
import { DELETE_COPY, RETRACT_COPY, type FlashbackDeletePreview } from '@/domain/flashback-retract'
import { RECOVER_COPY, RECOVER_LINK_ERRORS } from '@/domain/flashback-recover'
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
  CurrentRecruitmentCohortQueryDocument,
  CreateVolunteerApplicationMutationDocument,
  EnrollmentQueryDocument,
  EventDetailQueryDocument,
  EventModerationScopeQueryDocument,
  EventModeratorsQueryDocument,
  FlashbackAdjustFogMutationDocument,
  FlashbackAdjustTodayFogMutationDocument,
  FlashbackAddWishCommentMutationDocument,
  FlashbackCapsuleQueryDocument,
  FlashbackClaimMutationDocument,
  FlashbackCreateWishMutationDocument,
  FlashbackDeleteWishMutationDocument,
  FlashbackEndorseWishMutationDocument,
  FlashbackCancelEndorseWishMutationDocument,
  FlashbackExpectWishMutationDocument,
  FlashbackReportWishMutationDocument,
  FlashbackEnterMutationDocument,
  FlashbackMarkRevealedMutationDocument,
  FlashbackPublicStatsQueryDocument,
  FlashbackSendToWallMutationDocument,
  FlashbackArchivesQueryDocument,
  FlashbackRetractMutationDocument,
  FlashbackDeletePreviewQueryDocument,
  FlashbackDeleteMutationDocument,
  FlashbackRecoverMutationDocument,
  FlashbackRecoverClaimForAccountMutationDocument,
  FlashbackRecoverVerifyForAccountMutationDocument,
  FlashbackSetCardSharingMutationDocument,
  FlashbackSetQuoteLicenseMutationDocument,
  FlashbackSharedCardQueryDocument,
  FlashbackSubmitTodayMutationDocument,
  GenerateMiniProgramCodeMutationDocument,
  GrantConsentMutationDocument,
  MyEnrollmentsQueryDocument,
  MyResumeProfileQueryDocument,
  MyVolunteerApplicationsQueryDocument,
  RecruitmentWorkspaceQueryDocument,
  RejectEnrollmentMutationDocument,
  RejectJoinRequestMutationDocument,
  SessionQueryDocument,
  SignOutMutationDocument,
  SignInWithPlatformMutationDocument,
  SignInWithPlatformIdentityMutationDocument,
  UploadResumeFileMutationDocument,
  UpsertResumeProfileMutationDocument
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
  FlashbackCapsuleArchive,
  FlashbackCardSharing,
  FlashbackSharedCard,
  FlashbackRosterAnswer,
  FlashbackRosterSegment,
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
  RecruitmentCohort,
  ResumeFileInput,
  ResumeProfileForm,
  ResumeProfileSummary,
  SessionSnapshot,
  SubscriptionScenario,
  VolunteerApplicationForm,
  VolunteerApplicationSummary,
  WorkspaceSummary
} from '@/domain/models'
import { currentPlatform } from '@/platform'
import { setSilentLoginAllowed, silentLoginAllowed } from '@/state/silentLogin'
import { parseQualificationBadge } from '@/domain/initiative'
import { mapPublicWishEcho } from '@/domain/flashback'
import {
  RECRUITMENT_WORKSPACE_SLUG,
  parseCohortStatus,
  parseVolunteerPosition,
  parseVolunteerStatus
} from '@/domain/recruitment'
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
    publicModerators: string[] | null
    description: string | null
  }>

// 详情查询同文档带出的 myEnrollment 子集（#355 P1-3；两 kind 形状一致）
type MyEnrollmentRecord = NonNullable<EventDetailQuery['myEnrollment']>
// enrollments 两查询的行形状（#355 P1-4 列表 + 按 id 回查）。两文档选择集只在
// #727 押金快照金额上分叉：单条回查选 depositAmountCents（order-pay 创单前门用），
// 列表不选（该计算字段 load submission_payload，列表最多 100 行——不白拉 JSONB）
type EnrollmentRecord =
  | NonNullable<NonNullable<MyEnrollmentsQuery['enrollments']>['results']>[number]
  | NonNullable<NonNullable<EnrollmentQuery['enrollments']>['results']>[number]

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
    // 活动介绍：仅详情查询携带（列表记录 → null，不渲染介绍块）
    description: record.description ?? null,
    venue: 'venue' in record ? record.venue : null,
    initiativeId: record.initiativeId ?? null,
    publicModerators: record.publicModerators ?? null,
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
    // #727：押金快照金额（order-pay 创单前披露的金额源，与下单实付同源）。
    // 只有单条回查文档选了该字段；列表路径取不到 → null（诚实缺省，非 0）
    depositAmountCents:
      'depositAmountCents' in enrollment ? (enrollment.depositAmountCents ?? null) : null,
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
// BusinessError 单源在 ./business-error（#751 独立成文件：domain 纯函数与
// node --test 都要加载它）；code 与文案精确配对（抛出产出文案的那个 code）。
function mutationError(errors: Array<{ message?: string | null; code?: string | null }>): never {
  // code 命中 → 中文文案 + BusinessError（保留 code 供页面分派自愈，#751）；
  // 未命中 join message（通用兜底，拿不到 code 的场景用）
  for (const { code } of errors) {
    const copy = errorCopy(code)
    if (code && copy) throw new BusinessError(copy, code)
  }
  throw new Error(errors.map(({ message }) => message).filter(Boolean).join('；') || '操作失败')
}

/** 登录已失效：曾有 token 但会话降级（#355 P0-2）。getEnrollments/getMyOrders
 * 以此拒绝代替静默 []，页面据「从未报名」与「掉线」两种空态分叉渲染。 */
type CapsuleArchiveNode = NonNullable<FlashbackCapsuleQuery['flashbackCapsule']>['archives'][number]

/** 场次 + 名册映射：胶囊与相册（#933 flashbackArchives）共用——两处选择集逐字一致 */
function mapCapsuleArchive(archive: CapsuleArchiveNode): FlashbackCapsuleArchive {
  return {
    key: archive.key,
    name: archive.name ?? null,
    city: archive.city ?? null,
    occurredOn: archive.occurredOn ?? null,
    appliedCount: archive.appliedCount ?? null,
    attendedCount: archive.attendedCount ?? null,
    label: archive.label ?? null,
    isMine: archive.isMine,
    piles: (archive.piles ?? []).map((pile) => ({ city: pile.city, count: pile.count, returned: pile.returned })),
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
  }
}

export class SessionExpiredError extends Error {
  constructor(message = '登录已过期，请重新登录') {
    super(message)
    this.name = 'SessionExpiredError'
  }
}

// ── 志愿者招募（R20/R21）：三资源读面映射 ──────────────────────────────────
//
// 段位 / 职位 / 批次状态都走 domain/recruitment 的解析器（未知值 fail-closed 抛错），
// 不在这里静默兜底成某个合法值——后端加了新段位而前端未同步时，宁可报「服务端返回
// 未知申请段位」也不要把它显示成「已提交」。

type ResumeProfileRecord = NonNullable<MyResumeProfileQuery['myResumeProfile']>
type VolunteerApplicationRecord = MyVolunteerApplicationsQuery['myVolunteerApplications'][number]

function mapResumeProfile(record: ResumeProfileRecord): ResumeProfileSummary {
  return {
    id: record.id,
    fullName: record.fullName,
    contactEmail: record.contactEmail,
    weeklyHours: record.weeklyHours ?? null,
    skills: record.skills ?? [],
    // 文件元数据四键同源：未上传 → fileName null（其余三键随后端落 null/未设）
    fileName: record.fileName ?? null,
    fileContentType: record.fileContentType ?? null,
    fileSize: record.fileSize ?? null,
    uploadedAt: record.uploadedAt ?? null
  }
}

function mapVolunteerApplication(record: VolunteerApplicationRecord): VolunteerApplicationSummary {
  return {
    id: record.id,
    cohortId: record.cohortId,
    position: parseVolunteerPosition(record.position),
    city: record.city ?? null,
    heardAboutUs: record.heardAboutUs ?? null,
    hasInternalReferrer: record.hasInternalReferrer === true,
    message: record.message ?? null,
    status: parseVolunteerStatus(record.status),
    rejectionReason: record.rejectionReason ?? null,
    assignedEventId: record.assignedEventId ?? null,
    assignmentNote: record.assignmentNote ?? null,
    assignedAt: record.assignedAt ?? null
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
/** today fogSpans 解析:真实后端经 :json 标量(字符串),mock 直传对象——两者兼容 */
function parseTodayFog(
  raw: unknown
): Record<string, Array<{ start: number; len: number }>> | null {
  if (!raw) return null
  if (typeof raw === 'object') return raw as Record<string, Array<{ start: number; len: number }>>
  if (typeof raw !== 'string') return null
  try {
    const parsed = JSON.parse(raw) as Record<string, Array<{ start: number; len: number }>>
    return parsed && typeof parsed === 'object' ? parsed : null
  } catch {
    return null
  }
}

/** 公开卡段结构（#771）：与名册段（capsule.archives[].roster[].answers[].segments）
 *  同口径——fog=true 时 text 恒空（后端已置空；这里再兜一层：fog 段只要带了
 *  原文就丢弃，宁多雾一块也不放原文字符过去）。 */
function mapSharedCardSegments(
  segments: Array<{ text: string; fog: boolean; len: number } | null> | null | undefined
): FlashbackRosterSegment[] {
  return (segments ?? [])
    .filter((segment): segment is NonNullable<typeof segment> => segment != null)
    .map((segment) => ({
      text: segment.fog ? '' : segment.text,
      fog: segment.fog === true,
      len: segment.len
    }))
}

/** 公开卡题段列表（#771）：answers 与 today 同形（questionKey + 段列表），
 *  后者键为 today.now/want/need/say；两处共用本映射。 */
function mapSharedCardSections(
  sections:
    | Array<{ questionKey: string; segments: Array<{ text: string; fog: boolean; len: number } | null> | null } | null>
    | null
    | undefined
): FlashbackRosterAnswer[] {
  return (sections ?? [])
    .filter((section): section is NonNullable<typeof section> => section != null)
    .map((section) => ({
      questionKey: section.questionKey,
      segments: mapSharedCardSegments(section.segments)
    }))
}

/** 公开卡（#771）——**入参形状里根本没有原文**（后端投影只出段结构），
 *  所以不存在「回退到本人卡原文」的代码路径：这是防线的第一层。 */
function mapSharedCard(card: {
  displayName: string
  city?: string | null
  appliedAt?: string | null
  occurredOn?: string | null
  answers?: Array<{ questionKey: string; segments: Array<{ text: string; fog: boolean; len: number } | null> | null } | null> | null
  today?: Array<{ questionKey: string; segments: Array<{ text: string; fog: boolean; len: number } | null> | null } | null> | null
}): FlashbackSharedCard {
  return {
    displayName: card.displayName,
    city: card.city ?? null,
    appliedAt: card.appliedAt ?? null,
    occurredOn: card.occurredOn ?? null,
    answers: mapSharedCardSections(card.answers),
    today: mapSharedCardSections(card.today)
  }
}

export class RealMiniProgramApi implements MiniProgramApi {
  /**
   * 招募三资源的租户 id 缓存（同一部署内恒定）。小程序没有 URL slug，入口工作台
   * 只能按 slug 解析一次（getWorkspace，需登录），三次读写面共用——避免每页每个
   * 请求都打一次 slug 查询。失败不缓存（下次重试）。
   */
  private recruitmentWorkspaceId: string | null = null
  /** in-flight 去重：并发首载共享同一次解析；rejected 时清掉，保持「失败不缓存、下次重试」 */
  private recruitmentWorkspaceIdPromise: Promise<string> | null = null

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
    ).catch((error: unknown) => {
      // #930：登录限流（IP 天花板 / openid 桶）转中文——登录页原样显示 message，否则是英文
      // 「Too many requests」。rate_limited 是 infra 码，不进 error-copy 契约表（只收 domain 码）
      if (error instanceof GraphQLRequestError && error.errors.some(({ code }) => code === 'rate_limited')) {
        throw new Error('登录太频繁了，请稍后再试。')
      }
      throw error
    })
    const session = await this.hydrateSignedInSession()
    // 主动退出后关掉的回访静默登录，在任何一次登录成功后恢复（#930）
    setSilentLoginAllowed(true)
    return session
  }

  /**
   * #930 回访静默登录：已绑定本平台身份（openid）的账号只用平台登录凭证 code——不弹协议框、
   * 不走计费的手机号授权。本平台还没绑定（首次登录）或主动退出后 → null，页面退回手机号登录。
   */
  async signInSilently(loginCode: string): Promise<SessionSnapshot | null> {
    if (!silentLoginAllowed()) return null
    const previous = getAuthToken()
    try {
      await graphqlRequest<SignInWithPlatformIdentityMutation, SignInWithPlatformIdentityMutationVariables>(
        SignInWithPlatformIdentityMutationDocument,
        { platform: currentPlatform(), code: loginCode },
        { captureAuthCookie: true }
      )
    } catch (error) {
      // 失败不改变原登录态（mock 路径会在请求前先写入 token）
      setAuthToken(previous)
      if (error instanceof GraphQLRequestError && error.errors.some(({ code }) => code === 'platform_identity_not_found')) return null
      throw error
    }
    // 新会话：清旧 Workspace / 账号状态（token 已是新签发的），保留 pending scene
    clearWorkspaceTab()
    clearAccountState()
    return this.hydrateSignedInSession()
  }

  // 登录（手机号 / 静默）签发之后的会话水合：失败全量回滚，UI 显示失败与设备状态一致
  private async hydrateSignedInSession(): Promise<SessionSnapshot> {
    if (!getAuthToken()) throw new Error('登录成功但未收到 Bearer token，请检查响应 cookie 契约')
    try {
      return await this.fetchSession()
    } catch (error) {
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
      // 主动退出：下一次登录走手机号（方便换账号），不静默回到刚退出的账号（#930）
      setSilentLoginAllowed(false)
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
      // #727：押金快照金额同样未选，按目标押金配置本地推导（与 paymentMode 同款
      // 理由：同一时刻报名快照 = 目标配置；服务端计算字段的权威读取走
      // getEnrollment/getEnrollments。非押金场 null）
      depositAmountCents: form.target.depositEnabled ? form.target.depositAmountCents : null,
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

  // U4 愿望写操作:双入口 token,失效抛 FlashbackTokenInvalidError 由页面处理。
  // wish2 U8/U10 扩参:署名/期望地/公开授权;返回三态结果(页面按 status 分文案)
  async flashbackCreateWish(
    content: string,
    visibility: 'private' | 'public',
    token?: string | null,
    options?: {
      signatureChoice?: 'anonymous' | 'display_name'
      expectedCity?: string | null
      publicListingConsent?: boolean
      requestId?: string
    }
  ): Promise<{ id: string; status: string }> {
    const data = await graphqlRequest<FlashbackCreateWishMutation, FlashbackCreateWishMutationVariables>(
      FlashbackCreateWishMutationDocument,
      {
        content,
        visibility,
        token: token ?? null,
        signatureChoice: options?.signatureChoice ?? null,
        expectedCity: options?.expectedCity ?? null,
        publicListingConsent: options?.publicListingConsent ?? false,
        requestId: options?.requestId ?? null
      }
    ).catch((error: unknown) => {
      throwIfFlashbackTokenInvalid(error)
      // R20 年度额度/机审拒绝/城市名单外:code 命中 errorCopy 抛中文
      if (error instanceof GraphQLRequestError) mutationError(error.errors)
      throw error
    })
    const result = data.flashbackCreateWish
    if (!result?.id || !result.status) throw new Error('许愿结果异常，请稍后在「我的愿望」查看')
    return { id: result.id, status: result.status }
  }

  // wish2 U6/KTD3：附议登录版（旧 token 匿名腿下线——未登录由页面引登录页）
  async flashbackEndorseWish(
    wishId: string,
    options?: { contributionTypes?: string[]; message?: string | null; notify?: boolean }
  ): Promise<number> {
    const data = await graphqlRequest<FlashbackEndorseWishMutation, FlashbackEndorseWishMutationVariables>(
      FlashbackEndorseWishMutationDocument,
      {
        wishId,
        contributionTypes: options?.contributionTypes ?? [],
        message: options?.message ?? null,
        notify: options?.notify ?? false
      }
    ).catch((error: unknown) => {
      if (error instanceof GraphQLRequestError) mutationError(error.errors)
      throw error
    })
    return data.flashbackEndorseWish?.endorsementCount ?? 0
  }

  // wish2 U6/U9（KTD2）：期待/取消期待（服务端按登录态强制 u: 键；匿名传设备键）
  async flashbackExpectWish(wishId: string, expected: boolean, anonVoterKey?: string | null): Promise<number> {
    const data = await graphqlRequest<FlashbackExpectWishMutation, FlashbackExpectWishMutationVariables>(
      FlashbackExpectWishMutationDocument,
      { wishId, expected, anonVoterKey: anonVoterKey ?? null }
    ).catch((error: unknown) => {
      if (error instanceof GraphQLRequestError) mutationError(error.errors)
      throw error
    })
    return data.flashbackExpectWish?.expectationCount ?? 0
  }

  // wish2 U6/U9（KTD3）：取消附议（登录）
  async flashbackCancelEndorseWish(wishId: string): Promise<void> {
    await graphqlRequest<FlashbackCancelEndorseWishMutation, FlashbackCancelEndorseWishMutationVariables>(
      FlashbackCancelEndorseWishMutationDocument,
      { wishId }
    ).catch((error: unknown) => {
      if (error instanceof GraphQLRequestError) mutationError(error.errors)
      throw error
    })
  }

  // wish2 U6/U9（KTD5）：举报（预设理由 + ≤200 补充；匿名带设备键）
  async flashbackReportWish(
    wishId: string,
    reasonType: string,
    reasonFree?: string | null,
    anonVoterKey?: string | null
  ): Promise<void> {
    await graphqlRequest<FlashbackReportWishMutation, FlashbackReportWishMutationVariables>(
      FlashbackReportWishMutationDocument,
      {
        wishId,
        reasonType,
        reasonFree: reasonFree?.trim() || null,
        anonVoterKey: anonVoterKey ?? null
      }
    ).catch((error: unknown) => {
      if (error instanceof GraphQLRequestError) mutationError(error.errors)
      throw error
    })
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

  /** #933 相册：已登录即可读；未登录 → SessionExpiredError（页面据此跳登录） */
  async getFlashbackArchives(city?: string | null): Promise<{ archives: FlashbackCapsuleArchive[]; cities: string[] }> {
    const data = await graphqlRequest<FlashbackArchivesQuery, FlashbackArchivesQueryVariables>(
      FlashbackArchivesQueryDocument,
      { city: city ?? null }
    ).catch((error: unknown) => {
      if (
        error instanceof GraphQLRequestError &&
        (isAuthenticationError(error) ||
          error.errors.some((entry) => (entry.code ?? entry.extensions?.code) === 'flashback_auth_required'))
      ) {
        throw new SessionExpiredError()
      }
      throw error
    })
    const result = data.flashbackArchives
    if (!result) throw new Error('相册加载失败')
    return { archives: (result.archives ?? []).map(mapCapsuleArchive), cities: result.cities ?? [] }
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
        quoteSpans: (capsule.me.quoteSpans ?? [])
          .filter((s): s is NonNullable<typeof s> => s != null)
          .map((s) => ({ questionKey: s.questionKey, start: s.start, len: s.len })),
        quoteStats: capsule.me.quoteStats ? { likeCount: capsule.me.quoteStats.likeCount } : null,
        today: capsule.me.today
          ? {
              nowStatus: capsule.me.today.nowStatus ?? null,
              want: capsule.me.today.want ?? null,
              need: capsule.me.today.need ?? null,
              say: capsule.me.today.say ?? null,
              // 本人管理面雾区间(field → spans;:json 标量→解析容错)
              fogSpans: parseTodayFog(capsule.me.today.fogSpans),
              sentToWallAt: capsule.me.today.sentToWallAt ?? null
            }
          : null,
        answers: (capsule.me.answers ?? []).map((answer) => ({
          id: answer.id,
          questionKey: answer.questionKey,
          rawText: answer.rawText,
          fogSpans: (answer.fogSpans ?? []).map((span) => ({ start: span.start, len: span.len })),
          text: answer.text
        })),
        // #771：公开开关与本人预览。**没有 rawText 兜底**——预览段与公开读面
        // 同源（后端同一投影），页面不得拿 me.answers 的原文字符去补段。
        cardSharing: capsule.me.cardSharing
          ? {
              enabled: capsule.me.cardSharing.enabled === true,
              shareId: capsule.me.cardSharing.shareId ?? null,
              preview: capsule.me.cardSharing.preview
                ? mapSharedCard(capsule.me.cardSharing.preview)
                : { displayName: '', city: null, appliedAt: null, occurredOn: null, answers: [], today: [] }
            }
          : undefined
      },
      archives: (capsule.archives ?? []).map(mapCapsuleArchive),
      futureEvents: (capsule.futureEvents ?? []).map((frame) => ({
        initiativeSlug: frame.initiativeSlug,
        initiativeName: frame.initiativeName,
        initiativeStartsAt: frame.initiativeStartsAt ?? null,
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
      myWishQuotaRemaining: capsule.myWishQuotaRemaining ?? null,
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
    chosenQuoteSpans?: { questionKey: string; start: number; len: number }[] | null
  ): Promise<void> {
    const data = await graphqlRequest<FlashbackSetQuoteLicenseMutation, FlashbackSetQuoteLicenseMutationVariables>(
      FlashbackSetQuoteLicenseMutationDocument,
      { level, chosenQuoteSpans: chosenQuoteSpans ?? null }
    )
    if (!data.flashbackSetQuoteLicense) throw new Error('授权设置失败，请重试')
  }

  async flashbackAdjustFog(answerId: string, spans: FlashbackFogSpan[], token?: string | null): Promise<void> {
    await graphqlRequest<FlashbackAdjustFogMutation, FlashbackAdjustFogMutationVariables>(
      FlashbackAdjustFogMutationDocument,
      {
        token: token ?? undefined,
        answerId,
        spans: spans.map((span) => ({ start: span.start, len: span.len, reason: span.reason ?? 'owner' }))
      }
    )
  }
  // 今天的你句级雾面(field ∈ now/want/need/say;token 可选=会话面)
  async flashbackAdjustTodayFog(field: string, spans: FlashbackFogSpan[], token?: string | null): Promise<void> {
    await graphqlRequest<FlashbackAdjustTodayFogMutation, FlashbackAdjustTodayFogMutationVariables>(
      FlashbackAdjustTodayFogMutationDocument,
      {
        token: token ?? undefined,
        field,
        spans: spans.map((span) => ({ start: span.start, len: span.len }))
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
                  need: null,
                  say: result.progress.today.say ?? null,
                  fogSpans: null,
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

  // #931：token 省略（null）时后端按登录账号绑定档案——绝不传空串（空串会被当作 token 校验而失败）
  async flashbackSendToWall(token: string | null): Promise<void> {
    const data = await graphqlRequest<FlashbackSendToWallMutation, FlashbackSendToWallMutationVariables>(
      FlashbackSendToWallMutationDocument,
      { token: token || null }
    ).catch((error: unknown) => {
      throwIfFlashbackTokenInvalid(error)
      throw error
    })
    if (!data.flashbackSendToWall?.sentToWallAt) throw new Error('寄出失败，请重试')
  }

  async flashbackRetract(token: string | null): Promise<void> {
    const data = await graphqlRequest<FlashbackRetractMutation, FlashbackRetractMutationVariables>(
      FlashbackRetractMutationDocument,
      { token: token || null }
    ).catch((error: unknown) => {
      throwIfFlashbackTokenInvalid(error)
      throw error
    })
    if (!data.flashbackRetract?.retracted) throw new Error(RETRACT_COPY.error)
  }

  async flashbackDeletePreview(token: string | null): Promise<FlashbackDeletePreview> {
    const data = await graphqlRequest<FlashbackDeletePreviewQuery, FlashbackDeletePreviewQueryVariables>(
      FlashbackDeletePreviewQueryDocument,
      { token: token || null }
    ).catch((error: unknown) => {
      throwIfFlashbackTokenInvalid(error)
      throw error
    })
    const row = data.flashbackDeletePreview
    if (!row) throw new Error(DELETE_COPY.error)
    return { fullName: row.fullName, sentToWallAt: row.sentToWallAt ?? null, endorsementCount: row.endorsementCount }
  }

  async flashbackDelete(token: string | null, confirm: string): Promise<void> {
    const data = await graphqlRequest<FlashbackDeleteMutation, FlashbackDeleteMutationVariables>(
      FlashbackDeleteMutationDocument,
      { token: token || null, confirm }
    ).catch((error: unknown) => {
      throwIfFlashbackTokenInvalid(error)
      throw error
    })
    if (!data.flashbackDelete?.deleted) throw new Error(DELETE_COPY.error)
  }

  async flashbackRecover(identifier: string): Promise<void> {
    const data = await graphqlRequest<FlashbackRecoverMutation, FlashbackRecoverMutationVariables>(
      FlashbackRecoverMutationDocument,
      { identifier }
    ).catch((error: unknown) => {
      // 限流等 code 命中 errorCopy 抛中文
      if (error instanceof GraphQLRequestError) mutationError(error.errors)
      throw error
    })
    if (!data.flashbackRecover?.dispatched) throw new Error(RECOVER_COPY.errorRetry)
  }

  async flashbackRecoverVerifyForAccount(identifier: string, code: string): Promise<{ count: number }> {
    const data = await graphqlRequest<
      FlashbackRecoverVerifyForAccountMutation,
      FlashbackRecoverVerifyForAccountMutationVariables
    >(FlashbackRecoverVerifyForAccountMutationDocument, { identifier, code }).catch((error: unknown) => {
      // 错码 / 号码或卡属于另一个账号 / 限流：code 命中 errorCopy 抛中文
      if (error instanceof GraphQLRequestError) mutationError(error.errors)
      throw error
    })
    const result = data.flashbackRecoverVerifyForAccount
    if (!result?.bound) throw new Error(RECOVER_COPY.errorRetry)
    return { count: result.cards.length }
  }

  async flashbackRecoverClaimForAccount(link: string): Promise<{ count: number }> {
    const data = await graphqlRequest<
      FlashbackRecoverClaimForAccountMutation,
      FlashbackRecoverClaimForAccountMutationVariables
    >(FlashbackRecoverClaimForAccountMutationDocument, { link }).catch((error: unknown) => {
      if (error instanceof GraphQLRequestError) {
        // 链接失效三态走找回口径；卡属于另一个账号 / 限流命中 errorCopy
        const code = error.errors.map((entry) => entry.code ?? entry.extensions?.code).find((c) => c && RECOVER_LINK_ERRORS[c])
        if (code) throw new BusinessError(RECOVER_LINK_ERRORS[code], code)
        mutationError(error.errors)
      }
      throw error
    })
    const result = data.flashbackRecoverClaimForAccount
    if (!result?.bound) throw new Error(RECOVER_COPY.errorRetry)
    return { count: result.cards.length }
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

  // ── 卡片站外公开（#771/R14）────────────────────────────────────────────

  async flashbackSetCardSharing(enabled: boolean, token?: string | null): Promise<FlashbackCardSharing> {
    const data = await graphqlRequest<FlashbackSetCardSharingMutation, FlashbackSetCardSharingMutationVariables>(
      FlashbackSetCardSharingMutationDocument,
      { enabled, token: token ?? null }
    ).catch((error: unknown) => {
      // 首程链接失效（token 面）→ 类型化抛出（与其余 token 面写操作同规则）
      throwIfFlashbackTokenInvalid(error)
      throw error
    })
    const result = data.flashbackSetCardSharing
    if (!result) throw new Error('公开设置失败，请重试')
    return {
      enabled: result.enabled === true,
      shareId: result.shareId ?? null,
      preview: result.preview
        ? mapSharedCard(result.preview)
        : { displayName: '', city: null, appliedAt: null, occurredOn: null, answers: [], today: [] }
    }
  }

  async getFlashbackSharedCard(shareId: string): Promise<FlashbackSharedCard | null> {
    const data = await graphqlRequest<FlashbackSharedCardQuery, FlashbackSharedCardQueryVariables>(
      FlashbackSharedCardQueryDocument,
      { shareId }
    )
    // null 是**合法**空态（未开启/不存在/已删档），不是错误——页面据此渲染
    // 「这张卡已经收回」而不是错误面。网络/服务端故障仍由 graphqlRequest 抛出。
    if (!data.flashbackSharedCard) return null
    return mapSharedCard(data.flashbackSharedCard)
  }

  async createOrder(enrollmentId: string, depositConsent?: boolean): Promise<CreatedOrder> {
    const data = await graphqlRequest<CreateOrderMutation, CreateOrderMutationVariables>(
      CreateOrderMutationDocument,
      {
        input: {
          enrollmentId,
          provider: 'wechat_jsapi',
          // 押金同意（#727）：预检判定押金且用户已勾选才携带——缺失/false 时后端
          // 对押金单 fail-closed（order_deposit_consent_required）；非押金单忽略
          ...(depositConsent === true ? { depositConsent: true } : {})
        }
      }
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

  // ── 志愿者招募（R20/R21；tenant 见 domain/recruitment.ts 的 moduledoc）──────

  /** 入口工作台 id（slug 解析一次 + 进程内缓存；失败不缓存，下次重试）。
   * 并发首载（页面 load() 的三个读取并发进来）共享 in-flight promise，
   * 不各自重复发 session + getWorkspace。 */
  private async resolveRecruitmentWorkspaceId(): Promise<string> {
    if (this.recruitmentWorkspaceId) return this.recruitmentWorkspaceId
    if (this.recruitmentWorkspaceIdPromise) return this.recruitmentWorkspaceIdPromise
    const promise = (async () => {
      // 未登录时不发请求：这是「先登录再读批次」的门（getWorkspace 策略要求
      // actor 在场），也给页面一个可读的错误而不是 forbidden 原文。
      const session = await this.getSession()
      if (!session.user) throw new Error('请先登录后再申请')
      const data = await graphqlRequest<RecruitmentWorkspaceQuery, RecruitmentWorkspaceQueryVariables>(
        RecruitmentWorkspaceQueryDocument,
        { slug: RECRUITMENT_WORKSPACE_SLUG }
      )
      const id = data.getWorkspace?.id
      if (!id) throw new Error('招募入口工作台未配置，请稍后重试')
      this.recruitmentWorkspaceId = id
      return id
    })()
    this.recruitmentWorkspaceIdPromise = promise
    try {
      return await promise
    } catch (error) {
      // 失败不缓存 in-flight（下次调用重试）；缓存语义与 slug 缓存一致
      if (this.recruitmentWorkspaceIdPromise === promise) this.recruitmentWorkspaceIdPromise = null
      throw error
    }
  }

  async getCurrentRecruitmentCohort(): Promise<RecruitmentCohort | null> {
    const workspaceId = await this.resolveRecruitmentWorkspaceId()
    const data = await graphqlRequest<CurrentRecruitmentCohortQuery, CurrentRecruitmentCohortQueryVariables>(
      CurrentRecruitmentCohortQueryDocument,
      { workspaceId }
    )
    const record = data.currentRecruitmentCohort
    // null = 无 open 批次（空态）；读取失败在上面抛错（失败态）——两者不同桶
    if (!record) return null
    return {
      id: record.id,
      name: record.name,
      applyDeadlineAt: record.applyDeadlineAt,
      startsAt: record.startsAt ?? null,
      endsAt: record.endsAt ?? null,
      status: parseCohortStatus(record.status)
    }
  }

  async getMyResumeProfile(): Promise<ResumeProfileSummary | null> {
    const workspaceId = await this.resolveRecruitmentWorkspaceId()
    const data = await graphqlRequest<MyResumeProfileQuery, MyResumeProfileQueryVariables>(
      MyResumeProfileQueryDocument,
      { workspaceId }
    )
    return data.myResumeProfile ? mapResumeProfile(data.myResumeProfile) : null
  }

  async saveResumeProfile(form: ResumeProfileForm): Promise<ResumeProfileSummary> {
    const workspaceId = await this.resolveRecruitmentWorkspaceId()
    const data = await graphqlRequest<UpsertResumeProfileMutation, UpsertResumeProfileMutationVariables>(
      UpsertResumeProfileMutationDocument,
      {
        workspaceId,
        input: {
          fullName: form.fullName.trim(),
          contactEmail: form.contactEmail.trim(),
          // hours 选填：非法值在 domain 已归 undefined；此处只做「有没有」的分派
          ...(form.weeklyHours != null ? { weeklyHours: form.weeklyHours } : {}),
          // skills 缺省不改动（后端语义）：空数组视为「清空」由 domain 决定，
          // 本层不下判断——有就传，没有就不传。
          ...(form.skills != null ? { skills: form.skills } : {})
        }
      }
    )
    const result = data.upsertResumeProfile?.result
    if (!result) mutationError(data.upsertResumeProfile?.errors ?? [])
    return mapResumeProfile(result)
  }

  /**
   * 简历文件上传（U2 单入口）。base64 载荷可达 ~6.7MB（5MB 原始文件），远超默认
   * 15s 请求超时 → 单独放宽到 60s；其余 GraphQL 调用保持默认。
   *
   * 上传前必须先 upsertResumeProfile 建档：后端不代建半成品档案，会回
   * resume_profile_not_found（文案见 domain/error-copy.ts）。调用顺序由页面保证
   * （components/resume-upload 的 ensureProfile 回调）。
   */
  async uploadResumeFile(input: ResumeFileInput): Promise<ResumeProfileSummary> {
    const workspaceId = await this.resolveRecruitmentWorkspaceId()
    const data = await graphqlRequest<UploadResumeFileMutation, UploadResumeFileMutationVariables>(
      UploadResumeFileMutationDocument,
      { workspaceId, input: { fileName: input.fileName, contentType: input.contentType, contentBase64: input.contentBase64 } },
      { timeoutMs: 60_000 }
    )
    const result = data.uploadResumeFile?.result
    if (!result) mutationError(data.uploadResumeFile?.errors ?? [])
    return mapResumeProfile(result)
  }

  async getMyVolunteerApplications(): Promise<VolunteerApplicationSummary[]> {
    // 掉线 ≠ 没有申请（同 getEnrollments 口径）：拒绝而非静默 []，页面渲染重登空态
    const session = await this.getSession()
    if (!session.user) {
      if (session.authExpired) throw new SessionExpiredError()
      return []
    }
    const workspaceId = await this.resolveRecruitmentWorkspaceId()
    const data = await graphqlRequest<MyVolunteerApplicationsQuery, MyVolunteerApplicationsQueryVariables>(
      MyVolunteerApplicationsQueryDocument,
      { workspaceId }
    )
    return (data.myVolunteerApplications ?? []).map(mapVolunteerApplication)
  }

  async createVolunteerApplication(form: VolunteerApplicationForm): Promise<VolunteerApplicationSummary> {
    const workspaceId = await this.resolveRecruitmentWorkspaceId()
    const data = await graphqlRequest<CreateVolunteerApplicationMutation, CreateVolunteerApplicationMutationVariables>(
      CreateVolunteerApplicationMutationDocument,
      {
        workspaceId,
        input: {
          cohortId: form.cohortId,
          position: form.position,
          ...(form.city ? { city: form.city } : {}),
          ...(form.heardAboutUs ? { heardAboutUs: form.heardAboutUs } : {}),
          hasInternalReferrer: form.hasInternalReferrer === true,
          ...(form.message ? { message: form.message } : {})
        }
      }
    )
    const result = data.createVolunteerApplication?.result
    if (!result) mutationError(data.createVolunteerApplication?.errors ?? [])
    return mapVolunteerApplication(result)
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
  // #837 GraphQL 生成类型 status 为宽 string;domain 用 mapPublicWishEcho fail-closed 收敛
  latestEcho?: {
    id: string
    content: string
    status: string
    publishedAt: string
    correctedAt?: string | null
  } | null
  echoCount?: number
  echoes?: Array<{
    id: string
    content: string
    status: string
    publishedAt: string
    correctedAt?: string | null
  }>
  insertedAt: string
}): FlashbackWish {
  // #837 status 非法的回响整条丢弃(等同服务端本就不该返回),latestEcho / echoes 同规则
  const mappedEchoes = (wish.echoes ?? [])
    .map(mapPublicWishEcho)
    .filter((e): e is NonNullable<typeof e> => e !== null)
  const mappedLatest = wish.latestEcho ? mapPublicWishEcho(wish.latestEcho) : null
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
    latestEcho: mappedLatest,
    echoCount: wish.echoCount ?? 0,
    echoes: mappedEchoes,
    insertedAt: wish.insertedAt
  }
}
