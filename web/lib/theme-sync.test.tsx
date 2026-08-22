import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, waitFor, cleanup } from "@testing-library/react";
import { NextIntlClientProvider } from "next-intl";
import { MockedProvider } from "@apollo/client/testing/react";
import { ME_WORKSPACES } from "@/lib/graphql/workspace";
import { WORKSPACE_PROFILE } from "@/lib/graphql/profile";
import ThemeSync from "./theme-sync";

/**
 * ThemeSync 单测（ADR-0004 per-workspace 主题同步）。
 *
 * 核心回归保护：appliedFor ref 按 workspace 记忆，切换 workspace 时重应用服务端主题。
 * 数据链：meWorkspaces(slug→id) → workspaceProfile(workspaceId).uiThemePreference。
 */

const { useAuthed } = vi.hoisted(() => ({
	useAuthed: vi.fn(),
}));

const { useTheme } = vi.hoisted(() => ({
	useTheme: vi.fn(),
}));

vi.mock("@/lib/use-authed", () => ({ useAuthed }));
vi.mock("@/lib/theme-provider", () => ({ useTheme }));

// mock next/navigation usePathname
const pathnameMock = vi.fn(() => "/w/cgc-camp/settings/account/preferences");
vi.mock("next/navigation", () => ({
	usePathname: () => pathnameMock(),
	// @/i18n/navigation（next-intl createNavigation）工厂在 import 期还需要这些导出
	useRouter: () => ({ push: vi.fn(), replace: vi.fn(), prefetch: vi.fn() }),
	useParams: () => ({}),
	redirect: vi.fn(),
	permanentRedirect: vi.fn(),
}));

// i18n usePathname（2026-08-22 换源）需要 intl context；locale 可参数化（EN 用例）
function renderIntl(ui: React.ReactElement, locale: "zh-CN" | "en" = "zh-CN") {
	return render(
		<NextIntlClientProvider locale={locale}>{ui}</NextIntlClientProvider>,
	);
}

// jsdom 不提供 localStorage，用 in-memory 实现
const store = new Map<string, string>();
const localStorageMock: Storage = {
	get length() {
		return store.size;
	},
	clear: () => store.clear(),
	getItem: (key: string) => store.get(key) ?? null,
	key: (index: number) => Array.from(store.keys())[index] ?? null,
	removeItem: (key: string) => void store.delete(key),
	setItem: (key: string, value: string) => void store.set(key, String(value)),
};
Object.defineProperty(window, "localStorage", {
	value: localStorageMock,
	configurable: true,
});

beforeEach(() => {
	vi.clearAllMocks();
	// 每测重置 pathname（EN 回归用例会 mockReturnValue 覆盖，防泄漏到后续用例）
	pathnameMock.mockReturnValue("/w/cgc-camp/settings/account/preferences");
	store.clear();
	useAuthed.mockReturnValue({ authed: true, confirmed: true });
	pathnameMock.mockReturnValue("/w/cgc-camp/settings/account/preferences");
});

/** meWorkspaces mock：slug → id */
function wsMocks(workspaces: Array<{ slug: string; id: string }>) {
	return [
		{
			request: { query: ME_WORKSPACES },
			result: {
				data: {
					meWorkspaces: workspaces.map((w) => ({
						id: w.id,
						slug: w.slug,
						name: w.slug,
						joinPolicy: "open",
						sponsorshipEnabled: true,
						myRoleNames: [],
						myMembershipId: "wm_1",
						canAccess: true,
					})),
				},
			},
		},
	];
}

/** workspaceProfile mock */
function profileMocks(
	workspaceId: string,
	pref: string | null,
): Array<import("@apollo/client/testing").MockedResponse> {
	return [
		{
			request: { query: WORKSPACE_PROFILE, variables: { workspaceId } },
			result: {
				data: {
					workspaceProfile:
						pref == null
							? null
							: {
									id: "wsp_1",
									workspaceId,
									userId: "u1",
									uiThemePreference: pref,
								},
				},
			},
		},
	];
}

describe("ThemeSync（ADR-0004 按 workspace 应用服务端主题）", () => {
	it("首次拿到服务端偏好时应用一次", async () => {
		const setTheme = vi.fn();
		useTheme.mockReturnValue({ setTheme, theme: "dark", toggleTheme: vi.fn() });

		renderIntl(
			<MockedProvider
				mocks={[
					...wsMocks([{ slug: "cgc-camp", id: "ws_1" }]),
					...profileMocks("ws_1", "light"),
				]}
			>
				<ThemeSync />
			</MockedProvider>,
		);

		await waitFor(() => {
			expect(setTheme).toHaveBeenCalledTimes(1);
		});
		expect(setTheme).toHaveBeenCalledWith("light");
	});

	it("EN（/en 前缀路径）同样应用服务端 workspace 偏好（2026-08-22 locale 回归钉测）", async () => {
		const setTheme = vi.fn();
		useTheme.mockReturnValue({ setTheme, theme: "dark", toggleTheme: vi.fn() });
		pathnameMock.mockReturnValue("/en/w/cgc-camp/settings/account/preferences");

		renderIntl(
			<MockedProvider
				mocks={[
					...wsMocks([{ slug: "cgc-camp", id: "ws_1" }]),
					...profileMocks("ws_1", "light"),
				]}
			>
				<ThemeSync />
			</MockedProvider>,
			"en",
		);

		await waitFor(() => {
			expect(setTheme).toHaveBeenCalledTimes(1);
		});
		expect(setTheme).toHaveBeenCalledWith("light");
	});

	it("无效偏好不应用", async () => {
		const setTheme = vi.fn();
		useTheme.mockReturnValue({ setTheme, theme: "dark", toggleTheme: vi.fn() });

		renderIntl(
			<MockedProvider
				mocks={[
					...wsMocks([{ slug: "cgc-camp", id: "ws_1" }]),
					...profileMocks("ws_1", "neon"),
				]}
			>
				<ThemeSync />
			</MockedProvider>,
		);

		await new Promise((resolve) => setTimeout(resolve, 200));
		expect(setTheme).not.toHaveBeenCalled();
	});

	it("?theme= 覆盖时不应用", async () => {
		const originalSearch = window.location.search;
		Object.defineProperty(window, "location", {
			value: { ...window.location, search: "?theme=dark" },
			configurable: true,
		});

		const setTheme = vi.fn();
		useTheme.mockReturnValue({ setTheme, theme: "dark", toggleTheme: vi.fn() });

		renderIntl(
			<MockedProvider
				mocks={[
					...wsMocks([{ slug: "cgc-camp", id: "ws_1" }]),
					...profileMocks("ws_1", "light"),
				]}
			>
				<ThemeSync />
			</MockedProvider>,
		);

		await new Promise((resolve) => setTimeout(resolve, 200));
		expect(setTheme).not.toHaveBeenCalled();

		Object.defineProperty(window, "location", {
			value: { ...window.location, search: originalSearch },
			configurable: true,
		});
	});

	it("切换 workspace 重应用（核心回归保护）", async () => {
		const setTheme = vi.fn();
		useTheme.mockReturnValue({ setTheme, theme: "dark", toggleTheme: vi.fn() });

		// 首次渲染：cgc-camp → ws_1 → light
		renderIntl(
			<MockedProvider
				mocks={[
					...wsMocks([
						{ slug: "cgc-camp", id: "ws_1" },
						{ slug: "cgc-academy", id: "ws_2" },
					]),
					...profileMocks("ws_1", "light"),
				]}
			>
				<ThemeSync />
			</MockedProvider>,
		);

		await waitFor(() => {
			expect(setTheme).toHaveBeenCalledTimes(1);
		});
		expect(setTheme).toHaveBeenCalledWith("light");

		// 切到另一个 workspace：ws_2 → dark，应重新应用
		cleanup();
		vi.clearAllMocks();
		pathnameMock.mockReturnValue("/w/cgc-academy/settings/account/profile");
		useTheme.mockReturnValue({ setTheme, theme: "light", toggleTheme: vi.fn() });

		renderIntl(
			<MockedProvider
				mocks={[
					...wsMocks([
						{ slug: "cgc-camp", id: "ws_1" },
						{ slug: "cgc-academy", id: "ws_2" },
					]),
					...profileMocks("ws_2", "dark"),
				]}
			>
				<ThemeSync />
			</MockedProvider>,
		);

		await waitFor(() => {
			expect(setTheme).toHaveBeenCalledTimes(1);
		});
		expect(setTheme).toHaveBeenCalledWith("dark");
	});

	it("非 workspace 页面（无 slug）不拉取、不应用", async () => {
		pathnameMock.mockReturnValue("/login");
		const setTheme = vi.fn();
		useTheme.mockReturnValue({ setTheme, theme: "dark", toggleTheme: vi.fn() });

		renderIntl(
			<MockedProvider mocks={[]}>
				<ThemeSync />
			</MockedProvider>,
		);

		await new Promise((resolve) => setTimeout(resolve, 200));
		expect(setTheme).not.toHaveBeenCalled();
	});
});
