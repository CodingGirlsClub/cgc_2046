import type { OfferingKind, PublicOfferingItem } from "./graphql/events";
import {
	CREATE_ENROLLMENT,
	PUBLIC_GET_COURSE,
	PUBLIC_GET_EVENT,
	PUBLIC_LIST_COURSES,
	PUBLIC_LIST_EVENTS,
	type EnrollmentSubmissionResult,
} from "./graphql/events";
import { client } from "./apollo-client";

/**
 * E-5 #50 公开面数据源（匿名白名单路径，与 E-11 管理面 events.ts 分离）。
 *
 * - fetchPublicOfferings：匿名读 open+public 全部条目（发现页）；
 * - fetchPublicOffering：匿名按 id 读（宿主页；workspace/非 open 表现 NotFound）；
 * - submitEnrollment：登录后报名（后端 policy 校验 user_id == actor）。
 */

export async function fetchPublicOfferings(
	kind: OfferingKind,
): Promise<PublicOfferingItem[]> {
	const query = kind === "event" ? PUBLIC_LIST_EVENTS : PUBLIC_LIST_COURSES;
	const { data } = await client.query({ query });

	const result = data as unknown as Record<
		"listEvents" | "listCourses",
		{ results: PublicOfferingItem[] }
	>;

	return result[kind === "event" ? "listEvents" : "listCourses"]?.results ?? [];
}

export async function fetchPublicOffering(
	id: string,
	kind: OfferingKind,
): Promise<PublicOfferingItem | null> {
	const query = kind === "event" ? PUBLIC_GET_EVENT : PUBLIC_GET_COURSE;
	const { data } = await client.query({ query, variables: { id } });

	const result = data as unknown as Record<
		"getEvent" | "getCourse",
		PublicOfferingItem | null
	>;

	return result[kind === "event" ? "getEvent" : "getCourse"] ?? null;
}

export async function submitEnrollment(input: {
	eventId?: string;
	courseId?: string;
	userId: string;
	inviteCode?: string | null;
}): Promise<EnrollmentSubmissionResult> {
	const { data } = await client.mutate({
		mutation: CREATE_ENROLLMENT,
		variables: { input },
	});

	return (
		data?.createEnrollment ?? { result: null, errors: [{ message: "无响应" }] }
	);
}
