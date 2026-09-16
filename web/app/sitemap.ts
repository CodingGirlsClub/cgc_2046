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
	{ path: "/initiatives", changeFrequency: "daily", priority: 0.8 },
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

// 只取 slug 的精简版；filter 与 PUBLIC_LIST_*（lib/graphql/events.ts）保持一致。
// first 250 显式声明上限（服务端 default_limit 同款值）；翻页 UI 触发器 = 单工作台 ~200 供给物
const PUBLIC_SLUGS_QUERY = `
	query SitemapPublicSlugs {
		listEvents(first: 250, filter: { status: { eq: "open" }, visibility: { eq: "public" } }) {
			results { slug }
		}
		listCourses(first: 250, filter: { status: { eq: "open" }, visibility: { eq: "public" } }) {
			results { slug }
		}
	}
`;

// publicInitiatives 无 filter 参数（R5：open 先于 closed 全量返回，≤100），故按
// status 在本地筛 open——closed 是留档页，不进 sitemap（与 listEvents 的
// status: open 同口径）。**独立一条请求**：该字段是 non_null 根字段
// （graphql_schema.ex:206，错误走 :208-211），Absinthe 会把非空根字段的错误
// 上抛到 data=null——并进上一条查询会让 events/courses 的 slug 一起静默消失，
// 而 HTTP 仍是 200、下面的 catch 永不触发。
const PUBLIC_INITIATIVE_SLUGS_QUERY = `
	query SitemapPublicInitiativeSlugs {
		publicInitiatives { slug status }
	}
`;

type SlugResults = { results?: Array<{ slug?: string | null }> | null } | null;
type InitiativeSlugResults = Array<{ slug?: string | null; status?: string | null }> | null;

function extractSlugs(node: SlugResults): string[] {
	return (node?.results ?? [])
		.map((r) => r?.slug)
		.filter((s): s is string => typeof s === "string" && s.length > 0);
}

function extractOpenInitiativeSlugs(node: InitiativeSlugResults): string[] {
	return (node ?? [])
		.filter((r) => r?.status === "open")
		.map((r) => r?.slug)
		.filter((s): s is string => typeof s === "string" && s.length > 0);
}

function backendUrl(): string {
	// server 运行时直连后端（与 next.config.ts rewrites 同源 env）
	return process.env.BACKEND_URL?.trim() || "http://localhost:4000";
}

async function querySlugs<T>(query: string, pick: (data: Record<string, unknown>) => T): Promise<T> {
	const res = await fetch(`${backendUrl()}/api/graphql`, {
		method: "POST",
		headers: { "content-type": "application/json" },
		body: JSON.stringify({ query }),
		signal: AbortSignal.timeout(5000),
	});
	if (!res.ok) throw new Error(`sitemap graphql upstream ${res.status}`);
	const json = (await res.json()) as { data?: Record<string, unknown> | null };
	return pick(json.data ?? {});
}

// 每个上游字段各自 try：任一根字段报错（含 non_null 导致 data=null）只丢自己那段，
// 其余照常——sitemap 必须恒 200 且尽量完整。
async function safeQuery<T>(fallback: T, run: () => Promise<T>): Promise<T> {
	try {
		return await run();
	} catch {
		return fallback;
	}
}

export default async function sitemap(): Promise<MetadataRoute.Sitemap> {
	const staticEntries = STATIC_PATHS.map(({ path, changeFrequency, priority }) =>
		entry(path, changeFrequency, priority),
	);

	const [offerings, initiatives] = await Promise.all([
		safeQuery({ events: [] as string[], courses: [] as string[] }, () =>
			querySlugs(PUBLIC_SLUGS_QUERY, (data) => ({
				events: extractSlugs((data.listEvents ?? null) as SlugResults),
				courses: extractSlugs((data.listCourses ?? null) as SlugResults),
			})),
		),
		safeQuery([] as string[], () =>
			querySlugs(PUBLIC_INITIATIVE_SLUGS_QUERY, (data) =>
				extractOpenInitiativeSlugs((data.publicInitiatives ?? null) as InitiativeSlugResults),
			),
		),
	]);

	return [
		...staticEntries,
		...offerings.events.map((slug) =>
			entry(`/events/${encodeURIComponent(slug)}`, "weekly", 0.6),
		),
		...offerings.courses.map((slug) =>
			entry(`/courses/${encodeURIComponent(slug)}`, "weekly", 0.6),
		),
		...initiatives.map((slug) =>
			entry(`/initiatives/${encodeURIComponent(slug)}`, "weekly", 0.6),
		),
	];
}
