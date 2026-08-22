import type { MetadataRoute } from "next";
import { localizedUrl } from "@/lib/seo";

/**
 * /sitemap.xml（#239）：公开可索引面单源清单，与各页 pageAlternates 同口径
 * （zh-CN 无前缀 / en 前缀，D3）。proxy matcher 排除带点号路径，不经 next-intl。
 *
 * 动态条目走后端匿名白名单 query（listEvents/listCourses open+public，字段
 * 契约单源见 lib/graphql/events.ts PUBLIC_LIST_*）；后端不可达/响应异常时降级
 * 为纯静态条目——sitemap 必须恒 200，不因后端故障 500。
 */

// 每请求现取：动态条目要新鲜，且 build 期后端不可达时不把空结果焊死进产物
export const dynamic = "force-dynamic";

const STATIC_PATHS: ReadonlyArray<{
	path: string;
	changeFrequency: NonNullable<
		MetadataRoute.Sitemap[number]["changeFrequency"]
	>;
	priority: number;
}> = [
	{ path: "/", changeFrequency: "weekly", priority: 1 },
	{ path: "/events", changeFrequency: "daily", priority: 0.8 },
	{ path: "/courses", changeFrequency: "daily", priority: 0.8 },
	{ path: "/login", changeFrequency: "monthly", priority: 0.3 },
	{ path: "/register", changeFrequency: "monthly", priority: 0.3 },
	{ path: "/privacy", changeFrequency: "yearly", priority: 0.2 },
	{ path: "/terms", changeFrequency: "yearly", priority: 0.2 },
];

function entry(
	path: string,
	changeFrequency: NonNullable<MetadataRoute.Sitemap[number]["changeFrequency"]>,
	priority: number,
): MetadataRoute.Sitemap[number] {
	return {
		url: localizedUrl(path, "zh-CN"),
		changeFrequency,
		priority,
		alternates: {
			languages: {
				"zh-CN": localizedUrl(path, "zh-CN"),
				en: localizedUrl(path, "en"),
			},
		},
	};
}

// 只取 slug 的精简版；filter 与 PUBLIC_LIST_*（lib/graphql/events.ts）保持一致
const PUBLIC_SLUGS_QUERY = `
	query SitemapPublicSlugs {
		listEvents(filter: { status: { eq: "open" }, visibility: { eq: "public" } }) {
			results { slug }
		}
		listCourses(filter: { status: { eq: "open" }, visibility: { eq: "public" } }) {
			results { slug }
		}
	}
`;

type SlugResults = { results?: Array<{ slug?: string | null }> | null } | null;

function extractSlugs(node: SlugResults): string[] {
	return (node?.results ?? [])
		.map((r) => r?.slug)
		.filter((s): s is string => typeof s === "string" && s.length > 0);
}

async function fetchPublicSlugs(): Promise<{
	events: string[];
	courses: string[];
}> {
	// server 运行时直连后端（与 next.config.ts rewrites 同源 env）
	const backend = process.env.BACKEND_URL?.trim() || "http://localhost:4000";
	const res = await fetch(`${backend}/api/graphql`, {
		method: "POST",
		headers: { "content-type": "application/json" },
		body: JSON.stringify({ query: PUBLIC_SLUGS_QUERY }),
		signal: AbortSignal.timeout(5000),
	});
	if (!res.ok) throw new Error(`sitemap graphql upstream ${res.status}`);
	const json = (await res.json()) as {
		data?: { listEvents?: SlugResults; listCourses?: SlugResults };
	};
	return {
		events: extractSlugs(json.data?.listEvents ?? null),
		courses: extractSlugs(json.data?.listCourses ?? null),
	};
}

export default async function sitemap(): Promise<MetadataRoute.Sitemap> {
	const staticEntries = STATIC_PATHS.map(({ path, changeFrequency, priority }) =>
		entry(path, changeFrequency, priority),
	);

	try {
		const { events, courses } = await fetchPublicSlugs();
		return [
			...staticEntries,
			...events.map((slug) =>
				entry(`/events/${encodeURIComponent(slug)}`, "weekly", 0.6),
			),
			...courses.map((slug) =>
				entry(`/courses/${encodeURIComponent(slug)}`, "weekly", 0.6),
			),
		];
	} catch {
		return staticEntries;
	}
}
