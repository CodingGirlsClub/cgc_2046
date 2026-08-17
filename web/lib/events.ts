import type {
	EnrollmentPolicy,
	OfferingItem,
	OfferingKind,
	OfferingMutationResult,
	EventStatus,
	Visibility,
} from "./graphql/events";
import {
	CANCEL_COURSE,
	CANCEL_EVENT,
	CLOSE_COURSE,
	CLOSE_EVENT,
	CREATE_COURSE,
	CREATE_EVENT,
	GET_COURSE,
	GET_EVENT,
	LAUNCH_COURSE,
	LAUNCH_EVENT,
	LIST_COURSES,
	LIST_COURSE_ENROLLMENTS,
	LIST_EVENTS,
	LIST_EVENT_ENROLLMENTS,
	MY_COURSE_ENROLLMENT,
	MY_EVENT_ENROLLMENT,
	UPDATE_COURSE,
	UPDATE_EVENT,
} from "./graphql/events";
import { MANAGE_ROLE_NAMES } from "./graphql/workspace";
import { client } from "./apollo-client";

/**
 * E-11 #127 活动/课程数据源（唯一真实路径 = GraphQL，同 workspaces.ts 纪律）。
 *
 * - fetchWorkspaceOfferings：成员读本工作台非 draft 活动/课程；Owner/Admin 含 draft；
 * - create/update/transition：Owner/Admin 管理动作（后端 policy 兜底）；
 * - 状态机前置守卫在页面前端做乐观判定，后端返回 errors 时以 error 态呈现。
 */

/** 管理角色判定（列表/详情/新建页共用；后端 policy 兜底） */
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

export type OfferingDraftInput = {
	title: string;
	enrollmentPolicy: EnrollmentPolicy;
	visibility: Visibility;
	capacity?: number | null;
	registrationDeadline?: string | null;
};

export type OfferingUpdateInput = {
	title?: string;
	enrollmentPolicy?: EnrollmentPolicy;
	visibility?: Visibility;
	capacity?: number | null;
	registrationDeadline?: string | null;
	/** 赞助档位配置（每项 JSON.stringify 后作为 JsonString 提交；E-3 #48，仅 event） */
	sponsorshipTiers?: string[];
	/** 是否收费（U2-R1 定价面；收费报名须选档并完成支付，R4） */
	pricingEnabled?: boolean;
	/** 价格档位配置（每项 JSON.stringify 后作为 JsonString 提交；PriceTier 形状） */
	priceTiers?: string[];
};

/** 状态机动作（详情页按钮） */
export type EventTransition = "launch" | "close" | "cancel";

/** 后端状态机允许的动作（乐观前置守卫；后端仍会复验）。draft 仅 launch（后端
 * 只允许 open→cancel，draft 取消走删除语义 v1 不提供）。 */
export function allowedTransitions(status: EventStatus): EventTransition[] {
	switch (status) {
		case "draft":
			return ["launch"];
		case "open":
			return ["close", "cancel"];
		default:
			return [];
	}
}

const QUERY_BY_KIND = {
	event: { list: LIST_EVENTS, get: GET_EVENT },
	course: { list: LIST_COURSES, get: GET_COURSE },
};

export async function fetchWorkspaceOfferings(
	workspaceId: string,
	kind: OfferingKind,
): Promise<OfferingItem[]> {
	const query = QUERY_BY_KIND[kind].list;

	const { data } = await client.query({
		query,
		variables: { workspaceId },
	});

	const result = data as unknown as Record<
		"listEvents" | "listCourses",
		{ results: OfferingItem[] }
	>;

	return result[kind === "event" ? "listEvents" : "listCourses"]?.results ?? [];
}

export async function fetchOffering(
	id: string,
	kind: OfferingKind,
): Promise<OfferingItem | null> {
	const query = QUERY_BY_KIND[kind].get;
	const { data } = await client.query({ query, variables: { id } });

	const result = data as unknown as Record<"getEvent" | "getCourse", OfferingItem>;
	return result[kind === "event" ? "getEvent" : "getCourse"] ?? null;
}

const MUTATION_BY_KIND = {
	event: {
		create: CREATE_EVENT,
		update: UPDATE_EVENT,
		launch: LAUNCH_EVENT,
		close: CLOSE_EVENT,
		cancel: CANCEL_EVENT,
	},
	course: {
		create: CREATE_COURSE,
		update: UPDATE_COURSE,
		launch: LAUNCH_COURSE,
		close: CLOSE_COURSE,
		cancel: CANCEL_COURSE,
	},
};

const MUTATION_FIELDS: Record<OfferingKind, Record<"create" | "update" | EventTransition, string>> = {
	event: {
		create: "createEvent",
		update: "updateEvent",
		launch: "launchEvent",
		close: "closeEvent",
		cancel: "cancelEvent",
	},
	course: {
		create: "createCourse",
		update: "updateCourse",
		launch: "launchCourse",
		close: "closeCourse",
		cancel: "cancelCourse",
	},
};

export async function createOffering(
	workspaceId: string,
	kind: OfferingKind,
	input: OfferingDraftInput,
): Promise<OfferingMutationResult> {
	const { data } = await client.mutate({
		mutation: MUTATION_BY_KIND[kind].create,
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

	const result = data as unknown as Record<string, OfferingMutationResult>;
	return (
		result[MUTATION_FIELDS[kind].create] ?? { result: null, errors: [{ message: "无响应" }] }
	);
}

export async function updateOffering(
	id: string,
	kind: OfferingKind,
	input: OfferingUpdateInput,
): Promise<OfferingMutationResult> {
	const { data } = await client.mutate({
		mutation: MUTATION_BY_KIND[kind].update,
		variables: { id, input },
	});

	const result = data as unknown as Record<string, OfferingMutationResult>;
	return (
		result[MUTATION_FIELDS[kind].update] ?? { result: null, errors: [{ message: "无响应" }] }
	);
}

export async function transitionOffering(
	id: string,
	kind: OfferingKind,
	transition: EventTransition,
): Promise<OfferingMutationResult> {
	const { data } = await client.mutate({
		mutation: MUTATION_BY_KIND[kind][transition],
		variables: { id },
	});

	const result = data as unknown as Record<string, OfferingMutationResult>;
	return (
		result[MUTATION_FIELDS[kind][transition]] ??
		{ result: null, errors: [{ message: "无响应" }] }
	);
}

/** pending 报名数（request 策略待审批；详情页报名数据视图） */
export async function fetchPendingCount(id: string, kind: OfferingKind): Promise<number> {
	if (kind === "event") {
		const { data } = await client.query({
			query: LIST_EVENT_ENROLLMENTS,
			variables: { eventId: id },
		});
		return data?.enrollments?.count ?? 0;
	}

	const { data } = await client.query({
		query: LIST_COURSE_ENROLLMENTS,
		variables: { courseId: id },
	});
	return data?.enrollments?.count ?? 0;
}

/**
 * 当前用户对目标活动/课程是否有活跃报名（E-5 #50 G3 工作台详情页报名入口防重；
 * e2e #2：查询带活跃态过滤 status in [pending, payment_pending, confirmed]，
 * cancelled/expired/rejected 终态行不算「已报名」，取消后可再报名）。
 * 读策略仅本人可见 → 返回即已报名；查询失败返回 false（入口不显示，不误报已报名）。
 */
export async function fetchMyEnrollment(
	id: string,
	kind: OfferingKind,
	userId: string,
): Promise<boolean> {
	if (kind === "event") {
		const { data } = await client.query({
			query: MY_EVENT_ENROLLMENT,
			variables: { eventId: id, userId },
		});
		return (data?.enrollments?.results?.length ?? 0) > 0;
	}

	const { data } = await client.query({
		query: MY_COURSE_ENROLLMENT,
		variables: { courseId: id, userId },
	});
	return (data?.enrollments?.results?.length ?? 0) > 0;
}
