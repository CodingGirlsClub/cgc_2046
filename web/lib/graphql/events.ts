import { gql } from "@apollo/client";
import type { TypedDocumentNode } from "@apollo/client";
import type { MutationResult } from "./shared";

/**
 * E-11 #127 活动（Event）GraphQL 契约（对齐后端 event.ex / course.ex graphql 段）。
 *
 * 关键约定：
 * - 状态机：draft → open → closed/cancelled（终态不可逆，v1）；
 * - visibility 轴（D9）：public 公开可见 / workspace 仅工作台可见，
 *   可随时双向切换（含 open 后）；
 * - 读策略：匿名仅可读 open+public；成员可读本工作台全部（含 draft/closed）；
 * - 白名单（D2）：capacity/confirmedCount 对非成员为 null（field policy 筛除）；
 * - 写操作：Owner/Admin（后端 policy 兜底）；create 需 workspaceId 入参。
 */

/* ---------------- 类型 ---------------- */

export type EventStatus = "draft" | "open" | "closed" | "cancelled";
export type EnrollmentPolicy = "open" | "request" | "invite_only";
export type Visibility = "public" | "workspace";

export interface EventItem {
	id: string;
	workspaceId: string;
	title: string;
	status: EventStatus;
	visibility: Visibility;
	enrollmentPolicy: EnrollmentPolicy;
	/** 报名名额上限；null = 不限（非成员读到 null/缺省，D2 白名单） */
	capacity: number | null;
	/** 已确认名额数（非成员读到 null/缺省，D2 白名单） */
	confirmedCount: number | null;
	registrationDeadline: string | null;
}

/** create/update mutation 两段式返回（同 shared.MutationResult 语义） */
export type EventMutationResult = MutationResult<EventItem>;

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

export const EVENT_STATUSES: EventStatus[] = ["draft", "open", "closed", "cancelled"];
export const VISIBILITIES: Visibility[] = ["public", "workspace"];
export const ENROLLMENT_POLICIES: EnrollmentPolicy[] = ["open", "request", "invite_only"];

/* ---------------- Queries ---------------- */

export const LIST_EVENTS: TypedDocumentNode<
	{ listEvents: EventItem[] },
	{ workspaceId: string }
> = gql`
	query ListEvents($workspaceId: ID!) {
		listEvents(input: { workspaceId: $workspaceId }) {
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

export const GET_EVENT: TypedDocumentNode<{ getEvent: EventItem }, { id: string }> = gql`
	query GetEvent($id: ID!) {
		getEvent(id: $id) {
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
	{ createEvent: EventMutationResult },
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

export const UPDATE_EVENT: TypedDocumentNode<
	{ updateEvent: EventMutationResult },
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

export const LAUNCH_EVENT: TypedDocumentNode<
	{ launchEvent: EventMutationResult },
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

export const CLOSE_EVENT: TypedDocumentNode<
	{ closeEvent: EventMutationResult },
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

export const CANCEL_EVENT: TypedDocumentNode<
	{ cancelEvent: EventMutationResult },
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
