/** Internal type. DO NOT USE DIRECTLY. */
type Exact<T extends { [key: string]: unknown }> = { [K in keyof T]: T[K] };
/** Internal type. DO NOT USE DIRECTLY. */
export type Incremental<T> = T | { [P in keyof T]?: P extends ' $fragmentName' | '__typename' ? T[P] : never };
export type CourseFilterCapacity = {
  eq?: number | null | undefined;
  greaterThan?: number | null | undefined;
  greaterThanOrEqual?: number | null | undefined;
  in?: Array<number | null | undefined> | null | undefined;
  isDistinctFrom?: number | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: number | null | undefined;
  lessThan?: number | null | undefined;
  lessThanOrEqual?: number | null | undefined;
  notEq?: number | null | undefined;
  rangeAdjacent?: number | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: number | null | undefined;
};

export type CourseFilterConfirmedCount = {
  eq?: number | null | undefined;
  greaterThan?: number | null | undefined;
  greaterThanOrEqual?: number | null | undefined;
  in?: Array<number> | null | undefined;
  isDistinctFrom?: number | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: number | null | undefined;
  lessThan?: number | null | undefined;
  lessThanOrEqual?: number | null | undefined;
  notEq?: number | null | undefined;
  rangeAdjacent?: number | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: number | null | undefined;
};

export type CourseFilterCurriculumRequirements = {
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string | null | undefined> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
};

export type CourseFilterDescription = {
  contains?: string | null | undefined;
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  ilike?: string | null | undefined;
  in?: Array<string | null | undefined> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  like?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
  stringEndsWith?: string | null | undefined;
  stringStartsWith?: string | null | undefined;
};

export type CourseFilterEndsAt = {
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string | null | undefined> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
};

export type CourseFilterEnrollmentPolicy = {
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
};

export type CourseFilterId = {
  eq?: string | number | null | undefined;
  greaterThan?: string | number | null | undefined;
  greaterThanOrEqual?: string | number | null | undefined;
  in?: Array<string | number> | null | undefined;
  isDistinctFrom?: string | number | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | number | null | undefined;
  lessThan?: string | number | null | undefined;
  lessThanOrEqual?: string | number | null | undefined;
  notEq?: string | number | null | undefined;
  rangeAdjacent?: string | number | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | number | null | undefined;
};

export type CourseFilterInput = {
  and?: Array<CourseFilterInput> | null | undefined;
  /** 报名名额上限；nil 表示不限 */
  capacity?: CourseFilterCapacity | null | undefined;
  /** 已确认名额数（仅由 Enrollment 原子维护） */
  confirmedCount?: CourseFilterConfirmedCount | null | undefined;
  /** 教研材料需求（audience/duration/sections 等），作为 run input 注入 */
  curriculumRequirements?: CourseFilterCurriculumRequirements | null | undefined;
  /** 公开展示文案（可空；null 由展示层按空串呈现） */
  description?: CourseFilterDescription | null | undefined;
  /** 结课时间；须严格晚于 starts_at（KTD6），nil 表示未定（R1） */
  endsAt?: CourseFilterEndsAt | null | undefined;
  /** 报名策略：open / request / invite_only */
  enrollmentPolicy?: CourseFilterEnrollmentPolicy | null | undefined;
  id?: CourseFilterId | null | undefined;
  not?: Array<CourseFilterInput> | null | undefined;
  or?: Array<CourseFilterInput> | null | undefined;
  /** 是否收费（默认免费；true 时报名须选档并完成支付，R4） */
  pricingEnabled?: CourseFilterPricingEnabled | null | undefined;
  /** 当前标题是否为系统生成的临时占位（role-agent-journeys-v2 S3 零输入草稿，R21/AE1）；设置真实标题即清除，发布前置门 */
  provisionalTitle?: CourseFilterProvisionalTitle | null | undefined;
  /** 报名截止时间；nil 表示不设截止 */
  registrationDeadline?: CourseFilterRegistrationDeadline | null | undefined;
  /** 公开 URL 段（/courses/[slug]，全局唯一） */
  slug?: CourseFilterSlug | null | undefined;
  /** 开课时间；nil 表示未定（R1，Course 语义为开课/结课） */
  startsAt?: CourseFilterStartsAt | null | undefined;
  /** 课程状态：draft 草稿 / open 已发布 / closed 已结束 / cancelled 已取消 */
  status?: CourseFilterStatus | null | undefined;
  /** 课程标题；create 缺省时由 change 生成临时占位标题（未命名课程 <hex8>，见 provisional_title），读取面恒非空 */
  title?: CourseFilterTitle | null | undefined;
  /** 可见性：public 公开可见 / workspace 仅工作台可见（可随时双向切换，D9） */
  visibility?: CourseFilterVisibility | null | undefined;
  /** 教研 workflow 产物引用（领域模型 §5.2 ER） */
  workflowRunId?: CourseFilterWorkflowRunId | null | undefined;
  /** 所属工作台（租户）ID */
  workspaceId?: CourseFilterWorkspaceId | null | undefined;
};

export type CourseFilterPricingEnabled = {
  eq?: boolean | null | undefined;
  greaterThan?: boolean | null | undefined;
  greaterThanOrEqual?: boolean | null | undefined;
  in?: Array<boolean> | null | undefined;
  isDistinctFrom?: boolean | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: boolean | null | undefined;
  lessThan?: boolean | null | undefined;
  lessThanOrEqual?: boolean | null | undefined;
  notEq?: boolean | null | undefined;
  rangeAdjacent?: boolean | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: boolean | null | undefined;
};

export type CourseFilterProvisionalTitle = {
  eq?: boolean | null | undefined;
  greaterThan?: boolean | null | undefined;
  greaterThanOrEqual?: boolean | null | undefined;
  in?: Array<boolean> | null | undefined;
  isDistinctFrom?: boolean | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: boolean | null | undefined;
  lessThan?: boolean | null | undefined;
  lessThanOrEqual?: boolean | null | undefined;
  notEq?: boolean | null | undefined;
  rangeAdjacent?: boolean | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: boolean | null | undefined;
};

export type CourseFilterRegistrationDeadline = {
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string | null | undefined> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
};

export type CourseFilterSlug = {
  contains?: string | null | undefined;
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  ilike?: string | null | undefined;
  in?: Array<string | null | undefined> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  like?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
  stringEndsWith?: string | null | undefined;
  stringStartsWith?: string | null | undefined;
};

export type CourseFilterStartsAt = {
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string | null | undefined> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
};

export type CourseFilterStatus = {
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
};

export type CourseFilterTitle = {
  contains?: string | null | undefined;
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  ilike?: string | null | undefined;
  in?: Array<string> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  like?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
  stringEndsWith?: string | null | undefined;
  stringStartsWith?: string | null | undefined;
};

export type CourseFilterVisibility = {
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
};

export type CourseFilterWorkflowRunId = {
  eq?: string | number | null | undefined;
  greaterThan?: string | number | null | undefined;
  greaterThanOrEqual?: string | number | null | undefined;
  in?: Array<string | number | null | undefined> | null | undefined;
  isDistinctFrom?: string | number | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | number | null | undefined;
  lessThan?: string | number | null | undefined;
  lessThanOrEqual?: string | number | null | undefined;
  notEq?: string | number | null | undefined;
  rangeAdjacent?: string | number | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | number | null | undefined;
};

export type CourseFilterWorkspaceId = {
  eq?: string | number | null | undefined;
  greaterThan?: string | number | null | undefined;
  greaterThanOrEqual?: string | number | null | undefined;
  in?: Array<string | number> | null | undefined;
  isDistinctFrom?: string | number | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | number | null | undefined;
  lessThan?: string | number | null | undefined;
  lessThanOrEqual?: string | number | null | undefined;
  notEq?: string | number | null | undefined;
  rangeAdjacent?: string | number | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | number | null | undefined;
};

export type CreateEnrollmentInput = {
  /** 确认已满目标活动要求的最低年龄（min_age 非空的活动必传 true） */
  ageConfirmed?: boolean | null | undefined;
  approvalDeadline?: string | null | undefined;
  courseId?: string | number | null | undefined;
  eventId?: string | number | null | undefined;
  inviteCode?: string | null | undefined;
  submissionPayload?: string | null | undefined;
  /** 价格档位 ID（收费活动报名时必填） */
  tierId?: string | null | undefined;
  userId: string | number;
  workflowRunId?: string | number | null | undefined;
};

export type CreateOrderInput = {
  /** 确认已阅读并同意押金条款（仅押金单需要；非押金单忽略） */
  depositConsent?: boolean | null | undefined;
  /** 目标报名（须为本人 payment_pending 报名） */
  enrollmentId: string | number;
  /** 支付渠道 */
  provider: string;
};

export type CreateVolunteerApplicationInput = {
  /** 申请城市（Tutor 可远程） */
  city?: string | null | undefined;
  /** createVolunteerApplication 输入（R11 第 2 步；user_id 由 actor 强制填充，不接受客户端传入） */
  cohortId: string | number;
  /** 是否有内部推荐人（缺省 false） */
  hasInternalReferrer?: boolean | null | undefined;
  /** 如何得知我们 */
  heardAboutUs?: string | null | undefined;
  /** 留言（选填） */
  message?: string | null | undefined;
  /** 职位：event_moderator | tutor | coach */
  position: string;
};

export type EventFilterCapacity = {
  eq?: number | null | undefined;
  greaterThan?: number | null | undefined;
  greaterThanOrEqual?: number | null | undefined;
  in?: Array<number | null | undefined> | null | undefined;
  isDistinctFrom?: number | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: number | null | undefined;
  lessThan?: number | null | undefined;
  lessThanOrEqual?: number | null | undefined;
  notEq?: number | null | undefined;
  rangeAdjacent?: number | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: number | null | undefined;
};

export type EventFilterConfirmedCount = {
  eq?: number | null | undefined;
  greaterThan?: number | null | undefined;
  greaterThanOrEqual?: number | null | undefined;
  in?: Array<number> | null | undefined;
  isDistinctFrom?: number | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: number | null | undefined;
  lessThan?: number | null | undefined;
  lessThanOrEqual?: number | null | undefined;
  notEq?: number | null | undefined;
  rangeAdjacent?: number | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: number | null | undefined;
};

export type EventFilterCreatedBy = {
  eq?: string | number | null | undefined;
  greaterThan?: string | number | null | undefined;
  greaterThanOrEqual?: string | number | null | undefined;
  in?: Array<string | number | null | undefined> | null | undefined;
  isDistinctFrom?: string | number | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | number | null | undefined;
  lessThan?: string | number | null | undefined;
  lessThanOrEqual?: string | number | null | undefined;
  notEq?: string | number | null | undefined;
  rangeAdjacent?: string | number | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | number | null | undefined;
};

export type EventFilterCurriculumEnabled = {
  eq?: boolean | null | undefined;
  greaterThan?: boolean | null | undefined;
  greaterThanOrEqual?: boolean | null | undefined;
  in?: Array<boolean> | null | undefined;
  isDistinctFrom?: boolean | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: boolean | null | undefined;
  lessThan?: boolean | null | undefined;
  lessThanOrEqual?: boolean | null | undefined;
  notEq?: boolean | null | undefined;
  rangeAdjacent?: boolean | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: boolean | null | undefined;
};

export type EventFilterCurriculumRequirements = {
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string | null | undefined> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
};

export type EventFilterDepositAmountCents = {
  eq?: number | null | undefined;
  greaterThan?: number | null | undefined;
  greaterThanOrEqual?: number | null | undefined;
  in?: Array<number | null | undefined> | null | undefined;
  isDistinctFrom?: number | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: number | null | undefined;
  lessThan?: number | null | undefined;
  lessThanOrEqual?: number | null | undefined;
  notEq?: number | null | undefined;
  rangeAdjacent?: number | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: number | null | undefined;
};

export type EventFilterDepositEnabled = {
  eq?: boolean | null | undefined;
  greaterThan?: boolean | null | undefined;
  greaterThanOrEqual?: boolean | null | undefined;
  in?: Array<boolean> | null | undefined;
  isDistinctFrom?: boolean | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: boolean | null | undefined;
  lessThan?: boolean | null | undefined;
  lessThanOrEqual?: boolean | null | undefined;
  notEq?: boolean | null | undefined;
  rangeAdjacent?: boolean | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: boolean | null | undefined;
};

export type EventFilterDescription = {
  contains?: string | null | undefined;
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  ilike?: string | null | undefined;
  in?: Array<string | null | undefined> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  like?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
  stringEndsWith?: string | null | undefined;
  stringStartsWith?: string | null | undefined;
};

export type EventFilterEndsAt = {
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string | null | undefined> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
};

export type EventFilterEnrollmentPolicy = {
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
};

export type EventFilterId = {
  eq?: string | number | null | undefined;
  greaterThan?: string | number | null | undefined;
  greaterThanOrEqual?: string | number | null | undefined;
  in?: Array<string | number> | null | undefined;
  isDistinctFrom?: string | number | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | number | null | undefined;
  lessThan?: string | number | null | undefined;
  lessThanOrEqual?: string | number | null | undefined;
  notEq?: string | number | null | undefined;
  rangeAdjacent?: string | number | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | number | null | undefined;
};

export type EventFilterInitiativeId = {
  eq?: string | number | null | undefined;
  greaterThan?: string | number | null | undefined;
  greaterThanOrEqual?: string | number | null | undefined;
  in?: Array<string | number | null | undefined> | null | undefined;
  isDistinctFrom?: string | number | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | number | null | undefined;
  lessThan?: string | number | null | undefined;
  lessThanOrEqual?: string | number | null | undefined;
  notEq?: string | number | null | undefined;
  rangeAdjacent?: string | number | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | number | null | undefined;
};

export type EventFilterInput = {
  and?: Array<EventFilterInput> | null | undefined;
  /** 报名名额上限；nil 表示不限 */
  capacity?: EventFilterCapacity | null | undefined;
  /** 已确认名额数（仅由 Enrollment 原子维护） */
  confirmedCount?: EventFilterConfirmedCount | null | undefined;
  createdBy?: EventFilterCreatedBy | null | undefined;
  /** 是否启用教研 workflow */
  curriculumEnabled?: EventFilterCurriculumEnabled | null | undefined;
  /** 教研材料需求（audience/duration/sections 等），作为 run input 注入 */
  curriculumRequirements?: EventFilterCurriculumRequirements | null | undefined;
  /** 押金金额（分） */
  depositAmountCents?: EventFilterDepositAmountCents | null | undefined;
  /** 是否收取活动押金（与既有报名定价分开） */
  depositEnabled?: EventFilterDepositEnabled | null | undefined;
  /** 公开展示文案（可空；null 由展示层按空串呈现） */
  description?: EventFilterDescription | null | undefined;
  /** 活动结束时间；须严格晚于 starts_at（KTD6），nil 表示未定（R1） */
  endsAt?: EventFilterEndsAt | null | undefined;
  /** 报名策略：open / request / invite_only */
  enrollmentPolicy?: EventFilterEnrollmentPolicy | null | undefined;
  id?: EventFilterId | null | undefined;
  /** 所属平台级 Initiative；仅草稿可挂载 */
  initiativeId?: EventFilterInitiativeId | null | undefined;
  /** 报名最低年龄；nil 表示无年龄门槛 */
  minAge?: EventFilterMinAge | null | undefined;
  /** 成班最低确认人数；nil 表示不判定成班 */
  minParticipants?: EventFilterMinParticipants | null | undefined;
  not?: Array<EventFilterInput> | null | undefined;
  or?: Array<EventFilterInput> | null | undefined;
  /** 是否收费（默认免费；true 时报名须选档并完成支付，R4） */
  pricingEnabled?: EventFilterPricingEnabled | null | undefined;
  /** 成班事实：pending / confirmed / underfilled */
  qualificationStatus?: EventFilterQualificationStatus | null | undefined;
  /** 报名截止时间；nil 表示不设截止 */
  registrationDeadline?: EventFilterRegistrationDeadline | null | undefined;
  /** 公开 URL 段（/events/[slug] 或 /courses/[slug]，全局唯一） */
  slug?: EventFilterSlug | null | undefined;
  /** 赞助意向截止；nil 表示长期开放 */
  sponsorshipDeadline?: EventFilterSponsorshipDeadline | null | undefined;
  /** 是否开放赞助入口（默认开；tiers 未配置时入口隐藏，E-5 readiness ②） */
  sponsorshipEnabled?: EventFilterSponsorshipEnabled | null | undefined;
  /** 活动开始时间；nil 表示未定（R1） */
  startsAt?: EventFilterStartsAt | null | undefined;
  /** 活动状态：draft 草稿 / open 已发布 / closed 已结束 / cancelled 已取消 */
  status?: EventFilterStatus | null | undefined;
  /** 活动标题 */
  title?: EventFilterTitle | null | undefined;
  /** 结构化场地（country/province/city/district 四键，KTD5/R2）；nil 表示线上或未定 */
  venue?: EventFilterVenue | null | undefined;
  /** 可见性：public 公开可见 / workspace 仅工作台可见（可随时双向切换，D9） */
  visibility?: EventFilterVisibility | null | undefined;
  /** 教研 workflow 产物引用（领域模型 §5.2 ER） */
  workflowRunId?: EventFilterWorkflowRunId | null | undefined;
  /** 所属工作台（租户）ID */
  workspaceId?: EventFilterWorkspaceId | null | undefined;
};

export type EventFilterMinAge = {
  eq?: number | null | undefined;
  greaterThan?: number | null | undefined;
  greaterThanOrEqual?: number | null | undefined;
  in?: Array<number | null | undefined> | null | undefined;
  isDistinctFrom?: number | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: number | null | undefined;
  lessThan?: number | null | undefined;
  lessThanOrEqual?: number | null | undefined;
  notEq?: number | null | undefined;
  rangeAdjacent?: number | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: number | null | undefined;
};

export type EventFilterMinParticipants = {
  eq?: number | null | undefined;
  greaterThan?: number | null | undefined;
  greaterThanOrEqual?: number | null | undefined;
  in?: Array<number | null | undefined> | null | undefined;
  isDistinctFrom?: number | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: number | null | undefined;
  lessThan?: number | null | undefined;
  lessThanOrEqual?: number | null | undefined;
  notEq?: number | null | undefined;
  rangeAdjacent?: number | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: number | null | undefined;
};

export type EventFilterPricingEnabled = {
  eq?: boolean | null | undefined;
  greaterThan?: boolean | null | undefined;
  greaterThanOrEqual?: boolean | null | undefined;
  in?: Array<boolean> | null | undefined;
  isDistinctFrom?: boolean | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: boolean | null | undefined;
  lessThan?: boolean | null | undefined;
  lessThanOrEqual?: boolean | null | undefined;
  notEq?: boolean | null | undefined;
  rangeAdjacent?: boolean | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: boolean | null | undefined;
};

export type EventFilterQualificationStatus = {
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
};

export type EventFilterRegistrationDeadline = {
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string | null | undefined> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
};

export type EventFilterSlug = {
  contains?: string | null | undefined;
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  ilike?: string | null | undefined;
  in?: Array<string | null | undefined> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  like?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
  stringEndsWith?: string | null | undefined;
  stringStartsWith?: string | null | undefined;
};

export type EventFilterSponsorshipDeadline = {
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string | null | undefined> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
};

export type EventFilterSponsorshipEnabled = {
  eq?: boolean | null | undefined;
  greaterThan?: boolean | null | undefined;
  greaterThanOrEqual?: boolean | null | undefined;
  in?: Array<boolean> | null | undefined;
  isDistinctFrom?: boolean | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: boolean | null | undefined;
  lessThan?: boolean | null | undefined;
  lessThanOrEqual?: boolean | null | undefined;
  notEq?: boolean | null | undefined;
  rangeAdjacent?: boolean | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: boolean | null | undefined;
};

export type EventFilterStartsAt = {
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string | null | undefined> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
};

export type EventFilterStatus = {
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
};

export type EventFilterTitle = {
  contains?: string | null | undefined;
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  ilike?: string | null | undefined;
  in?: Array<string> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  like?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
  stringEndsWith?: string | null | undefined;
  stringStartsWith?: string | null | undefined;
};

export type EventFilterVenue = {
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string | null | undefined> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
};

export type EventFilterVisibility = {
  eq?: string | null | undefined;
  greaterThan?: string | null | undefined;
  greaterThanOrEqual?: string | null | undefined;
  in?: Array<string> | null | undefined;
  isDistinctFrom?: string | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | null | undefined;
  lessThan?: string | null | undefined;
  lessThanOrEqual?: string | null | undefined;
  notEq?: string | null | undefined;
  rangeAdjacent?: string | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | null | undefined;
};

export type EventFilterWorkflowRunId = {
  eq?: string | number | null | undefined;
  greaterThan?: string | number | null | undefined;
  greaterThanOrEqual?: string | number | null | undefined;
  in?: Array<string | number | null | undefined> | null | undefined;
  isDistinctFrom?: string | number | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | number | null | undefined;
  lessThan?: string | number | null | undefined;
  lessThanOrEqual?: string | number | null | undefined;
  notEq?: string | number | null | undefined;
  rangeAdjacent?: string | number | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | number | null | undefined;
};

export type EventFilterWorkspaceId = {
  eq?: string | number | null | undefined;
  greaterThan?: string | number | null | undefined;
  greaterThanOrEqual?: string | number | null | undefined;
  in?: Array<string | number> | null | undefined;
  isDistinctFrom?: string | number | null | undefined;
  isNil?: boolean | null | undefined;
  isNotDistinctFrom?: string | number | null | undefined;
  lessThan?: string | number | null | undefined;
  lessThanOrEqual?: string | number | null | undefined;
  notEq?: string | number | null | undefined;
  rangeAdjacent?: string | number | null | undefined;
  rangeContains?: string | null | undefined;
  rangeOverlaps?: string | number | null | undefined;
};

export type FlashbackFogSpanInput = {
  len: number;
  reason?: string | null | undefined;
  start: number;
};

export type FlashbackQuoteSpanInput = {
  len: number;
  questionKey: string;
  start: number;
};

export type FlashbackTodayInput = {
  mobilizationDonateIntent?: boolean | null | undefined;
  mobilizationHelpPromote?: boolean | null | undefined;
  mobilizationJoin1024?: boolean | null | undefined;
  mobilizationVolunteerLead?: boolean | null | undefined;
  need?: string | null | undefined;
  newsletterOptIn?: boolean | null | undefined;
  /** 「今天的你」问卷（R8）：四个自由文本 + Want/Give 标签 + 动员勾选（R20）+ Newsletter（R18）+ Reconnect（R19） */
  nowStatus?: string | null | undefined;
  reconnectTags?: Array<string | null | undefined> | null | undefined;
  say?: string | null | undefined;
  want?: string | null | undefined;
  wantGiveTags?: Array<string | null | undefined> | null | undefined;
};

export type RejectEnrollmentInput = {
  rejectionReason?: string | null | undefined;
};

export type RejectJoinRequestInput = {
  /** 拒绝原因 */
  rejectionReason?: string | null | undefined;
};

export type UploadResumeFileInput = {
  /** 文件内容（标准 base64；原始文件 ≤5MB，即请求体约 6.7MB，在 endpoint 8MB 闸门内） */
  contentBase64: string;
  /** 声明的 MIME（须与扩展名同族） */
  contentType: string;
  /** uploadResumeFile 输入（KTD3：base64-over-JSON；扩展名/声明 MIME/魔数三者一致才收） */
  fileName: string;
};

export type UpsertResumeProfileInput = {
  /** 联系邮箱（R14 邮件保底通道收件地址） */
  contactEmail: string;
  /** upsertResumeProfile 输入（R11 第 1 步；user_id 由 actor 强制填充） */
  fullName: string;
  /** 技能多选（字符串列表；缺省不改动） */
  skills?: Array<string> | null | undefined;
  /** 每周可投入小时数（选填） */
  weeklyHours?: number | null | undefined;
};

export type CatalogQueryVariables = Exact<{
  first?: number | null | undefined;
}>;


export type CatalogQuery = { listEvents: { results: Array<{ id: string, title: string, status: string, enrollmentPolicy: string, registrationDeadline: string | null, pricingEnabled: boolean, availablePriceTiers: Array<string> | null, startsAt: string | null, endsAt: string | null, venue: string | null, enrollmentBadge: string | null }> | null } | null, listCourses: { results: Array<{ id: string, title: string, status: string, enrollmentPolicy: string, registrationDeadline: string | null, pricingEnabled: boolean, availablePriceTiers: Array<string> | null, startsAt: string | null, endsAt: string | null, enrollmentBadge: string | null }> | null } | null };

export type CatalogSearchQueryVariables = Exact<{
  first?: number | null | undefined;
  eventFilter?: EventFilterInput | null | undefined;
  courseFilter?: CourseFilterInput | null | undefined;
}>;


export type CatalogSearchQuery = { listEvents: { results: Array<{ id: string, title: string, status: string, enrollmentPolicy: string, registrationDeadline: string | null, pricingEnabled: boolean, availablePriceTiers: Array<string> | null, startsAt: string | null, endsAt: string | null, venue: string | null, enrollmentBadge: string | null }> | null } | null, listCourses: { results: Array<{ id: string, title: string, status: string, enrollmentPolicy: string, registrationDeadline: string | null, pricingEnabled: boolean, availablePriceTiers: Array<string> | null, startsAt: string | null, endsAt: string | null, enrollmentBadge: string | null }> | null } | null };

export type EventDetailQueryVariables = Exact<{
  id: string | number;
}>;


export type EventDetailQuery = { getEvent: { id: string, title: string, status: string, enrollmentPolicy: string, registrationDeadline: string | null, description: string | null, pricingEnabled: boolean, availablePriceTiers: Array<string> | null, depositEnabled: boolean, depositAmountCents: number | null, minAge: number | null, startsAt: string | null, endsAt: string | null, venue: string | null, enrollmentBadge: string | null, qualificationBadge: string | null, shortBy: number | null, initiativeId: string | null, publicModerators: Array<string> | null } | null, myEnrollment: { id: string, status: string, approvalDeadline: string | null } | null };

export type CourseDetailQueryVariables = Exact<{
  id: string | number;
}>;


export type CourseDetailQuery = { getCourse: { id: string, title: string, status: string, enrollmentPolicy: string, registrationDeadline: string | null, description: string | null, pricingEnabled: boolean, availablePriceTiers: Array<string> | null, startsAt: string | null, endsAt: string | null, enrollmentBadge: string | null } | null, myEnrollment: { id: string, status: string, approvalDeadline: string | null } | null };

export type SessionQueryVariables = Exact<{ [key: string]: never; }>;


export type SessionQuery = { me: { id: string, email: string | null, displayName: string | null, memberNumber: string | null, joinedAt: string | null, isPlatformAdmin: boolean } | null, meWorkspaces: Array<{ id: string, slug: string, name: string, joinPolicy: string, myRoleNames: Array<string> | null, myMembershipId: string | null, canAccess: boolean | null, myAbilities: Array<string> | null, memberCount: number | null }>, myPendingApprovals: Array<{ id: string, kind: string, workspaceId: string, userId: string, eventId: string | null, courseId: string | null, status: string, approvalDeadline: string | null, requesterName: string | null, contextTitle: string | null, tierName: string | null, amount: number | null }> };

export type MyEnrollmentsQueryVariables = Exact<{
  userId: string | number;
  first?: number | null | undefined;
}>;


export type MyEnrollmentsQuery = { enrollments: { results: Array<{ id: string, workspaceId: string, eventId: string | null, courseId: string | null, userId: string, status: string, targetTitle: string | null, approvalDeadline: string | null, rejectionReason: string | null, approvedAt: string | null, expiredAt: string | null, cancelledAt: string | null, insertedAt: string, checkInCode: string | null, paymentMode: string | null, startsAt: string | null, venue: string | null, registrationDeadline: string | null }> | null } | null };

export type EnrollmentQueryVariables = Exact<{
  id: string | number;
}>;


export type EnrollmentQuery = { enrollments: { results: Array<{ id: string, workspaceId: string, eventId: string | null, courseId: string | null, userId: string, status: string, targetTitle: string | null, approvalDeadline: string | null, rejectionReason: string | null, approvedAt: string | null, expiredAt: string | null, cancelledAt: string | null, insertedAt: string, checkInCode: string | null, paymentMode: string | null, depositAmountCents: number | null, startsAt: string | null, venue: string | null, registrationDeadline: string | null }> | null } | null };

export type SignInWithPlatformMutationVariables = Exact<{
  platform: string;
  code: string;
  phoneCode?: string | null | undefined;
  encryptedData?: string | null | undefined;
  iv?: string | null | undefined;
}>;


export type SignInWithPlatformMutation = { signInWithPlatform: { id: string, email: string | null, isPlatformAdmin: boolean } | null };

export type SignOutMutationVariables = Exact<{ [key: string]: never; }>;


export type SignOutMutation = { signOut: string | null };

export type CreateEnrollmentMutationVariables = Exact<{
  input: CreateEnrollmentInput;
}>;


export type CreateEnrollmentMutation = { createEnrollment: { result: { id: string, workspaceId: string, eventId: string | null, courseId: string | null, userId: string, status: string, approvalDeadline: string | null, insertedAt: string } | null, errors: Array<{ message: string | null, code: string | null, fields: Array<string> | null }> } };

export type CancelEnrollmentMutationVariables = Exact<{
  id: string | number;
}>;


export type CancelEnrollmentMutation = { cancelEnrollment: { result: { id: string, workspaceId: string, eventId: string | null, courseId: string | null, userId: string, status: string, approvalDeadline: string | null, rejectionReason: string | null, cancelledAt: string | null } | null, errors: Array<{ message: string | null, code: string | null }> } };

export type ConfirmEnrollmentMutationVariables = Exact<{
  id: string | number;
}>;


export type ConfirmEnrollmentMutation = { confirmEnrollment: { result: { id: string, status: string, approvedAt: string | null } | null, errors: Array<{ message: string | null, fields: Array<string> | null }> } };

export type RejectEnrollmentMutationVariables = Exact<{
  id: string | number;
  input?: RejectEnrollmentInput | null | undefined;
}>;


export type RejectEnrollmentMutation = { rejectEnrollment: { result: { id: string, status: string, rejectionReason: string | null } | null, errors: Array<{ message: string | null, fields: Array<string> | null }> } };

export type ApproveJoinRequestMutationVariables = Exact<{
  id: string | number;
}>;


export type ApproveJoinRequestMutation = { approveJoinRequest: { result: { id: string, status: string, approvedAt: string | null } | null, errors: Array<{ message: string | null, fields: Array<string> | null }> } };

export type RejectJoinRequestMutationVariables = Exact<{
  id: string | number;
  input?: RejectJoinRequestInput | null | undefined;
}>;


export type RejectJoinRequestMutation = { rejectJoinRequest: { result: { id: string, status: string, rejectionReason: string | null } | null, errors: Array<{ message: string | null, fields: Array<string> | null }> } };

export type GrantConsentMutationVariables = Exact<{
  platform: string;
  templateKey: string;
}>;


export type GrantConsentMutation = { grantMiniProgramNotificationConsent: number | null };

export type GenerateMiniProgramCodeMutationVariables = Exact<{
  workspaceId: string | number;
  platform: string;
}>;


export type GenerateMiniProgramCodeMutation = { generateMiniProgramCode: { invitationId: string, platform: string, scene: string, codeBase64: string, expiresAt: string } | null };

export type AdmitMemberByTokenMutationVariables = Exact<{
  scene: string;
}>;


export type AdmitMemberByTokenMutation = { admitMemberByToken: { id: string, workspaceId: string, workspaceName: string | null, status: string, acceptedAt: string | null } | null };

export type CreateOrderMutationVariables = Exact<{
  input: CreateOrderInput;
}>;


export type CreateOrderMutation = { createOrder: { result: { id: string, enrollmentId: string, provider: string, outTradeNo: string, amountCents: number, status: string, expireAt: string, orderKind: string } | null, errors: Array<{ message: string | null, code: string | null }>, metadata: { credential: string | null } | null } };

export type OrderStatusQueryVariables = Exact<{
  id: string | number;
}>;


export type OrderStatusQuery = { orderStatus: { id: string, status: string, transactionId: string | null, amountCents: number, expireAt: string, orderKind: string } | null };

export type MyOrdersQueryVariables = Exact<{ [key: string]: never; }>;


export type MyOrdersQuery = { myOrders: { results: Array<{ id: string, enrollmentId: string, provider: string, status: string, amountCents: number, expireAt: string, orderKind: string }> | null } | null };

export type PublicInitiativesQueryVariables = Exact<{ [key: string]: never; }>;


export type PublicInitiativesQuery = { publicInitiatives: Array<{ id: string, name: string, slug: string, hashtag: string | null, status: string, description: string | null, windowStartsAt: string | null, windowEndsAt: string | null }> };

export type CheckInEnrollmentMutationVariables = Exact<{
  eventId: string | number;
  code: string;
  method: string;
}>;


export type CheckInEnrollmentMutation = { checkInEnrollment: { enrollmentId: string | null, checkedInAt: string | null, method: string | null, depositRefund: string | null, errors: Array<{ message: string | null, code: string | null } | null> | null } | null };

export type EventModerationScopeQueryVariables = Exact<{
  id: string | number;
}>;


export type EventModerationScopeQuery = { getEvent: { id: string, workspaceId: string } | null };

export type EventModeratorsQueryVariables = Exact<{
  workspaceId: string | number;
  eventId: string | number;
}>;


export type EventModeratorsQuery = { eventModerators: Array<{ userId: string }> };

export type PublicInitiativeQueryVariables = Exact<{
  slug: string;
}>;


export type PublicInitiativeQuery = { publicInitiative: { id: string, name: string, slug: string, hashtag: string | null, description: string | null, status: string, windowStartsAt: string | null, windowEndsAt: string | null, cityCount: number, eventCount: number, confirmedCount: number, qualifiedEventCount: number, cities: Array<{ city: string, events: Array<{ id: string, slug: string, title: string, status: string, startsAt: string | null, endsAt: string | null, registrationDeadline: string | null, venue: string | null, archived: boolean, qualificationBadge: string, shortBy: number | null, paymentMode: string, minAge: number | null, priceRangeMinCents: number | null, deposit: { enabled: boolean, amountCents: number | null, refundableOnCheckIn: boolean | null } }> }> } | null };

export type FlashbackCapsuleQueryVariables = Exact<{
  city?: string | null | undefined;
  token?: string | null | undefined;
}>;


export type FlashbackCapsuleQuery = { flashbackCapsule: { myWishQuotaRemaining: number | null, cities: Array<string>, me: { id: string, fullName: string, surname: string | null, city: string | null, occupationThen: string | null, participation: string, appliedAt: string | null, quoteLevel: string, quote: string | null, quoteSpans: Array<{ questionKey: string, start: number, len: number } | null> | null, quoteStats: { likeCount: number } | null, today: { nowStatus: string | null, want: string | null, need: string | null, say: string | null, fogSpans: string | null, sentToWallAt: string | null } | null, cardSharing: { enabled: boolean, shareId: string | null, preview: { displayName: string, city: string | null, appliedAt: string | null, occurredOn: string | null, answers: Array<{ questionKey: string, segments: Array<{ text: string, fog: boolean, len: number }> }>, today: Array<{ questionKey: string, segments: Array<{ text: string, fog: boolean, len: number }> }> } | null }, answers: Array<{ id: string, questionKey: string, rawText: string, text: string, fogSpans: Array<{ start: number, len: number }> }> }, archives: Array<{ key: string, name: string | null, city: string | null, occurredOn: string | null, appliedCount: number | null, attendedCount: number | null, label: string | null, isMine: boolean, roster: Array<{ id: string, surnameMasked: string, fullName: string | null, appliedAt: string | null, city: string | null, occupationThen: string | null, sentToWallAt: string | null, today: { nowStatus: string | null, want: string | null, say: string | null } | null, answers: Array<{ questionKey: string, segments: Array<{ text: string, fog: boolean, len: number }> }> }> }>, futureEvents: Array<{ initiativeSlug: string, initiativeName: string, initiativeStartsAt: string | null, events: Array<{ id: string, slug: string, title: string, city: string | null, startsAt: string | null, capacity: number | null, confirmedCount: number, registrationDeadline: string | null }> }>, publicWishes: Array<{ id: string, content: string, city: string | null, wisherMasked: string | null, endorsementCount: number, endorsedByMe: boolean, mine: boolean, echoCount: number, insertedAt: string, comments: Array<{ id: string, content: string, commenterMasked: string | null, insertedAt: string }>, latestEcho: { id: string, content: string, status: string, publishedAt: string, correctedAt: string | null } | null, echoes: Array<{ id: string, content: string, status: string, publishedAt: string, correctedAt: string | null }> }>, myPrivateWishes: Array<{ id: string, content: string, city: string | null, wisherMasked: string | null, endorsementCount: number, endorsedByMe: boolean, mine: boolean, insertedAt: string }> } | null };

export type FlashbackPublicStatsQueryVariables = Exact<{ [key: string]: never; }>;


export type FlashbackPublicStatsQuery = { flashbackPublicStats: { returnedCount: number, sentCount: number, archives: Array<{ key: string, name: string | null, city: string | null, occurredOn: string | null, appliedCount: number | null, attendedCount: number | null, label: string | null }> } | null };

export type FlashbackSubmitTodayMutationVariables = Exact<{
  input: FlashbackTodayInput;
  token?: string | null | undefined;
}>;


export type FlashbackSubmitTodayMutation = { flashbackSubmitToday: { today: { nowStatus: string | null, want: string | null, need: string | null, say: string | null } | null } | null };

export type FlashbackSetQuoteLicenseMutationVariables = Exact<{
  level: string;
  chosenQuoteSpans?: Array<FlashbackQuoteSpanInput> | FlashbackQuoteSpanInput | null | undefined;
  token?: string | null | undefined;
}>;


export type FlashbackSetQuoteLicenseMutation = { flashbackSetQuoteLicense: { level: string, chosenQuoteSpans: Array<{ questionKey: string, start: number, len: number } | null> | null } | null };

export type FlashbackEnterMutationVariables = Exact<{
  token: string;
}>;


export type FlashbackEnterMutation = { flashbackEnter: { line: string, profile: { fullName: string, surname: string | null, city: string | null, occupationThen: string | null, participation: string, role: string, appliedAt: string | null, archive: { key: string, name: string | null, city: string | null, occurredOn: string | null } | null, answers: Array<{ id: string, questionKey: string, rawText: string, fogSpans: Array<{ start: number, len: number } | null> | null } | null> | null } | null, progress: { quoteLevel: string, maskedPhone: string | null, maskedEmail: string | null, today: { nowStatus: string | null, want: string | null, say: string | null, sentToWallAt: string | null } | null } | null } | null };

export type FlashbackMarkRevealedMutationVariables = Exact<{
  token: string;
}>;


export type FlashbackMarkRevealedMutation = { flashbackMarkRevealed: { recorded: boolean } | null };

export type FlashbackSendToWallMutationVariables = Exact<{
  token: string;
}>;


export type FlashbackSendToWallMutation = { flashbackSendToWall: { sentToWallAt: string | null } | null };

export type FlashbackClaimMutationVariables = Exact<{
  token?: string | null | undefined;
}>;


export type FlashbackClaimMutation = { flashbackClaim: { bound: boolean, boundCount: number, maskedPhone: string | null } | null };

export type FlashbackAdjustFogMutationVariables = Exact<{
  token?: string | null | undefined;
  answerId: string | number;
  spans: Array<FlashbackFogSpanInput> | FlashbackFogSpanInput;
}>;


export type FlashbackAdjustFogMutation = { flashbackAdjustFog: { answerId: string, fogSpans: Array<{ start: number, len: number } | null> | null } | null };

export type FlashbackAdjustTodayFogMutationVariables = Exact<{
  token?: string | null | undefined;
  field: string;
  spans: Array<FlashbackFogSpanInput> | FlashbackFogSpanInput;
}>;


export type FlashbackAdjustTodayFogMutation = { flashbackAdjustTodayFog: { field: string, fogSpans: string | null } | null };

export type FlashbackCreateWishMutationVariables = Exact<{
  token?: string | null | undefined;
  requestId?: string | number | null | undefined;
  content: string;
  visibility: string;
  signatureChoice?: string | null | undefined;
  expectedCity?: string | null | undefined;
  publicListingConsent?: boolean | null | undefined;
}>;


export type FlashbackCreateWishMutation = { flashbackCreateWish: { id: string | null, endorsementCount: number, endorsedByMe: boolean, status: string } | null };

export type FlashbackCitiesQueryVariables = Exact<{ [key: string]: never; }>;


export type FlashbackCitiesQuery = { flashbackCities: Array<{ name: string, fullName: string, pinyin: string, lngLat: Array<number> }> };

export type FlashbackEndorseWishMutationVariables = Exact<{
  wishId: string | number;
  contributionTypes?: Array<string> | string | null | undefined;
  message?: string | null | undefined;
  notify?: boolean | null | undefined;
}>;


export type FlashbackEndorseWishMutation = { flashbackEndorseWish: { endorsementCount: number, endorsedByMe: boolean } | null };

export type FlashbackCancelEndorseWishMutationVariables = Exact<{
  wishId: string | number;
}>;


export type FlashbackCancelEndorseWishMutation = { flashbackCancelEndorseWish: { endorsementCount: number, endorsedByMe: boolean } | null };

export type FlashbackExpectWishMutationVariables = Exact<{
  wishId: string | number;
  expected: boolean;
  anonVoterKey?: string | null | undefined;
}>;


export type FlashbackExpectWishMutation = { flashbackExpectWish: { expectationCount: number, expectedByMe: boolean } | null };

export type FlashbackReportWishMutationVariables = Exact<{
  wishId: string | number;
  reasonType: string;
  reasonFree?: string | null | undefined;
  anonVoterKey?: string | null | undefined;
}>;


export type FlashbackReportWishMutation = { flashbackReportWish: { reportId: string, status: string } | null };

export type FlashbackPublicWishesQueryVariables = Exact<{
  city?: string | null | undefined;
  withEchoes?: boolean | null | undefined;
  seed?: string | null | undefined;
  offset?: number | null | undefined;
  limit?: number | null | undefined;
  voterKey?: string | null | undefined;
}>;


export type FlashbackPublicWishesQuery = { flashbackPublicWishes: Array<{ id: string, content: string, city: string | null, signature: string, expectationCount: number, endorsementCount: number, contributionDistribution: string, expectedByViewer: boolean, endorsedByViewer: boolean, echoCount: number, listedAt: string, insertedAt: string, latestEcho: { id: string, content: string, status: string, publishedAt: string, correctedAt: string | null } | null, echoes: Array<{ id: string, content: string, status: string, publishedAt: string, correctedAt: string | null }> }> };

export type FlashbackAddWishCommentMutationVariables = Exact<{
  token?: string | null | undefined;
  wishId: string | number;
  content: string;
}>;


export type FlashbackAddWishCommentMutation = { flashbackAddWishComment: { endorsementCount: number, endorsedByMe: boolean } | null };

export type FlashbackDeleteWishMutationVariables = Exact<{
  token?: string | null | undefined;
  wishId: string | number;
}>;


export type FlashbackDeleteWishMutation = { flashbackDeleteWish: boolean | null };

export type FlashbackSetCardSharingMutationVariables = Exact<{
  enabled: boolean;
  token?: string | null | undefined;
}>;


export type FlashbackSetCardSharingMutation = { flashbackSetCardSharing: { enabled: boolean, shareId: string | null, preview: { displayName: string, city: string | null, appliedAt: string | null, occurredOn: string | null, answers: Array<{ questionKey: string, segments: Array<{ text: string, fog: boolean, len: number }> }>, today: Array<{ questionKey: string, segments: Array<{ text: string, fog: boolean, len: number }> }> } | null } | null };

export type FlashbackSharedCardQueryVariables = Exact<{
  shareId: string;
}>;


export type FlashbackSharedCardQuery = { flashbackSharedCard: { displayName: string, city: string | null, appliedAt: string | null, occurredOn: string | null, answers: Array<{ questionKey: string, segments: Array<{ text: string, fog: boolean, len: number }> }>, today: Array<{ questionKey: string, segments: Array<{ text: string, fog: boolean, len: number }> }> } | null };

export type RecruitmentWorkspaceQueryVariables = Exact<{
  slug: string;
}>;


export type RecruitmentWorkspaceQuery = { getWorkspace: { id: string, name: string } | null };

export type CurrentRecruitmentCohortQueryVariables = Exact<{
  workspaceId: string | number;
}>;


export type CurrentRecruitmentCohortQuery = { currentRecruitmentCohort: { id: string, name: string, applyDeadlineAt: string, startsAt: string | null, endsAt: string | null, status: string } | null };

export type MyResumeProfileQueryVariables = Exact<{
  workspaceId: string | number;
}>;


export type MyResumeProfileQuery = { myResumeProfile: { id: string, fullName: string, contactEmail: string, weeklyHours: number | null, skills: Array<string>, fileName: string | null, fileContentType: string | null, fileSize: number | null, uploadedAt: string | null } | null };

export type UpsertResumeProfileMutationVariables = Exact<{
  workspaceId: string | number;
  input: UpsertResumeProfileInput;
}>;


export type UpsertResumeProfileMutation = { upsertResumeProfile: { result: { id: string, fullName: string, contactEmail: string, weeklyHours: number | null, skills: Array<string>, fileName: string | null, fileContentType: string | null, fileSize: number | null, uploadedAt: string | null } | null, errors: Array<{ message: string | null, code: string | null }> } | null };

export type UploadResumeFileMutationVariables = Exact<{
  workspaceId: string | number;
  input: UploadResumeFileInput;
}>;


export type UploadResumeFileMutation = { uploadResumeFile: { result: { id: string, fullName: string, contactEmail: string, weeklyHours: number | null, skills: Array<string>, fileName: string | null, fileContentType: string | null, fileSize: number | null, uploadedAt: string | null } | null, errors: Array<{ message: string | null, code: string | null }> } | null };

export type MyVolunteerApplicationsQueryVariables = Exact<{
  workspaceId: string | number;
}>;


export type MyVolunteerApplicationsQuery = { myVolunteerApplications: Array<{ id: string, cohortId: string, position: string, city: string | null, heardAboutUs: string | null, hasInternalReferrer: boolean, message: string | null, status: string, rejectionReason: string | null, assignedEventId: string | null, assignmentNote: string | null, assignedAt: string | null }> };

export type CreateVolunteerApplicationMutationVariables = Exact<{
  workspaceId: string | number;
  input: CreateVolunteerApplicationInput;
}>;


export type CreateVolunteerApplicationMutation = { createVolunteerApplication: { result: { id: string, cohortId: string, position: string, city: string | null, heardAboutUs: string | null, hasInternalReferrer: boolean, message: string | null, status: string, rejectionReason: string | null, assignedEventId: string | null, assignmentNote: string | null, assignedAt: string | null } | null, errors: Array<{ message: string | null, code: string | null }> } | null };

export type FlashbackVoicesQueryVariables = Exact<{
  voterKey?: string | null | undefined;
  city?: string | null | undefined;
}>;


export type FlashbackVoicesQuery = { flashbackPublicQuotes: Array<{ quoteId: string, text: string, attribution: string, city: string | null, year: number | null, likeCount: number, likedByViewer: boolean, level: string, publicSlug: string | null }> };

export type FlashbackVoiceQueryVariables = Exact<{
  quoteId: string | number;
  voterKey?: string | null | undefined;
}>;


export type FlashbackVoiceQuery = { flashbackPublicQuote: { quoteId: string, text: string, attribution: string, city: string | null, year: number | null, likeCount: number, likedByViewer: boolean, level: string, publicSlug: string | null } | null };

export type FlashbackRandomVoicesQueryVariables = Exact<{
  voterKey?: string | null | undefined;
  limit?: number | null | undefined;
}>;


export type FlashbackRandomVoicesQuery = { flashbackRandomQuotes: Array<{ quoteId: string, text: string, attribution: string, city: string | null, year: number | null, likeCount: number, likedByViewer: boolean, level: string, publicSlug: string | null }> };

export type FlashbackLikeVoiceMutationVariables = Exact<{
  quoteId: string | number;
  voterKey: string;
  liked: boolean;
}>;


export type FlashbackLikeVoiceMutation = { flashbackLikeQuote: { likeCount: number } | null };

export type FlashbackVoiceCitiesQueryVariables = Exact<{ [key: string]: never; }>;


export type FlashbackVoiceCitiesQuery = { flashbackVoiceCities: Array<{ name: string, fullName: string, pinyin: string, lngLat: Array<number> }> };

export type FlashbackMyWishesQueryVariables = Exact<{ [key: string]: never; }>;


export type FlashbackMyWishesQuery = { flashbackMyWishes: { quotaRemaining: number, wishes: Array<{ id: string, content: string, city: string | null, signature: string, visibility: string, status: string, insertedAt: string }> } | null };

export type FlashbackWishCitiesQueryVariables = Exact<{ [key: string]: never; }>;


export type FlashbackWishCitiesQuery = { flashbackWishCities: Array<{ name: string, lngLat: Array<number> }> };

export type FlashbackPublicWishQueryVariables = Exact<{
  wishId: string | number;
  voterKey?: string | null | undefined;
}>;


export type FlashbackPublicWishQuery = { flashbackPublicWish: { id: string, content: string, city: string | null, signature: string, expectationCount: number, endorsementCount: number, contributionDistribution: string, expectedByViewer: boolean, endorsedByViewer: boolean, echoCount: number, listedAt: string, insertedAt: string, latestEcho: { id: string, content: string, status: string, publishedAt: string, correctedAt: string | null } | null, echoes: Array<{ id: string, content: string, status: string, publishedAt: string, correctedAt: string | null }> } | null };
