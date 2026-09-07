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
  /** 目标报名（须为本人 payment_pending 报名） */
  enrollmentId: string | number;
  /** 支付渠道 */
  provider: string;
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

export type EventFilterInput = {
  and?: Array<EventFilterInput> | null | undefined;
  /** 报名名额上限；nil 表示不限 */
  capacity?: EventFilterCapacity | null | undefined;
  /** 已确认名额数（仅由 Enrollment 原子维护） */
  confirmedCount?: EventFilterConfirmedCount | null | undefined;
  /** 是否启用教研 workflow */
  curriculumEnabled?: EventFilterCurriculumEnabled | null | undefined;
  /** 教研材料需求（audience/duration/sections 等），作为 run input 注入 */
  curriculumRequirements?: EventFilterCurriculumRequirements | null | undefined;
  /** 公开展示文案（可空；null 由展示层按空串呈现） */
  description?: EventFilterDescription | null | undefined;
  /** 活动结束时间；须严格晚于 starts_at（KTD6），nil 表示未定（R1） */
  endsAt?: EventFilterEndsAt | null | undefined;
  /** 报名策略：open / request / invite_only */
  enrollmentPolicy?: EventFilterEnrollmentPolicy | null | undefined;
  id?: EventFilterId | null | undefined;
  not?: Array<EventFilterInput> | null | undefined;
  or?: Array<EventFilterInput> | null | undefined;
  /** 是否收费（默认免费；true 时报名须选档并完成支付，R4） */
  pricingEnabled?: EventFilterPricingEnabled | null | undefined;
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

export type RejectEnrollmentInput = {
  rejectionReason?: string | null | undefined;
};

export type RejectJoinRequestInput = {
  /** 拒绝原因 */
  rejectionReason?: string | null | undefined;
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


export type EventDetailQuery = { getEvent: { id: string, title: string, status: string, enrollmentPolicy: string, registrationDeadline: string | null, pricingEnabled: boolean, availablePriceTiers: Array<string> | null, startsAt: string | null, endsAt: string | null, venue: string | null, enrollmentBadge: string | null } | null, myEnrollment: { id: string, status: string, approvalDeadline: string | null } | null };

export type CourseDetailQueryVariables = Exact<{
  id: string | number;
}>;


export type CourseDetailQuery = { getCourse: { id: string, title: string, status: string, enrollmentPolicy: string, registrationDeadline: string | null, pricingEnabled: boolean, availablePriceTiers: Array<string> | null, startsAt: string | null, endsAt: string | null, enrollmentBadge: string | null } | null, myEnrollment: { id: string, status: string, approvalDeadline: string | null } | null };

export type SessionQueryVariables = Exact<{ [key: string]: never; }>;


export type SessionQuery = { me: { id: string, email: string | null, displayName: string | null, memberNumber: string | null, joinedAt: string | null, isPlatformAdmin: boolean } | null, meWorkspaces: Array<{ id: string, slug: string, name: string, joinPolicy: string, myRoleNames: Array<string> | null, myMembershipId: string | null, canAccess: boolean | null, myAbilities: Array<string> | null, memberCount: number | null }>, myPendingApprovals: Array<{ id: string, kind: string, workspaceId: string, userId: string, eventId: string | null, courseId: string | null, status: string, approvalDeadline: string | null, requesterName: string | null, contextTitle: string | null, tierName: string | null, amount: number | null }> };

export type MyEnrollmentsQueryVariables = Exact<{
  userId: string | number;
  first?: number | null | undefined;
}>;


export type MyEnrollmentsQuery = { enrollments: { results: Array<{ id: string, workspaceId: string, eventId: string | null, courseId: string | null, userId: string, status: string, targetTitle: string | null, approvalDeadline: string | null, rejectionReason: string | null, approvedAt: string | null, expiredAt: string | null, cancelledAt: string | null, insertedAt: string }> | null } | null };

export type EnrollmentQueryVariables = Exact<{
  id: string | number;
}>;


export type EnrollmentQuery = { enrollments: { results: Array<{ id: string, workspaceId: string, eventId: string | null, courseId: string | null, userId: string, status: string, targetTitle: string | null, approvalDeadline: string | null, rejectionReason: string | null, approvedAt: string | null, expiredAt: string | null, cancelledAt: string | null, insertedAt: string }> | null } | null };

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


export type CreateOrderMutation = { createOrder: { result: { id: string, enrollmentId: string, provider: string, outTradeNo: string, amountCents: number, status: string, expireAt: string } | null, errors: Array<{ message: string | null, code: string | null }>, metadata: { credential: string | null } | null } };

export type OrderStatusQueryVariables = Exact<{
  id: string | number;
}>;


export type OrderStatusQuery = { orderStatus: { id: string, status: string, transactionId: string | null, amountCents: number, expireAt: string } | null };

export type MyOrdersQueryVariables = Exact<{ [key: string]: never; }>;


export type MyOrdersQuery = { myOrders: { results: Array<{ id: string, enrollmentId: string, provider: string, status: string, amountCents: number, expireAt: string }> | null } | null };
