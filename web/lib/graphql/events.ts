import { gql } from "@apollo/client";
import type { TypedDocumentNode } from "@apollo/client";
import type { MutationResult } from "./shared";

/**
 * E-11 #127 活动/课程（Event/Course）GraphQL 契约（对齐 event.ex/course.ex
 * graphql 段 + backend/priv/graphql/schema.graphql）。
 *
 * 关键约定：
 * - 列表查询走 keyset 分页（KeysetPageOfEvent.results，filter 参数包裹）；
 * - 状态机：draft → open → closed/cancelled（终态不可逆，v1）；
 * - visibility 轴（D9）：public | workspace，可随时双向切换（含 open 后）；
 * - 读策略：匿名仅可读 open+public；成员可读本工作台非 draft；Owner/Admin 含 draft；
 * - 白名单（D2 denylist 式）：capacity/confirmedCount/workspaceId 等敏感字段
 *   对非成员为 null（field policy 筛除）；
 * - 写操作：Owner/Admin（后端 policy 兜底）；create 需 workspaceId 入参。
 */

/* ---------------- 类型 ---------------- */

export type EventStatus = "draft" | "open" | "closed" | "cancelled";
export type EnrollmentPolicy = "open" | "request" | "invite_only";
export type Visibility = "public" | "workspace";

/**
 * 公开派生报名标签（R6/KTD1，后端 EnrollmentBadge 单源）：
 * 优先级 full > starting_soon > enrolling；无 startsAt 永不 starting_soon。
 * 公开面只暴露派生标签，不暴露 capacity/confirmedCount 原始计数。
 */
export type EnrollmentBadge = "enrolling" | "starting_soon" | "full";

/** 结构化场地（venue JsonString JSON.parse 后形状，恰四键；仅 event 有 venue 槽，course 无位置概念） */
export interface VenueInfo {
  country: string;
  province: string;
  city: string;
  district: string;
}

/** 活动/课程共享字段（后端两个资源同构） */
export interface OfferingItem {
  id: string;
  workspaceId: string | null;
  title: string;
  /** 公开 URL 段（E-4 Speaker 邀请链接原料；成员可见） */
  slug: string | null;
  status: EventStatus;
  visibility: Visibility;
  enrollmentPolicy: EnrollmentPolicy;
  /** 报名名额上限；null = 不限（非成员读到 null，D2 白名单） */
  capacity: number | null;
  /** 已确认名额数（非成员读到 null，D2 白名单） */
  confirmedCount: number | null;
  registrationDeadline: string | null;
  /** 开始时间（ISO8601；null = 未定；R1，course 语义为开课/结课） */
  startsAt?: string | null;
  /** 结束时间（ISO8601；须晚于 startsAt，KTD6 后端校验；null = 未定） */
  endsAt?: string | null;
  /** 结构化场地（JsonString，JSON.parse 后为 VenueInfo；仅 event 有 venue 槽，null = 线上/未定） */
  venue?: string | null;
  /** 教研需求(自由文本;仅 course、成员可见;U8/R12) */
  researchRequirements?: string | null;
  /** 教研 run 引用(仅 course;U8 教研状态露出) */
  workflowRunId?: string | null;
  workflowRun?: { id: string; status: string } | null;
  /** 是否收费（默认免费；收费报名须选档并支付，R4 免费路径零变化） */
  pricingEnabled?: boolean | null;
  /** 可售价格档位（JsonString 数组，后端已过滤过期档，R2）；解析见 lib/payment.parsePriceTiers */
  availablePriceTiers?: string[] | null;
  /** 档位原始配置（JsonString 数组含过期档；U2-R1 定价编辑面数据源） */
  priceTiers?: string[] | null;
  /** 是否开放赞助入口（仅 event；E-3 #48） */
  sponsorshipEnabled?: boolean;
  /** 赞助档位配置（JsonString 数组，每项 JSON.parse 后为 SponsorshipTierConfig；仅 event） */
  sponsorshipTiers?: string[] | null;
  /** 赞助意向截止（仅 event） */
  sponsorshipDeadline?: string | null;
}

export type OfferingKind = "event" | "course";

/** create/update mutation 两段式返回（同 shared.MutationResult 语义） */
export type OfferingMutationResult = MutationResult<OfferingItem>;

/* ---------------- 展示词表（单源；页面一律 import，不重复字面量） ---------------- */

export const EVENT_STATUS_LABEL: Record<EventStatus, string> = {
  draft: "labels.eventStatus.draft",
  open: "labels.eventStatus.open",
  closed: "labels.eventStatus.closed",
  cancelled: "labels.eventStatus.cancelled",
};

export const EVENT_STATUS_TONE: Record<
  EventStatus,
  "neutral" | "positive" | "negative"
> = {
  draft: "neutral",
  open: "positive",
  closed: "neutral",
  cancelled: "negative",
};

export const VISIBILITY_LABEL: Record<Visibility, string> = {
  public: "labels.visibility.public",
  workspace: "labels.visibility.workspace",
};

export const ENROLLMENT_POLICY_LABEL: Record<EnrollmentPolicy, string> = {
  open: "labels.enrollmentPolicy.open",
  request: "labels.enrollmentPolicy.request",
  invite_only: "labels.enrollmentPolicy.invite_only",
};

export const OFFERING_LABEL: Record<OfferingKind, string> = {
  event: "labels.offeringKind.event",
  course: "labels.offeringKind.course",
};

export const ENROLLMENT_BADGE_LABEL: Record<EnrollmentBadge, string> = {
  enrolling: "labels.enrollmentBadge.enrolling",
  starting_soon: "labels.enrollmentBadge.starting_soon",
  full: "labels.enrollmentBadge.full",
};

export const EVENT_STATUSES: EventStatus[] = [
  "draft",
  "open",
  "closed",
  "cancelled",
];
export const VISIBILITIES: Visibility[] = ["public", "workspace"];
export const ENROLLMENT_POLICIES: EnrollmentPolicy[] = [
  "open",
  "request",
  "invite_only",
];
export const ENROLLMENT_BADGES: EnrollmentBadge[] = [
  "enrolling",
  "starting_soon",
  "full",
];

/* ---------------- Queries ---------------- */

export const LIST_EVENTS: TypedDocumentNode<
  { listEvents: { results: OfferingItem[] } },
  { workspaceId: string }
> = gql`
  query ListEvents($workspaceId: ID!) {
    listEvents(filter: { workspaceId: { eq: $workspaceId } }) {
      results {
        id
        workspaceId
        title
        status
        visibility
        enrollmentPolicy
        capacity
        confirmedCount
        registrationDeadline
        pricingEnabled
        priceTiers
      }
    }
  }
`;

export const LIST_COURSES: TypedDocumentNode<
  { listCourses: { results: OfferingItem[] } },
  { workspaceId: string }
> = gql`
  query ListCourses($workspaceId: ID!) {
    listCourses(filter: { workspaceId: { eq: $workspaceId } }) {
      results {
        id
        workspaceId
        title
        status
        visibility
        enrollmentPolicy
        capacity
        confirmedCount
        registrationDeadline
        pricingEnabled
        priceTiers
      }
    }
  }
`;

export const GET_EVENT: TypedDocumentNode<
  { getEvent: OfferingItem },
  { id: string }
> = gql`
  query GetEvent($id: ID!) {
    getEvent(id: $id) {
      id
      workspaceId
      title
      slug
      status
      visibility
      enrollmentPolicy
      capacity
      confirmedCount
      registrationDeadline
      startsAt
      endsAt
      venue
      sponsorshipEnabled
      sponsorshipTiers
      sponsorshipDeadline
      pricingEnabled
      availablePriceTiers
    }
  }
`;

export const GET_COURSE: TypedDocumentNode<
  {
    getCourse: OfferingItem & {
      workflowRun: { id: string; status: string } | null;
    };
  },
  { id: string }
> = gql`
  query GetCourse($id: ID!) {
    getCourse(id: $id) {
      id
      workspaceId
      title
      status
      visibility
      enrollmentPolicy
      capacity
      confirmedCount
      registrationDeadline
      startsAt
      endsAt
      researchRequirements
      workflowRunId
      workflowRun {
        id
        status
      }
      pricingEnabled
      availablePriceTiers
    }
  }
`;

/* ---------------- Mutations ---------------- */

export const CREATE_EVENT: TypedDocumentNode<
  { createEvent: OfferingMutationResult },
  { input: Record<string, unknown> }
> = gql`
  mutation CreateEvent($input: CreateEventInput!) {
    createEvent(input: $input) {
      result {
        id
        workspaceId
        title
        status
        visibility
        enrollmentPolicy
        capacity
        confirmedCount
        registrationDeadline
      }
      errors {
        code
        message
      }
    }
  }
`;

export const CREATE_COURSE: TypedDocumentNode<
  { createCourse: OfferingMutationResult },
  { input: Record<string, unknown> }
> = gql`
  mutation CreateCourse($input: CreateCourseInput!) {
    createCourse(input: $input) {
      result {
        id
        workspaceId
        title
        status
        visibility
        enrollmentPolicy
        capacity
        confirmedCount
        registrationDeadline
      }
      errors {
        code
        message
      }
    }
  }
`;

export const UPDATE_EVENT: TypedDocumentNode<
  { updateEvent: OfferingMutationResult },
  { id: string; input: Record<string, unknown> }
> = gql`
  mutation UpdateEvent($id: ID!, $input: UpdateEventInput!) {
    updateEvent(id: $id, input: $input) {
      result {
        id
        title
        status
        visibility
        enrollmentPolicy
        capacity
        registrationDeadline
        startsAt
        endsAt
        venue
      }
      errors {
        code
        message
      }
    }
  }
`;

export const UPDATE_COURSE: TypedDocumentNode<
  { updateCourse: OfferingMutationResult },
  { id: string; input: Record<string, unknown> }
> = gql`
  mutation UpdateCourse($id: ID!, $input: UpdateCourseInput!) {
    updateCourse(id: $id, input: $input) {
      result {
        id
        title
        status
        visibility
        enrollmentPolicy
        capacity
        registrationDeadline
        startsAt
        endsAt
        researchRequirements
      }
      errors {
        code
        message
      }
    }
  }
`;

export const LAUNCH_EVENT: TypedDocumentNode<
  { launchEvent: OfferingMutationResult },
  { id: string }
> = gql`
  mutation LaunchEvent($id: ID!) {
    launchEvent(id: $id) {
      result {
        id
        status
      }
      errors {
        code
        message
      }
    }
  }
`;

export const LAUNCH_COURSE: TypedDocumentNode<
  { launchCourse: OfferingMutationResult },
  { id: string }
> = gql`
  mutation LaunchCourse($id: ID!) {
    launchCourse(id: $id) {
      result {
        id
        status
      }
      errors {
        code
        message
      }
    }
  }
`;

export const CLOSE_EVENT: TypedDocumentNode<
  { closeEvent: OfferingMutationResult },
  { id: string }
> = gql`
  mutation CloseEvent($id: ID!) {
    closeEvent(id: $id) {
      result {
        id
        status
      }
      errors {
        code
        message
      }
    }
  }
`;

export const CLOSE_COURSE: TypedDocumentNode<
  { closeCourse: OfferingMutationResult },
  { id: string }
> = gql`
  mutation CloseCourse($id: ID!) {
    closeCourse(id: $id) {
      result {
        id
        status
      }
      errors {
        code
        message
      }
    }
  }
`;

export const CANCEL_EVENT: TypedDocumentNode<
  { cancelEvent: OfferingMutationResult },
  { id: string }
> = gql`
  mutation CancelEvent($id: ID!) {
    cancelEvent(id: $id) {
      result {
        id
        status
      }
      errors {
        code
        message
      }
    }
  }
`;

export const CANCEL_COURSE: TypedDocumentNode<
  { cancelCourse: OfferingMutationResult },
  { id: string }
> = gql`
  mutation CancelCourse($id: ID!) {
    cancelCourse(id: $id) {
      result {
        id
        status
      }
      errors {
        code
        message
      }
    }
  }
`;

/* ---------------- 公开面（E-5 #50：匿名白名单字段查询，不含 D2 敏感字段） ---------------- */

/** 公开活动/课程条目（匿名可读白名单：id/title/status/visibility/enrollmentPolicy/registrationDeadline + 时间/badge；capacity/confirmedCount 对匿名恒不可读） */
export interface PublicOfferingItem {
  id: string;
  slug: string;
  title: string;
  description: string | null;
  status: EventStatus;
  visibility: Visibility;
  enrollmentPolicy: EnrollmentPolicy;
  registrationDeadline: string | null;
  /** 开始时间（ISO8601）；null = 未定，展示层兜底「时间待定」（R3） */
  startsAt?: string | null;
  /** 结束时间（ISO8601）；null = 未定（R3） */
  endsAt?: string | null;
  /** 公开派生报名标签（R6/KTD1；展示经 ENROLLMENT_BADGE_LABEL） */
  enrollmentBadge?: EnrollmentBadge | null;
  /** 结构化场地（JsonString，JSON.parse 后为 VenueInfo；仅 event 有，null = 线上/未定，展示层兜底「地点待定」，R3） */
  venue?: string | null;
  /** 是否收费（公开报名面收费项须选档；R4 免费零变化） */
  pricingEnabled?: boolean | null;
  /** 可售价格档位（JsonString 数组，后端已过滤过期档，R2；解析见 lib/payment.parsePriceTiers） */
  availablePriceTiers?: string[] | null;
  /** 是否开放赞助入口（仅 event 有；E-3 #48） */
  sponsorshipEnabled?: boolean;
  /** 赞助档位配置（JsonString 数组，每项 JSON.parse 后为 SponsorshipTierConfig；仅 event） */
  sponsorshipTiers?: string[] | null;
}

export const PUBLIC_LIST_EVENTS: TypedDocumentNode<{
  listEvents: { results: PublicOfferingItem[] };
}> = gql`
  query PublicListEvents {
    listEvents(
      filter: { status: { eq: "open" }, visibility: { eq: "public" } }
    ) {
      results {
        id
        slug
        title
        description
        status
        visibility
        enrollmentPolicy
        registrationDeadline
        startsAt
        endsAt
        enrollmentBadge
        venue
      }
    }
  }
`;

export const PUBLIC_LIST_COURSES: TypedDocumentNode<{
  listCourses: { results: PublicOfferingItem[] };
}> = gql`
  query PublicListCourses {
    listCourses(
      filter: { status: { eq: "open" }, visibility: { eq: "public" } }
    ) {
      results {
        id
        slug
        title
        description
        status
        visibility
        enrollmentPolicy
        registrationDeadline
        startsAt
        endsAt
        enrollmentBadge
      }
    }
  }
`;

export const PUBLIC_GET_EVENT: TypedDocumentNode<
  { getEventBySlug: PublicOfferingItem | null },
  { slug: string }
> = gql`
  query PublicGetEvent($slug: String!) {
    getEventBySlug(slug: $slug) {
      id
      slug
      title
      description
      status
      visibility
      enrollmentPolicy
      registrationDeadline
      startsAt
      endsAt
      enrollmentBadge
      venue
      sponsorshipEnabled
      sponsorshipTiers
      pricingEnabled
      availablePriceTiers
    }
  }
`;

export const PUBLIC_GET_COURSE: TypedDocumentNode<
  { getCourseBySlug: PublicOfferingItem | null },
  { slug: string }
> = gql`
  query PublicGetCourse($slug: String!) {
    getCourseBySlug(slug: $slug) {
      id
      slug
      title
      description
      status
      visibility
      enrollmentPolicy
      registrationDeadline
      startsAt
      endsAt
      enrollmentBadge
      pricingEnabled
      availablePriceTiers
    }
  }
`;

/* ---------------- 报名（E-5 #50：createEnrollment 既有 mutation） ---------------- */

export type EnrollmentSubmissionResult = MutationResult<{
  id: string;
  status: string;
}>;

export const CREATE_ENROLLMENT: TypedDocumentNode<
  { createEnrollment: EnrollmentSubmissionResult },
  { input: Record<string, unknown> }
> = gql`
  mutation CreateEnrollment($input: CreateEnrollmentInput!) {
    createEnrollment(input: $input) {
      result {
        id
        status
      }
      errors {
        code
        message
      }
    }
  }
`;

/* ---------------- Enrollment 计数（详情页报名数据视图） ---------------- */

/** pending 报名数（request 策略待审批） */
export const LIST_EVENT_ENROLLMENTS: TypedDocumentNode<
  { enrollments: { count: number } },
  { eventId: string }
> = gql`
  query ListEventEnrollments($eventId: ID!) {
    enrollments(
      filter: { eventId: { eq: $eventId }, status: { eq: "pending" } }
    ) {
      count
    }
  }
`;

export const LIST_COURSE_ENROLLMENTS: TypedDocumentNode<
  { enrollments: { count: number } },
  { courseId: string }
> = gql`
  query ListCourseEnrollments($courseId: ID!) {
    enrollments(
      filter: { courseId: { eq: $courseId }, status: { eq: "pending" } }
    ) {
      count
    }
  }
`;

/* ---------------- 我的报名（工作台详情页入口防重，E-5 #50 G3） ---------------- */

/**
 * 当前用户对目标的活跃报名（e2e #2：终态 cancelled/expired/rejected 不算
 * 「已报名」，否则取消后 UI 无法再报名）。读策略仅本人可见 → 返回即已报名。
 * status 透传（支付接续：payment_pending 分叉「待支付」卡片，见 offering-pages）。
 */
export interface MyEnrollmentRow {
  id: string;
  status: string;
}

export const MY_EVENT_ENROLLMENT: TypedDocumentNode<
  { enrollments: { results: MyEnrollmentRow[] } },
  { eventId: string; userId: string }
> = gql`
  query MyEventEnrollment($eventId: ID!, $userId: ID!) {
    enrollments(
      filter: {
        eventId: { eq: $eventId }
        userId: { eq: $userId }
        status: { in: ["pending", "payment_pending", "confirmed"] }
      }
    ) {
      results {
        id
        status
      }
    }
  }
`;

export const MY_COURSE_ENROLLMENT: TypedDocumentNode<
  { enrollments: { results: MyEnrollmentRow[] } },
  { courseId: string; userId: string }
> = gql`
  query MyCourseEnrollment($courseId: ID!, $userId: ID!) {
    enrollments(
      filter: {
        courseId: { eq: $courseId }
        userId: { eq: $userId }
        status: { in: ["pending", "payment_pending", "confirmed"] }
      }
    ) {
      results {
        id
        status
      }
    }
  }
`;

/**
 * 按 id 读本人报名（/orders/new 进页守卫：校验报名是否为 payment_pending；
 * 读策略仅本人可见，他人/不存在 → 空 results）。
 */
export const MY_ENROLLMENT: TypedDocumentNode<
  { myEnrollments: { results: MyEnrollmentRow[] } },
  { id: string }
> = gql`
  query MyEnrollment($id: ID!) {
    myEnrollments(filter: { id: { eq: $id } }) {
      results {
        id
        status
      }
    }
  }
`;

/* ---------------- 课程地图(U8/R10:公开详情页,goal-only 无 checklist) ---------------- */

export interface CourseMapIssue {
  key: string;
  id: string;
  title: string;
  kind: string;
  goal: string | null;
}

export interface CourseMap {
  courseId: string;
  title: string;
  slug: string;
  goals: string[];
  issues: CourseMapIssue[];
}

export const COURSE_MAP: TypedDocumentNode<
  { courseMap: CourseMap | null },
  { slug: string }
> = gql`
  query CourseMap($slug: String!) {
    courseMap(slug: $slug) {
      courseId
      title
      slug
      goals
      issues {
        key
        id
        title
        kind
        goal
      }
    }
  }
`;
