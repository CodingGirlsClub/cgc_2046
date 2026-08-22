import { afterEach, describe, expect, it, vi } from "vitest";
import { localizedUrl, pageAlternates, resolveWebBaseUrl } from "./seo";

afterEach(() => {
	vi.unstubAllEnvs();
});

describe("resolveWebBaseUrl", () => {
	it("未设置时兜底 localhost:3000", () => {
		vi.stubEnv("NEXT_PUBLIC_WEB_BASE_URL", "");
		vi.stubEnv("NEXT_PUBLIC_SITE_URL", "");
		expect(resolveWebBaseUrl()).toBe("http://localhost:3000");
	});

	it("空串视同未设置（CI sed 注空防御），回退次级变量", () => {
		vi.stubEnv("NEXT_PUBLIC_WEB_BASE_URL", "   ");
		vi.stubEnv("NEXT_PUBLIC_SITE_URL", "https://site.example");
		expect(resolveWebBaseUrl()).toBe("https://site.example");
	});

	it("剥除尾斜杠，防拼出双斜杠路径", () => {
		vi.stubEnv("NEXT_PUBLIC_WEB_BASE_URL", "https://codingirlsclub.com/");
		expect(resolveWebBaseUrl()).toBe("https://codingirlsclub.com");
	});
});

describe("localizedUrl（D3：zh-CN 无前缀 / en 带 /en 前缀）", () => {
	it("zh-CN 根路径与子路径无前缀", () => {
		vi.stubEnv("NEXT_PUBLIC_WEB_BASE_URL", "https://codingirlsclub.com");
		expect(localizedUrl("/", "zh-CN")).toBe("https://codingirlsclub.com/");
		expect(localizedUrl("/events", "zh-CN")).toBe(
			"https://codingirlsclub.com/events",
		);
	});

	it("en 根路径输出 /en 无尾斜杠，子路径拼 /en 前缀", () => {
		vi.stubEnv("NEXT_PUBLIC_WEB_BASE_URL", "https://codingirlsclub.com");
		expect(localizedUrl("/", "en")).toBe("https://codingirlsclub.com/en");
		expect(localizedUrl("/events/ai-camp", "en")).toBe(
			"https://codingirlsclub.com/en/events/ai-camp",
		);
	});
});

describe("pageAlternates", () => {
	it("canonical 指当前 locale 页，languages 双向互指", () => {
		vi.stubEnv("NEXT_PUBLIC_WEB_BASE_URL", "https://codingirlsclub.com");
		expect(pageAlternates("/courses", "en")).toEqual({
			canonical: "https://codingirlsclub.com/en/courses",
			languages: {
				"zh-CN": "https://codingirlsclub.com/courses",
				en: "https://codingirlsclub.com/en/courses",
			},
		});
		expect(pageAlternates("/courses", "zh-CN")?.canonical).toBe(
			"https://codingirlsclub.com/courses",
		);
	});
});
