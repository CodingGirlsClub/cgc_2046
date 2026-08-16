import type { OfferingKind, PublicOfferingItem } from "./graphql/events";
import {
	CREATE_ENROLLMENT,
	PUBLIC_GET_COURSE,
	PUBLIC_GET_EVENT,
	PUBLIC_LIST_COURSES,
	PUBLIC_LIST_EVENTS,
	type EnrollmentSubmissionResult,
} from "./graphql/events";
import type { SponsorshipTierConfig } from "./graphql/sponsorship";
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
	slug: string,
	kind: OfferingKind,
): Promise<PublicOfferingItem | null> {
	const query = kind === "event" ? PUBLIC_GET_EVENT : PUBLIC_GET_COURSE;
	const { data } = await client.query({ query, variables: { slug } });

	const result = data as unknown as Record<
		"getEventBySlug" | "getCourseBySlug",
		PublicOfferingItem | null
	>;

	return result[kind === "event" ? "getEventBySlug" : "getCourseBySlug"] ?? null;
}

export async function submitEnrollment(input: {
	eventId?: string;
	courseId?: string;
	userId: string;
	inviteCode?: string | null;
	/** 收费目标必选档（R5：报名选档 → 占位 → payment_pending） */
	tierId?: string | null;
}): Promise<EnrollmentSubmissionResult> {
	const { data } = await client.mutate({
		mutation: CREATE_ENROLLMENT,
		variables: { input },
	});

	return (
		data?.createEnrollment ?? { result: null, errors: [{ message: "无响应" }] }
	);
}

/**
 * E-3 #48：sponsorshipTiers 是 JsonString 数组（每项 JSON 编码字符串），
 * 逐项 JSON.parse 为 SponsorshipTierConfig；解析失败/结构非法项静默丢弃
 * （展示层不假定结构，同 workflows.ts parseJsonString 纪律）。
 */
export function parseSponsorshipTiers(
	raw: string[] | null | undefined,
): SponsorshipTierConfig[] {
	if (!Array.isArray(raw)) return [];

	return raw.flatMap((item) => {
		try {
			const tier: unknown = JSON.parse(item);
			if (
				typeof tier === "object" &&
				tier !== null &&
				typeof (tier as Record<string, unknown>).id === "string" &&
				typeof (tier as Record<string, unknown>).name === "string" &&
				Array.isArray((tier as Record<string, unknown>).benefits)
			) {
				const t = tier as {
					id: string;
					name: string;
					// 后端档位 json 为 snake_case 键（见 sponsorship_tier.ex）
					amount_suggestion?: number | null;
					benefits: string[];
					exclusive?: boolean;
				};
				return [
					{
						id: t.id,
						name: t.name,
						amountSuggestion: t.amount_suggestion ?? null,
						benefits: t.benefits.filter((b): b is string => typeof b === "string"),
						exclusive: t.exclusive === true,
					},
				];
			}
			return [];
		} catch {
			return [];
		}
	});
}
