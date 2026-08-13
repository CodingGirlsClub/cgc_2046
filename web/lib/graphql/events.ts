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
 * - 读策略：匿名仅可读 open+public；成员可读本工作台全部；
 * - 白名单（D2 denylist 式）：capacity/confirmedCount/workspaceId 等敏感字段
 *   对非成员为 null（field policy 筛除）；
 * - 写操作：Owner/Admin（后端 policy 兜底）；create 需 workspaceId 入参。
 */

/* ---------------- 类型 ---------------- */

export type EventStatus = "draft" | "open" | "closed" | "cancelled";
export type EnrollmentPolicy = "open" | "request" | "invite_only";
export type Visibility = "public" | "workspace";

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
	draft: "草稿",
	open: "开放报名",
	closed: "已结束",
	cancelled: "已取消",
};

export const EVENT_STATUS_TONE: Record<EventStatus, "neutral" | "positive" | "negative"> = {
	draft: "neutral",
	open: "positive",
	closed: "neutral",
	cancelled: "negative",
};

export const VISIBILITY_LABEL: Record<Visibility, string> = {
	public: "公开可见",
	workspace: "仅工作台可见",
};

export const ENROLLMENT_POLICY_LABEL: Record<EnrollmentPolicy, string> = {
	open: "直接报名",
	request: "申请审批",
	invite_only: "邀请码报名",
};

export const OFFERING_LABEL: Record<OfferingKind, string> = {
	event: "活动",
	course: "课程",
};

export const EVENT_STATUSES: EventStatus[] = ["draft", "open", "closed", "cancelled"];
export const VISIBILITIES: Visibility[] = ["public", "workspace"];
export const ENROLLMENT_POLICIES: EnrollmentPolicy[] = ["open", "request", "invite_only"];

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
			}
		}
	}
`;

export const GET_EVENT: TypedDocumentNode<{ getEvent: OfferingItem }, { id: string }> = gql`
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
			sponsorshipEnabled
			sponsorshipTiers
			sponsorshipDeadline
		}
	}
`;

export const GET_COURSE: TypedDocumentNode<{ getCourse: OfferingItem }, { id: string }> = gql`
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
			}
			errors {
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
			}
			errors {
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
				message
			}
		}
	}
`;


/* ---------------- 公开面（E-5 #50：匿名白名单字段查询，不含 D2 敏感字段） ---------------- */

/** 公开活动/课程条目（匿名可读白名单：id/title/status/visibility/enrollmentPolicy/registrationDeadline） */
export interface PublicOfferingItem {
	id: string;
	slug: string;
	title: string;
	description: string | null;
	status: EventStatus;
	visibility: Visibility;
	enrollmentPolicy: EnrollmentPolicy;
	registrationDeadline: string | null;
	/** 是否开放赞助入口（仅 event 有；E-3 #48） */
	sponsorshipEnabled?: boolean;
	/** 赞助档位配置（JsonString 数组，每项 JSON.parse 后为 SponsorshipTierConfig；仅 event） */
	sponsorshipTiers?: string[] | null;
}

export const PUBLIC_LIST_EVENTS: TypedDocumentNode<
	{ listEvents: { results: PublicOfferingItem[] } }
> = gql`
	query PublicListEvents {
		listEvents(filter: { status: { eq: "open" }, visibility: { eq: "public" } }) {
			results {
				id
				slug
				title
				description
				status
				visibility
				enrollmentPolicy
				registrationDeadline
			}
		}
	}
`;

export const PUBLIC_LIST_COURSES: TypedDocumentNode<
	{ listCourses: { results: PublicOfferingItem[] } }
> = gql`
	query PublicListCourses {
		listCourses(filter: { status: { eq: "open" }, visibility: { eq: "public" } }) {
			results {
				id
				slug
				title
				description
				status
				visibility
				enrollmentPolicy
				registrationDeadline
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
			sponsorshipEnabled
			sponsorshipTiers
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
		enrollments(filter: { eventId: { eq: $eventId }, status: { eq: "pending" } }) {
			count
		}
	}
`;

export const LIST_COURSE_ENROLLMENTS: TypedDocumentNode<
	{ enrollments: { count: number } },
	{ courseId: string }
> = gql`
	query ListCourseEnrollments($courseId: ID!) {
		enrollments(filter: { courseId: { eq: $courseId }, status: { eq: "pending" } }) {
			count
		}
	}
`;
