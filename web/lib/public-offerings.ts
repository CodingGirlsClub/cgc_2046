import type { OfferingKind, PublicOfferingItem } from "./graphql/events";
import type { VenueInfo } from "./graphql/events";
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
 * - submitEnrollment：登录后报名（后端 policy 校验 user_id == actor）；
 * - 公开读一律 network-only（F4）：badge 由后端逐次派生，cache-first 会让
 *   报名失败后的重拉吃缓存旧 badge（U4 重派生失效）；公开面量级小，代价可忽略。
 */

export async function fetchPublicOfferings(
	kind: OfferingKind,
): Promise<PublicOfferingItem[]> {
	const query = kind === "event" ? PUBLIC_LIST_EVENTS : PUBLIC_LIST_COURSES;
	const { data } = await client.query({ query, fetchPolicy: "network-only" });

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
	const { data } = await client.query({
		query,
		variables: { slug },
		fetchPolicy: "network-only",
	});

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
		data?.createEnrollment ?? { result: null, errors: [{ message: "errors.noResponse" }] }
	);
}

/**
 * 保存路径序列化：产出后端白名单的 snake_case 键（SponsorshipTiersValidation
 * 只认 amount_suggestion 等；JSON.stringify 裸 SponsorshipTierConfig 会产出
 * camelCase 键被拒——0e35a51 起两端错配）。与下方 parseSponsorshipTiers 对偶。
 */
export function serializeSponsorshipTier(tier: SponsorshipTierConfig): string {
	return JSON.stringify({
		id: tier.id,
		name: tier.name,
		amount_suggestion: tier.amountSuggestion,
		benefits: tier.benefits,
		exclusive: tier.exclusive,
	});
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

/**
 * venue JsonString → VenueInfo（R3；恰四键 country/province/city/district）。
 * 解析失败/结构非法 → null，展示层兜底「地点待定」（不出现空白/报错）。
 * 仅 event 有 venue 槽；course 无位置概念，查询本身不取 venue。
 */
export function parseVenue(raw: string | null | undefined): VenueInfo | null {
	if (!raw) return null;
	try {
		const v: unknown = JSON.parse(raw);
		if (typeof v !== "object" || v === null) return null;
		const r = v as Record<string, unknown>;
		if (
			typeof r.country === "string" &&
			typeof r.province === "string" &&
			typeof r.city === "string" &&
			typeof r.district === "string"
		) {
			return {
				country: r.country,
				province: r.province,
				city: r.city,
				district: r.district,
			};
		}
		return null;
	} catch {
		return null;
	}
}

/** VenueInfo → 单行展示（空段及相邻重复行政区跳过；全空/null → null，R3） */
export function formatVenue(venue: VenueInfo | null): string | null {
	if (!venue) return null;
	const parts = [venue.country, venue.province, venue.city, venue.district]
		.map((part) => part.trim())
		.filter((part, index, all) => part !== "" && part !== all[index - 1]);
	return parts.length > 0 ? parts.join(" ") : null;
}
