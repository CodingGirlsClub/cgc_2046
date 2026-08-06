import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import {
	render,
	screen,
	cleanup,
	waitFor,
	within,
} from "@testing-library/react";
import ProfileEntry from "./profile-entry";

/** 测试本地 profile fixture（#1 mock 已删除） */
const TEST_PROFILE = {
	id: "u_0202",
	email: "xiaomei@example.com",
	displayName: "小美",
	avatarUrl: null,
	isPlatformAdmin: false,
};

/**
 * 个人资料入口组件测试（#69）。
 * mock：fetchCurrentProfile（lib/profile）返回 mock 当前用户。
 */

const { fetchProfile } = vi.hoisted(() => ({ fetchProfile: vi.fn() }));

vi.mock("@/lib/profile", async (importOriginal) => {
	const mod = (await importOriginal()) as Record<string, unknown>;
	return { ...mod, fetchCurrentProfile: fetchProfile };
});

beforeEach(() => {
	vi.clearAllMocks();
	fetchProfile.mockResolvedValue({ ...TEST_PROFILE });
});

afterEach(cleanup);

describe("ProfileEntry 个人资料入口 (#69)", () => {
	it("渲染头像首字母 + 展示名，链接到全局设置", async () => {
		render(<ProfileEntry />);
		await waitFor(() => {
			expect(screen.getByText("小美")).toBeInTheDocument();
		});
		const link = screen.getByTestId("profile-entry");
		expect(link).toHaveAttribute("href", "/settings/account/profile");
		// 头像首字母（小 → 小）
		expect(within(link as HTMLElement).getByText("小")).toBeInTheDocument();
	});

	it("compact 模式：只显示头像，不显示展示名", async () => {
		render(<ProfileEntry compact />);
		await waitFor(() => {
			expect(screen.getByTestId("profile-entry")).toBeInTheDocument();
		});
		expect(screen.queryByText("小美")).not.toBeInTheDocument();
	});

	it("fetch 失败：保留占位「…」仍可点击", async () => {
		fetchProfile.mockRejectedValue(new Error("boom"));
		render(<ProfileEntry />);
		await waitFor(() => {
			expect(screen.getByTestId("profile-entry")).toBeInTheDocument();
		});
		expect(screen.getByTestId("profile-entry")).toHaveAttribute(
			"href",
			"/settings/account/profile",
		);
	});

	it("传入 slug 时链接到工作区设置（P1-3）", async () => {
		render(<ProfileEntry slug="cgc-academy" />);
		await waitFor(() => {
			expect(screen.getByTestId("profile-entry")).toBeInTheDocument();
		});
		expect(screen.getByTestId("profile-entry")).toHaveAttribute(
			"href",
			"/w/cgc-academy/settings/account/profile",
		);
	});
});
