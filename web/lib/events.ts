import type {
	EnrollmentPolicy,
	OfferingItem,
	OfferingKind,
	OfferingMutationResult,
	EventStatus,
	VenueInfo,
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
import { client } from "./apollo-client";

/**
 * E-11 #127 活动/课程数据源（唯一真实路径 = GraphQL，同 workspaces.ts 纪律）。
 *
 * - fetchWorkspaceOfferings：成员读本工作台非 draft 活动/课程；Owner/Admin 含 draft；
 * - create/update/transition：Owner/Admin 管理动作（后端 policy 兜底）；
 * - 状态机前置守卫在页面前端做乐观判定，后端返回 errors 时以 error 态呈现。
 */

/** 内容管理能力判定（列表/详情/新建/定价/赞助页共用；#215 manage_events，后端 policy 兜底） */
export function canManageEvents(myAbilities: string[] = []): boolean {
	return myAbilities.includes("manage_events");
}

/**
 * 截止时间展示（null/非法值 → undecidedLabel，由调用方传翻译文案）。
 * 日期格式随 locale 由 toLocaleString 派生（F7）：locale 缺省 zh-CN，
 * 公开面调用点传 next-intl useLocale() 结果，/en 页面不再输出 zh-CN 形状。
 */
export function formatDeadline(
	deadline: string | null,
	undecidedLabel: string,
	locale?: string,
): string {
	if (!deadline) return undecidedLabel;
	const d = new Date(deadline);
	if (Number.isNaN(d.getTime())) return undecidedLabel;
	return d.toLocaleString(locale ?? "zh-CN", {
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
	/** 开始时间（UTC ISO；null = 未定；R1，course 语义为开课/结课） */
	startsAt?: string | null;
	/** 结束时间（UTC ISO；须晚于 startsAt，KTD6 后端复验；null = 未定） */
	endsAt?: string | null;
	/** 结构化 venue 四键草稿（仅 event；全空/null → 提交 null；缺键由表单 all-or-none 拦截，不下发） */
	venue?: VenueInfo | null;
	/** 收费开关（U6/R1）：undefined = 免费路径不下发键；true 时 priceTiers 必随行 */
	pricingEnabled?: boolean;
	/** 档位 JsonString 数组（caller-serializes） */
	priceTiers?: string[];
};

export type OfferingUpdateInput = {
	title?: string;
	enrollmentPolicy?: EnrollmentPolicy;
	visibility?: Visibility;
	capacity?: number | null;
	registrationDeadline?: string | null;
	/** 开始时间（UTC ISO；null = 清除/未定；未传 = 不落键保留既有值） */
	startsAt?: string | null;
	/** 结束时间（UTC ISO；同 startsAt 语义） */
	endsAt?: string | null;
	/** 结构化 venue 四键草稿（仅 event；全空/null → 清除；未传 = 不落键保留既有值） */
	venue?: VenueInfo | null;
	/** 赞助档位配置（每项 JSON.stringify 后作为 JsonString 提交；E-3 #48，仅 event） */
	sponsorshipTiers?: string[];
	/** 是否收费（U2-R1 定价面；收费报名须选档并完成支付，R4） */
	pricingEnabled?: boolean;
	/** 价格档位配置（每项 JSON.stringify 后作为 JsonString 提交；PriceTier 形状） */
	priceTiers?: string[];
};

/**
 * venue 四键草稿 → JsonString（KTD5 形状校验后端兜底）；
 * null/全空（trim 后）→ null。all-or-none 缺键拦截在表单层（不下发）。
 */
function venueDraftToJson(venue: VenueInfo | null | undefined): string | null {
	if (!venue) return null;
	const v = {
		country: venue.country.trim(),
		province: venue.province.trim(),
		city: venue.city.trim(),
		district: venue.district.trim(),
	};
	if (Object.values(v).every((s) => s === "")) return null;
	return JSON.stringify(v);
}

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
				startsAt: input.startsAt ?? null,
				endsAt: input.endsAt ?? null,
				// venue 仅 event 有槽（CreateCourseInput 无此字段，下发即 GraphQL 校验错误）
				...(kind === "event" ? { venue: venueDraftToJson(input.venue) } : {}),
				// 定价随创建透传（U6/R1）：调用方仅在开启收费时落键，免费路径不下发
				...(input.pricingEnabled !== undefined
					? {
							pricingEnabled: input.pricingEnabled,
							priceTiers: input.priceTiers ?? [],
						}
					: {}),
			},
		},
	});

	const result = data as unknown as Record<string, OfferingMutationResult>;
	return (
		result[MUTATION_FIELDS[kind].create] ?? { result: null, errors: [{ message: "errors.noResponse" }] }
	);
}

export async function updateOffering(
	id: string,
	kind: OfferingKind,
	input: OfferingUpdateInput,
): Promise<OfferingMutationResult> {
	const { venue, ...rest } = input;
	const { data } = await client.mutate({
		mutation: MUTATION_BY_KIND[kind].update,
		variables: {
			id,
			input: {
				...rest,
				// venue 草稿 → JsonString（全空 → null 清除）；未传不落键保留既有值；
				// course 无 venue 槽，误传剥离不下发
				...(venue !== undefined && kind === "event"
					? { venue: venueDraftToJson(venue) }
					: {}),
			},
		},
	});

	const result = data as unknown as Record<string, OfferingMutationResult>;
	return (
		result[MUTATION_FIELDS[kind].update] ?? { result: null, errors: [{ message: "errors.noResponse" }] }
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
		{ result: null, errors: [{ message: "errors.noResponse" }] }
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
 *
 * 返回活跃报名行（id + status，供 payment_pending 分叉「待支付」卡片与
 * confirmed「已报名」）；无活跃报名 → null；查询失败返回 null（入口不显示，
 * 不误报已报名）。
 */
export async function fetchMyEnrollment(
	id: string,
	kind: OfferingKind,
	userId: string,
): Promise<{ id: string; status: string } | null> {
	if (kind === "event") {
		const { data } = await client.query({
			query: MY_EVENT_ENROLLMENT,
			variables: { eventId: id, userId },
		});
		return data?.enrollments?.results?.[0] ?? null;
	}

	const { data } = await client.query({
		query: MY_COURSE_ENROLLMENT,
		variables: { courseId: id, userId },
	});
	return data?.enrollments?.results?.[0] ?? null;
}
