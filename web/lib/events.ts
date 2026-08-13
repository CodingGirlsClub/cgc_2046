import type {
	EventItem,
	EventMutationResult,
	EventStatus,
	EnrollmentPolicy,
	Visibility,
} from "./graphql/events";
import {
	CANCEL_EVENT,
	CLOSE_EVENT,
	CREATE_EVENT,
	GET_EVENT,
	LAUNCH_EVENT,
	LIST_EVENTS,
	UPDATE_EVENT,
} from "./graphql/events";
import { MANAGE_ROLE_NAMES } from "./graphql/workspace";
import { client } from "./apollo-client";

/**
 * E-11 #127 活动数据源（唯一真实路径 = GraphQL，同 workspaces.ts 纪律）。
 *
 * - fetchWorkspaceEvents：成员读本工作台全部活动（含 draft/closed）；
 * - createEvent / updateEvent / launchEvent / closeEvent / cancelEvent：
 *   Owner/Admin 管理动作（后端 policy 兜底）；
 * - 状态机前置守卫在页面前端做乐观判定，后端返回 errors 时以 error 态呈现。
 */

/** 管理角色判定（列表/详情/新建三页共用；后端 policy 兜底） */
export function canManageEvents(roleNames: string[] = []): boolean {
	return roleNames.some((r) => (MANAGE_ROLE_NAMES as readonly string[]).includes(r));
}

/** 截止时间展示（中文本地化；null/非法值 → 不设截止） */
export function formatDeadline(deadline: string | null): string {
	if (!deadline) return "不设截止";
	const d = new Date(deadline);
	if (Number.isNaN(d.getTime())) return "不设截止";
	return d.toLocaleString("zh-CN", {
		year: "numeric",
		month: "2-digit",
		day: "2-digit",
		hour: "2-digit",
		minute: "2-digit",
	});
}

export type EventDraftInput = {
	title: string;
	enrollmentPolicy: EnrollmentPolicy;
	visibility: Visibility;
	capacity?: number | null;
	registrationDeadline?: string | null;
};

export type EventUpdateInput = {
	title?: string;
	enrollmentPolicy?: EnrollmentPolicy;
	visibility?: Visibility;
	capacity?: number | null;
	registrationDeadline?: string | null;
};

/** 状态机动作（列表/详情页按钮） */
export type EventTransition = "launch" | "close" | "cancel";

/** 后端状态机允许的动作（乐观前置守卫；后端仍会复验） */
export function allowedTransitions(status: EventStatus): EventTransition[] {
	switch (status) {
		case "draft":
			return ["launch", "cancel"];
		case "open":
			return ["close", "cancel"];
		default:
			return [];
	}
}

export async function fetchWorkspaceEvents(workspaceId: string): Promise<EventItem[]> {
	const { data } = await client.query({
		query: LIST_EVENTS,
		variables: { workspaceId },
	});

	return data?.listEvents ?? [];
}

export async function fetchEvent(id: string): Promise<EventItem | null> {
	const { data } = await client.query({ query: GET_EVENT, variables: { id } });
	return data?.getEvent ?? null;
}

export async function createEvent(
	workspaceId: string,
	input: EventDraftInput,
): Promise<EventMutationResult> {
	const { data } = await client.mutate({
		mutation: CREATE_EVENT,
		variables: {
			input: {
				workspaceId,
				title: input.title,
				enrollmentPolicy: input.enrollmentPolicy,
				visibility: input.visibility,
				capacity: input.capacity ?? null,
				registrationDeadline: input.registrationDeadline ?? null,
			},
		},
	});

	return data?.createEvent ?? { result: null, errors: [{ message: "无响应" }] };
}

export async function updateEvent(
	id: string,
	input: EventUpdateInput,
): Promise<EventMutationResult> {
	const { data } = await client.mutate({
		mutation: UPDATE_EVENT,
		variables: { id, input },
	});

	return data?.updateEvent ?? { result: null, errors: [{ message: "无响应" }] };
}

export async function transitionEvent(
	id: string,
	transition: EventTransition,
): Promise<EventMutationResult> {
	const mutation =
		transition === "launch"
			? LAUNCH_EVENT
			: transition === "close"
				? CLOSE_EVENT
				: CANCEL_EVENT;

	const { data } = await client.mutate({ mutation, variables: { id } });

	// data 类型为三个 mutation 结果对象的并集；按 transition 收窄后索引
	const result = data as unknown as Record<
		"launchEvent" | "closeEvent" | "cancelEvent",
		EventMutationResult
	>;

	const field =
		transition === "launch"
			? "launchEvent"
			: transition === "close"
				? "closeEvent"
				: "cancelEvent";

	return result[field] ?? { result: null, errors: [{ message: "无响应" }] };
}
