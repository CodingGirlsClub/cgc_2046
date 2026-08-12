export type Maybe<T> = T | null;
export type InputMaybe<T> = Maybe<T>;
/** All built-in and custom scalars, mapped to their actual values */
export type Scalars = {
  ID: { input: string; output: string; }
  String: { input: string; output: string; }
  Boolean: { input: boolean; output: boolean; }
  Int: { input: number; output: number; }
  Float: { input: number; output: number; }
  /**
   * The `DateTime` scalar type represents a date and time in the UTC
   * timezone. The DateTime appears in a JSON response as an ISO8601 formatted
   * string, including UTC timezone ("Z"). The parsed date and time string will
   * be converted to UTC if there is an offset.
   */
  DateTime: { input: string; output: string; }
  /**
   * The `Json` scalar type represents arbitrary json string data, represented as UTF-8
   * character sequences. The Json type is most often used to represent a free-form
   * human-readable json string.
   */
  Json: { input: string; output: string; }
  /**
   * The `Json` scalar type represents arbitrary json string data, represented as UTF-8
   * character sequences. The Json type is most often used to represent a free-form
   * human-readable json string.
   */
  JsonString: { input: string; output: string; }
};

export type AbilityGrant = {
  allowed: Scalars['Boolean']['output'];
  /** 能力名：view_workspace / access_invite_only / list_members / manage_members / assign_roles / create_workspace */
  name: Scalars['String']['output'];
};

export type AcceptInvitationInput = {
  /** acceptInvitation 输入：token 为明文邀请令牌（accept 须复验） */
  token: Scalars['String']['input'];
};

export type AcceptInvitationResult = {
  errors: Array<MutationError>;
  /** acceptInvitation 返回：result 为已接受邀请记录；errors 为业务错误 */
  result?: Maybe<Invitation>;
};

export type AdminActionLog = {
  action: Scalars['String']['output'];
  actorId?: Maybe<Scalars['ID']['output']>;
  id: Scalars['ID']['output'];
  insertedAt: Scalars['DateTime']['output'];
  result: Scalars['String']['output'];
  targetId: Scalars['ID']['output'];
  targetType: Scalars['String']['output'];
};

export type AdminPendingOperation = {
  id: Scalars['ID']['output'];
  insertedAt: Scalars['DateTime']['output'];
  status: Scalars['String']['output'];
  summary: Scalars['String']['output'];
  tool: Scalars['String']['output'];
  userId: Scalars['ID']['output'];
};

export type AdminSignalLog = {
  id: Scalars['ID']['output'];
  insertedAt: Scalars['DateTime']['output'];
  signalType: Scalars['String']['output'];
  workspaceId: Scalars['ID']['output'];
};

export type AdminToolCallLog = {
  errorMessage?: Maybe<Scalars['String']['output']>;
  id: Scalars['ID']['output'];
  insertedAt: Scalars['DateTime']['output'];
  latencyMs?: Maybe<Scalars['Int']['output']>;
  resultStatus: Scalars['String']['output'];
  tool: Scalars['String']['output'];
  userId: Scalars['ID']['output'];
};

export type AdminUser = {
  displayName?: Maybe<Scalars['String']['output']>;
  email?: Maybe<Scalars['String']['output']>;
  id: Scalars['ID']['output'];
  insertedAt: Scalars['DateTime']['output'];
  isPlatformAdmin: Scalars['Boolean']['output'];
  workspaceMembershipCount?: Maybe<Scalars['Int']['output']>;
};

export type AdminUserPayload = {
  email?: Maybe<Scalars['String']['output']>;
  errors?: Maybe<Array<Maybe<MutationError>>>;
  id?: Maybe<Scalars['ID']['output']>;
  isPlatformAdmin?: Maybe<Scalars['Boolean']['output']>;
};

export type AdminWorkspace = {
  id: Scalars['ID']['output'];
  insertedAt: Scalars['DateTime']['output'];
  joinPolicy: Scalars['String']['output'];
  memberCount: Scalars['Int']['output'];
  name: Scalars['String']['output'];
  slug: Scalars['String']['output'];
  sponsorshipEnabled: Scalars['Boolean']['output'];
};

export type AdminWorkspaceApplication = {
  applicantId: Scalars['ID']['output'];
  approvedAt?: Maybe<Scalars['DateTime']['output']>;
  approvedBy?: Maybe<Scalars['ID']['output']>;
  id: Scalars['ID']['output'];
  insertedAt: Scalars['DateTime']['output'];
  name: Scalars['String']['output'];
  purpose: Scalars['String']['output'];
  rejectedAt?: Maybe<Scalars['DateTime']['output']>;
  rejectedBy?: Maybe<Scalars['ID']['output']>;
  rejectionReason?: Maybe<Scalars['String']['output']>;
  slug: Scalars['String']['output'];
  status: Scalars['String']['output'];
};

export type ApproveJoinRequestInput = {
  roleNames?: InputMaybe<Array<Scalars['String']['input']>>;
};

/** The result of the :approve_join_request mutation */
export type ApproveJoinRequestResult = {
  /** Any errors generated, if the mutation failed */
  errors: Array<MutationError>;
  /** The successful result of the mutation */
  result?: Maybe<JoinRequest>;
};

/** The result of the :approve_workspace_application mutation */
export type ApproveWorkspaceApplicationResult = {
  /** Any errors generated, if the mutation failed */
  errors: Array<MutationError>;
  /** The successful result of the mutation */
  result?: Maybe<WorkspaceApplication>;
};

export type AssignRolesInput = {
  roleNames: Array<Scalars['String']['input']>;
};

/** The result of the :assign_roles mutation */
export type AssignRolesResult = {
  /** Any errors generated, if the mutation failed */
  errors: Array<MutationError>;
  /** The successful result of the mutation */
  result?: Maybe<WorkspaceMembership>;
};

/** The result of the :cancel_enrollment mutation */
export type CancelEnrollmentResult = {
  /** Any errors generated, if the mutation failed */
  errors: Array<MutationError>;
  /** The successful result of the mutation */
  result?: Maybe<Enrollment>;
};

/** The result of the :confirm_enrollment mutation */
export type ConfirmEnrollmentResult = {
  /** Any errors generated, if the mutation failed */
  errors: Array<MutationError>;
  /** The successful result of the mutation */
  result?: Maybe<Enrollment>;
};

export type Course = {
  /** 报名名额上限；nil 表示不限 */
  capacity?: Maybe<Scalars['Int']['output']>;
  /** 已确认名额数（仅由 Enrollment 原子维护） */
  confirmedCount: Scalars['Int']['output'];
  /** 报名策略：open / request / invite_only */
  enrollmentPolicy: Scalars['String']['output'];
  id: Scalars['ID']['output'];
  /** 报名截止时间；nil 表示不设截止 */
  registrationDeadline?: Maybe<Scalars['DateTime']['output']>;
  /** 是否启用教研 workflow */
  researchEnabled: Scalars['Boolean']['output'];
  /** 教研材料需求（audience/duration/sections 等），作为 run input 注入 */
  researchRequirements?: Maybe<Scalars['JsonString']['output']>;
  /** 课程状态：draft 草稿 / open 已发布 / closed 已结束 / cancelled 已取消 */
  status: Scalars['String']['output'];
  /** 课程标题 */
  title: Scalars['String']['output'];
  /** 教研 workflow 产物引用（领域模型 §5.2 ER） */
  workflowRunId?: Maybe<Scalars['ID']['output']>;
  /** 所属工作台（租户）ID */
  workspaceId: Scalars['ID']['output'];
};

export type CourseFilterCapacity = {
  eq?: InputMaybe<Scalars['Int']['input']>;
  greaterThan?: InputMaybe<Scalars['Int']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['Int']['input']>;
  in?: InputMaybe<Array<InputMaybe<Scalars['Int']['input']>>>;
  isDistinctFrom?: InputMaybe<Scalars['Int']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['Int']['input']>;
  lessThan?: InputMaybe<Scalars['Int']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['Int']['input']>;
  notEq?: InputMaybe<Scalars['Int']['input']>;
};

export type CourseFilterConfirmedCount = {
  eq?: InputMaybe<Scalars['Int']['input']>;
  greaterThan?: InputMaybe<Scalars['Int']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['Int']['input']>;
  in?: InputMaybe<Array<Scalars['Int']['input']>>;
  isDistinctFrom?: InputMaybe<Scalars['Int']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['Int']['input']>;
  lessThan?: InputMaybe<Scalars['Int']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['Int']['input']>;
  notEq?: InputMaybe<Scalars['Int']['input']>;
};

export type CourseFilterEnrollmentPolicy = {
  eq?: InputMaybe<Scalars['String']['input']>;
  greaterThan?: InputMaybe<Scalars['String']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['String']['input']>;
  in?: InputMaybe<Array<Scalars['String']['input']>>;
  isDistinctFrom?: InputMaybe<Scalars['String']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['String']['input']>;
  lessThan?: InputMaybe<Scalars['String']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['String']['input']>;
  notEq?: InputMaybe<Scalars['String']['input']>;
};

export type CourseFilterId = {
  eq?: InputMaybe<Scalars['ID']['input']>;
  greaterThan?: InputMaybe<Scalars['ID']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  in?: InputMaybe<Array<Scalars['ID']['input']>>;
  isDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  lessThan?: InputMaybe<Scalars['ID']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  notEq?: InputMaybe<Scalars['ID']['input']>;
};

export type CourseFilterInput = {
  and?: InputMaybe<Array<CourseFilterInput>>;
  /** 报名名额上限；nil 表示不限 */
  capacity?: InputMaybe<CourseFilterCapacity>;
  /** 已确认名额数（仅由 Enrollment 原子维护） */
  confirmedCount?: InputMaybe<CourseFilterConfirmedCount>;
  /** 报名策略：open / request / invite_only */
  enrollmentPolicy?: InputMaybe<CourseFilterEnrollmentPolicy>;
  id?: InputMaybe<CourseFilterId>;
  not?: InputMaybe<Array<CourseFilterInput>>;
  or?: InputMaybe<Array<CourseFilterInput>>;
  /** 报名截止时间；nil 表示不设截止 */
  registrationDeadline?: InputMaybe<CourseFilterRegistrationDeadline>;
  /** 是否启用教研 workflow */
  researchEnabled?: InputMaybe<CourseFilterResearchEnabled>;
  /** 教研材料需求（audience/duration/sections 等），作为 run input 注入 */
  researchRequirements?: InputMaybe<CourseFilterResearchRequirements>;
  /** 课程状态：draft 草稿 / open 已发布 / closed 已结束 / cancelled 已取消 */
  status?: InputMaybe<CourseFilterStatus>;
  /** 课程标题 */
  title?: InputMaybe<CourseFilterTitle>;
  /** 教研 workflow 产物引用（领域模型 §5.2 ER） */
  workflowRunId?: InputMaybe<CourseFilterWorkflowRunId>;
  /** 所属工作台（租户）ID */
  workspaceId?: InputMaybe<CourseFilterWorkspaceId>;
};

export type CourseFilterRegistrationDeadline = {
  eq?: InputMaybe<Scalars['DateTime']['input']>;
  greaterThan?: InputMaybe<Scalars['DateTime']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['DateTime']['input']>;
  in?: InputMaybe<Array<InputMaybe<Scalars['DateTime']['input']>>>;
  isDistinctFrom?: InputMaybe<Scalars['DateTime']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['DateTime']['input']>;
  lessThan?: InputMaybe<Scalars['DateTime']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['DateTime']['input']>;
  notEq?: InputMaybe<Scalars['DateTime']['input']>;
};

export type CourseFilterResearchEnabled = {
  eq?: InputMaybe<Scalars['Boolean']['input']>;
  greaterThan?: InputMaybe<Scalars['Boolean']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['Boolean']['input']>;
  in?: InputMaybe<Array<Scalars['Boolean']['input']>>;
  isDistinctFrom?: InputMaybe<Scalars['Boolean']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['Boolean']['input']>;
  lessThan?: InputMaybe<Scalars['Boolean']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['Boolean']['input']>;
  notEq?: InputMaybe<Scalars['Boolean']['input']>;
};

export type CourseFilterResearchRequirements = {
  eq?: InputMaybe<Scalars['JsonString']['input']>;
  greaterThan?: InputMaybe<Scalars['JsonString']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['JsonString']['input']>;
  in?: InputMaybe<Array<InputMaybe<Scalars['JsonString']['input']>>>;
  isDistinctFrom?: InputMaybe<Scalars['JsonString']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['JsonString']['input']>;
  lessThan?: InputMaybe<Scalars['JsonString']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['JsonString']['input']>;
  notEq?: InputMaybe<Scalars['JsonString']['input']>;
};

export type CourseFilterStatus = {
  eq?: InputMaybe<Scalars['String']['input']>;
  greaterThan?: InputMaybe<Scalars['String']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['String']['input']>;
  in?: InputMaybe<Array<Scalars['String']['input']>>;
  isDistinctFrom?: InputMaybe<Scalars['String']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['String']['input']>;
  lessThan?: InputMaybe<Scalars['String']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['String']['input']>;
  notEq?: InputMaybe<Scalars['String']['input']>;
};

export type CourseFilterTitle = {
  contains?: InputMaybe<Scalars['String']['input']>;
  eq?: InputMaybe<Scalars['String']['input']>;
  greaterThan?: InputMaybe<Scalars['String']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['String']['input']>;
  ilike?: InputMaybe<Scalars['String']['input']>;
  in?: InputMaybe<Array<Scalars['String']['input']>>;
  isDistinctFrom?: InputMaybe<Scalars['String']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['String']['input']>;
  lessThan?: InputMaybe<Scalars['String']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['String']['input']>;
  like?: InputMaybe<Scalars['String']['input']>;
  notEq?: InputMaybe<Scalars['String']['input']>;
  stringEndsWith?: InputMaybe<Scalars['String']['input']>;
  stringStartsWith?: InputMaybe<Scalars['String']['input']>;
};

export type CourseFilterWorkflowRunId = {
  eq?: InputMaybe<Scalars['ID']['input']>;
  greaterThan?: InputMaybe<Scalars['ID']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  in?: InputMaybe<Array<InputMaybe<Scalars['ID']['input']>>>;
  isDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  lessThan?: InputMaybe<Scalars['ID']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  notEq?: InputMaybe<Scalars['ID']['input']>;
};

export type CourseFilterWorkspaceId = {
  eq?: InputMaybe<Scalars['ID']['input']>;
  greaterThan?: InputMaybe<Scalars['ID']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  in?: InputMaybe<Array<Scalars['ID']['input']>>;
  isDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  lessThan?: InputMaybe<Scalars['ID']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  notEq?: InputMaybe<Scalars['ID']['input']>;
};

export type CourseSortField =
  | 'CAPACITY'
  | 'CONFIRMED_COUNT'
  | 'ENROLLMENT_POLICY'
  | 'ID'
  | 'REGISTRATION_DEADLINE'
  | 'RESEARCH_ENABLED'
  | 'RESEARCH_REQUIREMENTS'
  | 'STATUS'
  | 'TITLE'
  | 'WORKFLOW_RUN_ID'
  | 'WORKSPACE_ID';

export type CourseSortInput = {
  field: CourseSortField;
  order?: InputMaybe<SortOrder>;
};

export type CreateEnrollmentInput = {
  approvalDeadline?: InputMaybe<Scalars['DateTime']['input']>;
  courseId?: InputMaybe<Scalars['ID']['input']>;
  eventId?: InputMaybe<Scalars['ID']['input']>;
  inviteCode?: InputMaybe<Scalars['String']['input']>;
  submissionPayload?: InputMaybe<Scalars['JsonString']['input']>;
  userId: Scalars['ID']['input'];
  workflowRunId?: InputMaybe<Scalars['ID']['input']>;
};

/** The result of the :create_enrollment mutation */
export type CreateEnrollmentResult = {
  /** Any errors generated, if the mutation failed */
  errors: Array<MutationError>;
  /** The successful result of the mutation */
  result?: Maybe<Enrollment>;
};

export type CreateInvitationInput = {
  /** 过期时间（可选） */
  expiresAt?: InputMaybe<Scalars['DateTime']['input']>;
  /** 邀请人 ID */
  inviterId: Scalars['ID']['input'];
  /** 预授权角色名数组（可选） */
  preauthorizedRoleNames?: InputMaybe<Array<Scalars['String']['input']>>;
  /** 目标邮箱（空=公开链接） */
  targetEmail?: InputMaybe<Scalars['String']['input']>;
  /** 目标工作台 ID */
  workspaceId: Scalars['ID']['input'];
};

export type CreateInvitationMetadata = {
  /** 明文邀请令牌（仅创建时返回一次，不落库） */
  plainToken: Scalars['String']['output'];
};

/** The result of the :create_invitation mutation */
export type CreateInvitationResult = {
  /** Any errors generated, if the mutation failed */
  errors: Array<MutationError>;
  /** Metadata produced by the mutation */
  metadata?: Maybe<CreateInvitationMetadata>;
  /** The successful result of the mutation */
  result?: Maybe<Invitation>;
};

export type CreateInviteBatchInput = {
  courseId?: InputMaybe<Scalars['ID']['input']>;
  eventId?: InputMaybe<Scalars['ID']['input']>;
  expiresAt?: InputMaybe<Scalars['DateTime']['input']>;
  inviteCode: Scalars['String']['input'];
  quota: Scalars['Int']['input'];
  remark?: InputMaybe<Scalars['String']['input']>;
  status?: InputMaybe<Scalars['String']['input']>;
};

/** The result of the :create_invite_batch mutation */
export type CreateInviteBatchResult = {
  /** Any errors generated, if the mutation failed */
  errors: Array<MutationError>;
  /** The successful result of the mutation */
  result?: Maybe<InviteBatch>;
};

export type CreateJoinRequestInput = {
  /** 申请留言（可选） */
  message?: InputMaybe<Scalars['String']['input']>;
  /** 申请人 ID */
  userId: Scalars['ID']['input'];
  /** 目标工作台 ID */
  workspaceId: Scalars['ID']['input'];
};

/** The result of the :create_join_request mutation */
export type CreateJoinRequestResult = {
  /** Any errors generated, if the mutation failed */
  errors: Array<MutationError>;
  /** The successful result of the mutation */
  result?: Maybe<JoinRequest>;
};

export type CreateMcpTokenPayload = {
  errors?: Maybe<Array<Maybe<MutationError>>>;
  plainToken?: Maybe<Scalars['String']['output']>;
  /** createMcpToken 返回：result 为 token 记录；plainToken 明文仅此一次 */
  result?: Maybe<McpToken>;
};

export type CreatePortfolioItemInput = {
  description?: InputMaybe<Scalars['String']['input']>;
  icon?: InputMaybe<Scalars['String']['input']>;
  /** createPortfolioItem 输入：title 必填，description/url/icon 可选 */
  title: Scalars['String']['input'];
  url?: InputMaybe<Scalars['String']['input']>;
};

export type CreateWorkspaceApplicationInput = {
  /** 申请人 ID */
  applicantId: Scalars['ID']['input'];
  /** 申请创建的工作台名称 */
  name: Scalars['String']['input'];
  /** 申请目的 */
  purpose: Scalars['String']['input'];
  /** 申请创建的工作台 slug（创建时校验全局唯一） */
  slug: Scalars['String']['input'];
};

/** The result of the :create_workspace_application mutation */
export type CreateWorkspaceApplicationResult = {
  /** Any errors generated, if the mutation failed */
  errors: Array<MutationError>;
  /** The successful result of the mutation */
  result?: Maybe<WorkspaceApplication>;
};

export type CreateWorkspaceInput = {
  /** 加入策略：open 公开直接加入 / request 公开申请审批 / invite_only 私密仅邀请 */
  joinPolicy?: InputMaybe<Scalars['String']['input']>;
  /** 工作台名称 */
  name: Scalars['String']['input'];
  /** 邀请新用户为 Owner（创建 preauthorized [:owner] 的 Invitation，pending-owner） */
  ownerEmail?: InputMaybe<Scalars['String']['input']>;
  /** 指定已有用户为 Owner（替代 actor.id 建 Owner membership） */
  ownerUserId?: InputMaybe<Scalars['ID']['input']>;
  /** 工作台唯一标识（小写字母/数字/连字符，创建者提供） */
  slug: Scalars['String']['input'];
  /** 是否开放赞助入口（默认开） */
  sponsorshipEnabled?: InputMaybe<Scalars['Boolean']['input']>;
};

export type CreateWorkspaceMetadata = {
  /** pending-owner 邀请明文 token（仅创建时返回一次，不落库） */
  ownerInvitationToken?: Maybe<Scalars['String']['output']>;
};

/** The result of the :create_workspace mutation */
export type CreateWorkspaceResult = {
  /** Any errors generated, if the mutation failed */
  errors: Array<MutationError>;
  /** Metadata produced by the mutation */
  metadata?: Maybe<CreateWorkspaceMetadata>;
  /** The successful result of the mutation */
  result?: Maybe<Workspace>;
};

/** The result of the :disable_invite_batch mutation */
export type DisableInviteBatchResult = {
  /** Any errors generated, if the mutation failed */
  errors: Array<MutationError>;
  /** The successful result of the mutation */
  result?: Maybe<InviteBatch>;
};

export type Enrollment = {
  approvalDeadline?: Maybe<Scalars['DateTime']['output']>;
  approvedAt?: Maybe<Scalars['DateTime']['output']>;
  approvedBy?: Maybe<Scalars['ID']['output']>;
  cancelledAt?: Maybe<Scalars['DateTime']['output']>;
  capacitySeq?: Maybe<Scalars['Int']['output']>;
  courseId?: Maybe<Scalars['ID']['output']>;
  eventId?: Maybe<Scalars['ID']['output']>;
  expiredAt?: Maybe<Scalars['DateTime']['output']>;
  id: Scalars['ID']['output'];
  inviteBatchId?: Maybe<Scalars['ID']['output']>;
  rejectionReason?: Maybe<Scalars['String']['output']>;
  status: Scalars['String']['output'];
  submissionPayload: Scalars['JsonString']['output'];
  userId: Scalars['ID']['output'];
  workflowRunId?: Maybe<Scalars['ID']['output']>;
  workspaceId: Scalars['ID']['output'];
};

export type EnrollmentFilterApprovalDeadline = {
  eq?: InputMaybe<Scalars['DateTime']['input']>;
  greaterThan?: InputMaybe<Scalars['DateTime']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['DateTime']['input']>;
  in?: InputMaybe<Array<InputMaybe<Scalars['DateTime']['input']>>>;
  isDistinctFrom?: InputMaybe<Scalars['DateTime']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['DateTime']['input']>;
  lessThan?: InputMaybe<Scalars['DateTime']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['DateTime']['input']>;
  notEq?: InputMaybe<Scalars['DateTime']['input']>;
};

export type EnrollmentFilterApprovedAt = {
  eq?: InputMaybe<Scalars['DateTime']['input']>;
  greaterThan?: InputMaybe<Scalars['DateTime']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['DateTime']['input']>;
  in?: InputMaybe<Array<InputMaybe<Scalars['DateTime']['input']>>>;
  isDistinctFrom?: InputMaybe<Scalars['DateTime']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['DateTime']['input']>;
  lessThan?: InputMaybe<Scalars['DateTime']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['DateTime']['input']>;
  notEq?: InputMaybe<Scalars['DateTime']['input']>;
};

export type EnrollmentFilterApprovedBy = {
  eq?: InputMaybe<Scalars['ID']['input']>;
  greaterThan?: InputMaybe<Scalars['ID']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  in?: InputMaybe<Array<InputMaybe<Scalars['ID']['input']>>>;
  isDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  lessThan?: InputMaybe<Scalars['ID']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  notEq?: InputMaybe<Scalars['ID']['input']>;
};

export type EnrollmentFilterCancelledAt = {
  eq?: InputMaybe<Scalars['DateTime']['input']>;
  greaterThan?: InputMaybe<Scalars['DateTime']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['DateTime']['input']>;
  in?: InputMaybe<Array<InputMaybe<Scalars['DateTime']['input']>>>;
  isDistinctFrom?: InputMaybe<Scalars['DateTime']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['DateTime']['input']>;
  lessThan?: InputMaybe<Scalars['DateTime']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['DateTime']['input']>;
  notEq?: InputMaybe<Scalars['DateTime']['input']>;
};

export type EnrollmentFilterCapacitySeq = {
  eq?: InputMaybe<Scalars['Int']['input']>;
  greaterThan?: InputMaybe<Scalars['Int']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['Int']['input']>;
  in?: InputMaybe<Array<InputMaybe<Scalars['Int']['input']>>>;
  isDistinctFrom?: InputMaybe<Scalars['Int']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['Int']['input']>;
  lessThan?: InputMaybe<Scalars['Int']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['Int']['input']>;
  notEq?: InputMaybe<Scalars['Int']['input']>;
};

export type EnrollmentFilterCourseId = {
  eq?: InputMaybe<Scalars['ID']['input']>;
  greaterThan?: InputMaybe<Scalars['ID']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  in?: InputMaybe<Array<InputMaybe<Scalars['ID']['input']>>>;
  isDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  lessThan?: InputMaybe<Scalars['ID']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  notEq?: InputMaybe<Scalars['ID']['input']>;
};

export type EnrollmentFilterEventId = {
  eq?: InputMaybe<Scalars['ID']['input']>;
  greaterThan?: InputMaybe<Scalars['ID']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  in?: InputMaybe<Array<InputMaybe<Scalars['ID']['input']>>>;
  isDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  lessThan?: InputMaybe<Scalars['ID']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  notEq?: InputMaybe<Scalars['ID']['input']>;
};

export type EnrollmentFilterExpiredAt = {
  eq?: InputMaybe<Scalars['DateTime']['input']>;
  greaterThan?: InputMaybe<Scalars['DateTime']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['DateTime']['input']>;
  in?: InputMaybe<Array<InputMaybe<Scalars['DateTime']['input']>>>;
  isDistinctFrom?: InputMaybe<Scalars['DateTime']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['DateTime']['input']>;
  lessThan?: InputMaybe<Scalars['DateTime']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['DateTime']['input']>;
  notEq?: InputMaybe<Scalars['DateTime']['input']>;
};

export type EnrollmentFilterId = {
  eq?: InputMaybe<Scalars['ID']['input']>;
  greaterThan?: InputMaybe<Scalars['ID']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  in?: InputMaybe<Array<Scalars['ID']['input']>>;
  isDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  lessThan?: InputMaybe<Scalars['ID']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  notEq?: InputMaybe<Scalars['ID']['input']>;
};

export type EnrollmentFilterInput = {
  and?: InputMaybe<Array<EnrollmentFilterInput>>;
  approvalDeadline?: InputMaybe<EnrollmentFilterApprovalDeadline>;
  approvedAt?: InputMaybe<EnrollmentFilterApprovedAt>;
  approvedBy?: InputMaybe<EnrollmentFilterApprovedBy>;
  cancelledAt?: InputMaybe<EnrollmentFilterCancelledAt>;
  capacitySeq?: InputMaybe<EnrollmentFilterCapacitySeq>;
  courseId?: InputMaybe<EnrollmentFilterCourseId>;
  eventId?: InputMaybe<EnrollmentFilterEventId>;
  expiredAt?: InputMaybe<EnrollmentFilterExpiredAt>;
  id?: InputMaybe<EnrollmentFilterId>;
  inviteBatchId?: InputMaybe<EnrollmentFilterInviteBatchId>;
  not?: InputMaybe<Array<EnrollmentFilterInput>>;
  or?: InputMaybe<Array<EnrollmentFilterInput>>;
  rejectionReason?: InputMaybe<EnrollmentFilterRejectionReason>;
  status?: InputMaybe<EnrollmentFilterStatus>;
  submissionPayload?: InputMaybe<EnrollmentFilterSubmissionPayload>;
  userId?: InputMaybe<EnrollmentFilterUserId>;
  workflowRunId?: InputMaybe<EnrollmentFilterWorkflowRunId>;
  workspaceId?: InputMaybe<EnrollmentFilterWorkspaceId>;
};

export type EnrollmentFilterInviteBatchId = {
  eq?: InputMaybe<Scalars['ID']['input']>;
  greaterThan?: InputMaybe<Scalars['ID']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  in?: InputMaybe<Array<InputMaybe<Scalars['ID']['input']>>>;
  isDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  lessThan?: InputMaybe<Scalars['ID']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  notEq?: InputMaybe<Scalars['ID']['input']>;
};

export type EnrollmentFilterRejectionReason = {
  contains?: InputMaybe<Scalars['String']['input']>;
  eq?: InputMaybe<Scalars['String']['input']>;
  greaterThan?: InputMaybe<Scalars['String']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['String']['input']>;
  ilike?: InputMaybe<Scalars['String']['input']>;
  in?: InputMaybe<Array<InputMaybe<Scalars['String']['input']>>>;
  isDistinctFrom?: InputMaybe<Scalars['String']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['String']['input']>;
  lessThan?: InputMaybe<Scalars['String']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['String']['input']>;
  like?: InputMaybe<Scalars['String']['input']>;
  notEq?: InputMaybe<Scalars['String']['input']>;
  stringEndsWith?: InputMaybe<Scalars['String']['input']>;
  stringStartsWith?: InputMaybe<Scalars['String']['input']>;
};

export type EnrollmentFilterStatus = {
  eq?: InputMaybe<Scalars['String']['input']>;
  greaterThan?: InputMaybe<Scalars['String']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['String']['input']>;
  in?: InputMaybe<Array<Scalars['String']['input']>>;
  isDistinctFrom?: InputMaybe<Scalars['String']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['String']['input']>;
  lessThan?: InputMaybe<Scalars['String']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['String']['input']>;
  notEq?: InputMaybe<Scalars['String']['input']>;
};

export type EnrollmentFilterSubmissionPayload = {
  eq?: InputMaybe<Scalars['JsonString']['input']>;
  greaterThan?: InputMaybe<Scalars['JsonString']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['JsonString']['input']>;
  in?: InputMaybe<Array<Scalars['JsonString']['input']>>;
  isDistinctFrom?: InputMaybe<Scalars['JsonString']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['JsonString']['input']>;
  lessThan?: InputMaybe<Scalars['JsonString']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['JsonString']['input']>;
  notEq?: InputMaybe<Scalars['JsonString']['input']>;
};

export type EnrollmentFilterUserId = {
  eq?: InputMaybe<Scalars['ID']['input']>;
  greaterThan?: InputMaybe<Scalars['ID']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  in?: InputMaybe<Array<Scalars['ID']['input']>>;
  isDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  lessThan?: InputMaybe<Scalars['ID']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  notEq?: InputMaybe<Scalars['ID']['input']>;
};

export type EnrollmentFilterWorkflowRunId = {
  eq?: InputMaybe<Scalars['ID']['input']>;
  greaterThan?: InputMaybe<Scalars['ID']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  in?: InputMaybe<Array<InputMaybe<Scalars['ID']['input']>>>;
  isDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  lessThan?: InputMaybe<Scalars['ID']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  notEq?: InputMaybe<Scalars['ID']['input']>;
};

export type EnrollmentFilterWorkspaceId = {
  eq?: InputMaybe<Scalars['ID']['input']>;
  greaterThan?: InputMaybe<Scalars['ID']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  in?: InputMaybe<Array<Scalars['ID']['input']>>;
  isDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  lessThan?: InputMaybe<Scalars['ID']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  notEq?: InputMaybe<Scalars['ID']['input']>;
};

export type EnrollmentSortField =
  | 'APPROVAL_DEADLINE'
  | 'APPROVED_AT'
  | 'APPROVED_BY'
  | 'CANCELLED_AT'
  | 'CAPACITY_SEQ'
  | 'COURSE_ID'
  | 'EVENT_ID'
  | 'EXPIRED_AT'
  | 'ID'
  | 'INVITE_BATCH_ID'
  | 'REJECTION_REASON'
  | 'STATUS'
  | 'SUBMISSION_PAYLOAD'
  | 'USER_ID'
  | 'WORKFLOW_RUN_ID'
  | 'WORKSPACE_ID';

export type EnrollmentSortInput = {
  field: EnrollmentSortField;
  order?: InputMaybe<SortOrder>;
};

export type Event = {
  /** 报名名额上限；nil 表示不限 */
  capacity?: Maybe<Scalars['Int']['output']>;
  /** 已确认名额数（仅由 Enrollment 原子维护） */
  confirmedCount: Scalars['Int']['output'];
  /** 报名策略：open / request / invite_only */
  enrollmentPolicy: Scalars['String']['output'];
  id: Scalars['ID']['output'];
  /** 报名截止时间；nil 表示不设截止 */
  registrationDeadline?: Maybe<Scalars['DateTime']['output']>;
  /** 是否启用教研 workflow */
  researchEnabled: Scalars['Boolean']['output'];
  /** 教研材料需求（audience/duration/sections 等），作为 run input 注入 */
  researchRequirements?: Maybe<Scalars['JsonString']['output']>;
  /** 活动状态：draft 草稿 / open 已发布 / closed 已结束 / cancelled 已取消 */
  status: Scalars['String']['output'];
  /** 活动标题 */
  title: Scalars['String']['output'];
  /** 教研 workflow 产物引用（领域模型 §5.2 ER） */
  workflowRunId?: Maybe<Scalars['ID']['output']>;
  /** 所属工作台（租户）ID */
  workspaceId: Scalars['ID']['output'];
};

export type EventFilterCapacity = {
  eq?: InputMaybe<Scalars['Int']['input']>;
  greaterThan?: InputMaybe<Scalars['Int']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['Int']['input']>;
  in?: InputMaybe<Array<InputMaybe<Scalars['Int']['input']>>>;
  isDistinctFrom?: InputMaybe<Scalars['Int']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['Int']['input']>;
  lessThan?: InputMaybe<Scalars['Int']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['Int']['input']>;
  notEq?: InputMaybe<Scalars['Int']['input']>;
};

export type EventFilterConfirmedCount = {
  eq?: InputMaybe<Scalars['Int']['input']>;
  greaterThan?: InputMaybe<Scalars['Int']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['Int']['input']>;
  in?: InputMaybe<Array<Scalars['Int']['input']>>;
  isDistinctFrom?: InputMaybe<Scalars['Int']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['Int']['input']>;
  lessThan?: InputMaybe<Scalars['Int']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['Int']['input']>;
  notEq?: InputMaybe<Scalars['Int']['input']>;
};

export type EventFilterEnrollmentPolicy = {
  eq?: InputMaybe<Scalars['String']['input']>;
  greaterThan?: InputMaybe<Scalars['String']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['String']['input']>;
  in?: InputMaybe<Array<Scalars['String']['input']>>;
  isDistinctFrom?: InputMaybe<Scalars['String']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['String']['input']>;
  lessThan?: InputMaybe<Scalars['String']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['String']['input']>;
  notEq?: InputMaybe<Scalars['String']['input']>;
};

export type EventFilterId = {
  eq?: InputMaybe<Scalars['ID']['input']>;
  greaterThan?: InputMaybe<Scalars['ID']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  in?: InputMaybe<Array<Scalars['ID']['input']>>;
  isDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  lessThan?: InputMaybe<Scalars['ID']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  notEq?: InputMaybe<Scalars['ID']['input']>;
};

export type EventFilterInput = {
  and?: InputMaybe<Array<EventFilterInput>>;
  /** 报名名额上限；nil 表示不限 */
  capacity?: InputMaybe<EventFilterCapacity>;
  /** 已确认名额数（仅由 Enrollment 原子维护） */
  confirmedCount?: InputMaybe<EventFilterConfirmedCount>;
  /** 报名策略：open / request / invite_only */
  enrollmentPolicy?: InputMaybe<EventFilterEnrollmentPolicy>;
  id?: InputMaybe<EventFilterId>;
  not?: InputMaybe<Array<EventFilterInput>>;
  or?: InputMaybe<Array<EventFilterInput>>;
  /** 报名截止时间；nil 表示不设截止 */
  registrationDeadline?: InputMaybe<EventFilterRegistrationDeadline>;
  /** 是否启用教研 workflow */
  researchEnabled?: InputMaybe<EventFilterResearchEnabled>;
  /** 教研材料需求（audience/duration/sections 等），作为 run input 注入 */
  researchRequirements?: InputMaybe<EventFilterResearchRequirements>;
  /** 活动状态：draft 草稿 / open 已发布 / closed 已结束 / cancelled 已取消 */
  status?: InputMaybe<EventFilterStatus>;
  /** 活动标题 */
  title?: InputMaybe<EventFilterTitle>;
  /** 教研 workflow 产物引用（领域模型 §5.2 ER） */
  workflowRunId?: InputMaybe<EventFilterWorkflowRunId>;
  /** 所属工作台（租户）ID */
  workspaceId?: InputMaybe<EventFilterWorkspaceId>;
};

export type EventFilterRegistrationDeadline = {
  eq?: InputMaybe<Scalars['DateTime']['input']>;
  greaterThan?: InputMaybe<Scalars['DateTime']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['DateTime']['input']>;
  in?: InputMaybe<Array<InputMaybe<Scalars['DateTime']['input']>>>;
  isDistinctFrom?: InputMaybe<Scalars['DateTime']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['DateTime']['input']>;
  lessThan?: InputMaybe<Scalars['DateTime']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['DateTime']['input']>;
  notEq?: InputMaybe<Scalars['DateTime']['input']>;
};

export type EventFilterResearchEnabled = {
  eq?: InputMaybe<Scalars['Boolean']['input']>;
  greaterThan?: InputMaybe<Scalars['Boolean']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['Boolean']['input']>;
  in?: InputMaybe<Array<Scalars['Boolean']['input']>>;
  isDistinctFrom?: InputMaybe<Scalars['Boolean']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['Boolean']['input']>;
  lessThan?: InputMaybe<Scalars['Boolean']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['Boolean']['input']>;
  notEq?: InputMaybe<Scalars['Boolean']['input']>;
};

export type EventFilterResearchRequirements = {
  eq?: InputMaybe<Scalars['JsonString']['input']>;
  greaterThan?: InputMaybe<Scalars['JsonString']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['JsonString']['input']>;
  in?: InputMaybe<Array<InputMaybe<Scalars['JsonString']['input']>>>;
  isDistinctFrom?: InputMaybe<Scalars['JsonString']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['JsonString']['input']>;
  lessThan?: InputMaybe<Scalars['JsonString']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['JsonString']['input']>;
  notEq?: InputMaybe<Scalars['JsonString']['input']>;
};

export type EventFilterStatus = {
  eq?: InputMaybe<Scalars['String']['input']>;
  greaterThan?: InputMaybe<Scalars['String']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['String']['input']>;
  in?: InputMaybe<Array<Scalars['String']['input']>>;
  isDistinctFrom?: InputMaybe<Scalars['String']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['String']['input']>;
  lessThan?: InputMaybe<Scalars['String']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['String']['input']>;
  notEq?: InputMaybe<Scalars['String']['input']>;
};

export type EventFilterTitle = {
  contains?: InputMaybe<Scalars['String']['input']>;
  eq?: InputMaybe<Scalars['String']['input']>;
  greaterThan?: InputMaybe<Scalars['String']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['String']['input']>;
  ilike?: InputMaybe<Scalars['String']['input']>;
  in?: InputMaybe<Array<Scalars['String']['input']>>;
  isDistinctFrom?: InputMaybe<Scalars['String']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['String']['input']>;
  lessThan?: InputMaybe<Scalars['String']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['String']['input']>;
  like?: InputMaybe<Scalars['String']['input']>;
  notEq?: InputMaybe<Scalars['String']['input']>;
  stringEndsWith?: InputMaybe<Scalars['String']['input']>;
  stringStartsWith?: InputMaybe<Scalars['String']['input']>;
};

export type EventFilterWorkflowRunId = {
  eq?: InputMaybe<Scalars['ID']['input']>;
  greaterThan?: InputMaybe<Scalars['ID']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  in?: InputMaybe<Array<InputMaybe<Scalars['ID']['input']>>>;
  isDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  lessThan?: InputMaybe<Scalars['ID']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  notEq?: InputMaybe<Scalars['ID']['input']>;
};

export type EventFilterWorkspaceId = {
  eq?: InputMaybe<Scalars['ID']['input']>;
  greaterThan?: InputMaybe<Scalars['ID']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  in?: InputMaybe<Array<Scalars['ID']['input']>>;
  isDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  lessThan?: InputMaybe<Scalars['ID']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  notEq?: InputMaybe<Scalars['ID']['input']>;
};

export type EventSortField =
  | 'CAPACITY'
  | 'CONFIRMED_COUNT'
  | 'ENROLLMENT_POLICY'
  | 'ID'
  | 'REGISTRATION_DEADLINE'
  | 'RESEARCH_ENABLED'
  | 'RESEARCH_REQUIREMENTS'
  | 'STATUS'
  | 'TITLE'
  | 'WORKFLOW_RUN_ID'
  | 'WORKSPACE_ID';

export type EventSortInput = {
  field: EventSortField;
  order?: InputMaybe<SortOrder>;
};

export type Invitation = {
  /** 接受时间 */
  acceptedAt?: Maybe<Scalars['DateTime']['output']>;
  /** 接受人（全局用户）ID */
  acceptedBy?: Maybe<Scalars['ID']['output']>;
  effectiveStatus?: Maybe<Scalars['String']['output']>;
  /** 过期时间（可选） */
  expiresAt?: Maybe<Scalars['DateTime']['output']>;
  id: Scalars['ID']['output'];
  /** 邀请人（全局用户）ID */
  inviterId: Scalars['ID']['output'];
  /** 预授权角色名数组（可选） */
  preauthorizedRoleNames?: Maybe<Array<Scalars['String']['output']>>;
  /** 邀请状态 */
  status: Scalars['String']['output'];
  /** 目标邮箱（空=公开链接） */
  targetEmail?: Maybe<Scalars['String']['output']>;
  /** 邀请令牌的 SHA256 哈希 */
  tokenHash: Scalars['String']['output'];
  /** 所属工作台（租户）ID */
  workspaceId: Scalars['ID']['output'];
  workspaceJoinPolicy?: Maybe<Scalars['String']['output']>;
  workspaceName?: Maybe<Scalars['String']['output']>;
  workspaceSlug?: Maybe<Scalars['String']['output']>;
};

export type InvitationFilterAcceptedAt = {
  eq?: InputMaybe<Scalars['DateTime']['input']>;
  greaterThan?: InputMaybe<Scalars['DateTime']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['DateTime']['input']>;
  in?: InputMaybe<Array<InputMaybe<Scalars['DateTime']['input']>>>;
  isDistinctFrom?: InputMaybe<Scalars['DateTime']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['DateTime']['input']>;
  lessThan?: InputMaybe<Scalars['DateTime']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['DateTime']['input']>;
  notEq?: InputMaybe<Scalars['DateTime']['input']>;
};

export type InvitationFilterAcceptedBy = {
  eq?: InputMaybe<Scalars['ID']['input']>;
  greaterThan?: InputMaybe<Scalars['ID']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  in?: InputMaybe<Array<InputMaybe<Scalars['ID']['input']>>>;
  isDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  lessThan?: InputMaybe<Scalars['ID']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  notEq?: InputMaybe<Scalars['ID']['input']>;
};

export type InvitationFilterExpiresAt = {
  eq?: InputMaybe<Scalars['DateTime']['input']>;
  greaterThan?: InputMaybe<Scalars['DateTime']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['DateTime']['input']>;
  in?: InputMaybe<Array<InputMaybe<Scalars['DateTime']['input']>>>;
  isDistinctFrom?: InputMaybe<Scalars['DateTime']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['DateTime']['input']>;
  lessThan?: InputMaybe<Scalars['DateTime']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['DateTime']['input']>;
  notEq?: InputMaybe<Scalars['DateTime']['input']>;
};

export type InvitationFilterId = {
  eq?: InputMaybe<Scalars['ID']['input']>;
  greaterThan?: InputMaybe<Scalars['ID']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  in?: InputMaybe<Array<Scalars['ID']['input']>>;
  isDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  lessThan?: InputMaybe<Scalars['ID']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  notEq?: InputMaybe<Scalars['ID']['input']>;
};

export type InvitationFilterInput = {
  /** 接受时间 */
  acceptedAt?: InputMaybe<InvitationFilterAcceptedAt>;
  /** 接受人（全局用户）ID */
  acceptedBy?: InputMaybe<InvitationFilterAcceptedBy>;
  and?: InputMaybe<Array<InvitationFilterInput>>;
  /** 过期时间（可选） */
  expiresAt?: InputMaybe<InvitationFilterExpiresAt>;
  id?: InputMaybe<InvitationFilterId>;
  /** 邀请人（全局用户）ID */
  inviterId?: InputMaybe<InvitationFilterInviterId>;
  not?: InputMaybe<Array<InvitationFilterInput>>;
  or?: InputMaybe<Array<InvitationFilterInput>>;
  /** 邀请状态 */
  status?: InputMaybe<InvitationFilterStatus>;
  /** 目标邮箱（空=公开链接） */
  targetEmail?: InputMaybe<InvitationFilterTargetEmail>;
  /** 邀请令牌的 SHA256 哈希 */
  tokenHash?: InputMaybe<InvitationFilterTokenHash>;
  /** 所属工作台（租户）ID */
  workspaceId?: InputMaybe<InvitationFilterWorkspaceId>;
};

export type InvitationFilterInviterId = {
  eq?: InputMaybe<Scalars['ID']['input']>;
  greaterThan?: InputMaybe<Scalars['ID']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  in?: InputMaybe<Array<Scalars['ID']['input']>>;
  isDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  lessThan?: InputMaybe<Scalars['ID']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  notEq?: InputMaybe<Scalars['ID']['input']>;
};

export type InvitationFilterStatus = {
  eq?: InputMaybe<Scalars['String']['input']>;
  greaterThan?: InputMaybe<Scalars['String']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['String']['input']>;
  in?: InputMaybe<Array<Scalars['String']['input']>>;
  isDistinctFrom?: InputMaybe<Scalars['String']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['String']['input']>;
  lessThan?: InputMaybe<Scalars['String']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['String']['input']>;
  notEq?: InputMaybe<Scalars['String']['input']>;
};

export type InvitationFilterTargetEmail = {
  contains?: InputMaybe<Scalars['String']['input']>;
  eq?: InputMaybe<Scalars['String']['input']>;
  greaterThan?: InputMaybe<Scalars['String']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['String']['input']>;
  ilike?: InputMaybe<Scalars['String']['input']>;
  in?: InputMaybe<Array<InputMaybe<Scalars['String']['input']>>>;
  isDistinctFrom?: InputMaybe<Scalars['String']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['String']['input']>;
  lessThan?: InputMaybe<Scalars['String']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['String']['input']>;
  like?: InputMaybe<Scalars['String']['input']>;
  notEq?: InputMaybe<Scalars['String']['input']>;
  stringEndsWith?: InputMaybe<Scalars['String']['input']>;
  stringStartsWith?: InputMaybe<Scalars['String']['input']>;
};

export type InvitationFilterTokenHash = {
  contains?: InputMaybe<Scalars['String']['input']>;
  eq?: InputMaybe<Scalars['String']['input']>;
  greaterThan?: InputMaybe<Scalars['String']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['String']['input']>;
  ilike?: InputMaybe<Scalars['String']['input']>;
  in?: InputMaybe<Array<Scalars['String']['input']>>;
  isDistinctFrom?: InputMaybe<Scalars['String']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['String']['input']>;
  lessThan?: InputMaybe<Scalars['String']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['String']['input']>;
  like?: InputMaybe<Scalars['String']['input']>;
  notEq?: InputMaybe<Scalars['String']['input']>;
  stringEndsWith?: InputMaybe<Scalars['String']['input']>;
  stringStartsWith?: InputMaybe<Scalars['String']['input']>;
};

export type InvitationFilterWorkspaceId = {
  eq?: InputMaybe<Scalars['ID']['input']>;
  greaterThan?: InputMaybe<Scalars['ID']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  in?: InputMaybe<Array<Scalars['ID']['input']>>;
  isDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  lessThan?: InputMaybe<Scalars['ID']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  notEq?: InputMaybe<Scalars['ID']['input']>;
};

export type InvitationSortField =
  | 'ACCEPTED_AT'
  | 'ACCEPTED_BY'
  | 'EXPIRES_AT'
  | 'ID'
  | 'INVITER_ID'
  | 'STATUS'
  | 'TARGET_EMAIL'
  | 'TOKEN_HASH'
  | 'WORKSPACE_ID';

export type InvitationSortInput = {
  field: InvitationSortField;
  order?: InputMaybe<SortOrder>;
};

export type InviteBatch = {
  courseId?: Maybe<Scalars['ID']['output']>;
  eventId?: Maybe<Scalars['ID']['output']>;
  expiresAt?: Maybe<Scalars['DateTime']['output']>;
  id: Scalars['ID']['output'];
  inviteCode: Scalars['String']['output'];
  quota: Scalars['Int']['output'];
  remainingQuota: Scalars['Int']['output'];
  remark?: Maybe<Scalars['String']['output']>;
  status: Scalars['String']['output'];
  workspaceId: Scalars['ID']['output'];
};

export type InviteBatchFilterCourseId = {
  eq?: InputMaybe<Scalars['ID']['input']>;
  greaterThan?: InputMaybe<Scalars['ID']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  in?: InputMaybe<Array<InputMaybe<Scalars['ID']['input']>>>;
  isDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  lessThan?: InputMaybe<Scalars['ID']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  notEq?: InputMaybe<Scalars['ID']['input']>;
};

export type InviteBatchFilterEventId = {
  eq?: InputMaybe<Scalars['ID']['input']>;
  greaterThan?: InputMaybe<Scalars['ID']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  in?: InputMaybe<Array<InputMaybe<Scalars['ID']['input']>>>;
  isDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  lessThan?: InputMaybe<Scalars['ID']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  notEq?: InputMaybe<Scalars['ID']['input']>;
};

export type InviteBatchFilterExpiresAt = {
  eq?: InputMaybe<Scalars['DateTime']['input']>;
  greaterThan?: InputMaybe<Scalars['DateTime']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['DateTime']['input']>;
  in?: InputMaybe<Array<InputMaybe<Scalars['DateTime']['input']>>>;
  isDistinctFrom?: InputMaybe<Scalars['DateTime']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['DateTime']['input']>;
  lessThan?: InputMaybe<Scalars['DateTime']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['DateTime']['input']>;
  notEq?: InputMaybe<Scalars['DateTime']['input']>;
};

export type InviteBatchFilterId = {
  eq?: InputMaybe<Scalars['ID']['input']>;
  greaterThan?: InputMaybe<Scalars['ID']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  in?: InputMaybe<Array<Scalars['ID']['input']>>;
  isDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  lessThan?: InputMaybe<Scalars['ID']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  notEq?: InputMaybe<Scalars['ID']['input']>;
};

export type InviteBatchFilterInput = {
  and?: InputMaybe<Array<InviteBatchFilterInput>>;
  courseId?: InputMaybe<InviteBatchFilterCourseId>;
  eventId?: InputMaybe<InviteBatchFilterEventId>;
  expiresAt?: InputMaybe<InviteBatchFilterExpiresAt>;
  id?: InputMaybe<InviteBatchFilterId>;
  inviteCode?: InputMaybe<InviteBatchFilterInviteCode>;
  not?: InputMaybe<Array<InviteBatchFilterInput>>;
  or?: InputMaybe<Array<InviteBatchFilterInput>>;
  quota?: InputMaybe<InviteBatchFilterQuota>;
  remainingQuota?: InputMaybe<InviteBatchFilterRemainingQuota>;
  remark?: InputMaybe<InviteBatchFilterRemark>;
  status?: InputMaybe<InviteBatchFilterStatus>;
  workspaceId?: InputMaybe<InviteBatchFilterWorkspaceId>;
};

export type InviteBatchFilterInviteCode = {
  contains?: InputMaybe<Scalars['String']['input']>;
  eq?: InputMaybe<Scalars['String']['input']>;
  greaterThan?: InputMaybe<Scalars['String']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['String']['input']>;
  ilike?: InputMaybe<Scalars['String']['input']>;
  in?: InputMaybe<Array<Scalars['String']['input']>>;
  isDistinctFrom?: InputMaybe<Scalars['String']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['String']['input']>;
  lessThan?: InputMaybe<Scalars['String']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['String']['input']>;
  like?: InputMaybe<Scalars['String']['input']>;
  notEq?: InputMaybe<Scalars['String']['input']>;
  stringEndsWith?: InputMaybe<Scalars['String']['input']>;
  stringStartsWith?: InputMaybe<Scalars['String']['input']>;
};

export type InviteBatchFilterQuota = {
  eq?: InputMaybe<Scalars['Int']['input']>;
  greaterThan?: InputMaybe<Scalars['Int']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['Int']['input']>;
  in?: InputMaybe<Array<Scalars['Int']['input']>>;
  isDistinctFrom?: InputMaybe<Scalars['Int']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['Int']['input']>;
  lessThan?: InputMaybe<Scalars['Int']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['Int']['input']>;
  notEq?: InputMaybe<Scalars['Int']['input']>;
};

export type InviteBatchFilterRemainingQuota = {
  eq?: InputMaybe<Scalars['Int']['input']>;
  greaterThan?: InputMaybe<Scalars['Int']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['Int']['input']>;
  in?: InputMaybe<Array<Scalars['Int']['input']>>;
  isDistinctFrom?: InputMaybe<Scalars['Int']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['Int']['input']>;
  lessThan?: InputMaybe<Scalars['Int']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['Int']['input']>;
  notEq?: InputMaybe<Scalars['Int']['input']>;
};

export type InviteBatchFilterRemark = {
  contains?: InputMaybe<Scalars['String']['input']>;
  eq?: InputMaybe<Scalars['String']['input']>;
  greaterThan?: InputMaybe<Scalars['String']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['String']['input']>;
  ilike?: InputMaybe<Scalars['String']['input']>;
  in?: InputMaybe<Array<InputMaybe<Scalars['String']['input']>>>;
  isDistinctFrom?: InputMaybe<Scalars['String']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['String']['input']>;
  lessThan?: InputMaybe<Scalars['String']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['String']['input']>;
  like?: InputMaybe<Scalars['String']['input']>;
  notEq?: InputMaybe<Scalars['String']['input']>;
  stringEndsWith?: InputMaybe<Scalars['String']['input']>;
  stringStartsWith?: InputMaybe<Scalars['String']['input']>;
};

export type InviteBatchFilterStatus = {
  eq?: InputMaybe<Scalars['String']['input']>;
  greaterThan?: InputMaybe<Scalars['String']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['String']['input']>;
  in?: InputMaybe<Array<Scalars['String']['input']>>;
  isDistinctFrom?: InputMaybe<Scalars['String']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['String']['input']>;
  lessThan?: InputMaybe<Scalars['String']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['String']['input']>;
  notEq?: InputMaybe<Scalars['String']['input']>;
};

export type InviteBatchFilterWorkspaceId = {
  eq?: InputMaybe<Scalars['ID']['input']>;
  greaterThan?: InputMaybe<Scalars['ID']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  in?: InputMaybe<Array<Scalars['ID']['input']>>;
  isDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  lessThan?: InputMaybe<Scalars['ID']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  notEq?: InputMaybe<Scalars['ID']['input']>;
};

export type InviteBatchSortField =
  | 'COURSE_ID'
  | 'EVENT_ID'
  | 'EXPIRES_AT'
  | 'ID'
  | 'INVITE_CODE'
  | 'QUOTA'
  | 'REMAINING_QUOTA'
  | 'REMARK'
  | 'STATUS'
  | 'WORKSPACE_ID';

export type InviteBatchSortInput = {
  field: InviteBatchSortField;
  order?: InputMaybe<SortOrder>;
};

export type JoinRequest = {
  /** 审批截止时间（默认 created_at + 7 天） */
  approvalDeadline?: Maybe<Scalars['DateTime']['output']>;
  /** 审批时间 */
  approvedAt?: Maybe<Scalars['DateTime']['output']>;
  /** 审批人（全局用户）ID */
  approvedBy?: Maybe<Scalars['ID']['output']>;
  /** 过期时间 */
  expiredAt?: Maybe<Scalars['DateTime']['output']>;
  id: Scalars['ID']['output'];
  /** 申请留言（可选） */
  message?: Maybe<Scalars['String']['output']>;
  /** 拒绝原因（可选） */
  rejectionReason?: Maybe<Scalars['String']['output']>;
  /** 申请状态 */
  status: Scalars['String']['output'];
  /** 申请人（全局用户）ID */
  userId: Scalars['ID']['output'];
  /** 所属工作台（租户）ID */
  workspaceId: Scalars['ID']['output'];
};

export type JoinRequestFilterApprovalDeadline = {
  eq?: InputMaybe<Scalars['DateTime']['input']>;
  greaterThan?: InputMaybe<Scalars['DateTime']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['DateTime']['input']>;
  in?: InputMaybe<Array<InputMaybe<Scalars['DateTime']['input']>>>;
  isDistinctFrom?: InputMaybe<Scalars['DateTime']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['DateTime']['input']>;
  lessThan?: InputMaybe<Scalars['DateTime']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['DateTime']['input']>;
  notEq?: InputMaybe<Scalars['DateTime']['input']>;
};

export type JoinRequestFilterApprovedAt = {
  eq?: InputMaybe<Scalars['DateTime']['input']>;
  greaterThan?: InputMaybe<Scalars['DateTime']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['DateTime']['input']>;
  in?: InputMaybe<Array<InputMaybe<Scalars['DateTime']['input']>>>;
  isDistinctFrom?: InputMaybe<Scalars['DateTime']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['DateTime']['input']>;
  lessThan?: InputMaybe<Scalars['DateTime']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['DateTime']['input']>;
  notEq?: InputMaybe<Scalars['DateTime']['input']>;
};

export type JoinRequestFilterApprovedBy = {
  eq?: InputMaybe<Scalars['ID']['input']>;
  greaterThan?: InputMaybe<Scalars['ID']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  in?: InputMaybe<Array<InputMaybe<Scalars['ID']['input']>>>;
  isDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  lessThan?: InputMaybe<Scalars['ID']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  notEq?: InputMaybe<Scalars['ID']['input']>;
};

export type JoinRequestFilterExpiredAt = {
  eq?: InputMaybe<Scalars['DateTime']['input']>;
  greaterThan?: InputMaybe<Scalars['DateTime']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['DateTime']['input']>;
  in?: InputMaybe<Array<InputMaybe<Scalars['DateTime']['input']>>>;
  isDistinctFrom?: InputMaybe<Scalars['DateTime']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['DateTime']['input']>;
  lessThan?: InputMaybe<Scalars['DateTime']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['DateTime']['input']>;
  notEq?: InputMaybe<Scalars['DateTime']['input']>;
};

export type JoinRequestFilterId = {
  eq?: InputMaybe<Scalars['ID']['input']>;
  greaterThan?: InputMaybe<Scalars['ID']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  in?: InputMaybe<Array<Scalars['ID']['input']>>;
  isDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  lessThan?: InputMaybe<Scalars['ID']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  notEq?: InputMaybe<Scalars['ID']['input']>;
};

export type JoinRequestFilterInput = {
  and?: InputMaybe<Array<JoinRequestFilterInput>>;
  /** 审批截止时间（默认 created_at + 7 天） */
  approvalDeadline?: InputMaybe<JoinRequestFilterApprovalDeadline>;
  /** 审批时间 */
  approvedAt?: InputMaybe<JoinRequestFilterApprovedAt>;
  /** 审批人（全局用户）ID */
  approvedBy?: InputMaybe<JoinRequestFilterApprovedBy>;
  /** 过期时间 */
  expiredAt?: InputMaybe<JoinRequestFilterExpiredAt>;
  id?: InputMaybe<JoinRequestFilterId>;
  /** 申请留言（可选） */
  message?: InputMaybe<JoinRequestFilterMessage>;
  not?: InputMaybe<Array<JoinRequestFilterInput>>;
  or?: InputMaybe<Array<JoinRequestFilterInput>>;
  /** 拒绝原因（可选） */
  rejectionReason?: InputMaybe<JoinRequestFilterRejectionReason>;
  /** 申请状态 */
  status?: InputMaybe<JoinRequestFilterStatus>;
  /** 申请人（全局用户）ID */
  userId?: InputMaybe<JoinRequestFilterUserId>;
  /** 所属工作台（租户）ID */
  workspaceId?: InputMaybe<JoinRequestFilterWorkspaceId>;
};

export type JoinRequestFilterMessage = {
  contains?: InputMaybe<Scalars['String']['input']>;
  eq?: InputMaybe<Scalars['String']['input']>;
  greaterThan?: InputMaybe<Scalars['String']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['String']['input']>;
  ilike?: InputMaybe<Scalars['String']['input']>;
  in?: InputMaybe<Array<InputMaybe<Scalars['String']['input']>>>;
  isDistinctFrom?: InputMaybe<Scalars['String']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['String']['input']>;
  lessThan?: InputMaybe<Scalars['String']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['String']['input']>;
  like?: InputMaybe<Scalars['String']['input']>;
  notEq?: InputMaybe<Scalars['String']['input']>;
  stringEndsWith?: InputMaybe<Scalars['String']['input']>;
  stringStartsWith?: InputMaybe<Scalars['String']['input']>;
};

export type JoinRequestFilterRejectionReason = {
  contains?: InputMaybe<Scalars['String']['input']>;
  eq?: InputMaybe<Scalars['String']['input']>;
  greaterThan?: InputMaybe<Scalars['String']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['String']['input']>;
  ilike?: InputMaybe<Scalars['String']['input']>;
  in?: InputMaybe<Array<InputMaybe<Scalars['String']['input']>>>;
  isDistinctFrom?: InputMaybe<Scalars['String']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['String']['input']>;
  lessThan?: InputMaybe<Scalars['String']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['String']['input']>;
  like?: InputMaybe<Scalars['String']['input']>;
  notEq?: InputMaybe<Scalars['String']['input']>;
  stringEndsWith?: InputMaybe<Scalars['String']['input']>;
  stringStartsWith?: InputMaybe<Scalars['String']['input']>;
};

export type JoinRequestFilterStatus = {
  eq?: InputMaybe<Scalars['String']['input']>;
  greaterThan?: InputMaybe<Scalars['String']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['String']['input']>;
  in?: InputMaybe<Array<Scalars['String']['input']>>;
  isDistinctFrom?: InputMaybe<Scalars['String']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['String']['input']>;
  lessThan?: InputMaybe<Scalars['String']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['String']['input']>;
  notEq?: InputMaybe<Scalars['String']['input']>;
};

export type JoinRequestFilterUserId = {
  eq?: InputMaybe<Scalars['ID']['input']>;
  greaterThan?: InputMaybe<Scalars['ID']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  in?: InputMaybe<Array<Scalars['ID']['input']>>;
  isDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  lessThan?: InputMaybe<Scalars['ID']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  notEq?: InputMaybe<Scalars['ID']['input']>;
};

export type JoinRequestFilterWorkspaceId = {
  eq?: InputMaybe<Scalars['ID']['input']>;
  greaterThan?: InputMaybe<Scalars['ID']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  in?: InputMaybe<Array<Scalars['ID']['input']>>;
  isDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  lessThan?: InputMaybe<Scalars['ID']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  notEq?: InputMaybe<Scalars['ID']['input']>;
};

export type JoinRequestSortField =
  | 'APPROVAL_DEADLINE'
  | 'APPROVED_AT'
  | 'APPROVED_BY'
  | 'EXPIRED_AT'
  | 'ID'
  | 'MESSAGE'
  | 'REJECTION_REASON'
  | 'STATUS'
  | 'USER_ID'
  | 'WORKSPACE_ID';

export type JoinRequestSortInput = {
  field: JoinRequestSortField;
  order?: InputMaybe<SortOrder>;
};

export type JoinWorkspaceInput = {
  /** 目标工作台 ID */
  workspaceId: Scalars['ID']['input'];
};

/** A keyset page of :course */
export type KeysetPageOfCourse = {
  /** Total count on all pages */
  count?: Maybe<Scalars['Int']['output']>;
  /** The last keyset in the results */
  endKeyset?: Maybe<Scalars['String']['output']>;
  /** The records contained in the page */
  results?: Maybe<Array<Course>>;
  /** The first keyset in the results */
  startKeyset?: Maybe<Scalars['String']['output']>;
};

/** A keyset page of :enrollment */
export type KeysetPageOfEnrollment = {
  /** Total count on all pages */
  count?: Maybe<Scalars['Int']['output']>;
  /** The last keyset in the results */
  endKeyset?: Maybe<Scalars['String']['output']>;
  /** The records contained in the page */
  results?: Maybe<Array<Enrollment>>;
  /** The first keyset in the results */
  startKeyset?: Maybe<Scalars['String']['output']>;
};

/** A keyset page of :event */
export type KeysetPageOfEvent = {
  /** Total count on all pages */
  count?: Maybe<Scalars['Int']['output']>;
  /** The last keyset in the results */
  endKeyset?: Maybe<Scalars['String']['output']>;
  /** The records contained in the page */
  results?: Maybe<Array<Event>>;
  /** The first keyset in the results */
  startKeyset?: Maybe<Scalars['String']['output']>;
};

/** A keyset page of :invitation */
export type KeysetPageOfInvitation = {
  /** Total count on all pages */
  count?: Maybe<Scalars['Int']['output']>;
  /** The last keyset in the results */
  endKeyset?: Maybe<Scalars['String']['output']>;
  /** The records contained in the page */
  results?: Maybe<Array<Invitation>>;
  /** The first keyset in the results */
  startKeyset?: Maybe<Scalars['String']['output']>;
};

/** A keyset page of :invite_batch */
export type KeysetPageOfInviteBatch = {
  /** Total count on all pages */
  count?: Maybe<Scalars['Int']['output']>;
  /** The last keyset in the results */
  endKeyset?: Maybe<Scalars['String']['output']>;
  /** The records contained in the page */
  results?: Maybe<Array<InviteBatch>>;
  /** The first keyset in the results */
  startKeyset?: Maybe<Scalars['String']['output']>;
};

/** A keyset page of :join_request */
export type KeysetPageOfJoinRequest = {
  /** Total count on all pages */
  count?: Maybe<Scalars['Int']['output']>;
  /** The last keyset in the results */
  endKeyset?: Maybe<Scalars['String']['output']>;
  /** The records contained in the page */
  results?: Maybe<Array<JoinRequest>>;
  /** The first keyset in the results */
  startKeyset?: Maybe<Scalars['String']['output']>;
};

/** A keyset page of :workflow_run */
export type KeysetPageOfWorkflowRun = {
  /** Total count on all pages */
  count?: Maybe<Scalars['Int']['output']>;
  /** The last keyset in the results */
  endKeyset?: Maybe<Scalars['String']['output']>;
  /** The records contained in the page */
  results?: Maybe<Array<WorkflowRun>>;
  /** The first keyset in the results */
  startKeyset?: Maybe<Scalars['String']['output']>;
};

/** A keyset page of :workspace_application */
export type KeysetPageOfWorkspaceApplication = {
  /** Total count on all pages */
  count?: Maybe<Scalars['Int']['output']>;
  /** The last keyset in the results */
  endKeyset?: Maybe<Scalars['String']['output']>;
  /** The records contained in the page */
  results?: Maybe<Array<WorkspaceApplication>>;
  /** The first keyset in the results */
  startKeyset?: Maybe<Scalars['String']['output']>;
};

/** A keyset page of :workspace_membership */
export type KeysetPageOfWorkspaceMembership = {
  /** Total count on all pages */
  count?: Maybe<Scalars['Int']['output']>;
  /** The last keyset in the results */
  endKeyset?: Maybe<Scalars['String']['output']>;
  /** The records contained in the page */
  results?: Maybe<Array<WorkspaceMembership>>;
  /** The first keyset in the results */
  startKeyset?: Maybe<Scalars['String']['output']>;
};

export type McpToken = {
  /** MCP 连接 token（明文不可经此类型读回；hash 不落 GraphQL 面） */
  id: Scalars['ID']['output'];
  insertedAt: Scalars['DateTime']['output'];
  lastUsedAt?: Maybe<Scalars['DateTime']['output']>;
  name: Scalars['String']['output'];
  revokedAt?: Maybe<Scalars['DateTime']['output']>;
};

export type MiniprogramCodeResult = {
  codeBase64: Scalars['String']['output'];
  expiresAt: Scalars['DateTime']['output'];
  invitationId: Scalars['ID']['output'];
  platform: Scalars['String']['output'];
  scene: Scalars['String']['output'];
};

/** An error generated by a failed mutation */
export type MutationError = {
  /** An error code for the given error */
  code?: Maybe<Scalars['String']['output']>;
  /** The field or fields that produced the error */
  fields?: Maybe<Array<Scalars['String']['output']>>;
  /** The human readable error message */
  message?: Maybe<Scalars['String']['output']>;
  /** The path to the field that produced the error */
  path?: Maybe<Array<Scalars['String']['output']>>;
  /** A shorter error message, with vars not replaced */
  shortMessage?: Maybe<Scalars['String']['output']>;
  /** Replacements for the short message */
  vars?: Maybe<Scalars['Json']['output']>;
};

export type PendingApproval = {
  approvalDeadline?: Maybe<Scalars['DateTime']['output']>;
  courseId?: Maybe<Scalars['ID']['output']>;
  eventId?: Maybe<Scalars['ID']['output']>;
  id: Scalars['ID']['output'];
  kind: Scalars['String']['output'];
  status: Scalars['String']['output'];
  userId: Scalars['ID']['output'];
  workspaceId: Scalars['ID']['output'];
};

export type PermissionMatrixPayload = {
  roles: Array<PermissionMatrixRow>;
};

export type PermissionMatrixRow = {
  abilities: Array<AbilityGrant>;
  /** 角色名：owner / admin / member / tutor / volunteer / learner */
  name: Scalars['String']['output'];
};

export type PortfolioItem = {
  description?: Maybe<Scalars['String']['output']>;
  icon: Scalars['String']['output'];
  /** per-workspace 作品集条目（ADR-0004） */
  id: Scalars['ID']['output'];
  title: Scalars['String']['output'];
  url?: Maybe<Scalars['String']['output']>;
  workspaceId: Scalars['ID']['output'];
};

export type ReassignWorkspaceOwnerInput = {
  /** 改发 pending-owner 邀请给新邮箱（preauthorized [:owner]，带 expires_at） */
  ownerEmail?: InputMaybe<Scalars['String']['input']>;
  /** 改指现有用户为 Owner（建 Owner membership） */
  ownerUserId?: InputMaybe<Scalars['ID']['input']>;
};

export type ReassignWorkspaceOwnerMetadata = {
  /** 新 pending-owner 邀请明文 token（仅返回一次，不落库） */
  ownerInvitationToken?: Maybe<Scalars['String']['output']>;
};

/** The result of the :reassign_workspace_owner mutation */
export type ReassignWorkspaceOwnerResult = {
  /** Any errors generated, if the mutation failed */
  errors: Array<MutationError>;
  /** Metadata produced by the mutation */
  metadata?: Maybe<ReassignWorkspaceOwnerMetadata>;
  /** The successful result of the mutation */
  result?: Maybe<Workspace>;
};

export type RejectEnrollmentInput = {
  rejectionReason?: InputMaybe<Scalars['String']['input']>;
};

/** The result of the :reject_enrollment mutation */
export type RejectEnrollmentResult = {
  /** Any errors generated, if the mutation failed */
  errors: Array<MutationError>;
  /** The successful result of the mutation */
  result?: Maybe<Enrollment>;
};

export type RejectJoinRequestInput = {
  /** 拒绝原因 */
  rejectionReason?: InputMaybe<Scalars['String']['input']>;
};

/** The result of the :reject_join_request mutation */
export type RejectJoinRequestResult = {
  /** Any errors generated, if the mutation failed */
  errors: Array<MutationError>;
  /** The successful result of the mutation */
  result?: Maybe<JoinRequest>;
};

export type RejectWorkspaceApplicationInput = {
  /** 拒绝原因 */
  rejectionReason?: InputMaybe<Scalars['String']['input']>;
};

/** The result of the :reject_workspace_application mutation */
export type RejectWorkspaceApplicationResult = {
  /** Any errors generated, if the mutation failed */
  errors: Array<MutationError>;
  /** The successful result of the mutation */
  result?: Maybe<WorkspaceApplication>;
};

/** The result of the :revoke_invitation mutation */
export type RevokeInvitationResult = {
  /** Any errors generated, if the mutation failed */
  errors: Array<MutationError>;
  /** The successful result of the mutation */
  result?: Maybe<Invitation>;
};

export type Role = {
  /** 角色说明 */
  description?: Maybe<Scalars['String']['output']>;
  id: Scalars['ID']['output'];
  /** 角色名：owner / admin / member / tutor / volunteer / learner */
  name: Scalars['String']['output'];
  /** 所属工作台（租户）ID */
  workspaceId: Scalars['ID']['output'];
};

export type RoleFilterDescription = {
  contains?: InputMaybe<Scalars['String']['input']>;
  eq?: InputMaybe<Scalars['String']['input']>;
  greaterThan?: InputMaybe<Scalars['String']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['String']['input']>;
  ilike?: InputMaybe<Scalars['String']['input']>;
  in?: InputMaybe<Array<InputMaybe<Scalars['String']['input']>>>;
  isDistinctFrom?: InputMaybe<Scalars['String']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['String']['input']>;
  lessThan?: InputMaybe<Scalars['String']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['String']['input']>;
  like?: InputMaybe<Scalars['String']['input']>;
  notEq?: InputMaybe<Scalars['String']['input']>;
  stringEndsWith?: InputMaybe<Scalars['String']['input']>;
  stringStartsWith?: InputMaybe<Scalars['String']['input']>;
};

export type RoleFilterId = {
  eq?: InputMaybe<Scalars['ID']['input']>;
  greaterThan?: InputMaybe<Scalars['ID']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  in?: InputMaybe<Array<Scalars['ID']['input']>>;
  isDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  lessThan?: InputMaybe<Scalars['ID']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  notEq?: InputMaybe<Scalars['ID']['input']>;
};

export type RoleFilterInput = {
  and?: InputMaybe<Array<RoleFilterInput>>;
  /** 角色说明 */
  description?: InputMaybe<RoleFilterDescription>;
  id?: InputMaybe<RoleFilterId>;
  /** 角色名：owner / admin / member / tutor / volunteer / learner */
  name?: InputMaybe<RoleFilterName>;
  not?: InputMaybe<Array<RoleFilterInput>>;
  or?: InputMaybe<Array<RoleFilterInput>>;
  /** 所属工作台（租户）ID */
  workspaceId?: InputMaybe<RoleFilterWorkspaceId>;
};

export type RoleFilterName = {
  eq?: InputMaybe<Scalars['String']['input']>;
  greaterThan?: InputMaybe<Scalars['String']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['String']['input']>;
  in?: InputMaybe<Array<Scalars['String']['input']>>;
  isDistinctFrom?: InputMaybe<Scalars['String']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['String']['input']>;
  lessThan?: InputMaybe<Scalars['String']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['String']['input']>;
  notEq?: InputMaybe<Scalars['String']['input']>;
};

export type RoleFilterWorkspaceId = {
  eq?: InputMaybe<Scalars['ID']['input']>;
  greaterThan?: InputMaybe<Scalars['ID']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  in?: InputMaybe<Array<Scalars['ID']['input']>>;
  isDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  lessThan?: InputMaybe<Scalars['ID']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  notEq?: InputMaybe<Scalars['ID']['input']>;
};

export type RoleSortField =
  | 'DESCRIPTION'
  | 'ID'
  | 'NAME'
  | 'WORKSPACE_ID';

export type RoleSortInput = {
  field: RoleSortField;
  order?: InputMaybe<SortOrder>;
};

export type RootMutationType = {
  /** 接受邀请→建 Membership + 预授权角色入座（#96：手写 resolver 绕过 read policy 记录加载） */
  acceptInvitation?: Maybe<AcceptInvitationResult>;
  /** 使用一次性小程序 scene 接受工作台邀请 */
  admitMemberByToken?: Maybe<Invitation>;
  /** 审批通过加入申请（Owner/Admin，自动建 Membership + MembershipRole） */
  approveJoinRequest: ApproveJoinRequestResult;
  /** 审批通过创建工作台申请（platform_admin，自动创建 workspace + applicant 为 Owner） */
  approveWorkspaceApplication: ApproveWorkspaceApplicationResult;
  /** 分配成员角色（多角色并集，仅 Owner/Admin） */
  assignRoles: AssignRolesResult;
  /** 报名人取消报名；confirmed 报名释放名额 */
  cancelEnrollment: CancelEnrollmentResult;
  /** Owner/Admin 确认 pending 报名并原子占用名额 */
  confirmEnrollment: ConfirmEnrollmentResult;
  /** 创建报名；open/invite_only 立即占位，request 等待审批 */
  createEnrollment: CreateEnrollmentResult;
  /** 创建邀请（Owner/Admin/Volunteer） */
  createInvitation: CreateInvitationResult;
  createInviteBatch: CreateInviteBatchResult;
  /** 提交加入申请 */
  createJoinRequest: CreateJoinRequestResult;
  /** 签发 MCP 连接 token（切片 D #44；明文仅本次经 plainToken 返回一次，库中只存 SHA256 hash） */
  createMcpToken?: Maybe<CreateMcpTokenPayload>;
  /** 在某工作台创建作品集条目（ADR-0004；workspace_id 与 user_id 自动填充，防跨租户伪造） */
  createPortfolioItem?: Maybe<PortfolioItem>;
  /** 创建工作台（仅平台管理员） */
  createWorkspace: CreateWorkspaceResult;
  /** 提交创建工作台申请 */
  createWorkspaceApplication: CreateWorkspaceApplicationResult;
  /** 删除某工作台自己的作品集条目（ADR-0004；tenant 隔离） */
  deletePortfolioItem?: Maybe<PortfolioItem>;
  /** 平台管理员：降级用户 platform_admin（R9；≥1 admin 不变量由 User :demote_platform_admin action 守卫） */
  demoteUser?: Maybe<AdminUserPayload>;
  disableInviteBatch: DisableInviteBatchResult;
  /** Owner/Admin 创建一次性工作台邀请小程序码 */
  generateMiniProgramCode?: Maybe<MiniprogramCodeResult>;
  /** 记录一次小程序订阅消息授权并增加一个可用次数 */
  grantMiniProgramNotificationConsent?: Maybe<Scalars['Int']['output']>;
  /** 直接加入公开工作台（join_policy==:open）→ 建 Membership + learner 角色 */
  joinWorkspace: Workspace;
  /** 平台管理员：提升用户为 platform_admin（R9；仅 platform_admin 可调） */
  promoteUser?: Maybe<AdminUserPayload>;
  /** 重指派 Owner（仅平台管理员，pending-owner 期间）：撤销 active Owner 邀请 + 改指现有用户或发新邀请 */
  reassignWorkspaceOwner: ReassignWorkspaceOwnerResult;
  /** Owner/Admin 拒绝 pending 报名 */
  rejectEnrollment: RejectEnrollmentResult;
  /** 拒绝加入申请（Owner/Admin） */
  rejectJoinRequest: RejectJoinRequestResult;
  /** 拒绝创建工作台申请（platform_admin） */
  rejectWorkspaceApplication: RejectWorkspaceApplicationResult;
  /** 撤销邀请（邀请人本人或 Owner/Admin 或平台管理员） */
  revokeInvitation: RevokeInvitationResult;
  /** 撤销 MCP 连接 token（切片 D #44；仅本人，置 revokedAt 保留审计行；他人 token 一律 not_found 不泄露存在性） */
  revokeMcpToken?: Maybe<McpToken>;
  /** 设置当前用户在某工作台的 UI 主题偏好（ADR-0004 per-workspace） */
  setWorkspaceTheme?: Maybe<WorkspaceProfile>;
  /** 使用邮箱密码登录（#60 路径 B：httpOnly cookie 交付 token） */
  signIn?: Maybe<SignInResult>;
  /** 小程序平台一键登录（N1，Phase 1）：code2session + 平台手机号锚定统一身份，token 经 httpOnly cookie 交付 */
  signInWithPlatform?: Maybe<SignInWithPlatformResult>;
  /** 登出：服务端撤销当前 token 并清除 httpOnly cookie（token 被偷也无法重放） */
  signOut?: Maybe<Scalars['String']['output']>;
  /** 注册新用户（#60 路径 B：httpOnly cookie 交付 token，自动登录） */
  signUp?: Maybe<SignUpPayload>;
  /** 更新当前用户全局显示名（ADR-0004：displayName 保留全局身份字段） */
  updateDisplayName?: Maybe<User>;
  /** 更新某工作台自己的作品集条目（ADR-0004；tenant 隔离） */
  updatePortfolioItem?: Maybe<PortfolioItem>;
  /** 更新工作台（Owner/Admin 或平台管理员） */
  updateWorkspace: UpdateWorkspaceResult;
  /** 更新当前用户在某工作台的资料（ADR-0004 per-workspace） */
  updateWorkspaceProfile?: Maybe<WorkspaceProfile>;
};


export type RootMutationTypeAcceptInvitationArgs = {
  id: Scalars['ID']['input'];
  input: AcceptInvitationInput;
};


export type RootMutationTypeAdmitMemberByTokenArgs = {
  scene: Scalars['String']['input'];
};


export type RootMutationTypeApproveJoinRequestArgs = {
  id: Scalars['ID']['input'];
  input?: InputMaybe<ApproveJoinRequestInput>;
};


export type RootMutationTypeApproveWorkspaceApplicationArgs = {
  id: Scalars['ID']['input'];
};


export type RootMutationTypeAssignRolesArgs = {
  id: Scalars['ID']['input'];
  input: AssignRolesInput;
};


export type RootMutationTypeCancelEnrollmentArgs = {
  id: Scalars['ID']['input'];
};


export type RootMutationTypeConfirmEnrollmentArgs = {
  id: Scalars['ID']['input'];
};


export type RootMutationTypeCreateEnrollmentArgs = {
  input: CreateEnrollmentInput;
};


export type RootMutationTypeCreateInvitationArgs = {
  input: CreateInvitationInput;
};


export type RootMutationTypeCreateInviteBatchArgs = {
  input: CreateInviteBatchInput;
};


export type RootMutationTypeCreateJoinRequestArgs = {
  input: CreateJoinRequestInput;
};


export type RootMutationTypeCreateMcpTokenArgs = {
  name: Scalars['String']['input'];
};


export type RootMutationTypeCreatePortfolioItemArgs = {
  input: CreatePortfolioItemInput;
  workspaceId: Scalars['ID']['input'];
};


export type RootMutationTypeCreateWorkspaceArgs = {
  input: CreateWorkspaceInput;
};


export type RootMutationTypeCreateWorkspaceApplicationArgs = {
  input: CreateWorkspaceApplicationInput;
};


export type RootMutationTypeDeletePortfolioItemArgs = {
  id: Scalars['ID']['input'];
  workspaceId: Scalars['ID']['input'];
};


export type RootMutationTypeDemoteUserArgs = {
  id: Scalars['ID']['input'];
};


export type RootMutationTypeDisableInviteBatchArgs = {
  id: Scalars['ID']['input'];
};


export type RootMutationTypeGenerateMiniProgramCodeArgs = {
  platform: Scalars['String']['input'];
  workspaceId: Scalars['ID']['input'];
};


export type RootMutationTypeGrantMiniProgramNotificationConsentArgs = {
  platform: Scalars['String']['input'];
  templateKey: Scalars['String']['input'];
};


export type RootMutationTypeJoinWorkspaceArgs = {
  input: JoinWorkspaceInput;
};


export type RootMutationTypePromoteUserArgs = {
  id: Scalars['ID']['input'];
};


export type RootMutationTypeReassignWorkspaceOwnerArgs = {
  id: Scalars['ID']['input'];
  input?: InputMaybe<ReassignWorkspaceOwnerInput>;
};


export type RootMutationTypeRejectEnrollmentArgs = {
  id: Scalars['ID']['input'];
  input?: InputMaybe<RejectEnrollmentInput>;
};


export type RootMutationTypeRejectJoinRequestArgs = {
  id: Scalars['ID']['input'];
  input?: InputMaybe<RejectJoinRequestInput>;
};


export type RootMutationTypeRejectWorkspaceApplicationArgs = {
  id: Scalars['ID']['input'];
  input?: InputMaybe<RejectWorkspaceApplicationInput>;
};


export type RootMutationTypeRevokeInvitationArgs = {
  id: Scalars['ID']['input'];
};


export type RootMutationTypeRevokeMcpTokenArgs = {
  id: Scalars['ID']['input'];
};


export type RootMutationTypeSetWorkspaceThemeArgs = {
  input: SetWorkspaceThemeInput;
  workspaceId: Scalars['ID']['input'];
};


export type RootMutationTypeSignInArgs = {
  email: Scalars['String']['input'];
  password: Scalars['String']['input'];
};


export type RootMutationTypeSignInWithPlatformArgs = {
  code: Scalars['String']['input'];
  encryptedData: Scalars['String']['input'];
  iv: Scalars['String']['input'];
  platform: Scalars['String']['input'];
};


export type RootMutationTypeSignUpArgs = {
  input: SignUpInput;
};


export type RootMutationTypeUpdateDisplayNameArgs = {
  displayName: Scalars['String']['input'];
};


export type RootMutationTypeUpdatePortfolioItemArgs = {
  id: Scalars['ID']['input'];
  input: UpdatePortfolioItemInput;
  workspaceId: Scalars['ID']['input'];
};


export type RootMutationTypeUpdateWorkspaceArgs = {
  id: Scalars['ID']['input'];
  input?: InputMaybe<UpdateWorkspaceInput>;
};


export type RootMutationTypeUpdateWorkspaceProfileArgs = {
  input: UpdateWorkspaceProfileInput;
  workspaceId: Scalars['ID']['input'];
};

export type RootQueryType = {
  enrollments?: Maybe<KeysetPageOfEnrollment>;
  /** 按 id 获取课程（#40） */
  getCourse?: Maybe<Course>;
  /** 按 id 获取活动（#40） */
  getEvent?: Maybe<Event>;
  /** 按 id 获取 workflow run 详情（#40） */
  getWorkflowRun?: Maybe<WorkflowRun>;
  /** 按 slug 获取工作台（需登录） */
  getWorkspace?: Maybe<Workspace>;
  /** 按 id 获取工作台（需登录） */
  getWorkspaceById?: Maybe<Workspace>;
  /** 邀请列表（邀请人仅见自己；Owner/Admin 见全部） */
  invitations?: Maybe<KeysetPageOfInvitation>;
  inviteBatches?: Maybe<KeysetPageOfInviteBatch>;
  /** 加入申请列表（申请人仅见自己；Owner/Admin 见全部） */
  joinRequests?: Maybe<KeysetPageOfJoinRequest>;
  /** 平台管理员：治理操作留痕（#116 R10a；action 过滤，分页 first/after） */
  listAdminActionLogs: Array<AdminActionLog>;
  /** 工作台的课程列表（#40 展示页） */
  listCourses?: Maybe<KeysetPageOfCourse>;
  /** 工作台的活动列表（#40 展示页） */
  listEvents?: Maybe<KeysetPageOfEvent>;
  /** 平台管理员：MCP 待确认操作日志（R10；workspaceId 按 params JSONB 过滤，D5） */
  listPendingOperations: Array<AdminPendingOperation>;
  /** 平台管理员：workflow 信号日志（R10；workspaceId 按真实列过滤，分页 first/after） */
  listSignalLogs: Array<AdminSignalLog>;
  /** 平台管理员：MCP 工具调用审计日志（R10；workspaceId 按 params JSONB 过滤，D5） */
  listToolCallLogs: Array<AdminToolCallLog>;
  /** 平台管理员：用户列表（R8；search 匹配 email/display_name，分页 first/after） */
  listUsers: Array<AdminUser>;
  /** 工作台的 workflow run 列表（#40 展示页） */
  listWorkflowRuns?: Maybe<KeysetPageOfWorkflowRun>;
  /** 平台管理员：工作台创建申请列表（R7；status 过滤，分页 first/after） */
  listWorkspaceApplications: Array<AdminWorkspaceApplication>;
  /** 平台管理员：工作台列表（R13；search 匹配 name/slug，分页 first/after） */
  listWorkspaces: Array<AdminWorkspace>;
  /** 当前登录用户个人资料（#68 Profile API，需登录）：id/email/displayName/isPlatformAdmin + memberNumber/joinedAt（ADR-0004 收窄为全局身份） */
  me?: Maybe<User>;
  /** 当前用户可进入的工作台列表（成员资格 + 创建者） */
  meWorkspaces: Array<Workspace>;
  /** 当前用户的 MCP 连接 token 列表（切片 D #44；不含明文，新→旧；policy 仅见本人） */
  myMcpTokens?: Maybe<Array<Maybe<McpToken>>>;
  /** 当前用户作为 Owner/Admin 的跨工作台待审批项（Enrollment + JoinRequest） */
  myPendingApprovals: Array<PendingApproval>;
  /** 当前用户（申请人）的工作台创建申请列表（R7a；任何人可见自己的申请） */
  myWorkspaceApplications: Array<AdminWorkspaceApplication>;
  /** 当前用户在某工作台的作品集条目列表（ADR-0004 per-workspace） */
  myWorkspacePortfolio?: Maybe<Array<Maybe<PortfolioItem>>>;
  /** 角色权限矩阵（#66 Rbac）：六角色 × 六能力，对齐前端权限表（需登录；#1 能力接口：abilities 为通用列表） */
  permissionMatrix?: Maybe<PermissionMatrixPayload>;
  /** Placeholder query until the first resource is added */
  ping?: Maybe<Scalars['String']['output']>;
  /** 校验邀请 token，返回邀请信息 + 工作台预览 */
  validateInvitation?: Maybe<Invitation>;
  /** 工作台创建申请列表（申请人仅见自己；platform_admin 见全部） */
  workspaceApplications?: Maybe<KeysetPageOfWorkspaceApplication>;
  /** 工作台成员列表（成员本人仅见自己；Owner/Admin 见全部，供成员管理页） */
  workspaceMembers?: Maybe<KeysetPageOfWorkspaceMembership>;
  /** 当前用户在某工作台的公开资料（ADR-0004 per-workspace；按 visibility 授权） */
  workspaceProfile?: Maybe<WorkspaceProfile>;
};


export type RootQueryTypeEnrollmentsArgs = {
  after?: InputMaybe<Scalars['String']['input']>;
  before?: InputMaybe<Scalars['String']['input']>;
  filter?: InputMaybe<EnrollmentFilterInput>;
  first?: InputMaybe<Scalars['Int']['input']>;
  last?: InputMaybe<Scalars['Int']['input']>;
  sort?: InputMaybe<Array<InputMaybe<EnrollmentSortInput>>>;
};


export type RootQueryTypeGetCourseArgs = {
  filter?: InputMaybe<CourseFilterInput>;
  id: Scalars['ID']['input'];
};


export type RootQueryTypeGetEventArgs = {
  filter?: InputMaybe<EventFilterInput>;
  id: Scalars['ID']['input'];
};


export type RootQueryTypeGetWorkflowRunArgs = {
  filter?: InputMaybe<WorkflowRunFilterInput>;
  id: Scalars['ID']['input'];
};


export type RootQueryTypeGetWorkspaceArgs = {
  filter?: InputMaybe<WorkspaceFilterInput>;
  slug: Scalars['String']['input'];
};


export type RootQueryTypeGetWorkspaceByIdArgs = {
  filter?: InputMaybe<WorkspaceFilterInput>;
  id: Scalars['ID']['input'];
};


export type RootQueryTypeInvitationsArgs = {
  after?: InputMaybe<Scalars['String']['input']>;
  before?: InputMaybe<Scalars['String']['input']>;
  filter?: InputMaybe<InvitationFilterInput>;
  first?: InputMaybe<Scalars['Int']['input']>;
  last?: InputMaybe<Scalars['Int']['input']>;
  sort?: InputMaybe<Array<InputMaybe<InvitationSortInput>>>;
};


export type RootQueryTypeInviteBatchesArgs = {
  after?: InputMaybe<Scalars['String']['input']>;
  before?: InputMaybe<Scalars['String']['input']>;
  filter?: InputMaybe<InviteBatchFilterInput>;
  first?: InputMaybe<Scalars['Int']['input']>;
  last?: InputMaybe<Scalars['Int']['input']>;
  sort?: InputMaybe<Array<InputMaybe<InviteBatchSortInput>>>;
};


export type RootQueryTypeJoinRequestsArgs = {
  after?: InputMaybe<Scalars['String']['input']>;
  before?: InputMaybe<Scalars['String']['input']>;
  filter?: InputMaybe<JoinRequestFilterInput>;
  first?: InputMaybe<Scalars['Int']['input']>;
  last?: InputMaybe<Scalars['Int']['input']>;
  sort?: InputMaybe<Array<InputMaybe<JoinRequestSortInput>>>;
};


export type RootQueryTypeListAdminActionLogsArgs = {
  action?: InputMaybe<Scalars['String']['input']>;
  after?: InputMaybe<Scalars['String']['input']>;
  first?: InputMaybe<Scalars['Int']['input']>;
  insertedAfter?: InputMaybe<Scalars['DateTime']['input']>;
  insertedBefore?: InputMaybe<Scalars['DateTime']['input']>;
};


export type RootQueryTypeListCoursesArgs = {
  after?: InputMaybe<Scalars['String']['input']>;
  before?: InputMaybe<Scalars['String']['input']>;
  filter?: InputMaybe<CourseFilterInput>;
  first?: InputMaybe<Scalars['Int']['input']>;
  last?: InputMaybe<Scalars['Int']['input']>;
  sort?: InputMaybe<Array<InputMaybe<CourseSortInput>>>;
};


export type RootQueryTypeListEventsArgs = {
  after?: InputMaybe<Scalars['String']['input']>;
  before?: InputMaybe<Scalars['String']['input']>;
  filter?: InputMaybe<EventFilterInput>;
  first?: InputMaybe<Scalars['Int']['input']>;
  last?: InputMaybe<Scalars['Int']['input']>;
  sort?: InputMaybe<Array<InputMaybe<EventSortInput>>>;
};


export type RootQueryTypeListPendingOperationsArgs = {
  after?: InputMaybe<Scalars['String']['input']>;
  first?: InputMaybe<Scalars['Int']['input']>;
  insertedAfter?: InputMaybe<Scalars['DateTime']['input']>;
  insertedBefore?: InputMaybe<Scalars['DateTime']['input']>;
  status?: InputMaybe<Scalars['String']['input']>;
  workspaceId?: InputMaybe<Scalars['ID']['input']>;
};


export type RootQueryTypeListSignalLogsArgs = {
  after?: InputMaybe<Scalars['String']['input']>;
  first?: InputMaybe<Scalars['Int']['input']>;
  insertedAfter?: InputMaybe<Scalars['DateTime']['input']>;
  insertedBefore?: InputMaybe<Scalars['DateTime']['input']>;
  signalType?: InputMaybe<Scalars['String']['input']>;
  workspaceId?: InputMaybe<Scalars['ID']['input']>;
};


export type RootQueryTypeListToolCallLogsArgs = {
  after?: InputMaybe<Scalars['String']['input']>;
  first?: InputMaybe<Scalars['Int']['input']>;
  insertedAfter?: InputMaybe<Scalars['DateTime']['input']>;
  insertedBefore?: InputMaybe<Scalars['DateTime']['input']>;
  status?: InputMaybe<Scalars['String']['input']>;
  workspaceId?: InputMaybe<Scalars['ID']['input']>;
};


export type RootQueryTypeListUsersArgs = {
  after?: InputMaybe<Scalars['String']['input']>;
  first?: InputMaybe<Scalars['Int']['input']>;
  search?: InputMaybe<Scalars['String']['input']>;
};


export type RootQueryTypeListWorkflowRunsArgs = {
  after?: InputMaybe<Scalars['String']['input']>;
  before?: InputMaybe<Scalars['String']['input']>;
  filter?: InputMaybe<WorkflowRunFilterInput>;
  first?: InputMaybe<Scalars['Int']['input']>;
  last?: InputMaybe<Scalars['Int']['input']>;
  sort?: InputMaybe<Array<InputMaybe<WorkflowRunSortInput>>>;
};


export type RootQueryTypeListWorkspaceApplicationsArgs = {
  after?: InputMaybe<Scalars['String']['input']>;
  first?: InputMaybe<Scalars['Int']['input']>;
  status?: InputMaybe<Scalars['String']['input']>;
};


export type RootQueryTypeListWorkspacesArgs = {
  after?: InputMaybe<Scalars['String']['input']>;
  first?: InputMaybe<Scalars['Int']['input']>;
  search?: InputMaybe<Scalars['String']['input']>;
};


export type RootQueryTypeMeWorkspacesArgs = {
  filter?: InputMaybe<WorkspaceFilterInput>;
  sort?: InputMaybe<Array<InputMaybe<WorkspaceSortInput>>>;
};


export type RootQueryTypeMyWorkspacePortfolioArgs = {
  workspaceId: Scalars['ID']['input'];
};


export type RootQueryTypeValidateInvitationArgs = {
  filter?: InputMaybe<InvitationFilterInput>;
  token: Scalars['String']['input'];
};


export type RootQueryTypeWorkspaceApplicationsArgs = {
  after?: InputMaybe<Scalars['String']['input']>;
  before?: InputMaybe<Scalars['String']['input']>;
  filter?: InputMaybe<WorkspaceApplicationFilterInput>;
  first?: InputMaybe<Scalars['Int']['input']>;
  last?: InputMaybe<Scalars['Int']['input']>;
  sort?: InputMaybe<Array<InputMaybe<WorkspaceApplicationSortInput>>>;
};


export type RootQueryTypeWorkspaceMembersArgs = {
  after?: InputMaybe<Scalars['String']['input']>;
  before?: InputMaybe<Scalars['String']['input']>;
  filter?: InputMaybe<WorkspaceMembershipFilterInput>;
  first?: InputMaybe<Scalars['Int']['input']>;
  last?: InputMaybe<Scalars['Int']['input']>;
  sort?: InputMaybe<Array<InputMaybe<WorkspaceMembershipSortInput>>>;
};


export type RootQueryTypeWorkspaceProfileArgs = {
  workspaceId: Scalars['ID']['input'];
};

export type SetWorkspaceThemeInput = {
  /** setWorkspaceTheme 输入：uiThemePreference 必填，仅 dark | light */
  uiThemePreference: Scalars['String']['input'];
};

export type SignInResult = {
  email: Scalars['String']['output'];
  id: Scalars['ID']['output'];
  isPlatformAdmin: Scalars['Boolean']['output'];
};

export type SignInWithPlatformResult = {
  email?: Maybe<Scalars['String']['output']>;
  id: Scalars['ID']['output'];
  isPlatformAdmin: Scalars['Boolean']['output'];
};

export type SignUpInput = {
  email: Scalars['String']['input'];
  password: Scalars['String']['input'];
};

export type SignUpPayload = {
  errors?: Maybe<Array<Maybe<MutationError>>>;
  result?: Maybe<SignUpUser>;
};

export type SignUpUser = {
  email: Scalars['String']['output'];
  id: Scalars['ID']['output'];
  isPlatformAdmin: Scalars['Boolean']['output'];
};

export type SortOrder =
  | 'ASC'
  | 'ASC_NULLS_FIRST'
  | 'ASC_NULLS_LAST'
  | 'DESC'
  | 'DESC_NULLS_FIRST'
  | 'DESC_NULLS_LAST';

export type UpdatePortfolioItemInput = {
  description?: InputMaybe<Scalars['String']['input']>;
  icon?: InputMaybe<Scalars['String']['input']>;
  /** updatePortfolioItem 输入：title/description/url/icon 可选 */
  title?: InputMaybe<Scalars['String']['input']>;
  url?: InputMaybe<Scalars['String']['input']>;
};

export type UpdateWorkspaceInput = {
  /** 加入策略：open 公开直接加入 / request 公开申请审批 / invite_only 私密仅邀请 */
  joinPolicy?: InputMaybe<Scalars['String']['input']>;
  /** 工作台名称 */
  name?: InputMaybe<Scalars['String']['input']>;
  /** 工作台唯一标识（小写字母/数字/连字符，创建者提供） */
  slug?: InputMaybe<Scalars['String']['input']>;
  /** 是否开放赞助入口（默认开） */
  sponsorshipEnabled?: InputMaybe<Scalars['Boolean']['input']>;
};

export type UpdateWorkspaceProfileInput = {
  about?: InputMaybe<Scalars['String']['input']>;
  /** updateWorkspaceProfile 输入（ADR-0004）：avatarUrl/location/about/skills/visibility 可选 */
  avatarUrl?: InputMaybe<Scalars['String']['input']>;
  location?: InputMaybe<Scalars['String']['input']>;
  skills?: InputMaybe<Array<InputMaybe<Scalars['String']['input']>>>;
  visibility?: InputMaybe<Scalars['String']['input']>;
};

/** The result of the :update_workspace mutation */
export type UpdateWorkspaceResult = {
  /** Any errors generated, if the mutation failed */
  errors: Array<MutationError>;
  /** The successful result of the mutation */
  result?: Maybe<Workspace>;
};

export type User = {
  /** 显示名（全局身份字段；可为 null，前端以 email 前缀兜底） */
  displayName?: Maybe<Scalars['String']['output']>;
  /** 用户邮箱（全局唯一；小程序手机号用户为 null——Phase 1 起放宽可空） */
  email?: Maybe<Scalars['String']['output']>;
  id: Scalars['ID']['output'];
  /** 是否平台管理员（全局标记） */
  isPlatformAdmin: Scalars['Boolean']['output'];
  /** 注册（加入）时间 */
  joinedAt?: Maybe<Scalars['DateTime']['output']>;
  /** 平台级成员编号（P1 由用户 id 确定性生成，格式 CGC-XXXXXX，稳定唯一） */
  memberNumber?: Maybe<Scalars['String']['output']>;
};

export type WorkflowRun = {
  /** 绑定的 WorkflowDefinition ID */
  definitionId: Scalars['ID']['output'];
  /** 绑定的定义版本号（D-A2 版本快照，已开始 run 不随后续版本变动） */
  definitionVersion: Scalars['Int']['output'];
  /** 执行产物 facts（按 step_key 聚合，引擎执行后写入） */
  facts?: Maybe<Scalars['JsonString']['output']>;
  /** 结束时间（终态 action 写入） */
  finishedAt?: Maybe<Scalars['DateTime']['output']>;
  id: Scalars['ID']['output'];
  /** run 输入快照（创建时固化，执行引擎按此驱动） */
  inputSnapshot?: Maybe<Scalars['JsonString']['output']>;
  /** Jido partition（= workspace_id，ADR-0002 决策 6 运行时隔离） */
  partitionId?: Maybe<Scalars['ID']['output']>;
  /** 开始执行时间（start action 写入） */
  startedAt?: Maybe<Scalars['DateTime']['output']>;
  /** 执行状态机：pending/running/waiting/succeeded/failed/cancelled/expired */
  status: Scalars['String']['output'];
  /** 乐观锁版本号，每次状态流转 +1 */
  version: Scalars['Int']['output'];
  /** 所属工作台（租户）ID */
  workspaceId: Scalars['ID']['output'];
};

export type WorkflowRunFilterDefinitionId = {
  eq?: InputMaybe<Scalars['ID']['input']>;
  greaterThan?: InputMaybe<Scalars['ID']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  in?: InputMaybe<Array<Scalars['ID']['input']>>;
  isDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  lessThan?: InputMaybe<Scalars['ID']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  notEq?: InputMaybe<Scalars['ID']['input']>;
};

export type WorkflowRunFilterDefinitionVersion = {
  eq?: InputMaybe<Scalars['Int']['input']>;
  greaterThan?: InputMaybe<Scalars['Int']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['Int']['input']>;
  in?: InputMaybe<Array<Scalars['Int']['input']>>;
  isDistinctFrom?: InputMaybe<Scalars['Int']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['Int']['input']>;
  lessThan?: InputMaybe<Scalars['Int']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['Int']['input']>;
  notEq?: InputMaybe<Scalars['Int']['input']>;
};

export type WorkflowRunFilterFacts = {
  eq?: InputMaybe<Scalars['JsonString']['input']>;
  greaterThan?: InputMaybe<Scalars['JsonString']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['JsonString']['input']>;
  in?: InputMaybe<Array<InputMaybe<Scalars['JsonString']['input']>>>;
  isDistinctFrom?: InputMaybe<Scalars['JsonString']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['JsonString']['input']>;
  lessThan?: InputMaybe<Scalars['JsonString']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['JsonString']['input']>;
  notEq?: InputMaybe<Scalars['JsonString']['input']>;
};

export type WorkflowRunFilterFinishedAt = {
  eq?: InputMaybe<Scalars['DateTime']['input']>;
  greaterThan?: InputMaybe<Scalars['DateTime']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['DateTime']['input']>;
  in?: InputMaybe<Array<InputMaybe<Scalars['DateTime']['input']>>>;
  isDistinctFrom?: InputMaybe<Scalars['DateTime']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['DateTime']['input']>;
  lessThan?: InputMaybe<Scalars['DateTime']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['DateTime']['input']>;
  notEq?: InputMaybe<Scalars['DateTime']['input']>;
};

export type WorkflowRunFilterId = {
  eq?: InputMaybe<Scalars['ID']['input']>;
  greaterThan?: InputMaybe<Scalars['ID']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  in?: InputMaybe<Array<Scalars['ID']['input']>>;
  isDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  lessThan?: InputMaybe<Scalars['ID']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  notEq?: InputMaybe<Scalars['ID']['input']>;
};

export type WorkflowRunFilterInput = {
  and?: InputMaybe<Array<WorkflowRunFilterInput>>;
  /** 绑定的 WorkflowDefinition ID */
  definitionId?: InputMaybe<WorkflowRunFilterDefinitionId>;
  /** 绑定的定义版本号（D-A2 版本快照，已开始 run 不随后续版本变动） */
  definitionVersion?: InputMaybe<WorkflowRunFilterDefinitionVersion>;
  /** 执行产物 facts（按 step_key 聚合，引擎执行后写入） */
  facts?: InputMaybe<WorkflowRunFilterFacts>;
  /** 结束时间（终态 action 写入） */
  finishedAt?: InputMaybe<WorkflowRunFilterFinishedAt>;
  id?: InputMaybe<WorkflowRunFilterId>;
  /** run 输入快照（创建时固化，执行引擎按此驱动） */
  inputSnapshot?: InputMaybe<WorkflowRunFilterInputSnapshot>;
  not?: InputMaybe<Array<WorkflowRunFilterInput>>;
  or?: InputMaybe<Array<WorkflowRunFilterInput>>;
  /** Jido partition（= workspace_id，ADR-0002 决策 6 运行时隔离） */
  partitionId?: InputMaybe<WorkflowRunFilterPartitionId>;
  /** 开始执行时间（start action 写入） */
  startedAt?: InputMaybe<WorkflowRunFilterStartedAt>;
  /** 执行状态机：pending/running/waiting/succeeded/failed/cancelled/expired */
  status?: InputMaybe<WorkflowRunFilterStatus>;
  /** 乐观锁版本号，每次状态流转 +1 */
  version?: InputMaybe<WorkflowRunFilterVersion>;
  /** 所属工作台（租户）ID */
  workspaceId?: InputMaybe<WorkflowRunFilterWorkspaceId>;
};

export type WorkflowRunFilterInputSnapshot = {
  eq?: InputMaybe<Scalars['JsonString']['input']>;
  greaterThan?: InputMaybe<Scalars['JsonString']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['JsonString']['input']>;
  in?: InputMaybe<Array<InputMaybe<Scalars['JsonString']['input']>>>;
  isDistinctFrom?: InputMaybe<Scalars['JsonString']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['JsonString']['input']>;
  lessThan?: InputMaybe<Scalars['JsonString']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['JsonString']['input']>;
  notEq?: InputMaybe<Scalars['JsonString']['input']>;
};

export type WorkflowRunFilterPartitionId = {
  eq?: InputMaybe<Scalars['ID']['input']>;
  greaterThan?: InputMaybe<Scalars['ID']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  in?: InputMaybe<Array<InputMaybe<Scalars['ID']['input']>>>;
  isDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  lessThan?: InputMaybe<Scalars['ID']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  notEq?: InputMaybe<Scalars['ID']['input']>;
};

export type WorkflowRunFilterStartedAt = {
  eq?: InputMaybe<Scalars['DateTime']['input']>;
  greaterThan?: InputMaybe<Scalars['DateTime']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['DateTime']['input']>;
  in?: InputMaybe<Array<InputMaybe<Scalars['DateTime']['input']>>>;
  isDistinctFrom?: InputMaybe<Scalars['DateTime']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['DateTime']['input']>;
  lessThan?: InputMaybe<Scalars['DateTime']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['DateTime']['input']>;
  notEq?: InputMaybe<Scalars['DateTime']['input']>;
};

export type WorkflowRunFilterStatus = {
  eq?: InputMaybe<Scalars['String']['input']>;
  greaterThan?: InputMaybe<Scalars['String']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['String']['input']>;
  in?: InputMaybe<Array<Scalars['String']['input']>>;
  isDistinctFrom?: InputMaybe<Scalars['String']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['String']['input']>;
  lessThan?: InputMaybe<Scalars['String']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['String']['input']>;
  notEq?: InputMaybe<Scalars['String']['input']>;
};

export type WorkflowRunFilterVersion = {
  eq?: InputMaybe<Scalars['Int']['input']>;
  greaterThan?: InputMaybe<Scalars['Int']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['Int']['input']>;
  in?: InputMaybe<Array<Scalars['Int']['input']>>;
  isDistinctFrom?: InputMaybe<Scalars['Int']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['Int']['input']>;
  lessThan?: InputMaybe<Scalars['Int']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['Int']['input']>;
  notEq?: InputMaybe<Scalars['Int']['input']>;
};

export type WorkflowRunFilterWorkspaceId = {
  eq?: InputMaybe<Scalars['ID']['input']>;
  greaterThan?: InputMaybe<Scalars['ID']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  in?: InputMaybe<Array<Scalars['ID']['input']>>;
  isDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  lessThan?: InputMaybe<Scalars['ID']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  notEq?: InputMaybe<Scalars['ID']['input']>;
};

export type WorkflowRunSortField =
  | 'DEFINITION_ID'
  | 'DEFINITION_VERSION'
  | 'FACTS'
  | 'FINISHED_AT'
  | 'ID'
  | 'INPUT_SNAPSHOT'
  | 'PARTITION_ID'
  | 'STARTED_AT'
  | 'STATUS'
  | 'VERSION'
  | 'WORKSPACE_ID';

export type WorkflowRunSortInput = {
  field: WorkflowRunSortField;
  order?: InputMaybe<SortOrder>;
};

export type Workspace = {
  /** 当前用户是否可进入该工作台（成员/创建者） */
  canAccess?: Maybe<Scalars['Boolean']['output']>;
  id: Scalars['ID']['output'];
  /** 加入策略：open 公开直接加入 / request 公开申请审批 / invite_only 私密仅邀请 */
  joinPolicy: Scalars['String']['output'];
  /** 成员数量（P1 计算字段，SQL count(memberships)） */
  memberCount?: Maybe<Scalars['Int']['output']>;
  /** 当前用户在该工作台的能力列表（能力接口，与 Rbac.abilities_for/2 一致） */
  myAbilities?: Maybe<Array<Scalars['String']['output']>>;
  /** 当前用户在该工作台的成员资格 ID（非成员为 null） */
  myMembershipId?: Maybe<Scalars['ID']['output']>;
  /** 当前用户在该工作台的角色名数组（非成员为 []） */
  myRoleNames?: Maybe<Array<Scalars['String']['output']>>;
  /** 工作台名称 */
  name: Scalars['String']['output'];
  /** 工作台唯一标识（小写字母/数字/连字符，创建者提供） */
  slug: Scalars['String']['output'];
  /** 是否开放赞助入口（默认开） */
  sponsorshipEnabled: Scalars['Boolean']['output'];
};

export type WorkspaceApplication = {
  /** 申请人（全局用户）ID */
  applicantId: Scalars['ID']['output'];
  /** 审批截止时间（默认 created_at + 7 天） */
  approvalDeadline?: Maybe<Scalars['DateTime']['output']>;
  /** 审批时间 */
  approvedAt?: Maybe<Scalars['DateTime']['output']>;
  /** 审批人（platform_admin）ID */
  approvedBy?: Maybe<Scalars['ID']['output']>;
  /** 过期时间 */
  expiredAt?: Maybe<Scalars['DateTime']['output']>;
  id: Scalars['ID']['output'];
  /** 申请创建的工作台名称 */
  name: Scalars['String']['output'];
  /** 申请目的 */
  purpose: Scalars['String']['output'];
  /** 拒绝时间 */
  rejectedAt?: Maybe<Scalars['DateTime']['output']>;
  /** 拒绝人（platform_admin）ID */
  rejectedBy?: Maybe<Scalars['ID']['output']>;
  /** 拒绝原因（可选） */
  rejectionReason?: Maybe<Scalars['String']['output']>;
  /** 申请创建的工作台 slug（创建时校验全局唯一） */
  slug: Scalars['String']['output'];
  /** 申请状态 */
  status: Scalars['String']['output'];
};

export type WorkspaceApplicationFilterApplicantId = {
  eq?: InputMaybe<Scalars['ID']['input']>;
  greaterThan?: InputMaybe<Scalars['ID']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  in?: InputMaybe<Array<Scalars['ID']['input']>>;
  isDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  lessThan?: InputMaybe<Scalars['ID']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  notEq?: InputMaybe<Scalars['ID']['input']>;
};

export type WorkspaceApplicationFilterApprovalDeadline = {
  eq?: InputMaybe<Scalars['DateTime']['input']>;
  greaterThan?: InputMaybe<Scalars['DateTime']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['DateTime']['input']>;
  in?: InputMaybe<Array<InputMaybe<Scalars['DateTime']['input']>>>;
  isDistinctFrom?: InputMaybe<Scalars['DateTime']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['DateTime']['input']>;
  lessThan?: InputMaybe<Scalars['DateTime']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['DateTime']['input']>;
  notEq?: InputMaybe<Scalars['DateTime']['input']>;
};

export type WorkspaceApplicationFilterApprovedAt = {
  eq?: InputMaybe<Scalars['DateTime']['input']>;
  greaterThan?: InputMaybe<Scalars['DateTime']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['DateTime']['input']>;
  in?: InputMaybe<Array<InputMaybe<Scalars['DateTime']['input']>>>;
  isDistinctFrom?: InputMaybe<Scalars['DateTime']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['DateTime']['input']>;
  lessThan?: InputMaybe<Scalars['DateTime']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['DateTime']['input']>;
  notEq?: InputMaybe<Scalars['DateTime']['input']>;
};

export type WorkspaceApplicationFilterApprovedBy = {
  eq?: InputMaybe<Scalars['ID']['input']>;
  greaterThan?: InputMaybe<Scalars['ID']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  in?: InputMaybe<Array<InputMaybe<Scalars['ID']['input']>>>;
  isDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  lessThan?: InputMaybe<Scalars['ID']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  notEq?: InputMaybe<Scalars['ID']['input']>;
};

export type WorkspaceApplicationFilterExpiredAt = {
  eq?: InputMaybe<Scalars['DateTime']['input']>;
  greaterThan?: InputMaybe<Scalars['DateTime']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['DateTime']['input']>;
  in?: InputMaybe<Array<InputMaybe<Scalars['DateTime']['input']>>>;
  isDistinctFrom?: InputMaybe<Scalars['DateTime']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['DateTime']['input']>;
  lessThan?: InputMaybe<Scalars['DateTime']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['DateTime']['input']>;
  notEq?: InputMaybe<Scalars['DateTime']['input']>;
};

export type WorkspaceApplicationFilterId = {
  eq?: InputMaybe<Scalars['ID']['input']>;
  greaterThan?: InputMaybe<Scalars['ID']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  in?: InputMaybe<Array<Scalars['ID']['input']>>;
  isDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  lessThan?: InputMaybe<Scalars['ID']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  notEq?: InputMaybe<Scalars['ID']['input']>;
};

export type WorkspaceApplicationFilterInput = {
  and?: InputMaybe<Array<WorkspaceApplicationFilterInput>>;
  /** 申请人（全局用户）ID */
  applicantId?: InputMaybe<WorkspaceApplicationFilterApplicantId>;
  /** 审批截止时间（默认 created_at + 7 天） */
  approvalDeadline?: InputMaybe<WorkspaceApplicationFilterApprovalDeadline>;
  /** 审批时间 */
  approvedAt?: InputMaybe<WorkspaceApplicationFilterApprovedAt>;
  /** 审批人（platform_admin）ID */
  approvedBy?: InputMaybe<WorkspaceApplicationFilterApprovedBy>;
  /** 过期时间 */
  expiredAt?: InputMaybe<WorkspaceApplicationFilterExpiredAt>;
  id?: InputMaybe<WorkspaceApplicationFilterId>;
  /** 申请创建的工作台名称 */
  name?: InputMaybe<WorkspaceApplicationFilterName>;
  not?: InputMaybe<Array<WorkspaceApplicationFilterInput>>;
  or?: InputMaybe<Array<WorkspaceApplicationFilterInput>>;
  /** 申请目的 */
  purpose?: InputMaybe<WorkspaceApplicationFilterPurpose>;
  /** 拒绝时间 */
  rejectedAt?: InputMaybe<WorkspaceApplicationFilterRejectedAt>;
  /** 拒绝人（platform_admin）ID */
  rejectedBy?: InputMaybe<WorkspaceApplicationFilterRejectedBy>;
  /** 拒绝原因（可选） */
  rejectionReason?: InputMaybe<WorkspaceApplicationFilterRejectionReason>;
  /** 申请创建的工作台 slug（创建时校验全局唯一） */
  slug?: InputMaybe<WorkspaceApplicationFilterSlug>;
  /** 申请状态 */
  status?: InputMaybe<WorkspaceApplicationFilterStatus>;
};

export type WorkspaceApplicationFilterName = {
  contains?: InputMaybe<Scalars['String']['input']>;
  eq?: InputMaybe<Scalars['String']['input']>;
  greaterThan?: InputMaybe<Scalars['String']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['String']['input']>;
  ilike?: InputMaybe<Scalars['String']['input']>;
  in?: InputMaybe<Array<Scalars['String']['input']>>;
  isDistinctFrom?: InputMaybe<Scalars['String']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['String']['input']>;
  lessThan?: InputMaybe<Scalars['String']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['String']['input']>;
  like?: InputMaybe<Scalars['String']['input']>;
  notEq?: InputMaybe<Scalars['String']['input']>;
  stringEndsWith?: InputMaybe<Scalars['String']['input']>;
  stringStartsWith?: InputMaybe<Scalars['String']['input']>;
};

export type WorkspaceApplicationFilterPurpose = {
  contains?: InputMaybe<Scalars['String']['input']>;
  eq?: InputMaybe<Scalars['String']['input']>;
  greaterThan?: InputMaybe<Scalars['String']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['String']['input']>;
  ilike?: InputMaybe<Scalars['String']['input']>;
  in?: InputMaybe<Array<Scalars['String']['input']>>;
  isDistinctFrom?: InputMaybe<Scalars['String']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['String']['input']>;
  lessThan?: InputMaybe<Scalars['String']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['String']['input']>;
  like?: InputMaybe<Scalars['String']['input']>;
  notEq?: InputMaybe<Scalars['String']['input']>;
  stringEndsWith?: InputMaybe<Scalars['String']['input']>;
  stringStartsWith?: InputMaybe<Scalars['String']['input']>;
};

export type WorkspaceApplicationFilterRejectedAt = {
  eq?: InputMaybe<Scalars['DateTime']['input']>;
  greaterThan?: InputMaybe<Scalars['DateTime']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['DateTime']['input']>;
  in?: InputMaybe<Array<InputMaybe<Scalars['DateTime']['input']>>>;
  isDistinctFrom?: InputMaybe<Scalars['DateTime']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['DateTime']['input']>;
  lessThan?: InputMaybe<Scalars['DateTime']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['DateTime']['input']>;
  notEq?: InputMaybe<Scalars['DateTime']['input']>;
};

export type WorkspaceApplicationFilterRejectedBy = {
  eq?: InputMaybe<Scalars['ID']['input']>;
  greaterThan?: InputMaybe<Scalars['ID']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  in?: InputMaybe<Array<InputMaybe<Scalars['ID']['input']>>>;
  isDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  lessThan?: InputMaybe<Scalars['ID']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  notEq?: InputMaybe<Scalars['ID']['input']>;
};

export type WorkspaceApplicationFilterRejectionReason = {
  contains?: InputMaybe<Scalars['String']['input']>;
  eq?: InputMaybe<Scalars['String']['input']>;
  greaterThan?: InputMaybe<Scalars['String']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['String']['input']>;
  ilike?: InputMaybe<Scalars['String']['input']>;
  in?: InputMaybe<Array<InputMaybe<Scalars['String']['input']>>>;
  isDistinctFrom?: InputMaybe<Scalars['String']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['String']['input']>;
  lessThan?: InputMaybe<Scalars['String']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['String']['input']>;
  like?: InputMaybe<Scalars['String']['input']>;
  notEq?: InputMaybe<Scalars['String']['input']>;
  stringEndsWith?: InputMaybe<Scalars['String']['input']>;
  stringStartsWith?: InputMaybe<Scalars['String']['input']>;
};

export type WorkspaceApplicationFilterSlug = {
  contains?: InputMaybe<Scalars['String']['input']>;
  eq?: InputMaybe<Scalars['String']['input']>;
  greaterThan?: InputMaybe<Scalars['String']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['String']['input']>;
  ilike?: InputMaybe<Scalars['String']['input']>;
  in?: InputMaybe<Array<Scalars['String']['input']>>;
  isDistinctFrom?: InputMaybe<Scalars['String']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['String']['input']>;
  lessThan?: InputMaybe<Scalars['String']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['String']['input']>;
  like?: InputMaybe<Scalars['String']['input']>;
  notEq?: InputMaybe<Scalars['String']['input']>;
  stringEndsWith?: InputMaybe<Scalars['String']['input']>;
  stringStartsWith?: InputMaybe<Scalars['String']['input']>;
};

export type WorkspaceApplicationFilterStatus = {
  eq?: InputMaybe<Scalars['String']['input']>;
  greaterThan?: InputMaybe<Scalars['String']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['String']['input']>;
  in?: InputMaybe<Array<Scalars['String']['input']>>;
  isDistinctFrom?: InputMaybe<Scalars['String']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['String']['input']>;
  lessThan?: InputMaybe<Scalars['String']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['String']['input']>;
  notEq?: InputMaybe<Scalars['String']['input']>;
};

export type WorkspaceApplicationSortField =
  | 'APPLICANT_ID'
  | 'APPROVAL_DEADLINE'
  | 'APPROVED_AT'
  | 'APPROVED_BY'
  | 'EXPIRED_AT'
  | 'ID'
  | 'NAME'
  | 'PURPOSE'
  | 'REJECTED_AT'
  | 'REJECTED_BY'
  | 'REJECTION_REASON'
  | 'SLUG'
  | 'STATUS';

export type WorkspaceApplicationSortInput = {
  field: WorkspaceApplicationSortField;
  order?: InputMaybe<SortOrder>;
};

export type WorkspaceFilterId = {
  eq?: InputMaybe<Scalars['ID']['input']>;
  greaterThan?: InputMaybe<Scalars['ID']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  in?: InputMaybe<Array<Scalars['ID']['input']>>;
  isDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  lessThan?: InputMaybe<Scalars['ID']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  notEq?: InputMaybe<Scalars['ID']['input']>;
};

export type WorkspaceFilterInput = {
  and?: InputMaybe<Array<WorkspaceFilterInput>>;
  id?: InputMaybe<WorkspaceFilterId>;
  /** 加入策略：open 公开直接加入 / request 公开申请审批 / invite_only 私密仅邀请 */
  joinPolicy?: InputMaybe<WorkspaceFilterJoinPolicy>;
  /** 工作台名称 */
  name?: InputMaybe<WorkspaceFilterName>;
  not?: InputMaybe<Array<WorkspaceFilterInput>>;
  or?: InputMaybe<Array<WorkspaceFilterInput>>;
  /** 工作台唯一标识（小写字母/数字/连字符，创建者提供） */
  slug?: InputMaybe<WorkspaceFilterSlug>;
  /** 是否开放赞助入口（默认开） */
  sponsorshipEnabled?: InputMaybe<WorkspaceFilterSponsorshipEnabled>;
};

export type WorkspaceFilterJoinPolicy = {
  eq?: InputMaybe<Scalars['String']['input']>;
  greaterThan?: InputMaybe<Scalars['String']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['String']['input']>;
  in?: InputMaybe<Array<Scalars['String']['input']>>;
  isDistinctFrom?: InputMaybe<Scalars['String']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['String']['input']>;
  lessThan?: InputMaybe<Scalars['String']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['String']['input']>;
  notEq?: InputMaybe<Scalars['String']['input']>;
};

export type WorkspaceFilterName = {
  contains?: InputMaybe<Scalars['String']['input']>;
  eq?: InputMaybe<Scalars['String']['input']>;
  greaterThan?: InputMaybe<Scalars['String']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['String']['input']>;
  ilike?: InputMaybe<Scalars['String']['input']>;
  in?: InputMaybe<Array<Scalars['String']['input']>>;
  isDistinctFrom?: InputMaybe<Scalars['String']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['String']['input']>;
  lessThan?: InputMaybe<Scalars['String']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['String']['input']>;
  like?: InputMaybe<Scalars['String']['input']>;
  notEq?: InputMaybe<Scalars['String']['input']>;
  stringEndsWith?: InputMaybe<Scalars['String']['input']>;
  stringStartsWith?: InputMaybe<Scalars['String']['input']>;
};

export type WorkspaceFilterSlug = {
  contains?: InputMaybe<Scalars['String']['input']>;
  eq?: InputMaybe<Scalars['String']['input']>;
  greaterThan?: InputMaybe<Scalars['String']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['String']['input']>;
  ilike?: InputMaybe<Scalars['String']['input']>;
  in?: InputMaybe<Array<Scalars['String']['input']>>;
  isDistinctFrom?: InputMaybe<Scalars['String']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['String']['input']>;
  lessThan?: InputMaybe<Scalars['String']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['String']['input']>;
  like?: InputMaybe<Scalars['String']['input']>;
  notEq?: InputMaybe<Scalars['String']['input']>;
  stringEndsWith?: InputMaybe<Scalars['String']['input']>;
  stringStartsWith?: InputMaybe<Scalars['String']['input']>;
};

export type WorkspaceFilterSponsorshipEnabled = {
  eq?: InputMaybe<Scalars['Boolean']['input']>;
  greaterThan?: InputMaybe<Scalars['Boolean']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['Boolean']['input']>;
  in?: InputMaybe<Array<Scalars['Boolean']['input']>>;
  isDistinctFrom?: InputMaybe<Scalars['Boolean']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['Boolean']['input']>;
  lessThan?: InputMaybe<Scalars['Boolean']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['Boolean']['input']>;
  notEq?: InputMaybe<Scalars['Boolean']['input']>;
};

export type WorkspaceMembership = {
  id: Scalars['ID']['output'];
  /** 加入时间（P1 G7，= inserted_at） */
  joinedAt?: Maybe<Scalars['DateTime']['output']>;
  roles: Array<Role>;
  /** 成员昵称（平铺自 user 关系，P1 G6） */
  userDisplayName?: Maybe<Scalars['String']['output']>;
  /** 成员邮箱（平铺自 user 关系，P1 G6） */
  userEmail?: Maybe<Scalars['String']['output']>;
  /** 成员（全局用户）ID */
  userId: Scalars['ID']['output'];
  /** 所属工作台（租户）ID */
  workspaceId: Scalars['ID']['output'];
};


export type WorkspaceMembershipRolesArgs = {
  filter?: InputMaybe<RoleFilterInput>;
  limit?: InputMaybe<Scalars['Int']['input']>;
  offset?: InputMaybe<Scalars['Int']['input']>;
  sort?: InputMaybe<Array<InputMaybe<RoleSortInput>>>;
};

export type WorkspaceMembershipFilterId = {
  eq?: InputMaybe<Scalars['ID']['input']>;
  greaterThan?: InputMaybe<Scalars['ID']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  in?: InputMaybe<Array<Scalars['ID']['input']>>;
  isDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  lessThan?: InputMaybe<Scalars['ID']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  notEq?: InputMaybe<Scalars['ID']['input']>;
};

export type WorkspaceMembershipFilterInput = {
  and?: InputMaybe<Array<WorkspaceMembershipFilterInput>>;
  id?: InputMaybe<WorkspaceMembershipFilterId>;
  /** 加入时间（P1 G7，= inserted_at） */
  joinedAt?: InputMaybe<WorkspaceMembershipFilterJoinedAt>;
  not?: InputMaybe<Array<WorkspaceMembershipFilterInput>>;
  or?: InputMaybe<Array<WorkspaceMembershipFilterInput>>;
  roles?: InputMaybe<RoleFilterInput>;
  /** 成员昵称（平铺自 user 关系，P1 G6） */
  userDisplayName?: InputMaybe<WorkspaceMembershipFilterUserDisplayName>;
  /** 成员邮箱（平铺自 user 关系，P1 G6） */
  userEmail?: InputMaybe<WorkspaceMembershipFilterUserEmail>;
  /** 成员（全局用户）ID */
  userId?: InputMaybe<WorkspaceMembershipFilterUserId>;
  /** 所属工作台（租户）ID */
  workspaceId?: InputMaybe<WorkspaceMembershipFilterWorkspaceId>;
};

export type WorkspaceMembershipFilterJoinedAt = {
  eq?: InputMaybe<Scalars['DateTime']['input']>;
  greaterThan?: InputMaybe<Scalars['DateTime']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['DateTime']['input']>;
  in?: InputMaybe<Array<Scalars['DateTime']['input']>>;
  isDistinctFrom?: InputMaybe<Scalars['DateTime']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['DateTime']['input']>;
  lessThan?: InputMaybe<Scalars['DateTime']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['DateTime']['input']>;
  notEq?: InputMaybe<Scalars['DateTime']['input']>;
};

export type WorkspaceMembershipFilterUserDisplayName = {
  contains?: InputMaybe<Scalars['String']['input']>;
  eq?: InputMaybe<Scalars['String']['input']>;
  greaterThan?: InputMaybe<Scalars['String']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['String']['input']>;
  ilike?: InputMaybe<Scalars['String']['input']>;
  in?: InputMaybe<Array<Scalars['String']['input']>>;
  isDistinctFrom?: InputMaybe<Scalars['String']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['String']['input']>;
  lessThan?: InputMaybe<Scalars['String']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['String']['input']>;
  like?: InputMaybe<Scalars['String']['input']>;
  notEq?: InputMaybe<Scalars['String']['input']>;
  stringEndsWith?: InputMaybe<Scalars['String']['input']>;
  stringStartsWith?: InputMaybe<Scalars['String']['input']>;
};

export type WorkspaceMembershipFilterUserEmail = {
  contains?: InputMaybe<Scalars['String']['input']>;
  eq?: InputMaybe<Scalars['String']['input']>;
  greaterThan?: InputMaybe<Scalars['String']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['String']['input']>;
  ilike?: InputMaybe<Scalars['String']['input']>;
  in?: InputMaybe<Array<Scalars['String']['input']>>;
  isDistinctFrom?: InputMaybe<Scalars['String']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['String']['input']>;
  lessThan?: InputMaybe<Scalars['String']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['String']['input']>;
  like?: InputMaybe<Scalars['String']['input']>;
  notEq?: InputMaybe<Scalars['String']['input']>;
  stringEndsWith?: InputMaybe<Scalars['String']['input']>;
  stringStartsWith?: InputMaybe<Scalars['String']['input']>;
};

export type WorkspaceMembershipFilterUserId = {
  eq?: InputMaybe<Scalars['ID']['input']>;
  greaterThan?: InputMaybe<Scalars['ID']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  in?: InputMaybe<Array<Scalars['ID']['input']>>;
  isDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  lessThan?: InputMaybe<Scalars['ID']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  notEq?: InputMaybe<Scalars['ID']['input']>;
};

export type WorkspaceMembershipFilterWorkspaceId = {
  eq?: InputMaybe<Scalars['ID']['input']>;
  greaterThan?: InputMaybe<Scalars['ID']['input']>;
  greaterThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  in?: InputMaybe<Array<Scalars['ID']['input']>>;
  isDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  isNil?: InputMaybe<Scalars['Boolean']['input']>;
  isNotDistinctFrom?: InputMaybe<Scalars['ID']['input']>;
  lessThan?: InputMaybe<Scalars['ID']['input']>;
  lessThanOrEqual?: InputMaybe<Scalars['ID']['input']>;
  notEq?: InputMaybe<Scalars['ID']['input']>;
};

export type WorkspaceMembershipSortField =
  | 'ID'
  | 'JOINED_AT'
  | 'USER_DISPLAY_NAME'
  | 'USER_EMAIL'
  | 'USER_ID'
  | 'WORKSPACE_ID';

export type WorkspaceMembershipSortInput = {
  field: WorkspaceMembershipSortField;
  order?: InputMaybe<SortOrder>;
};

export type WorkspaceProfile = {
  about?: Maybe<Scalars['String']['output']>;
  avatarUrl?: Maybe<Scalars['String']['output']>;
  /** per-workspace 成员公开资料（ADR-0004） */
  id: Scalars['ID']['output'];
  location?: Maybe<Scalars['String']['output']>;
  skills?: Maybe<Array<Maybe<Scalars['String']['output']>>>;
  uiThemePreference: Scalars['String']['output'];
  userId: Scalars['ID']['output'];
  visibility?: Maybe<Scalars['String']['output']>;
  workspaceId: Scalars['ID']['output'];
};

export type WorkspaceSortField =
  | 'ID'
  | 'JOIN_POLICY'
  | 'NAME'
  | 'SLUG'
  | 'SPONSORSHIP_ENABLED';

export type WorkspaceSortInput = {
  field: WorkspaceSortField;
  order?: InputMaybe<SortOrder>;
};
