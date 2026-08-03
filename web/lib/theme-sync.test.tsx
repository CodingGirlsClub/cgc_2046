import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, waitFor, cleanup } from "@testing-library/react";
import { MockedProvider } from "@apollo/client/testing/react";
import { ME_PROFILE } from "@/lib/graphql/profile";
import ThemeSync from "./theme-sync";

/**
 * ThemeSync 单测（#77）。
 *
 * 核心回归保护：appliedForUserId ref 确保换用户时重应用服务端主题，
 * 旧 applied 布尔实现会在「u1→u2」换用户时失败（不重应用）。
 */

const { useAuthed } = vi.hoisted(() => ({
	useAuthed: vi.fn(),
}));

const { useTheme } = vi.hoisted(() => ({
	useTheme: vi.fn(),
}));

vi.mock("@/lib/use-authed", () => ({ useAuthed }));
vi.mock("@/lib/theme-provider", () => ({ useTheme }));

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
	store.clear();
	useAuthed.mockReturnValue({ authed: true, confirmed: true });
});

function makeMock(data: { id: string; uiThemePreference: string } | null) {
	return {
		request: { query: ME_PROFILE },
		result: { data: { me: data } },
	};
}

describe("ThemeSync（#77 按 userId 重置）", () => {
	it("首次拿到服务端偏好时应用一次", async () => {
		const setTheme = vi.fn();
		useTheme.mockReturnValue({ setTheme, theme: "dark", toggleTheme: vi.fn() });

		render(
			<MockedProvider
				mocks={[makeMock({ id: "u1", uiThemePreference: "light" })]}
			>
				<ThemeSync />
			</MockedProvider>,
		);

		await waitFor(() => {
			expect(setTheme).toHaveBeenCalledTimes(1);
		});
		expect(setTheme).toHaveBeenCalledWith("light");
	});

	it("无效偏好不应用", async () => {
		const setTheme = vi.fn();
		useTheme.mockReturnValue({ setTheme, theme: "dark", toggleTheme: vi.fn() });

		render(
			<MockedProvider
				mocks={[makeMock({ id: "u1", uiThemePreference: "neon" })]}
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

		render(
			<MockedProvider
				mocks={[makeMock({ id: "u1", uiThemePreference: "light" })]}
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

	it("换用户重应用（核心回归保护，闭合 #76）", async () => {
		const setTheme = vi.fn();
		useTheme.mockReturnValue({ setTheme, theme: "dark", toggleTheme: vi.fn() });

		// 首次渲染：u1 light
		render(
			<MockedProvider
				mocks={[makeMock({ id: "u1", uiThemePreference: "light" })]}
			>
				<ThemeSync />
			</MockedProvider>,
		);

		await waitFor(() => {
			expect(setTheme).toHaveBeenCalledTimes(1);
		});
		expect(setTheme).toHaveBeenCalledWith("light");

		// 卸载并重新渲染：u2 dark（模拟换用户场景）
		cleanup();
		vi.clearAllMocks();
		useAuthed.mockReturnValue({ authed: true, confirmed: true });
		useTheme.mockReturnValue({ setTheme, theme: "dark", toggleTheme: vi.fn() });

		render(
			<MockedProvider
				mocks={[makeMock({ id: "u2", uiThemePreference: "dark" })]}
			>
				<ThemeSync />
			</MockedProvider>,
		);

		await waitFor(() => {
			// 旧 applied 布尔实现会在此失败——setTheme 不会被再次调用
			expect(setTheme).toHaveBeenCalledTimes(1);
		});
		expect(setTheme).toHaveBeenCalledWith("dark");
	});

	it("登出（data.me 为 undefined）复位后重登仍应用", async () => {
		const setTheme = vi.fn();
		useTheme.mockReturnValue({ setTheme, theme: "dark", toggleTheme: vi.fn() });

		// 首次渲染：u1 light
		render(
			<MockedProvider
				mocks={[makeMock({ id: "u1", uiThemePreference: "light" })]}
			>
				<ThemeSync />
			</MockedProvider>,
		);

		await waitFor(() => {
			expect(setTheme).toHaveBeenCalledTimes(1);
		});
		expect(setTheme).toHaveBeenCalledWith("light");

		// 登出：data.me 为 null
		cleanup();
		vi.clearAllMocks();
		useAuthed.mockReturnValue({ authed: true, confirmed: true });
		useTheme.mockReturnValue({ setTheme, theme: "dark", toggleTheme: vi.fn() });

		render(
			<MockedProvider mocks={[makeMock(null)]}>
				<ThemeSync />
			</MockedProvider>,
		);

		await new Promise((resolve) => setTimeout(resolve, 200));
		// 登出不应触发 setTheme
		expect(setTheme).toHaveBeenCalledTimes(0);

		// 重新登录：u1 light（应重新应用）
		cleanup();
		vi.clearAllMocks();
		useAuthed.mockReturnValue({ authed: true, confirmed: true });
		useTheme.mockReturnValue({ setTheme, theme: "dark", toggleTheme: vi.fn() });

		render(
			<MockedProvider
				mocks={[makeMock({ id: "u1", uiThemePreference: "light" })]}
			>
				<ThemeSync />
			</MockedProvider>,
		);

		await waitFor(() => {
			// 复位后应重新应用
			expect(setTheme).toHaveBeenCalledTimes(1);
		});
		expect(setTheme).toHaveBeenCalledWith("light");
	});
});
