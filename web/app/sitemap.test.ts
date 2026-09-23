import { afterEach, describe, expect, it, vi } from "vitest";
import sitemap from "./sitemap";

/** 静态公开路由数（sitemap.ts STATIC_PATHS）——新增公开页时同步 */
const STATIC_COUNT = 10;

/**
 * sitemap 现在分两条独立查询（供给物一条、Initiative 一条，见 sitemap.ts 注释：
 * `publicInitiatives` 是 non_null 根字段，并进一条会让一坏全坏）。桩按请求体里
 * 的 operation 名分派，才能分别构造「只有一条上游坏」的场景。
 */
function stubFetch(byQuery: Record<string, unknown>, fallback: unknown = { data: {} }) {
	const calls: string[] = [];
	const impl = vi.fn(async (_url: string, init?: { body?: string }) => {
		const body = init?.body ?? "{}";
		const name = /query\s+(\w+)/.exec(body)?.[1] ?? "";
		calls.push(name);
		const hit = byQuery[name];
		if (hit instanceof Error) throw hit;
		if (hit === undefined) return { ok: true, json: async () => fallback };
		if (typeof hit === "object" && hit !== null && "status" in hit) {
			return { ok: false, status: (hit as { status: number }).status, json: async () => ({}) };
		}
		return { ok: true, json: async () => hit };
	});
	vi.stubGlobal("fetch", impl);
	return calls;
}

const OFFERINGS_OK = {
	data: {
		listEvents: { results: [{ slug: "ai-camp" }, { slug: null }] },
		listCourses: { results: [{ slug: "intro-web" }] },
	},
};

const INITIATIVES_OK = {
	data: {
		publicInitiatives: [
			{ slug: "hackerstart1024", status: "open" },
			{ slug: "archived-campaign", status: "closed" },
			{ slug: null, status: "open" },
		],
	},
};

afterEach(() => {
	vi.unstubAllGlobals();
	vi.unstubAllEnvs();
});

describe("sitemap", () => {
	it("后端可达时静态 + 动态条目齐全，每条带 zh/en alternates", async () => {
		vi.stubEnv("NEXT_PUBLIC_WEB_BASE_URL", "https://codingirlsclub.com");
		const calls = stubFetch({
			SitemapPublicSlugs: OFFERINGS_OK,
			SitemapPublicInitiativeSlugs: INITIATIVES_OK,
		});

		const entries = await sitemap();

		expect(calls.sort()).toEqual(["SitemapPublicInitiativeSlugs", "SitemapPublicSlugs"]);

		// null slug / closed initiative 被过滤：8 静态 + 1 event + 1 course + 1 initiative
		expect(entries).toHaveLength(STATIC_COUNT + 3);
		const eventEntry = entries.find(
			(e) => e.url === "https://codingirlsclub.com/events/ai-camp",
		);
		expect(eventEntry?.alternates?.languages).toEqual({
			"zh-CN": "https://codingirlsclub.com/events/ai-camp",
			en: "https://codingirlsclub.com/en/events/ai-camp",
		});
		expect(
			entries.some((e) => e.url === "https://codingirlsclub.com/courses/intro-web"),
		).toBe(true);

		// 公开 Initiative 详情页与 /events/[slug] 同口径进索引；closed 留档页不进
		const initiativeEntry = entries.find(
			(e) => e.url === "https://codingirlsclub.com/initiatives/hackerstart1024",
		);
		expect(initiativeEntry?.alternates?.languages).toEqual({
			"zh-CN": "https://codingirlsclub.com/initiatives/hackerstart1024",
			en: "https://codingirlsclub.com/en/initiatives/hackerstart1024",
		});
		expect(
			entries.some((e) => e.url.includes("archived-campaign")),
		).toBe(false);

		// /initiatives 登记钉（code-review 缺口：防同计数的路径笔误静默通过）
		const initiativesEntry = entries.find(
			(e) => e.url === "https://codingirlsclub.com/initiatives",
		);
		expect(initiativesEntry?.alternates?.languages).toEqual({
			"zh-CN": "https://codingirlsclub.com/initiatives",
			en: "https://codingirlsclub.com/en/initiatives",
		});

		// campaign 宣传页登记钉（U6）：静态条目 + 双语言 alternates 一并进索引
		const campaignEntry = entries.find(
			(e) => e.url === "https://codingirlsclub.com/hackerstart-1024",
		);
		expect(campaignEntry?.alternates?.languages).toEqual({
			"zh-CN": "https://codingirlsclub.com/hackerstart-1024",
			en: "https://codingirlsclub.com/en/hackerstart-1024",
		});
	});

	it("后端不可达时降级为纯静态条目，不抛错", async () => {
		vi.stubEnv("NEXT_PUBLIC_WEB_BASE_URL", "https://codingirlsclub.com");
		stubFetch({
			SitemapPublicSlugs: new Error("ECONNREFUSED"),
			SitemapPublicInitiativeSlugs: new Error("ECONNREFUSED"),
		});

		const entries = await sitemap();

		expect(entries).toHaveLength(STATIC_COUNT);
		expect(entries[0]?.url).toBe("https://codingirlsclub.com/");
	});

	it("上游非 200 同样降级为静态条目", async () => {
		vi.stubEnv("NEXT_PUBLIC_WEB_BASE_URL", "https://codingirlsclub.com");
		stubFetch({
			SitemapPublicSlugs: { status: 502 },
			SitemapPublicInitiativeSlugs: { status: 502 },
		});

		const entries = await sitemap();

		expect(entries).toHaveLength(STATIC_COUNT);
	});

	// 非空根字段（publicInitiatives）报错时 Absinthe 把整个 data 置 null 且 HTTP 仍 200：
	// 若两条查询合并，events/courses 会一起静默消失，catch 也永不触发。
	it("Initiative 查询单独坏掉时，events/courses 条目不丢", async () => {
		vi.stubEnv("NEXT_PUBLIC_WEB_BASE_URL", "https://codingirlsclub.com");
		stubFetch({
			SitemapPublicSlugs: OFFERINGS_OK,
			// data: null = 非空根字段报错的真实响应形状（HTTP 200）
			SitemapPublicInitiativeSlugs: { data: null },
		});

		const entries = await sitemap();

		expect(entries).toHaveLength(STATIC_COUNT + 2);
		expect(
			entries.some((e) => e.url === "https://codingirlsclub.com/events/ai-camp"),
		).toBe(true);
		expect(
			entries.some((e) => e.url === "https://codingirlsclub.com/courses/intro-web"),
		).toBe(true);
		expect(entries.some((e) => e.url.includes("/initiatives/hacker"))).toBe(false);
	});

	it("供给物查询单独坏掉时，Initiative 条目不丢", async () => {
		vi.stubEnv("NEXT_PUBLIC_WEB_BASE_URL", "https://codingirlsclub.com");
		stubFetch({
			SitemapPublicSlugs: { data: null },
			SitemapPublicInitiativeSlugs: INITIATIVES_OK,
		});

		const entries = await sitemap();

		expect(entries).toHaveLength(STATIC_COUNT + 1);
		expect(
			entries.some(
				(e) => e.url === "https://codingirlsclub.com/initiatives/hackerstart1024",
			),
		).toBe(true);
	});
});
