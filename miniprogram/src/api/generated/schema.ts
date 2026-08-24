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

export type AdminReconciliationFinding = {
  entityId: Scalars['String']['output'];
  entityType: Scalars['String']['output'];
  firstSeenAt: Scalars['DateTime']['output'];
  id: Scalars['ID']['output'];
  insertedAt: Scalars['DateTime']['output'];
  lastSeenAt: Scalars['DateTime']['output'];
  rule: Scalars['String']['output'];
  workspaceId?: Maybe<Scalars['ID']['output']>;
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

/** The result of the :approve_sponsorship mutation */
export type ApproveSponsorshipResult = {
  /** Any errors generated, if the mutation failed */
  errors: Array<MutationError>;
  /** The successful result of the mutation */
  result?: Maybe<Sponsorship>;
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

/** The result of the :cancel_course mutation */
export type CancelCourseResult = {
  /** Any errors generated, if the mutation failed */
  errors: Array<MutationError>;
  /** The successful result of the mutation */
  result?: Maybe<Course>;
};

/** The result of the :cancel_enrollment mutation */
export type CancelEnrollmentResult = {
  /** Any errors generated, if the mutation failed */
  errors: Array<MutationError>;
  /** The successful result of the mutation */
  result?: Maybe<Enrollment>;
};

/** The result of the :cancel_event mutation */
export type CancelEventResult = {
  /** Any errors generated, if the mutation failed */
  errors: Array<MutationError>;
  /** The successful result of the mutation */
  result?: Maybe<Event>;
};

/** The result of the :cancel_order mutation */
export type CancelOrderResult = {
  /** Any errors generated, if the mutation failed */
  errors: Array<MutationError>;
  /** The successful result of the mutation */
  result?: Maybe<Order>;
};

/** The result of the :close_course mutation */
export type CloseCourseResult = {
  /** Any errors generated, if the mutation failed */
  errors: Array<MutationError>;
  /** The successful result of the mutation */
  result?: Maybe<Course>;
};

/** The result of the :close_event mutation */
export type CloseEventResult = {
  /** Any errors generated, if the mutation failed */
  errors: Array<MutationError>;
  /** The successful result of the mutation */
  result?: Maybe<Event>;
};

/** The result of the :confirm_enrollment mutation */
export type ConfirmEnrollmentResult = {
  /** Any errors generated, if the mutation failed */
  errors: Array<MutationError>;
  /** The successful result of the mutation */
  result?: Maybe<Enrollment>;
};

export type Course = {
  availablePriceTiers?: Maybe<Array<Scalars['JsonString']['output']>>;
  /** 报名名额上限；nil 表示不限 */
  capacity?: Maybe<Scalars['Int']['output']>;
  /** 已确认名额数（仅由 Enrollment 原子维护） */
  confirmedCount: Scalars['Int']['output'];
  /** 公开展示文案（可空；null 由展示层按空串呈现） */
  description?: Maybe<Scalars['String']['output']>;
  /** 结课时间；须严格晚于 starts_at（KTD6），nil 表示未定（R1） */
  endsAt?: Maybe<Scalars['DateTime']['output']>;
  enrollmentBadge?: Maybe<Scalars['String']['output']>;
  /** 报名策略：open / request / invite_only */
  enrollmentPolicy: Scalars['String']['output'];
  id: Scalars['ID']['output'];
  /** 价格档位配置（PriceTier 形状，见 price_tier.ex） */
  priceTiers: Array<Scalars['JsonString']['output']>;
  /** 是否收费（默认免费；true 时报名须选档并完成支付，R4） */
  pricingEnabled: Scalars['Boolean']['output'];
  /** 报名截止时间；nil 表示不设截止 */
  registrationDeadline?: Maybe<Scalars['DateTime']['output']>;
  /** 教研材料需求（audience/duration/sections 等），作为 run input 注入 */
  researchRequirements?: Maybe<Scalars['JsonString']['output']>;
  /** 公开 URL 段（/courses/[slug]，全局唯一） */
  slug?: Maybe<Scalars['String']['output']>;
  /** 开课时间；nil 表示未定（R1，Course 语义为开课/结课） */
  startsAt?: Maybe<Scalars['DateTime']['output']>;
  /** 课程状态：draft 草稿 / open 已发布 / closed 已结束 / cancelled 已取消 */
  status: Scalars['String']['output'];
  /** 课程标题 */
  title: Scalars['String']['output'];
  /** 可见性：public 公开可见 / workspace 仅工作台可见（可随时双向切换，D9） */
  visibility: Scalars['String']['output'];
  workflowRun?: Maybe<WorkflowRun>;
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
  rangeAdjacent?: InputMaybe<Scalars['Int']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['Int']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['Int']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['Int']['input']>;
};

export type CourseFilterDescription = {
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
  rangeAdjacent?: InputMaybe<Scalars['String']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['String']['input']>;
  stringEndsWith?: InputMaybe<Scalars['String']['input']>;
  stringStartsWith?: InputMaybe<Scalars['String']['input']>;
};

export type CourseFilterEndsAt = {
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
  rangeAdjacent?: InputMaybe<Scalars['DateTime']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['DateTime']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['String']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['String']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['ID']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['ID']['input']>;
};

export type CourseFilterInput = {
  and?: InputMaybe<Array<CourseFilterInput>>;
  /** 报名名额上限；nil 表示不限 */
  capacity?: InputMaybe<CourseFilterCapacity>;
  /** 已确认名额数（仅由 Enrollment 原子维护） */
  confirmedCount?: InputMaybe<CourseFilterConfirmedCount>;
  /** 公开展示文案（可空；null 由展示层按空串呈现） */
  description?: InputMaybe<CourseFilterDescription>;
  /** 结课时间；须严格晚于 starts_at（KTD6），nil 表示未定（R1） */
  endsAt?: InputMaybe<CourseFilterEndsAt>;
  /** 报名策略：open / request / invite_only */
  enrollmentPolicy?: InputMaybe<CourseFilterEnrollmentPolicy>;
  id?: InputMaybe<CourseFilterId>;
  not?: InputMaybe<Array<CourseFilterInput>>;
  or?: InputMaybe<Array<CourseFilterInput>>;
  /** 是否收费（默认免费；true 时报名须选档并完成支付，R4） */
  pricingEnabled?: InputMaybe<CourseFilterPricingEnabled>;
  /** 报名截止时间；nil 表示不设截止 */
  registrationDeadline?: InputMaybe<CourseFilterRegistrationDeadline>;
  /** 教研材料需求（audience/duration/sections 等），作为 run input 注入 */
  researchRequirements?: InputMaybe<CourseFilterResearchRequirements>;
  /** 公开 URL 段（/courses/[slug]，全局唯一） */
  slug?: InputMaybe<CourseFilterSlug>;
  /** 开课时间；nil 表示未定（R1，Course 语义为开课/结课） */
  startsAt?: InputMaybe<CourseFilterStartsAt>;
  /** 课程状态：draft 草稿 / open 已发布 / closed 已结束 / cancelled 已取消 */
  status?: InputMaybe<CourseFilterStatus>;
  /** 课程标题 */
  title?: InputMaybe<CourseFilterTitle>;
  /** 可见性：public 公开可见 / workspace 仅工作台可见（可随时双向切换，D9） */
  visibility?: InputMaybe<CourseFilterVisibility>;
  workflowRun?: InputMaybe<WorkflowRunFilterInput>;
  /** 教研 workflow 产物引用（领域模型 §5.2 ER） */
  workflowRunId?: InputMaybe<CourseFilterWorkflowRunId>;
  /** 所属工作台（租户）ID */
  workspaceId?: InputMaybe<CourseFilterWorkspaceId>;
};

export type CourseFilterPricingEnabled = {
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
  rangeAdjacent?: InputMaybe<Scalars['Boolean']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['Boolean']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['DateTime']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['DateTime']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['JsonString']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['JsonString']['input']>;
};

export type CourseFilterSlug = {
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
  rangeAdjacent?: InputMaybe<Scalars['String']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['String']['input']>;
  stringEndsWith?: InputMaybe<Scalars['String']['input']>;
  stringStartsWith?: InputMaybe<Scalars['String']['input']>;
};

export type CourseFilterStartsAt = {
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
  rangeAdjacent?: InputMaybe<Scalars['DateTime']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['DateTime']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['String']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['String']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['String']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['String']['input']>;
  stringEndsWith?: InputMaybe<Scalars['String']['input']>;
  stringStartsWith?: InputMaybe<Scalars['String']['input']>;
};

export type CourseFilterVisibility = {
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
  rangeAdjacent?: InputMaybe<Scalars['String']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['String']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['ID']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['ID']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['ID']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['ID']['input']>;
};

export type CourseLearningDetail = {
  courseId: Scalars['ID']['output'];
  goals: Array<Scalars['String']['output']>;
  issues: Array<LearningIssue>;
  progress?: Maybe<LearningProgress>;
  slug?: Maybe<Scalars['String']['output']>;
  title: Scalars['String']['output'];
};

export type CourseMap = {
  courseId: Scalars['ID']['output'];
  goals: Array<Scalars['String']['output']>;
  issues: Array<CourseMapIssue>;
  slug: Scalars['String']['output'];
  title: Scalars['String']['output'];
};

export type CourseMapIssue = {
  goal?: Maybe<Scalars['String']['output']>;
  id: Scalars['String']['output'];
  key: Scalars['String']['output'];
  kind: Scalars['String']['output'];
  title: Scalars['String']['output'];
};

export type CourseSortField =
  | 'CAPACITY'
  | 'CONFIRMED_COUNT'
  | 'DESCRIPTION'
  | 'ENDS_AT'
  | 'ENROLLMENT_POLICY'
  | 'ID'
  | 'PRICING_ENABLED'
  | 'REGISTRATION_DEADLINE'
  | 'RESEARCH_REQUIREMENTS'
  | 'SLUG'
  | 'STARTS_AT'
  | 'STATUS'
  | 'TITLE'
  | 'VISIBILITY'
  | 'WORKFLOW_RUN_ID'
  | 'WORKSPACE_ID';

export type CourseSortInput = {
  field: CourseSortField;
  order?: InputMaybe<SortOrder>;
};

export type CreateCourseInput = {
  /** 报名名额上限；nil 表示不限 */
  capacity?: InputMaybe<Scalars['Int']['input']>;
  /** 公开展示文案（可空；null 由展示层按空串呈现） */
  description?: InputMaybe<Scalars['String']['input']>;
  /** 结课时间；须严格晚于 starts_at（KTD6），nil 表示未定（R1） */
  endsAt?: InputMaybe<Scalars['DateTime']['input']>;
  /** 报名策略：open / request / invite_only */
  enrollmentPolicy?: InputMaybe<Scalars['String']['input']>;
  /** 价格档位配置（PriceTier 形状，见 price_tier.ex） */
  priceTiers?: InputMaybe<Array<Scalars['JsonString']['input']>>;
  /** 是否收费（默认免费；true 时报名须选档并完成支付，R4） */
  pricingEnabled?: InputMaybe<Scalars['Boolean']['input']>;
  /** 报名截止时间；nil 表示不设截止 */
  registrationDeadline?: InputMaybe<Scalars['DateTime']['input']>;
  /** 教研材料需求（audience/duration/sections 等），作为 run input 注入 */
  researchRequirements?: InputMaybe<Scalars['JsonString']['input']>;
  /** 公开 URL 段（/courses/[slug]，全局唯一） */
  slug?: InputMaybe<Scalars['String']['input']>;
  /** 开课时间；nil 表示未定（R1，Course 语义为开课/结课） */
  startsAt?: InputMaybe<Scalars['DateTime']['input']>;
  /** 课程标题 */
  title: Scalars['String']['input'];
  /** 可见性：public 公开可见 / workspace 仅工作台可见（可随时双向切换，D9） */
  visibility?: InputMaybe<Scalars['String']['input']>;
  /** 目标工作台 ID（GraphQL 入口必传；tenant 已注入时省略） */
  workspaceId?: InputMaybe<Scalars['ID']['input']>;
};

/** The result of the :create_course mutation */
export type CreateCourseResult = {
  /** Any errors generated, if the mutation failed */
  errors: Array<MutationError>;
  /** The successful result of the mutation */
  result?: Maybe<Course>;
};

export type CreateEnrollmentInput = {
  approvalDeadline?: InputMaybe<Scalars['DateTime']['input']>;
  courseId?: InputMaybe<Scalars['ID']['input']>;
  eventId?: InputMaybe<Scalars['ID']['input']>;
  inviteCode?: InputMaybe<Scalars['String']['input']>;
  submissionPayload?: InputMaybe<Scalars['JsonString']['input']>;
  /** 价格档位 ID（收费活动报名时必填） */
  tierId?: InputMaybe<Scalars['String']['input']>;
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

export type CreateEventInput = {
  /** 报名名额上限；nil 表示不限 */
  capacity?: InputMaybe<Scalars['Int']['input']>;
  /** 公开展示文案（可空；null 由展示层按空串呈现） */
  description?: InputMaybe<Scalars['String']['input']>;
  /** 活动结束时间；须严格晚于 starts_at（KTD6），nil 表示未定（R1） */
  endsAt?: InputMaybe<Scalars['DateTime']['input']>;
  /** 报名策略：open / request / invite_only */
  enrollmentPolicy?: InputMaybe<Scalars['String']['input']>;
  /** 价格档位配置（PriceTier 形状，见 price_tier.ex） */
  priceTiers?: InputMaybe<Array<Scalars['JsonString']['input']>>;
  /** 是否收费（默认免费；true 时报名须选档并完成支付，R4） */
  pricingEnabled?: InputMaybe<Scalars['Boolean']['input']>;
  /** 报名截止时间；nil 表示不设截止 */
  registrationDeadline?: InputMaybe<Scalars['DateTime']['input']>;
  /** 是否启用教研 workflow */
  researchEnabled?: InputMaybe<Scalars['Boolean']['input']>;
  /** 教研材料需求（audience/duration/sections 等），作为 run input 注入 */
  researchRequirements?: InputMaybe<Scalars['JsonString']['input']>;
  /** 公开 URL 段（/events/[slug] 或 /courses/[slug]，全局唯一） */
  slug?: InputMaybe<Scalars['String']['input']>;
  /** 赞助意向截止；nil 表示长期开放 */
  sponsorshipDeadline?: InputMaybe<Scalars['DateTime']['input']>;
  /** 是否开放赞助入口（默认开；tiers 未配置时入口隐藏，E-5 readiness ②） */
  sponsorshipEnabled?: InputMaybe<Scalars['Boolean']['input']>;
  /** 赞助档位配置（SponsorshipTier 形状，见 sponsorship_tier.ex） */
  sponsorshipTiers?: InputMaybe<Array<Scalars['JsonString']['input']>>;
  /** 活动开始时间；nil 表示未定（R1） */
  startsAt?: InputMaybe<Scalars['DateTime']['input']>;
  /** 活动标题 */
  title: Scalars['String']['input'];
  /** 结构化场地（country/province/city/district 四键，KTD5/R2）；nil 表示线上或未定 */
  venue?: InputMaybe<Scalars['JsonString']['input']>;
  /** 可见性：public 公开可见 / workspace 仅工作台可见（可随时双向切换，D9） */
  visibility?: InputMaybe<Scalars['String']['input']>;
  /** 目标工作台 ID（GraphQL 入口必传；tenant 已注入时省略） */
  workspaceId?: InputMaybe<Scalars['ID']['input']>;
};

/** The result of the :create_event mutation */
export type CreateEventResult = {
  /** Any errors generated, if the mutation failed */
  errors: Array<MutationError>;
  /** The successful result of the mutation */
  result?: Maybe<Event>;
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

export type CreateOrderInput = {
  /** 目标报名（须为本人 payment_pending 报名） */
  enrollmentId: Scalars['ID']['input'];
  /** 支付渠道 */
  provider: Scalars['String']['input'];
};

export type CreateOrderMetadata = {
  /** 渠道支付凭据（jsapi 调起参数 / 二维码链接 / 跳转 URL） */
  credential?: Maybe<Scalars['JsonString']['output']>;
};

/** The result of the :create_order mutation */
export type CreateOrderResult = {
  /** Any errors generated, if the mutation failed */
  errors: Array<MutationError>;
  /** Metadata produced by the mutation */
  metadata?: Maybe<CreateOrderMetadata>;
  /** The successful result of the mutation */
  result?: Maybe<Order>;
};

export type CreatePortfolioItemInput = {
  description?: InputMaybe<Scalars['String']['input']>;
  icon?: InputMaybe<Scalars['String']['input']>;
  /** createPortfolioItem 输入：title 必填，description/url/icon 可选 */
  title: Scalars['String']['input'];
  url?: InputMaybe<Scalars['String']['input']>;
};

export type CreateSpeakerInvitationInput = {
  eventId: Scalars['ID']['input'];
  expiresAt?: InputMaybe<Scalars['DateTime']['input']>;
  note?: InputMaybe<Scalars['String']['input']>;
  scheduledAt?: InputMaybe<Scalars['DateTime']['input']>;
  speakerEmail?: InputMaybe<Scalars['String']['input']>;
  speakerName: Scalars['String']['input'];
  topic?: InputMaybe<Scalars['String']['input']>;
  /** createSpeakerInvitation 输入：workspaceId + eventId + speakerName 必填，其余可选 */
  workspaceId: Scalars['ID']['input'];
};

export type CreateSpeakerInvitationPayload = {
  errors: Array<MutationError>;
  plainToken?: Maybe<Scalars['String']['output']>;
  /** createSpeakerInvitation 返回：result 为邀请记录；plainToken 明文仅此一次 */
  result?: Maybe<SpeakerInvitation>;
};

export type CreateSponsorshipInput = {
  /** 意向金额（元，v1 仅登记不收款；可空） */
  amount?: InputMaybe<Scalars['Int']['input']>;
  /** 赞助方公司/展示名 */
  companyName: Scalars['String']['input'];
  /** 联系邮箱（必填） */
  contactEmail: Scalars['String']['input'];
  contactPhone?: InputMaybe<Scalars['String']['input']>;
  eventId?: InputMaybe<Scalars['ID']['input']>;
  /** 赞助级别：event 单场 / workspace 长期 */
  level: Scalars['String']['input'];
  /** 备注/合作意向 */
  message?: InputMaybe<Scalars['String']['input']>;
  /** 赞助方（全局账号，非成员） */
  sponsorUserId: Scalars['ID']['input'];
  targetWorkspaceId?: InputMaybe<Scalars['ID']['input']>;
  /** 意向档位（指向目标 sponsorship_tiers 配置内的档位 id，可选） */
  tierId?: InputMaybe<Scalars['ID']['input']>;
};

/** The result of the :create_sponsorship mutation */
export type CreateSponsorshipResult = {
  /** Any errors generated, if the mutation failed */
  errors: Array<MutationError>;
  /** The successful result of the mutation */
  result?: Maybe<Sponsorship>;
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
  /** 赞助意向截止；nil 表示长期开放 */
  sponsorshipDeadline?: InputMaybe<Scalars['DateTime']['input']>;
  /** 是否开放赞助入口（默认开） */
  sponsorshipEnabled?: InputMaybe<Scalars['Boolean']['input']>;
  /** 赞助档位配置（SponsorshipTier 形状，见 sponsorship_tier.ex） */
  sponsorshipTiers?: InputMaybe<Array<Scalars['JsonString']['input']>>;
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
  insertedAt: Scalars['DateTime']['output'];
  inviteBatchId?: Maybe<Scalars['ID']['output']>;
  rejectionReason?: Maybe<Scalars['String']['output']>;
  status: Scalars['String']['output'];
  targetTitle?: Maybe<Scalars['String']['output']>;
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
  rangeAdjacent?: InputMaybe<Scalars['DateTime']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['DateTime']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['DateTime']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['DateTime']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['ID']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['ID']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['DateTime']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['DateTime']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['Int']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['Int']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['ID']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['ID']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['ID']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['ID']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['DateTime']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['DateTime']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['ID']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['ID']['input']>;
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
  insertedAt?: InputMaybe<EnrollmentFilterInsertedAt>;
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

export type EnrollmentFilterInsertedAt = {
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
  rangeAdjacent?: InputMaybe<Scalars['DateTime']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['DateTime']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['ID']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['ID']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['String']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['String']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['String']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['String']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['JsonString']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['JsonString']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['ID']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['ID']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['ID']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['ID']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['ID']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['ID']['input']>;
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
  | 'INSERTED_AT'
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
  availablePriceTiers?: Maybe<Array<Scalars['JsonString']['output']>>;
  /** 报名名额上限；nil 表示不限 */
  capacity?: Maybe<Scalars['Int']['output']>;
  /** 已确认名额数（仅由 Enrollment 原子维护） */
  confirmedCount: Scalars['Int']['output'];
  /** 公开展示文案（可空；null 由展示层按空串呈现） */
  description?: Maybe<Scalars['String']['output']>;
  /** 活动结束时间；须严格晚于 starts_at（KTD6），nil 表示未定（R1） */
  endsAt?: Maybe<Scalars['DateTime']['output']>;
  enrollmentBadge?: Maybe<Scalars['String']['output']>;
  /** 报名策略：open / request / invite_only */
  enrollmentPolicy: Scalars['String']['output'];
  id: Scalars['ID']['output'];
  /** 价格档位配置（PriceTier 形状，见 price_tier.ex） */
  priceTiers: Array<Scalars['JsonString']['output']>;
  /** 是否收费（默认免费；true 时报名须选档并完成支付，R4） */
  pricingEnabled: Scalars['Boolean']['output'];
  /** 报名截止时间；nil 表示不设截止 */
  registrationDeadline?: Maybe<Scalars['DateTime']['output']>;
  /** 是否启用教研 workflow */
  researchEnabled: Scalars['Boolean']['output'];
  /** 教研材料需求（audience/duration/sections 等），作为 run input 注入 */
  researchRequirements?: Maybe<Scalars['JsonString']['output']>;
  /** 公开 URL 段（/events/[slug] 或 /courses/[slug]，全局唯一） */
  slug?: Maybe<Scalars['String']['output']>;
  /** 赞助意向截止；nil 表示长期开放 */
  sponsorshipDeadline?: Maybe<Scalars['DateTime']['output']>;
  /** 是否开放赞助入口（默认开；tiers 未配置时入口隐藏，E-5 readiness ②） */
  sponsorshipEnabled: Scalars['Boolean']['output'];
  /** 赞助档位配置（SponsorshipTier 形状，见 sponsorship_tier.ex） */
  sponsorshipTiers: Array<Scalars['JsonString']['output']>;
  /** 活动开始时间；nil 表示未定（R1） */
  startsAt?: Maybe<Scalars['DateTime']['output']>;
  /** 活动状态：draft 草稿 / open 已发布 / closed 已结束 / cancelled 已取消 */
  status: Scalars['String']['output'];
  /** 活动标题 */
  title: Scalars['String']['output'];
  /** 结构化场地（country/province/city/district 四键，KTD5/R2）；nil 表示线上或未定 */
  venue?: Maybe<Scalars['JsonString']['output']>;
  /** 可见性：public 公开可见 / workspace 仅工作台可见（可随时双向切换，D9） */
  visibility: Scalars['String']['output'];
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
  rangeAdjacent?: InputMaybe<Scalars['Int']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['Int']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['Int']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['Int']['input']>;
};

export type EventFilterDescription = {
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
  rangeAdjacent?: InputMaybe<Scalars['String']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['String']['input']>;
  stringEndsWith?: InputMaybe<Scalars['String']['input']>;
  stringStartsWith?: InputMaybe<Scalars['String']['input']>;
};

export type EventFilterEndsAt = {
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
  rangeAdjacent?: InputMaybe<Scalars['DateTime']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['DateTime']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['String']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['String']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['ID']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['ID']['input']>;
};

export type EventFilterInput = {
  and?: InputMaybe<Array<EventFilterInput>>;
  /** 报名名额上限；nil 表示不限 */
  capacity?: InputMaybe<EventFilterCapacity>;
  /** 已确认名额数（仅由 Enrollment 原子维护） */
  confirmedCount?: InputMaybe<EventFilterConfirmedCount>;
  /** 公开展示文案（可空；null 由展示层按空串呈现） */
  description?: InputMaybe<EventFilterDescription>;
  /** 活动结束时间；须严格晚于 starts_at（KTD6），nil 表示未定（R1） */
  endsAt?: InputMaybe<EventFilterEndsAt>;
  /** 报名策略：open / request / invite_only */
  enrollmentPolicy?: InputMaybe<EventFilterEnrollmentPolicy>;
  id?: InputMaybe<EventFilterId>;
  not?: InputMaybe<Array<EventFilterInput>>;
  or?: InputMaybe<Array<EventFilterInput>>;
  /** 是否收费（默认免费；true 时报名须选档并完成支付，R4） */
  pricingEnabled?: InputMaybe<EventFilterPricingEnabled>;
  /** 报名截止时间；nil 表示不设截止 */
  registrationDeadline?: InputMaybe<EventFilterRegistrationDeadline>;
  /** 是否启用教研 workflow */
  researchEnabled?: InputMaybe<EventFilterResearchEnabled>;
  /** 教研材料需求（audience/duration/sections 等），作为 run input 注入 */
  researchRequirements?: InputMaybe<EventFilterResearchRequirements>;
  /** 公开 URL 段（/events/[slug] 或 /courses/[slug]，全局唯一） */
  slug?: InputMaybe<EventFilterSlug>;
  /** 赞助意向截止；nil 表示长期开放 */
  sponsorshipDeadline?: InputMaybe<EventFilterSponsorshipDeadline>;
  /** 是否开放赞助入口（默认开；tiers 未配置时入口隐藏，E-5 readiness ②） */
  sponsorshipEnabled?: InputMaybe<EventFilterSponsorshipEnabled>;
  /** 活动开始时间；nil 表示未定（R1） */
  startsAt?: InputMaybe<EventFilterStartsAt>;
  /** 活动状态：draft 草稿 / open 已发布 / closed 已结束 / cancelled 已取消 */
  status?: InputMaybe<EventFilterStatus>;
  /** 活动标题 */
  title?: InputMaybe<EventFilterTitle>;
  /** 结构化场地（country/province/city/district 四键，KTD5/R2）；nil 表示线上或未定 */
  venue?: InputMaybe<EventFilterVenue>;
  /** 可见性：public 公开可见 / workspace 仅工作台可见（可随时双向切换，D9） */
  visibility?: InputMaybe<EventFilterVisibility>;
  /** 教研 workflow 产物引用（领域模型 §5.2 ER） */
  workflowRunId?: InputMaybe<EventFilterWorkflowRunId>;
  /** 所属工作台（租户）ID */
  workspaceId?: InputMaybe<EventFilterWorkspaceId>;
};

export type EventFilterPricingEnabled = {
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
  rangeAdjacent?: InputMaybe<Scalars['Boolean']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['Boolean']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['DateTime']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['DateTime']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['Boolean']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['Boolean']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['JsonString']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['JsonString']['input']>;
};

export type EventFilterSlug = {
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
  rangeAdjacent?: InputMaybe<Scalars['String']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['String']['input']>;
  stringEndsWith?: InputMaybe<Scalars['String']['input']>;
  stringStartsWith?: InputMaybe<Scalars['String']['input']>;
};

export type EventFilterSponsorshipDeadline = {
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
  rangeAdjacent?: InputMaybe<Scalars['DateTime']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['DateTime']['input']>;
};

export type EventFilterSponsorshipEnabled = {
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
  rangeAdjacent?: InputMaybe<Scalars['Boolean']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['Boolean']['input']>;
};

export type EventFilterStartsAt = {
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
  rangeAdjacent?: InputMaybe<Scalars['DateTime']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['DateTime']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['String']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['String']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['String']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['String']['input']>;
  stringEndsWith?: InputMaybe<Scalars['String']['input']>;
  stringStartsWith?: InputMaybe<Scalars['String']['input']>;
};

export type EventFilterVenue = {
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
  rangeAdjacent?: InputMaybe<Scalars['JsonString']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['JsonString']['input']>;
};

export type EventFilterVisibility = {
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
  rangeAdjacent?: InputMaybe<Scalars['String']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['String']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['ID']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['ID']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['ID']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['ID']['input']>;
};

export type EventSortField =
  | 'CAPACITY'
  | 'CONFIRMED_COUNT'
  | 'DESCRIPTION'
  | 'ENDS_AT'
  | 'ENROLLMENT_POLICY'
  | 'ID'
  | 'PRICING_ENABLED'
  | 'REGISTRATION_DEADLINE'
  | 'RESEARCH_ENABLED'
  | 'RESEARCH_REQUIREMENTS'
  | 'SLUG'
  | 'SPONSORSHIP_DEADLINE'
  | 'SPONSORSHIP_ENABLED'
  | 'STARTS_AT'
  | 'STATUS'
  | 'TITLE'
  | 'VENUE'
  | 'VISIBILITY'
  | 'WORKFLOW_RUN_ID'
  | 'WORKSPACE_ID';

export type EventSortInput = {
  field: EventSortField;
  order?: InputMaybe<SortOrder>;
};

export type FulfillDeliveryInput = {
  proofNote: Scalars['String']['input'];
};

/** The result of the :fulfill_delivery mutation */
export type FulfillDeliveryResult = {
  /** Any errors generated, if the mutation failed */
  errors: Array<MutationError>;
  /** The successful result of the mutation */
  result?: Maybe<SponsorshipDelivery>;
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
  rangeAdjacent?: InputMaybe<Scalars['DateTime']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['DateTime']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['ID']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['ID']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['DateTime']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['DateTime']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['ID']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['ID']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['ID']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['ID']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['String']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['String']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['String']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['String']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['String']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['String']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['ID']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['ID']['input']>;
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
  insertedAt: Scalars['DateTime']['output'];
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
  rangeAdjacent?: InputMaybe<Scalars['ID']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['ID']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['ID']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['ID']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['DateTime']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['DateTime']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['ID']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['ID']['input']>;
};

export type InviteBatchFilterInput = {
  and?: InputMaybe<Array<InviteBatchFilterInput>>;
  courseId?: InputMaybe<InviteBatchFilterCourseId>;
  eventId?: InputMaybe<InviteBatchFilterEventId>;
  expiresAt?: InputMaybe<InviteBatchFilterExpiresAt>;
  id?: InputMaybe<InviteBatchFilterId>;
  insertedAt?: InputMaybe<InviteBatchFilterInsertedAt>;
  inviteCode?: InputMaybe<InviteBatchFilterInviteCode>;
  not?: InputMaybe<Array<InviteBatchFilterInput>>;
  or?: InputMaybe<Array<InviteBatchFilterInput>>;
  quota?: InputMaybe<InviteBatchFilterQuota>;
  remainingQuota?: InputMaybe<InviteBatchFilterRemainingQuota>;
  remark?: InputMaybe<InviteBatchFilterRemark>;
  status?: InputMaybe<InviteBatchFilterStatus>;
  workspaceId?: InputMaybe<InviteBatchFilterWorkspaceId>;
};

export type InviteBatchFilterInsertedAt = {
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
  rangeAdjacent?: InputMaybe<Scalars['DateTime']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['DateTime']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['String']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['String']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['Int']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['Int']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['Int']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['Int']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['String']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['String']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['String']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['String']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['ID']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['ID']['input']>;
};

export type InviteBatchSortField =
  | 'COURSE_ID'
  | 'EVENT_ID'
  | 'EXPIRES_AT'
  | 'ID'
  | 'INSERTED_AT'
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

export type IssueChecklistItem = {
  done: Scalars['Boolean']['output'];
  evidence?: Maybe<Scalars['String']['output']>;
  id: Scalars['String']['output'];
  recordedAt?: Maybe<Scalars['DateTime']['output']>;
  text: Scalars['String']['output'];
};

export type IssueMaterial = {
  ref?: Maybe<Scalars['String']['output']>;
  title?: Maybe<Scalars['String']['output']>;
};

export type IssueStory = {
  asA?: Maybe<Scalars['String']['output']>;
  checklist: Array<IssueChecklistItem>;
  given: Array<Scalars['String']['output']>;
  goal?: Maybe<Scalars['String']['output']>;
  materials: Array<IssueMaterial>;
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
  rangeAdjacent?: InputMaybe<Scalars['DateTime']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['DateTime']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['DateTime']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['DateTime']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['ID']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['ID']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['DateTime']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['DateTime']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['ID']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['ID']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['String']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['String']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['String']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['String']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['String']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['String']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['ID']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['ID']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['ID']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['ID']['input']>;
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

/** A keyset page of :order */
export type KeysetPageOfOrder = {
  /** Total count on all pages */
  count?: Maybe<Scalars['Int']['output']>;
  /** The last keyset in the results */
  endKeyset?: Maybe<Scalars['String']['output']>;
  /** The records contained in the page */
  results?: Maybe<Array<Order>>;
  /** The first keyset in the results */
  startKeyset?: Maybe<Scalars['String']['output']>;
};

/** A keyset page of :sponsorship */
export type KeysetPageOfSponsorship = {
  /** Total count on all pages */
  count?: Maybe<Scalars['Int']['output']>;
  /** The last keyset in the results */
  endKeyset?: Maybe<Scalars['String']['output']>;
  /** The records contained in the page */
  results?: Maybe<Array<Sponsorship>>;
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

/** The result of the :launch_course mutation */
export type LaunchCourseResult = {
  /** Any errors generated, if the mutation failed */
  errors: Array<MutationError>;
  /** The successful result of the mutation */
  result?: Maybe<Course>;
};

/** The result of the :launch_event mutation */
export type LaunchEventResult = {
  /** Any errors generated, if the mutation failed */
  errors: Array<MutationError>;
  /** The successful result of the mutation */
  result?: Maybe<Event>;
};

export type LearningIssue = {
  id: Scalars['String']['output'];
  key: Scalars['String']['output'];
  kind: Scalars['String']['output'];
  status: Scalars['String']['output'];
  story?: Maybe<IssueStory>;
  title: Scalars['String']['output'];
};

export type LearningProgress = {
  currentIssueId?: Maybe<Scalars['String']['output']>;
  currentIssueKey?: Maybe<Scalars['String']['output']>;
  currentIssueTitle?: Maybe<Scalars['String']['output']>;
  doneIssues: Scalars['Int']['output'];
  totalIssues: Scalars['Int']['output'];
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

export type MyLearningRun = {
  courseId?: Maybe<Scalars['ID']['output']>;
  currentIssueId?: Maybe<Scalars['String']['output']>;
  currentIssueKey?: Maybe<Scalars['String']['output']>;
  currentIssueTitle?: Maybe<Scalars['String']['output']>;
  doneIssues: Scalars['Int']['output'];
  enrollmentId: Scalars['ID']['output'];
  runId: Scalars['ID']['output'];
  status: Scalars['String']['output'];
  targetTitle?: Maybe<Scalars['String']['output']>;
  totalIssues: Scalars['Int']['output'];
};

export type OfferingReadinessItem = {
  key: Scalars['String']['output'];
  label: Scalars['String']['output'];
  ok: Scalars['Boolean']['output'];
};

export type OfferingReadinessPayload = {
  items: Array<OfferingReadinessItem>;
  ready: Scalars['Boolean']['output'];
};

export type Order = {
  amountCents: Scalars['Int']['output'];
  cancelReason?: Maybe<Scalars['String']['output']>;
  /** 关联报名所属 Course（KTD2：订单按课程筛选） */
  courseId?: Maybe<Scalars['ID']['output']>;
  enrollmentId: Scalars['ID']['output'];
  /** 关联报名当前状态 */
  enrollmentStatus?: Maybe<Scalars['String']['output']>;
  /** 关联报名所属 Event（KTD2：订单按活动筛选） */
  eventId?: Maybe<Scalars['ID']['output']>;
  expireAt: Scalars['DateTime']['output'];
  id: Scalars['ID']['output'];
  /** 报名人邮箱（管理面识别付款人） */
  learnerEmail?: Maybe<Scalars['String']['output']>;
  outTradeNo: Scalars['String']['output'];
  provider: Scalars['String']['output'];
  refundedAt?: Maybe<Scalars['DateTime']['output']>;
  status: Scalars['String']['output'];
  /** 下单时档位快照 id（U8 已售档守卫） */
  tierId?: Maybe<Scalars['String']['output']>;
  /** 下单时档位快照名（R3 改价不追溯） */
  tierName?: Maybe<Scalars['String']['output']>;
  tierSnapshot: Scalars['JsonString']['output'];
  transactionId?: Maybe<Scalars['String']['output']>;
  workspaceId: Scalars['ID']['output'];
};

export type OrderFilterAmountCents = {
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
  rangeAdjacent?: InputMaybe<Scalars['Int']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['Int']['input']>;
};

export type OrderFilterCancelReason = {
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
  rangeAdjacent?: InputMaybe<Scalars['String']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['String']['input']>;
  stringEndsWith?: InputMaybe<Scalars['String']['input']>;
  stringStartsWith?: InputMaybe<Scalars['String']['input']>;
};

export type OrderFilterCourseId = {
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
  rangeAdjacent?: InputMaybe<Scalars['ID']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['ID']['input']>;
};

export type OrderFilterEnrollmentId = {
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
  rangeAdjacent?: InputMaybe<Scalars['ID']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['ID']['input']>;
};

export type OrderFilterEnrollmentStatus = {
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
  rangeAdjacent?: InputMaybe<Scalars['String']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['String']['input']>;
};

export type OrderFilterEventId = {
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
  rangeAdjacent?: InputMaybe<Scalars['ID']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['ID']['input']>;
};

export type OrderFilterExpireAt = {
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
  rangeAdjacent?: InputMaybe<Scalars['DateTime']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['DateTime']['input']>;
};

export type OrderFilterId = {
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
  rangeAdjacent?: InputMaybe<Scalars['ID']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['ID']['input']>;
};

export type OrderFilterInput = {
  amountCents?: InputMaybe<OrderFilterAmountCents>;
  and?: InputMaybe<Array<OrderFilterInput>>;
  cancelReason?: InputMaybe<OrderFilterCancelReason>;
  /** 关联报名所属 Course（KTD2：订单按课程筛选） */
  courseId?: InputMaybe<OrderFilterCourseId>;
  enrollmentId?: InputMaybe<OrderFilterEnrollmentId>;
  /** 关联报名当前状态 */
  enrollmentStatus?: InputMaybe<OrderFilterEnrollmentStatus>;
  /** 关联报名所属 Event（KTD2：订单按活动筛选） */
  eventId?: InputMaybe<OrderFilterEventId>;
  expireAt?: InputMaybe<OrderFilterExpireAt>;
  id?: InputMaybe<OrderFilterId>;
  /** 报名人邮箱（管理面识别付款人） */
  learnerEmail?: InputMaybe<OrderFilterLearnerEmail>;
  not?: InputMaybe<Array<OrderFilterInput>>;
  or?: InputMaybe<Array<OrderFilterInput>>;
  outTradeNo?: InputMaybe<OrderFilterOutTradeNo>;
  provider?: InputMaybe<OrderFilterProvider>;
  refundedAt?: InputMaybe<OrderFilterRefundedAt>;
  status?: InputMaybe<OrderFilterStatus>;
  /** 下单时档位快照 id（U8 已售档守卫） */
  tierId?: InputMaybe<OrderFilterTierId>;
  /** 下单时档位快照名（R3 改价不追溯） */
  tierName?: InputMaybe<OrderFilterTierName>;
  tierSnapshot?: InputMaybe<OrderFilterTierSnapshot>;
  transactionId?: InputMaybe<OrderFilterTransactionId>;
  workspaceId?: InputMaybe<OrderFilterWorkspaceId>;
};

export type OrderFilterLearnerEmail = {
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
  rangeAdjacent?: InputMaybe<Scalars['String']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['String']['input']>;
  stringEndsWith?: InputMaybe<Scalars['String']['input']>;
  stringStartsWith?: InputMaybe<Scalars['String']['input']>;
};

export type OrderFilterOutTradeNo = {
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
  rangeAdjacent?: InputMaybe<Scalars['String']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['String']['input']>;
  stringEndsWith?: InputMaybe<Scalars['String']['input']>;
  stringStartsWith?: InputMaybe<Scalars['String']['input']>;
};

export type OrderFilterProvider = {
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
  rangeAdjacent?: InputMaybe<Scalars['String']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['String']['input']>;
};

export type OrderFilterRefundedAt = {
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
  rangeAdjacent?: InputMaybe<Scalars['DateTime']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['DateTime']['input']>;
};

export type OrderFilterStatus = {
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
  rangeAdjacent?: InputMaybe<Scalars['String']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['String']['input']>;
};

export type OrderFilterTierId = {
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
  rangeAdjacent?: InputMaybe<Scalars['String']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['String']['input']>;
  stringEndsWith?: InputMaybe<Scalars['String']['input']>;
  stringStartsWith?: InputMaybe<Scalars['String']['input']>;
};

export type OrderFilterTierName = {
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
  rangeAdjacent?: InputMaybe<Scalars['String']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['String']['input']>;
  stringEndsWith?: InputMaybe<Scalars['String']['input']>;
  stringStartsWith?: InputMaybe<Scalars['String']['input']>;
};

export type OrderFilterTierSnapshot = {
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
  rangeAdjacent?: InputMaybe<Scalars['JsonString']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['JsonString']['input']>;
};

export type OrderFilterTransactionId = {
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
  rangeAdjacent?: InputMaybe<Scalars['String']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['String']['input']>;
  stringEndsWith?: InputMaybe<Scalars['String']['input']>;
  stringStartsWith?: InputMaybe<Scalars['String']['input']>;
};

export type OrderFilterWorkspaceId = {
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
  rangeAdjacent?: InputMaybe<Scalars['ID']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['ID']['input']>;
};

export type OrderSortField =
  | 'AMOUNT_CENTS'
  | 'CANCEL_REASON'
  | 'COURSE_ID'
  | 'ENROLLMENT_ID'
  | 'ENROLLMENT_STATUS'
  | 'EVENT_ID'
  | 'EXPIRE_AT'
  | 'ID'
  | 'LEARNER_EMAIL'
  | 'OUT_TRADE_NO'
  | 'PROVIDER'
  | 'REFUNDED_AT'
  | 'STATUS'
  | 'TIER_ID'
  | 'TIER_NAME'
  | 'TIER_SNAPSHOT'
  | 'TRANSACTION_ID'
  | 'WORKSPACE_ID';

export type OrderSortInput = {
  field: OrderSortField;
  order?: InputMaybe<SortOrder>;
};

export type PendingApproval = {
  amount?: Maybe<Scalars['Int']['output']>;
  approvalDeadline?: Maybe<Scalars['DateTime']['output']>;
  companyName?: Maybe<Scalars['String']['output']>;
  contactEmail?: Maybe<Scalars['String']['output']>;
  contextTitle?: Maybe<Scalars['String']['output']>;
  courseId?: Maybe<Scalars['ID']['output']>;
  eventId?: Maybe<Scalars['ID']['output']>;
  eventSlug?: Maybe<Scalars['String']['output']>;
  expiredAt?: Maybe<Scalars['DateTime']['output']>;
  id: Scalars['ID']['output'];
  kind: Scalars['String']['output'];
  level?: Maybe<Scalars['String']['output']>;
  requesterName?: Maybe<Scalars['String']['output']>;
  status: Scalars['String']['output'];
  tierName?: Maybe<Scalars['String']['output']>;
  userId: Scalars['ID']['output'];
  workspaceId: Scalars['ID']['output'];
  workspaceName?: Maybe<Scalars['String']['output']>;
  workspaceSlug?: Maybe<Scalars['String']['output']>;
};

export type PermissionMatrixPayload = {
  roles: Array<PermissionMatrixRow>;
};

export type PermissionMatrixRow = {
  abilities: Array<AbilityGrant>;
  /** 角色名：owner / admin / tutor / volunteer / learner */
  name: Scalars['String']['output'];
};

export type PhoneCodePurpose =
  | 'LOGIN'
  | 'WECHAT_BIND';

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

/** The result of the :refund_order mutation */
export type RefundOrderResult = {
  /** Any errors generated, if the mutation failed */
  errors: Array<MutationError>;
  /** The successful result of the mutation */
  result?: Maybe<Order>;
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

export type RejectSponsorshipInput = {
  rejectionReason?: InputMaybe<Scalars['String']['input']>;
};

/** The result of the :reject_sponsorship mutation */
export type RejectSponsorshipResult = {
  /** Any errors generated, if the mutation failed */
  errors: Array<MutationError>;
  /** The successful result of the mutation */
  result?: Maybe<Sponsorship>;
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

export type ReplaceProviderInput = {
  /** 待替换的旧订单（本人 pending 单） */
  orderId: Scalars['ID']['input'];
  provider: Scalars['String']['input'];
};

export type ReplaceProviderMetadata = {
  /** 新渠道支付凭据 */
  credential?: Maybe<Scalars['JsonString']['output']>;
};

/** The result of the :replace_provider mutation */
export type ReplaceProviderResult = {
  /** Any errors generated, if the mutation failed */
  errors: Array<MutationError>;
  /** Metadata produced by the mutation */
  metadata?: Maybe<ReplaceProviderMetadata>;
  /** The successful result of the mutation */
  result?: Maybe<Order>;
};

export type RequestPasswordResetResult = {
  sent: Scalars['Boolean']['output'];
};

export type RequestPhoneCodeResult = {
  retryAfterSeconds: Scalars['Int']['output'];
  sent: Scalars['Boolean']['output'];
};

export type ResendSpeakerInvitationPayload = {
  errors: Array<MutationError>;
  plainToken?: Maybe<Scalars['String']['output']>;
  /** resendSpeakerInvitation 返回：result 为邀请记录；plainToken 新明文仅此一次 */
  result?: Maybe<SpeakerInvitation>;
};

export type ResetPasswordResult = {
  ok: Scalars['Boolean']['output'];
};

/** The result of the :retry_refund mutation */
export type RetryRefundResult = {
  /** Any errors generated, if the mutation failed */
  errors: Array<MutationError>;
  /** The successful result of the mutation */
  result?: Maybe<Order>;
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
  /** 角色名：owner / admin / tutor / volunteer / learner */
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
  rangeAdjacent?: InputMaybe<Scalars['String']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['String']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['ID']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['ID']['input']>;
};

export type RoleFilterInput = {
  and?: InputMaybe<Array<RoleFilterInput>>;
  /** 角色说明 */
  description?: InputMaybe<RoleFilterDescription>;
  id?: InputMaybe<RoleFilterId>;
  /** 角色名：owner / admin / tutor / volunteer / learner */
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
  rangeAdjacent?: InputMaybe<Scalars['String']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['String']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['ID']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['ID']['input']>;
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
  /** Speaker 用邀请 token 接受邀请（着陆页；token 一次性，接受后失效） */
  acceptSpeakerInvitation?: Maybe<SpeakerInvitationActionPayload>;
  /** 使用一次性小程序 scene 接受工作台邀请 */
  admitMemberByToken?: Maybe<Invitation>;
  /** 审批通过加入申请（Owner/Admin，自动建 Membership（默认无标签角色）） */
  approveJoinRequest: ApproveJoinRequestResult;
  /** 审批通过：pending → active，同事务物化履约账本（SponsorshipDelivery） */
  approveSponsorship: ApproveSponsorshipResult;
  /** 审批通过创建工作台申请（platform_admin，自动创建 workspace + applicant 为 Owner） */
  approveWorkspaceApplication: ApproveWorkspaceApplicationResult;
  /** 分配成员角色（多角色并集，仅 Owner/Admin） */
  assignRoles: AssignRolesResult;
  /** 微信扫码绑定手机号完成登录（plan 002 U4；phone 5/15min 限流） */
  bindWechatWithPhone?: Maybe<SignInWithPhoneCodeResult>;
  /** 取消课程：open → cancelled，发 course.ended 信号 */
  cancelCourse: CancelCourseResult;
  /** 报名人取消报名；confirmed/payment_pending 报名释放名额 */
  cancelEnrollment: CancelEnrollmentResult;
  /** 取消活动：open → cancelled，发 event.ended 信号 */
  cancelEvent: CancelEventResult;
  /** 报名者取消自己的 pending 订单（报名保持 payment_pending 可再下单，R12） */
  cancelOrder: CancelOrderResult;
  /** 结束课程：open → closed，发 course.ended 信号 */
  closeCourse: CloseCourseResult;
  /** 结束活动：open → closed，发 event.ended 信号 */
  closeEvent: CloseEventResult;
  /** 材料产出后完成邀请（Speaker 本人自助或 Owner/Admin 兜底；accepted → completed） */
  completeSpeakerInvitation?: Maybe<SpeakerInvitationActionPayload>;
  /** Owner/Admin 确认 pending 报名并原子占用名额 */
  confirmEnrollment: ConfirmEnrollmentResult;
  /** 创建课程（默认 status=draft） */
  createCourse: CreateCourseResult;
  /** 创建报名；open/invite_only 立即占位，request 等待审批 */
  createEnrollment: CreateEnrollmentResult;
  /** 创建活动（默认 status=draft） */
  createEvent: CreateEventResult;
  /** 创建邀请（Owner/Admin/Volunteer） */
  createInvitation: CreateInvitationResult;
  createInviteBatch: CreateInviteBatchResult;
  /** 提交加入申请 */
  createJoinRequest: CreateJoinRequestResult;
  /** 签发 MCP 连接 token（切片 D #44；明文仅本次经 plainToken 返回一次，库中只存 SHA256 hash） */
  createMcpToken?: Maybe<CreateMcpTokenPayload>;
  /** 报名者下单：payment_pending 报名 → pending 订单 + 渠道凭据（R5/R6/R13） */
  createOrder: CreateOrderResult;
  /** 在某工作台创建作品集条目（ADR-0004；workspace_id 与 user_id 自动填充，防跨租户伪造） */
  createPortfolioItem?: Maybe<PortfolioItem>;
  /** Owner/Admin 创建 Speaker 邀请；明文 token 仅经 plainToken 返回一次（库中只存 SHA256 哈希） */
  createSpeakerInvitation?: Maybe<CreateSpeakerInvitationPayload>;
  /** 提交赞助意向：校验后创建 pending（不生效权益，等审批） */
  createSponsorship: CreateSponsorshipResult;
  /** 创建工作台（仅平台管理员） */
  createWorkspace: CreateWorkspaceResult;
  /** 提交创建工作台申请 */
  createWorkspaceApplication: CreateWorkspaceApplicationResult;
  /** Speaker 用邀请 token 婉拒邀请（着陆页；token 一次性，婉拒后失效） */
  declineSpeakerInvitation?: Maybe<SpeakerInvitationActionPayload>;
  /** 删除某工作台自己的作品集条目（ADR-0004；tenant 隔离） */
  deletePortfolioItem?: Maybe<PortfolioItem>;
  /** 平台管理员：降级用户 platform_admin（R9；≥1 admin 不变量由 User :demote_platform_admin action 守卫） */
  demoteUser?: Maybe<AdminUserPayload>;
  disableInviteBatch: DisableInviteBatchResult;
  /** 拒绝首公里接入邀请（每次登录弹直到明确拒绝；幂等保留首次拒绝时间戳，仅本人） */
  dismissOnboardingInvitation?: Maybe<User>;
  /** 后台核销交付行（fulfilled_at + proof_note；Owner/Admin） */
  fulfillDelivery: FulfillDeliveryResult;
  /** Owner/Admin 创建一次性工作台邀请小程序码 */
  generateMiniProgramCode?: Maybe<MiniprogramCodeResult>;
  /** 记录一次小程序订阅消息授权并增加一个可用次数 */
  grantMiniProgramNotificationConsent?: Maybe<Scalars['Int']['output']>;
  /** 直接加入公开工作台（join_policy==:open）→ 建无标签 Membership */
  joinWorkspace: Workspace;
  /** 发布课程：draft → open，发 course.launched 信号 */
  launchCourse: LaunchCourseResult;
  /** 发布活动：draft → open，发 event.launched 信号 */
  launchEvent: LaunchEventResult;
  /** 平台管理员：提升用户为 platform_admin（R9；仅 platform_admin 可调） */
  promoteUser?: Maybe<AdminUserPayload>;
  /** 重指派 Owner（仅平台管理员，pending-owner 期间）：撤销 active Owner 邀请 + 改指现有用户或发新邀请 */
  reassignWorkspaceOwner: ReassignWorkspaceOwnerResult;
  /** 管理员单笔全额退款：paid → refunding 并入队渠道退款（退款即取消，ADR-0007） */
  refundOrder: RefundOrderResult;
  /** Owner/Admin 拒绝 pending 报名 */
  rejectEnrollment: RejectEnrollmentResult;
  /** 拒绝加入申请（Owner/Admin） */
  rejectJoinRequest: RejectJoinRequestResult;
  /** 审批拒绝：pending → rejected，rejection_reason 落审计字段 */
  rejectSponsorship: RejectSponsorshipResult;
  /** 拒绝创建工作台申请（platform_admin） */
  rejectWorkspaceApplication: RejectWorkspaceApplicationResult;
  /** 换渠道：旧 pending 单 cancelled + 新单（新 out_trade_no），R11 */
  replaceProvider: ReplaceProviderResult;
  /** 请求发送密码重置邮件（无论邮箱是否存在都返回统一成功结果） */
  requestPasswordReset?: Maybe<RequestPasswordResetResult>;
  /** 请求发送手机验证码（plan 002 U3；限流 phone 1/60s + 5/1h + 20/1d、IP 30/1d） */
  requestPhoneCode?: Maybe<RequestPhoneCodeResult>;
  /** Owner/Admin 重发邀请/重新生成链接：旧链接即刻作废，新明文 token 仅经 plainToken 返回一次；有邮箱的同时异步发出新邮件（尽力而为，不承诺送达） */
  resendSpeakerInvitation?: Maybe<ResendSpeakerInvitationPayload>;
  /** 使用一次性密码重置 token 设置新密码 */
  resetPassword?: Maybe<ResetPasswordResult>;
  /** 管理员重试退款：refund_failed → refunding 重入退款链（R17） */
  retryRefund: RetryRefundResult;
  /** 撤销邀请（邀请人本人或 Owner/Admin 或平台管理员） */
  revokeInvitation: RevokeInvitationResult;
  /** 撤销 MCP 连接 token（切片 D #44；仅本人，置 revokedAt 保留审计行；他人 token 一律 not_found 不泄露存在性） */
  revokeMcpToken?: Maybe<McpToken>;
  /** Speaker 保存分享材料（落 WorkflowRun.facts[materials]；Speaker 本人自助或 Owner/Admin 兜底；materials 为 JSON 字符串） */
  saveSpeakerMaterials?: Maybe<SpeakerInvitationActionPayload>;
  /** 设置当前用户在某工作台的 UI 主题偏好（ADR-0004 per-workspace） */
  setWorkspaceTheme?: Maybe<WorkspaceProfile>;
  /** 账号密码登录（plan 002 U2：login 含 @ 走邮箱，否则手机号归一化；token 经 httpOnly cookie 交付） */
  signIn?: Maybe<SignInResult>;
  /** 手机验证码登录（plan 002 U3；用户不存在自动建号；token 经 httpOnly cookie 交付） */
  signInWithPhoneCode?: Maybe<SignInWithPhoneCodeResult>;
  /** 小程序平台一键登录（N1，Phase 1）：code2session + 平台手机号锚定统一身份，token 经 httpOnly cookie 交付 */
  signInWithPlatform?: Maybe<SignInWithPlatformResult>;
  /** 微信扫码回调（plan 002 U4；IP 20/15min 限流）：已绑定直登，未绑定返回绑定票据 */
  signInWithWechat?: Maybe<SignInWithWechatResult>;
  /** 登出：服务端撤销当前 token 并清除 httpOnly cookie（token 被偷也无法重放） */
  signOut?: Maybe<Scalars['String']['output']>;
  /** 注册新用户（#60 路径 B：httpOnly cookie 交付 token，自动登录） */
  signUp?: Maybe<SignUpPayload>;
  /** 编辑课程元数据（Owner/Admin） */
  updateCourse: UpdateCourseResult;
  /** 更新当前用户全局显示名（ADR-0004：displayName 保留全局身份字段） */
  updateDisplayName?: Maybe<User>;
  /** 编辑活动元数据（Owner/Admin） */
  updateEvent: UpdateEventResult;
  /** 更新当前用户界面语言偏好（i18n Phase 1；zh-CN | en，仅本人） */
  updateMyLocale?: Maybe<User>;
  /** 更新某工作台自己的作品集条目（ADR-0004；tenant 隔离） */
  updatePortfolioItem?: Maybe<PortfolioItem>;
  /** 更新工作台（Owner/Admin 或平台管理员） */
  updateWorkspace: UpdateWorkspaceResult;
  /** 更新当前用户在某工作台的资料（ADR-0004 per-workspace） */
  updateWorkspaceProfile?: Maybe<WorkspaceProfile>;
  /** Owner/Admin/平台管理员免缴：payment_pending → confirmed（个案免费唯一入口，R18） */
  waivePayment: WaivePaymentResult;
  /** 发起微信扫码登录（plan 002 U4；未配置 → wechat_login_unavailable；IP 20/15min 限流） */
  wechatLoginStart?: Maybe<WechatLoginStartResult>;
};


export type RootMutationTypeAcceptInvitationArgs = {
  id: Scalars['ID']['input'];
  input: AcceptInvitationInput;
};


export type RootMutationTypeAcceptSpeakerInvitationArgs = {
  token: Scalars['String']['input'];
};


export type RootMutationTypeAdmitMemberByTokenArgs = {
  scene: Scalars['String']['input'];
};


export type RootMutationTypeApproveJoinRequestArgs = {
  id: Scalars['ID']['input'];
  input?: InputMaybe<ApproveJoinRequestInput>;
};


export type RootMutationTypeApproveSponsorshipArgs = {
  id: Scalars['ID']['input'];
};


export type RootMutationTypeApproveWorkspaceApplicationArgs = {
  id: Scalars['ID']['input'];
};


export type RootMutationTypeAssignRolesArgs = {
  id: Scalars['ID']['input'];
  input: AssignRolesInput;
};


export type RootMutationTypeBindWechatWithPhoneArgs = {
  bindTicket: Scalars['String']['input'];
  code: Scalars['String']['input'];
  phone: Scalars['String']['input'];
};


export type RootMutationTypeCancelCourseArgs = {
  id: Scalars['ID']['input'];
};


export type RootMutationTypeCancelEnrollmentArgs = {
  id: Scalars['ID']['input'];
};


export type RootMutationTypeCancelEventArgs = {
  id: Scalars['ID']['input'];
};


export type RootMutationTypeCancelOrderArgs = {
  id: Scalars['ID']['input'];
};


export type RootMutationTypeCloseCourseArgs = {
  id: Scalars['ID']['input'];
};


export type RootMutationTypeCloseEventArgs = {
  id: Scalars['ID']['input'];
};


export type RootMutationTypeCompleteSpeakerInvitationArgs = {
  id: Scalars['ID']['input'];
};


export type RootMutationTypeConfirmEnrollmentArgs = {
  id: Scalars['ID']['input'];
};


export type RootMutationTypeCreateCourseArgs = {
  input: CreateCourseInput;
};


export type RootMutationTypeCreateEnrollmentArgs = {
  input: CreateEnrollmentInput;
};


export type RootMutationTypeCreateEventArgs = {
  input: CreateEventInput;
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


export type RootMutationTypeCreateOrderArgs = {
  input: CreateOrderInput;
};


export type RootMutationTypeCreatePortfolioItemArgs = {
  input: CreatePortfolioItemInput;
  workspaceId: Scalars['ID']['input'];
};


export type RootMutationTypeCreateSpeakerInvitationArgs = {
  input: CreateSpeakerInvitationInput;
};


export type RootMutationTypeCreateSponsorshipArgs = {
  input: CreateSponsorshipInput;
};


export type RootMutationTypeCreateWorkspaceArgs = {
  input: CreateWorkspaceInput;
};


export type RootMutationTypeCreateWorkspaceApplicationArgs = {
  input: CreateWorkspaceApplicationInput;
};


export type RootMutationTypeDeclineSpeakerInvitationArgs = {
  token: Scalars['String']['input'];
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


export type RootMutationTypeFulfillDeliveryArgs = {
  id: Scalars['ID']['input'];
  input: FulfillDeliveryInput;
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


export type RootMutationTypeLaunchCourseArgs = {
  id: Scalars['ID']['input'];
};


export type RootMutationTypeLaunchEventArgs = {
  id: Scalars['ID']['input'];
};


export type RootMutationTypePromoteUserArgs = {
  id: Scalars['ID']['input'];
};


export type RootMutationTypeReassignWorkspaceOwnerArgs = {
  id: Scalars['ID']['input'];
  input?: InputMaybe<ReassignWorkspaceOwnerInput>;
};


export type RootMutationTypeRefundOrderArgs = {
  id: Scalars['ID']['input'];
};


export type RootMutationTypeRejectEnrollmentArgs = {
  id: Scalars['ID']['input'];
  input?: InputMaybe<RejectEnrollmentInput>;
};


export type RootMutationTypeRejectJoinRequestArgs = {
  id: Scalars['ID']['input'];
  input?: InputMaybe<RejectJoinRequestInput>;
};


export type RootMutationTypeRejectSponsorshipArgs = {
  id: Scalars['ID']['input'];
  input?: InputMaybe<RejectSponsorshipInput>;
};


export type RootMutationTypeRejectWorkspaceApplicationArgs = {
  id: Scalars['ID']['input'];
  input?: InputMaybe<RejectWorkspaceApplicationInput>;
};


export type RootMutationTypeReplaceProviderArgs = {
  input: ReplaceProviderInput;
};


export type RootMutationTypeRequestPasswordResetArgs = {
  email: Scalars['String']['input'];
};


export type RootMutationTypeRequestPhoneCodeArgs = {
  phone: Scalars['String']['input'];
  purpose: PhoneCodePurpose;
};


export type RootMutationTypeResendSpeakerInvitationArgs = {
  id: Scalars['ID']['input'];
};


export type RootMutationTypeResetPasswordArgs = {
  password: Scalars['String']['input'];
  resetToken: Scalars['String']['input'];
};


export type RootMutationTypeRetryRefundArgs = {
  id: Scalars['ID']['input'];
};


export type RootMutationTypeRevokeInvitationArgs = {
  id: Scalars['ID']['input'];
};


export type RootMutationTypeRevokeMcpTokenArgs = {
  id: Scalars['ID']['input'];
};


export type RootMutationTypeSaveSpeakerMaterialsArgs = {
  invitationId: Scalars['ID']['input'];
  materials: Scalars['JsonString']['input'];
};


export type RootMutationTypeSetWorkspaceThemeArgs = {
  input: SetWorkspaceThemeInput;
  workspaceId: Scalars['ID']['input'];
};


export type RootMutationTypeSignInArgs = {
  login: Scalars['String']['input'];
  password: Scalars['String']['input'];
};


export type RootMutationTypeSignInWithPhoneCodeArgs = {
  code: Scalars['String']['input'];
  phone: Scalars['String']['input'];
};


export type RootMutationTypeSignInWithPlatformArgs = {
  code: Scalars['String']['input'];
  encryptedData?: InputMaybe<Scalars['String']['input']>;
  iv?: InputMaybe<Scalars['String']['input']>;
  phoneCode?: InputMaybe<Scalars['String']['input']>;
  platform: Scalars['String']['input'];
};


export type RootMutationTypeSignInWithWechatArgs = {
  code: Scalars['String']['input'];
  state: Scalars['String']['input'];
};


export type RootMutationTypeSignUpArgs = {
  input: SignUpInput;
};


export type RootMutationTypeUpdateCourseArgs = {
  id: Scalars['ID']['input'];
  input?: InputMaybe<UpdateCourseInput>;
};


export type RootMutationTypeUpdateDisplayNameArgs = {
  displayName: Scalars['String']['input'];
};


export type RootMutationTypeUpdateEventArgs = {
  id: Scalars['ID']['input'];
  input?: InputMaybe<UpdateEventInput>;
};


export type RootMutationTypeUpdateMyLocaleArgs = {
  locale: Scalars['String']['input'];
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


export type RootMutationTypeWaivePaymentArgs = {
  id: Scalars['ID']['input'];
};


export type RootMutationTypeWechatLoginStartArgs = {
  next?: InputMaybe<Scalars['String']['input']>;
};

export type RootQueryType = {
  /** 当前用户的课程学习详情（U7 抽屉数据：课程地图 + 本人记录合成；恒 actor 视角无他人面） */
  courseLearningDetail?: Maybe<CourseLearningDetail>;
  /** 公开课程地图(U7/R10):issue key/标题/kind/goal 一行;匿名可读,不露 checklist */
  courseMap?: Maybe<CourseMap>;
  enrollments?: Maybe<KeysetPageOfEnrollment>;
  /** 按 id 获取课程（#40） */
  getCourse?: Maybe<Course>;
  /** 按 slug 获取（E-5 公开宿主页） */
  getCourseBySlug?: Maybe<Course>;
  /** 按 id 获取活动（#40） */
  getEvent?: Maybe<Event>;
  /** 按 slug 获取（E-5 公开宿主页） */
  getEventBySlug?: Maybe<Event>;
  getSponsorship?: Maybe<Sponsorship>;
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
  /** 当前用户跨工作台的报名记录 */
  myEnrollments?: Maybe<KeysetPageOfEnrollment>;
  /** 当前用户 confirmed 报名对应的学习 run 进度（非成员可读） */
  myLearningRuns: Array<MyLearningRun>;
  /** 当前用户的 MCP 连接 token 列表（切片 D #44；不含明文，新→旧；policy 仅见本人） */
  myMcpTokens?: Maybe<Array<Maybe<McpToken>>>;
  /** 当前用户订单列表（R14） */
  myOrders?: Maybe<KeysetPageOfOrder>;
  /** 当前用户作为 Owner/Admin 的跨工作台待审批项（Enrollment + JoinRequest + Sponsorship）；include_expired=true 时附带已过期行（只读展示，E-8 #123） */
  myPendingApprovals: Array<PendingApproval>;
  /** 当前用户跨工作台的赞助意向 */
  mySponsorships?: Maybe<KeysetPageOfSponsorship>;
  /** 当前用户（申请人）的工作台创建申请列表（R7a；任何人可见自己的申请） */
  myWorkspaceApplications: Array<AdminWorkspaceApplication>;
  /** 当前用户在某工作台的作品集条目列表（ADR-0004 per-workspace） */
  myWorkspacePortfolio?: Maybe<Array<Maybe<PortfolioItem>>>;
  /** 当前用户在某工作台的 MCP 工具调用活动流（plan 020 U2.1；policy：workspace 成员 + 仅本人；params 摘要级不返回） */
  myWorkspaceToolCalls: Array<WorkspaceToolCall>;
  offeringReadiness?: Maybe<OfferingReadinessPayload>;
  /** 订单状态轮询（2s×30s 轻量面，R14） */
  orderStatus?: Maybe<Order>;
  /** 当前用户作为 Owner/Admin 的跨工作台可操作待办总数（Enrollment + JoinRequest + Sponsorship 的 pending 且未过审批截止）；已过期不计（KTD8 口径，与 /approvals 展示含过期行存在有意差异） */
  pendingApprovalsCount: Scalars['Int']['output'];
  /** 角色权限矩阵（#66 Rbac）：五角色 × 八能力，对齐前端权限表（需登录；#1 能力接口：abilities 为通用列表） */
  permissionMatrix?: Maybe<PermissionMatrixPayload>;
  /** Placeholder query until the first resource is added */
  ping?: Maybe<Scalars['String']['output']>;
  /** 平台管理员：对账扫描发现（E-10 #125；rule/entity_type 枚举过滤、workspaceId 真实列过滤，分页 first/after） */
  reconciliationFindings: Array<AdminReconciliationFinding>;
  /** 邀请卡片（Speaker 着陆页，无需登录）：token 公开校验，返回邀请主题/时间 + Event 公开信息 + viewerIsInviter；无效/过期/已用 token 统一错误，不泄露其它邀请 */
  speakerInvitationCard?: Maybe<SpeakerInvitationCard>;
  /** 某 Event 的 Speaker 邀请列表（仅 Owner/Admin 或平台管理员，read policy 兜底） */
  speakerInvitations: Array<SpeakerInvitation>;
  sponsorships?: Maybe<KeysetPageOfSponsorship>;
  /** 校验邀请 token，返回邀请信息 + 工作台预览 */
  validateInvitation?: Maybe<Invitation>;
  /** 工作台创建申请列表（申请人仅见自己；platform_admin 见全部） */
  workspaceApplications?: Maybe<KeysetPageOfWorkspaceApplication>;
  /** 工作台成员列表（成员本人仅见自己；Owner/Admin 见全部，供成员管理页） */
  workspaceMembers?: Maybe<KeysetPageOfWorkspaceMembership>;
  /** 工作台订单列表（R24 管理面） */
  workspaceOrders?: Maybe<KeysetPageOfOrder>;
  /** 工作台收款统计（R24/U4）：已收/待收/已退；可选 eventId/courseId 收敛到单活动口径 */
  workspacePaymentStats: Scalars['JsonString']['output'];
  /** 当前用户在某工作台的公开资料（ADR-0004 per-workspace；按 visibility 授权） */
  workspaceProfile?: Maybe<WorkspaceProfile>;
};


export type RootQueryTypeCourseLearningDetailArgs = {
  courseId: Scalars['ID']['input'];
};


export type RootQueryTypeCourseMapArgs = {
  slug: Scalars['String']['input'];
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


export type RootQueryTypeGetCourseBySlugArgs = {
  filter?: InputMaybe<CourseFilterInput>;
  slug: Scalars['String']['input'];
};


export type RootQueryTypeGetEventArgs = {
  filter?: InputMaybe<EventFilterInput>;
  id: Scalars['ID']['input'];
};


export type RootQueryTypeGetEventBySlugArgs = {
  filter?: InputMaybe<EventFilterInput>;
  slug: Scalars['String']['input'];
};


export type RootQueryTypeGetSponsorshipArgs = {
  filter?: InputMaybe<SponsorshipFilterInput>;
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


export type RootQueryTypeMyEnrollmentsArgs = {
  after?: InputMaybe<Scalars['String']['input']>;
  before?: InputMaybe<Scalars['String']['input']>;
  filter?: InputMaybe<EnrollmentFilterInput>;
  first?: InputMaybe<Scalars['Int']['input']>;
  last?: InputMaybe<Scalars['Int']['input']>;
  sort?: InputMaybe<Array<InputMaybe<EnrollmentSortInput>>>;
};


export type RootQueryTypeMyOrdersArgs = {
  after?: InputMaybe<Scalars['String']['input']>;
  before?: InputMaybe<Scalars['String']['input']>;
  filter?: InputMaybe<OrderFilterInput>;
  first?: InputMaybe<Scalars['Int']['input']>;
  last?: InputMaybe<Scalars['Int']['input']>;
  sort?: InputMaybe<Array<InputMaybe<OrderSortInput>>>;
};


export type RootQueryTypeMyPendingApprovalsArgs = {
  includeExpired?: InputMaybe<Scalars['Boolean']['input']>;
};


export type RootQueryTypeMySponsorshipsArgs = {
  after?: InputMaybe<Scalars['String']['input']>;
  before?: InputMaybe<Scalars['String']['input']>;
  filter?: InputMaybe<SponsorshipFilterInput>;
  first?: InputMaybe<Scalars['Int']['input']>;
  last?: InputMaybe<Scalars['Int']['input']>;
  sort?: InputMaybe<Array<InputMaybe<SponsorshipSortInput>>>;
};


export type RootQueryTypeMyWorkspacePortfolioArgs = {
  workspaceId: Scalars['ID']['input'];
};


export type RootQueryTypeMyWorkspaceToolCallsArgs = {
  first?: InputMaybe<Scalars['Int']['input']>;
  workspaceId: Scalars['ID']['input'];
};


export type RootQueryTypeOfferingReadinessArgs = {
  id: Scalars['ID']['input'];
};


export type RootQueryTypeOrderStatusArgs = {
  filter?: InputMaybe<OrderFilterInput>;
  id: Scalars['ID']['input'];
};


export type RootQueryTypeReconciliationFindingsArgs = {
  after?: InputMaybe<Scalars['String']['input']>;
  entityType?: InputMaybe<Scalars['String']['input']>;
  first?: InputMaybe<Scalars['Int']['input']>;
  rule?: InputMaybe<Scalars['String']['input']>;
  workspaceId?: InputMaybe<Scalars['ID']['input']>;
};


export type RootQueryTypeSpeakerInvitationCardArgs = {
  token: Scalars['String']['input'];
};


export type RootQueryTypeSpeakerInvitationsArgs = {
  eventId: Scalars['ID']['input'];
};


export type RootQueryTypeSponsorshipsArgs = {
  after?: InputMaybe<Scalars['String']['input']>;
  before?: InputMaybe<Scalars['String']['input']>;
  filter?: InputMaybe<SponsorshipFilterInput>;
  first?: InputMaybe<Scalars['Int']['input']>;
  last?: InputMaybe<Scalars['Int']['input']>;
  sort?: InputMaybe<Array<InputMaybe<SponsorshipSortInput>>>;
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


export type RootQueryTypeWorkspaceOrdersArgs = {
  after?: InputMaybe<Scalars['String']['input']>;
  before?: InputMaybe<Scalars['String']['input']>;
  filter?: InputMaybe<OrderFilterInput>;
  first?: InputMaybe<Scalars['Int']['input']>;
  last?: InputMaybe<Scalars['Int']['input']>;
  sort?: InputMaybe<Array<InputMaybe<OrderSortInput>>>;
  workspaceId: Scalars['ID']['input'];
};


export type RootQueryTypeWorkspacePaymentStatsArgs = {
  courseId?: InputMaybe<Scalars['ID']['input']>;
  eventId?: InputMaybe<Scalars['ID']['input']>;
  workspaceId: Scalars['ID']['input'];
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

export type SignInWithPhoneCodeResult = {
  email?: Maybe<Scalars['String']['output']>;
  id: Scalars['ID']['output'];
  isPlatformAdmin: Scalars['Boolean']['output'];
};

export type SignInWithPlatformResult = {
  email?: Maybe<Scalars['String']['output']>;
  id: Scalars['ID']['output'];
  isPlatformAdmin: Scalars['Boolean']['output'];
};

export type SignInWithWechatResult = {
  bindTicket?: Maybe<Scalars['String']['output']>;
  status: WechatSignInStatus;
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

export type SpeakerInvitation = {
  acceptedAt?: Maybe<Scalars['DateTime']['output']>;
  acceptedBy?: Maybe<Scalars['ID']['output']>;
  completedAt?: Maybe<Scalars['DateTime']['output']>;
  declinedAt?: Maybe<Scalars['DateTime']['output']>;
  /** 目标活动（Event）ID */
  eventId: Scalars['ID']['output'];
  /** token 有效期（可空 = 不设过期） */
  expiresAt?: Maybe<Scalars['DateTime']['output']>;
  id: Scalars['ID']['output'];
  /** 发起人（Owner/Admin） */
  invitedBy: Scalars['ID']['output'];
  /** 备注（可选） */
  note?: Maybe<Scalars['String']['output']>;
  /** 分享时间（可选） */
  scheduledAt?: Maybe<Scalars['DateTime']['output']>;
  /** 被邀请人邮箱（可空 = 手动转发链接） */
  speakerEmail?: Maybe<Scalars['String']['output']>;
  /** 被邀请人姓名 */
  speakerName: Scalars['String']['output'];
  /** 接受后绑定的全局账号（拍板 #1：Speaker 必须全局账号，不成为成员） */
  speakerUserId?: Maybe<Scalars['ID']['output']>;
  /** 状态机：invited / accepted / declined / completed */
  status: Scalars['String']['output'];
  /** 分享主题（可选） */
  topic?: Maybe<Scalars['String']['output']>;
  /** 来源邀请 workflow run（材料产出落点，邀请设计 §5.3；仅 create action 内部写入，同 Event.workflow_run_id 先例） */
  workflowRunId?: Maybe<Scalars['ID']['output']>;
  /** 所属工作台（租户）ID（= Event 的 workspace_id） */
  workspaceId: Scalars['ID']['output'];
};

export type SpeakerInvitationActionPayload = {
  errors: Array<MutationError>;
  /** accept/decline/saveSpeakerMaterials/completeSpeakerInvitation 返回：result + errors 两段式 */
  result?: Maybe<SpeakerInvitation>;
};

export type SpeakerInvitationCard = {
  event: SpeakerInvitationCardEvent;
  scheduledAt?: Maybe<Scalars['DateTime']['output']>;
  /** token 公开卡片：邀请主题/时间 + Event 公开信息（D2 白名单，不泄露其它邀请） */
  status: Scalars['String']['output'];
  topic?: Maybe<Scalars['String']['output']>;
  /** 当前登录用户是否为发出人（匿名为 false；不泄露 invitedBy） */
  viewerIsInviter: Scalars['Boolean']['output'];
};

export type SpeakerInvitationCardEvent = {
  description?: Maybe<Scalars['String']['output']>;
  id: Scalars['ID']['output'];
  slug?: Maybe<Scalars['String']['output']>;
  status: Scalars['String']['output'];
  title: Scalars['String']['output'];
};

export type Sponsorship = {
  /** 意向金额（元，v1 仅登记不收款；可空） */
  amount?: Maybe<Scalars['Int']['output']>;
  approvalDeadline?: Maybe<Scalars['DateTime']['output']>;
  approvedAt?: Maybe<Scalars['DateTime']['output']>;
  approvedBy?: Maybe<Scalars['ID']['output']>;
  /** 赞助方公司/展示名 */
  companyName: Scalars['String']['output'];
  /** 联系邮箱（必填） */
  contactEmail: Scalars['String']['output'];
  contactPhone?: Maybe<Scalars['String']['output']>;
  deliveries: Array<SponsorshipDelivery>;
  endedAt?: Maybe<Scalars['DateTime']['output']>;
  eventId?: Maybe<Scalars['ID']['output']>;
  expiredAt?: Maybe<Scalars['DateTime']['output']>;
  id: Scalars['ID']['output'];
  /** 赞助级别：event 单场 / workspace 长期 */
  level: Scalars['String']['output'];
  /** 备注/合作意向 */
  message?: Maybe<Scalars['String']['output']>;
  rejectionReason?: Maybe<Scalars['String']['output']>;
  /** 赞助方（全局账号，非成员） */
  sponsorUserId: Scalars['ID']['output'];
  startedAt?: Maybe<Scalars['DateTime']['output']>;
  status: Scalars['String']['output'];
  targetTitle?: Maybe<Scalars['String']['output']>;
  /** 意向档位（指向目标 sponsorship_tiers 配置内的档位 id，可选） */
  tierId?: Maybe<Scalars['ID']['output']>;
  /** 档位展示名冗余（审批/展示用） */
  tierName?: Maybe<Scalars['String']['output']>;
  workflowRunId?: Maybe<Scalars['ID']['output']>;
  /** 所属工作台（租户）：Event 级 = 活动所属工作台；Workspace 级 = 目标工作台 */
  workspaceId: Scalars['ID']['output'];
};


export type SponsorshipDeliveriesArgs = {
  filter?: InputMaybe<SponsorshipDeliveryFilterInput>;
  limit?: InputMaybe<Scalars['Int']['input']>;
  offset?: InputMaybe<Scalars['Int']['input']>;
  sort?: InputMaybe<Array<InputMaybe<SponsorshipDeliverySortInput>>>;
};

export type SponsorshipDelivery = {
  /** 权益项名（物化自 tier.benefits） */
  benefit: Scalars['String']['output'];
  dueDate?: Maybe<Scalars['DateTime']['output']>;
  /** 独占位标记（随档位复制） */
  exclusive: Scalars['Boolean']['output'];
  fulfilledAt?: Maybe<Scalars['DateTime']['output']>;
  id: Scalars['ID']['output'];
  proofNote?: Maybe<Scalars['String']['output']>;
  sponsorshipId: Scalars['ID']['output'];
  /** 所属工作台（物化时从 Sponsorship 复制，租户） */
  workspaceId: Scalars['ID']['output'];
};

export type SponsorshipDeliveryFilterBenefit = {
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
  rangeAdjacent?: InputMaybe<Scalars['String']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['String']['input']>;
  stringEndsWith?: InputMaybe<Scalars['String']['input']>;
  stringStartsWith?: InputMaybe<Scalars['String']['input']>;
};

export type SponsorshipDeliveryFilterDueDate = {
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
  rangeAdjacent?: InputMaybe<Scalars['DateTime']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['DateTime']['input']>;
};

export type SponsorshipDeliveryFilterExclusive = {
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
  rangeAdjacent?: InputMaybe<Scalars['Boolean']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['Boolean']['input']>;
};

export type SponsorshipDeliveryFilterFulfilledAt = {
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
  rangeAdjacent?: InputMaybe<Scalars['DateTime']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['DateTime']['input']>;
};

export type SponsorshipDeliveryFilterId = {
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
  rangeAdjacent?: InputMaybe<Scalars['ID']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['ID']['input']>;
};

export type SponsorshipDeliveryFilterInput = {
  and?: InputMaybe<Array<SponsorshipDeliveryFilterInput>>;
  /** 权益项名（物化自 tier.benefits） */
  benefit?: InputMaybe<SponsorshipDeliveryFilterBenefit>;
  dueDate?: InputMaybe<SponsorshipDeliveryFilterDueDate>;
  /** 独占位标记（随档位复制） */
  exclusive?: InputMaybe<SponsorshipDeliveryFilterExclusive>;
  fulfilledAt?: InputMaybe<SponsorshipDeliveryFilterFulfilledAt>;
  id?: InputMaybe<SponsorshipDeliveryFilterId>;
  not?: InputMaybe<Array<SponsorshipDeliveryFilterInput>>;
  or?: InputMaybe<Array<SponsorshipDeliveryFilterInput>>;
  proofNote?: InputMaybe<SponsorshipDeliveryFilterProofNote>;
  sponsorshipId?: InputMaybe<SponsorshipDeliveryFilterSponsorshipId>;
  /** 所属工作台（物化时从 Sponsorship 复制，租户） */
  workspaceId?: InputMaybe<SponsorshipDeliveryFilterWorkspaceId>;
};

export type SponsorshipDeliveryFilterProofNote = {
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
  rangeAdjacent?: InputMaybe<Scalars['String']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['String']['input']>;
  stringEndsWith?: InputMaybe<Scalars['String']['input']>;
  stringStartsWith?: InputMaybe<Scalars['String']['input']>;
};

export type SponsorshipDeliveryFilterSponsorshipId = {
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
  rangeAdjacent?: InputMaybe<Scalars['ID']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['ID']['input']>;
};

export type SponsorshipDeliveryFilterWorkspaceId = {
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
  rangeAdjacent?: InputMaybe<Scalars['ID']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['ID']['input']>;
};

export type SponsorshipDeliverySortField =
  | 'BENEFIT'
  | 'DUE_DATE'
  | 'EXCLUSIVE'
  | 'FULFILLED_AT'
  | 'ID'
  | 'PROOF_NOTE'
  | 'SPONSORSHIP_ID'
  | 'WORKSPACE_ID';

export type SponsorshipDeliverySortInput = {
  field: SponsorshipDeliverySortField;
  order?: InputMaybe<SortOrder>;
};

export type SponsorshipFilterAmount = {
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
  rangeAdjacent?: InputMaybe<Scalars['Int']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['Int']['input']>;
};

export type SponsorshipFilterApprovalDeadline = {
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
  rangeAdjacent?: InputMaybe<Scalars['DateTime']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['DateTime']['input']>;
};

export type SponsorshipFilterApprovedAt = {
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
  rangeAdjacent?: InputMaybe<Scalars['DateTime']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['DateTime']['input']>;
};

export type SponsorshipFilterApprovedBy = {
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
  rangeAdjacent?: InputMaybe<Scalars['ID']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['ID']['input']>;
};

export type SponsorshipFilterCompanyName = {
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
  rangeAdjacent?: InputMaybe<Scalars['String']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['String']['input']>;
  stringEndsWith?: InputMaybe<Scalars['String']['input']>;
  stringStartsWith?: InputMaybe<Scalars['String']['input']>;
};

export type SponsorshipFilterContactEmail = {
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
  rangeAdjacent?: InputMaybe<Scalars['String']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['String']['input']>;
  stringEndsWith?: InputMaybe<Scalars['String']['input']>;
  stringStartsWith?: InputMaybe<Scalars['String']['input']>;
};

export type SponsorshipFilterContactPhone = {
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
  rangeAdjacent?: InputMaybe<Scalars['String']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['String']['input']>;
  stringEndsWith?: InputMaybe<Scalars['String']['input']>;
  stringStartsWith?: InputMaybe<Scalars['String']['input']>;
};

export type SponsorshipFilterEndedAt = {
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
  rangeAdjacent?: InputMaybe<Scalars['DateTime']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['DateTime']['input']>;
};

export type SponsorshipFilterEventId = {
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
  rangeAdjacent?: InputMaybe<Scalars['ID']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['ID']['input']>;
};

export type SponsorshipFilterExpiredAt = {
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
  rangeAdjacent?: InputMaybe<Scalars['DateTime']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['DateTime']['input']>;
};

export type SponsorshipFilterId = {
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
  rangeAdjacent?: InputMaybe<Scalars['ID']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['ID']['input']>;
};

export type SponsorshipFilterInput = {
  /** 意向金额（元，v1 仅登记不收款；可空） */
  amount?: InputMaybe<SponsorshipFilterAmount>;
  and?: InputMaybe<Array<SponsorshipFilterInput>>;
  approvalDeadline?: InputMaybe<SponsorshipFilterApprovalDeadline>;
  approvedAt?: InputMaybe<SponsorshipFilterApprovedAt>;
  approvedBy?: InputMaybe<SponsorshipFilterApprovedBy>;
  /** 赞助方公司/展示名 */
  companyName?: InputMaybe<SponsorshipFilterCompanyName>;
  /** 联系邮箱（必填） */
  contactEmail?: InputMaybe<SponsorshipFilterContactEmail>;
  contactPhone?: InputMaybe<SponsorshipFilterContactPhone>;
  deliveries?: InputMaybe<SponsorshipDeliveryFilterInput>;
  endedAt?: InputMaybe<SponsorshipFilterEndedAt>;
  eventId?: InputMaybe<SponsorshipFilterEventId>;
  expiredAt?: InputMaybe<SponsorshipFilterExpiredAt>;
  id?: InputMaybe<SponsorshipFilterId>;
  /** 赞助级别：event 单场 / workspace 长期 */
  level?: InputMaybe<SponsorshipFilterLevel>;
  /** 备注/合作意向 */
  message?: InputMaybe<SponsorshipFilterMessage>;
  not?: InputMaybe<Array<SponsorshipFilterInput>>;
  or?: InputMaybe<Array<SponsorshipFilterInput>>;
  rejectionReason?: InputMaybe<SponsorshipFilterRejectionReason>;
  /** 赞助方（全局账号，非成员） */
  sponsorUserId?: InputMaybe<SponsorshipFilterSponsorUserId>;
  startedAt?: InputMaybe<SponsorshipFilterStartedAt>;
  status?: InputMaybe<SponsorshipFilterStatus>;
  /** 意向档位（指向目标 sponsorship_tiers 配置内的档位 id，可选） */
  tierId?: InputMaybe<SponsorshipFilterTierId>;
  /** 档位展示名冗余（审批/展示用） */
  tierName?: InputMaybe<SponsorshipFilterTierName>;
  workflowRunId?: InputMaybe<SponsorshipFilterWorkflowRunId>;
  /** 所属工作台（租户）：Event 级 = 活动所属工作台；Workspace 级 = 目标工作台 */
  workspaceId?: InputMaybe<SponsorshipFilterWorkspaceId>;
};

export type SponsorshipFilterLevel = {
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
  rangeAdjacent?: InputMaybe<Scalars['String']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['String']['input']>;
};

export type SponsorshipFilterMessage = {
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
  rangeAdjacent?: InputMaybe<Scalars['String']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['String']['input']>;
  stringEndsWith?: InputMaybe<Scalars['String']['input']>;
  stringStartsWith?: InputMaybe<Scalars['String']['input']>;
};

export type SponsorshipFilterRejectionReason = {
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
  rangeAdjacent?: InputMaybe<Scalars['String']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['String']['input']>;
  stringEndsWith?: InputMaybe<Scalars['String']['input']>;
  stringStartsWith?: InputMaybe<Scalars['String']['input']>;
};

export type SponsorshipFilterSponsorUserId = {
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
  rangeAdjacent?: InputMaybe<Scalars['ID']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['ID']['input']>;
};

export type SponsorshipFilterStartedAt = {
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
  rangeAdjacent?: InputMaybe<Scalars['DateTime']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['DateTime']['input']>;
};

export type SponsorshipFilterStatus = {
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
  rangeAdjacent?: InputMaybe<Scalars['String']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['String']['input']>;
};

export type SponsorshipFilterTierId = {
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
  rangeAdjacent?: InputMaybe<Scalars['ID']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['ID']['input']>;
};

export type SponsorshipFilterTierName = {
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
  rangeAdjacent?: InputMaybe<Scalars['String']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['String']['input']>;
  stringEndsWith?: InputMaybe<Scalars['String']['input']>;
  stringStartsWith?: InputMaybe<Scalars['String']['input']>;
};

export type SponsorshipFilterWorkflowRunId = {
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
  rangeAdjacent?: InputMaybe<Scalars['ID']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['ID']['input']>;
};

export type SponsorshipFilterWorkspaceId = {
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
  rangeAdjacent?: InputMaybe<Scalars['ID']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['ID']['input']>;
};

export type SponsorshipSortField =
  | 'AMOUNT'
  | 'APPROVAL_DEADLINE'
  | 'APPROVED_AT'
  | 'APPROVED_BY'
  | 'COMPANY_NAME'
  | 'CONTACT_EMAIL'
  | 'CONTACT_PHONE'
  | 'ENDED_AT'
  | 'EVENT_ID'
  | 'EXPIRED_AT'
  | 'ID'
  | 'LEVEL'
  | 'MESSAGE'
  | 'REJECTION_REASON'
  | 'SPONSOR_USER_ID'
  | 'STARTED_AT'
  | 'STATUS'
  | 'TIER_ID'
  | 'TIER_NAME'
  | 'WORKFLOW_RUN_ID'
  | 'WORKSPACE_ID';

export type SponsorshipSortInput = {
  field: SponsorshipSortField;
  order?: InputMaybe<SortOrder>;
};

export type UpdateCourseInput = {
  /** 报名名额上限；nil 表示不限 */
  capacity?: InputMaybe<Scalars['Int']['input']>;
  /** 公开展示文案（可空；null 由展示层按空串呈现） */
  description?: InputMaybe<Scalars['String']['input']>;
  /** 结课时间；须严格晚于 starts_at（KTD6），nil 表示未定（R1） */
  endsAt?: InputMaybe<Scalars['DateTime']['input']>;
  /** 报名策略：open / request / invite_only */
  enrollmentPolicy?: InputMaybe<Scalars['String']['input']>;
  /** 价格档位配置（PriceTier 形状，见 price_tier.ex） */
  priceTiers?: InputMaybe<Array<Scalars['JsonString']['input']>>;
  /** 是否收费（默认免费；true 时报名须选档并完成支付，R4） */
  pricingEnabled?: InputMaybe<Scalars['Boolean']['input']>;
  /** 报名截止时间；nil 表示不设截止 */
  registrationDeadline?: InputMaybe<Scalars['DateTime']['input']>;
  /** 教研材料需求（audience/duration/sections 等），作为 run input 注入 */
  researchRequirements?: InputMaybe<Scalars['JsonString']['input']>;
  /** 公开 URL 段（/courses/[slug]，全局唯一） */
  slug?: InputMaybe<Scalars['String']['input']>;
  /** 开课时间；nil 表示未定（R1，Course 语义为开课/结课） */
  startsAt?: InputMaybe<Scalars['DateTime']['input']>;
  /** 课程标题 */
  title?: InputMaybe<Scalars['String']['input']>;
  /** 可见性：public 公开可见 / workspace 仅工作台可见（可随时双向切换，D9） */
  visibility?: InputMaybe<Scalars['String']['input']>;
};

/** The result of the :update_course mutation */
export type UpdateCourseResult = {
  /** Any errors generated, if the mutation failed */
  errors: Array<MutationError>;
  /** The successful result of the mutation */
  result?: Maybe<Course>;
};

export type UpdateEventInput = {
  /** 报名名额上限；nil 表示不限 */
  capacity?: InputMaybe<Scalars['Int']['input']>;
  /** 公开展示文案（可空；null 由展示层按空串呈现） */
  description?: InputMaybe<Scalars['String']['input']>;
  /** 活动结束时间；须严格晚于 starts_at（KTD6），nil 表示未定（R1） */
  endsAt?: InputMaybe<Scalars['DateTime']['input']>;
  /** 报名策略：open / request / invite_only */
  enrollmentPolicy?: InputMaybe<Scalars['String']['input']>;
  /** 价格档位配置（PriceTier 形状，见 price_tier.ex） */
  priceTiers?: InputMaybe<Array<Scalars['JsonString']['input']>>;
  /** 是否收费（默认免费；true 时报名须选档并完成支付，R4） */
  pricingEnabled?: InputMaybe<Scalars['Boolean']['input']>;
  /** 报名截止时间；nil 表示不设截止 */
  registrationDeadline?: InputMaybe<Scalars['DateTime']['input']>;
  /** 是否启用教研 workflow */
  researchEnabled?: InputMaybe<Scalars['Boolean']['input']>;
  /** 教研材料需求（audience/duration/sections 等），作为 run input 注入 */
  researchRequirements?: InputMaybe<Scalars['JsonString']['input']>;
  /** 公开 URL 段（/events/[slug] 或 /courses/[slug]，全局唯一） */
  slug?: InputMaybe<Scalars['String']['input']>;
  /** 赞助意向截止；nil 表示长期开放 */
  sponsorshipDeadline?: InputMaybe<Scalars['DateTime']['input']>;
  /** 是否开放赞助入口（默认开；tiers 未配置时入口隐藏，E-5 readiness ②） */
  sponsorshipEnabled?: InputMaybe<Scalars['Boolean']['input']>;
  /** 赞助档位配置（SponsorshipTier 形状，见 sponsorship_tier.ex） */
  sponsorshipTiers?: InputMaybe<Array<Scalars['JsonString']['input']>>;
  /** 活动开始时间；nil 表示未定（R1） */
  startsAt?: InputMaybe<Scalars['DateTime']['input']>;
  /** 活动标题 */
  title?: InputMaybe<Scalars['String']['input']>;
  /** 结构化场地（country/province/city/district 四键，KTD5/R2）；nil 表示线上或未定 */
  venue?: InputMaybe<Scalars['JsonString']['input']>;
  /** 可见性：public 公开可见 / workspace 仅工作台可见（可随时双向切换，D9） */
  visibility?: InputMaybe<Scalars['String']['input']>;
};

/** The result of the :update_event mutation */
export type UpdateEventResult = {
  /** Any errors generated, if the mutation failed */
  errors: Array<MutationError>;
  /** The successful result of the mutation */
  result?: Maybe<Event>;
};

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
  /** 赞助意向截止；nil 表示长期开放 */
  sponsorshipDeadline?: InputMaybe<Scalars['DateTime']['input']>;
  /** 是否开放赞助入口（默认开） */
  sponsorshipEnabled?: InputMaybe<Scalars['Boolean']['input']>;
  /** 赞助档位配置（SponsorshipTier 形状，见 sponsorship_tier.ex） */
  sponsorshipTiers?: InputMaybe<Array<Scalars['JsonString']['input']>>;
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
  /** 用户界面语言偏好（i18n Phase 1，BCP47 对外命名：zh-CN | en；null = 未设置，协商链回退） */
  locale?: Maybe<Scalars['String']['output']>;
  /** 平台级成员编号（P1 由用户 id 确定性生成，格式 CGC-XXXXXX，稳定唯一） */
  memberNumber?: Maybe<Scalars['String']['output']>;
  /** 首公里接入邀请的拒绝时间（R2：拒绝后模态不再自动弹出；null = 未拒绝，跨设备一致） */
  onboardingInvitationDismissedAt?: Maybe<Scalars['DateTime']['output']>;
};

/** The result of the :waive_payment mutation */
export type WaivePaymentResult = {
  /** Any errors generated, if the mutation failed */
  errors: Array<MutationError>;
  /** The successful result of the mutation */
  result?: Maybe<Enrollment>;
};

export type WechatLoginStartResult = {
  expiresInSeconds: Scalars['Int']['output'];
  qrUrl: Scalars['String']['output'];
  state: Scalars['String']['output'];
};

export type WechatSignInStatus =
  | 'NEEDS_BINDING'
  | 'SIGNED_IN';

export type WorkflowDefinition = {
  /** 人工步骤审批超时秒数；nil = 永不超时（不设默认值） */
  approvalTimeout?: Maybe<Scalars['Int']['output']>;
  id: Scalars['ID']['output'];
  /** workflow 输入参数 schema */
  inputSchema?: Maybe<Scalars['JsonString']['output']>;
  /** 蓝图名称（租户内可读） */
  name: Scalars['String']['output'];
  /** 执行拓扑（步骤顺序/依赖），声明式数据；Step 字段独立存于 Step 资源 */
  nodeDef?: Maybe<Scalars['JsonString']['output']>;
  /** 生命周期：draft 草稿 / published 已发布 / archived 已归档 */
  status: Scalars['String']['output'];
  /** workflow 类型：learning 学习 / enrollment 报名 / sponsorship 赞助 / speaker_invitation 邀请讲者 / research 教研 */
  type: Scalars['String']['output'];
  /** 版本号，单调递增；new_version 出 v+1（#34） */
  version: Scalars['Int']['output'];
  /** 所属工作台（租户）ID */
  workspaceId: Scalars['ID']['output'];
};

export type WorkflowDefinitionFilterApprovalTimeout = {
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
  rangeAdjacent?: InputMaybe<Scalars['Int']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['Int']['input']>;
};

export type WorkflowDefinitionFilterId = {
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
  rangeAdjacent?: InputMaybe<Scalars['ID']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['ID']['input']>;
};

export type WorkflowDefinitionFilterInput = {
  and?: InputMaybe<Array<WorkflowDefinitionFilterInput>>;
  /** 人工步骤审批超时秒数；nil = 永不超时（不设默认值） */
  approvalTimeout?: InputMaybe<WorkflowDefinitionFilterApprovalTimeout>;
  id?: InputMaybe<WorkflowDefinitionFilterId>;
  /** workflow 输入参数 schema */
  inputSchema?: InputMaybe<WorkflowDefinitionFilterInputSchema>;
  /** 蓝图名称（租户内可读） */
  name?: InputMaybe<WorkflowDefinitionFilterName>;
  /** 执行拓扑（步骤顺序/依赖），声明式数据；Step 字段独立存于 Step 资源 */
  nodeDef?: InputMaybe<WorkflowDefinitionFilterNodeDef>;
  not?: InputMaybe<Array<WorkflowDefinitionFilterInput>>;
  or?: InputMaybe<Array<WorkflowDefinitionFilterInput>>;
  /** 生命周期：draft 草稿 / published 已发布 / archived 已归档 */
  status?: InputMaybe<WorkflowDefinitionFilterStatus>;
  /** workflow 类型：learning 学习 / enrollment 报名 / sponsorship 赞助 / speaker_invitation 邀请讲者 / research 教研 */
  type?: InputMaybe<WorkflowDefinitionFilterType>;
  /** 版本号，单调递增；new_version 出 v+1（#34） */
  version?: InputMaybe<WorkflowDefinitionFilterVersion>;
  /** 所属工作台（租户）ID */
  workspaceId?: InputMaybe<WorkflowDefinitionFilterWorkspaceId>;
};

export type WorkflowDefinitionFilterInputSchema = {
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
  rangeAdjacent?: InputMaybe<Scalars['JsonString']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['JsonString']['input']>;
};

export type WorkflowDefinitionFilterName = {
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
  rangeAdjacent?: InputMaybe<Scalars['String']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['String']['input']>;
  stringEndsWith?: InputMaybe<Scalars['String']['input']>;
  stringStartsWith?: InputMaybe<Scalars['String']['input']>;
};

export type WorkflowDefinitionFilterNodeDef = {
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
  rangeAdjacent?: InputMaybe<Scalars['JsonString']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['JsonString']['input']>;
};

export type WorkflowDefinitionFilterStatus = {
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
  rangeAdjacent?: InputMaybe<Scalars['String']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['String']['input']>;
};

export type WorkflowDefinitionFilterType = {
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
  rangeAdjacent?: InputMaybe<Scalars['String']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['String']['input']>;
};

export type WorkflowDefinitionFilterVersion = {
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
  rangeAdjacent?: InputMaybe<Scalars['Int']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['Int']['input']>;
};

export type WorkflowDefinitionFilterWorkspaceId = {
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
  rangeAdjacent?: InputMaybe<Scalars['ID']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['ID']['input']>;
};

export type WorkflowRun = {
  definition: WorkflowDefinition;
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
  /** run 绑定版本的步骤定义（step_key/title/type/output_schema，plan 020） */
  steps?: Maybe<Array<Scalars['JsonString']['output']>>;
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
  rangeAdjacent?: InputMaybe<Scalars['ID']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['ID']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['Int']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['Int']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['JsonString']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['JsonString']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['DateTime']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['DateTime']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['ID']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['ID']['input']>;
};

export type WorkflowRunFilterInput = {
  and?: InputMaybe<Array<WorkflowRunFilterInput>>;
  definition?: InputMaybe<WorkflowDefinitionFilterInput>;
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
  rangeAdjacent?: InputMaybe<Scalars['JsonString']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['JsonString']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['ID']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['ID']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['DateTime']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['DateTime']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['String']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['String']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['Int']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['Int']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['ID']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['ID']['input']>;
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
  /** 赞助意向截止；nil 表示长期开放 */
  sponsorshipDeadline?: Maybe<Scalars['DateTime']['output']>;
  /** 是否开放赞助入口（默认开） */
  sponsorshipEnabled: Scalars['Boolean']['output'];
  /** 赞助档位配置（SponsorshipTier 形状，见 sponsorship_tier.ex） */
  sponsorshipTiers: Array<Scalars['JsonString']['output']>;
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
  rangeAdjacent?: InputMaybe<Scalars['ID']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['ID']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['DateTime']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['DateTime']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['DateTime']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['DateTime']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['ID']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['ID']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['DateTime']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['DateTime']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['ID']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['ID']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['String']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['String']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['String']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['String']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['DateTime']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['DateTime']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['ID']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['ID']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['String']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['String']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['String']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['String']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['String']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['String']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['ID']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['ID']['input']>;
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
  /** 赞助意向截止；nil 表示长期开放 */
  sponsorshipDeadline?: InputMaybe<WorkspaceFilterSponsorshipDeadline>;
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
  rangeAdjacent?: InputMaybe<Scalars['String']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['String']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['String']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['String']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['String']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['String']['input']>;
  stringEndsWith?: InputMaybe<Scalars['String']['input']>;
  stringStartsWith?: InputMaybe<Scalars['String']['input']>;
};

export type WorkspaceFilterSponsorshipDeadline = {
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
  rangeAdjacent?: InputMaybe<Scalars['DateTime']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['DateTime']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['Boolean']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['Boolean']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['ID']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['ID']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['DateTime']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['DateTime']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['String']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['String']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['String']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['String']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['ID']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['ID']['input']>;
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
  rangeAdjacent?: InputMaybe<Scalars['ID']['input']>;
  rangeContains?: InputMaybe<Scalars['String']['input']>;
  rangeOverlaps?: InputMaybe<Scalars['ID']['input']>;
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
  | 'SPONSORSHIP_DEADLINE'
  | 'SPONSORSHIP_ENABLED';

export type WorkspaceSortInput = {
  field: WorkspaceSortField;
  order?: InputMaybe<SortOrder>;
};

export type WorkspaceToolCall = {
  errorMessage?: Maybe<Scalars['String']['output']>;
  id: Scalars['ID']['output'];
  insertedAt: Scalars['DateTime']['output'];
  latencyMs?: Maybe<Scalars['Int']['output']>;
  status: Scalars['String']['output'];
  tool: Scalars['String']['output'];
};
