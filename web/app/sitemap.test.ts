import { afterEach, describe, expect, it, vi } from "vitest";
import sitemap from "./sitemap";

/** 静态公开路由数（sitemap.ts STATIC_PATHS）——新增公开页时同步 */
const STATIC_COUNT = 7;

function stubFetchOk(body: unknown) {
	vi.stubGlobal(
		"fetch",
		vi.fn(async () => ({
			ok: true,
			json: async () => body,
		})),
	);
}

afterEach(() => {
	vi.unstubAllGlobals();
	vi.unstubAllEnvs();
});

describe("sitemap", () => {
	it("后端可达时静态 + 动态条目齐全，每条带 zh/en alternates", async () => {
		vi.stubEnv("NEXT_PUBLIC_WEB_BASE_URL", "https://codingirlsclub.com");
		stubFetchOk({
			data: {
				listEvents: { results: [{ slug: "ai-camp" }, { slug: null }] },
				listCourses: { results: [{ slug: "intro-web" }] },
			},
		});

		const entries = await sitemap();

		// null slug 被过滤：7 静态 + 1 event + 1 course
		expect(entries).toHaveLength(STATIC_COUNT + 2);
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
	});

	it("后端不可达时降级为纯静态条目，不抛错", async () => {
		vi.stubEnv("NEXT_PUBLIC_WEB_BASE_URL", "https://codingirlsclub.com");
		vi.stubGlobal(
			"fetch",
			vi.fn(async () => {
				throw new Error("ECONNREFUSED");
			}),
		);

		const entries = await sitemap();

		expect(entries).toHaveLength(STATIC_COUNT);
		expect(entries[0]?.url).toBe("https://codingirlsclub.com/");
	});

	it("上游非 200 同样降级为静态条目", async () => {
		vi.stubEnv("NEXT_PUBLIC_WEB_BASE_URL", "https://codingirlsclub.com");
		vi.stubGlobal(
			"fetch",
			vi.fn(async () => ({ ok: false, status: 502, json: async () => ({}) })),
		);

		const entries = await sitemap();

		expect(entries).toHaveLength(STATIC_COUNT);
	});
});
