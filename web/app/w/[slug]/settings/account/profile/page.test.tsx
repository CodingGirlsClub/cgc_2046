import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import {
	render,
	screen,
	cleanup,
	waitFor,
} from "@testing-library/react";
import WorkspaceAccountProfilePage from "./page";

/**
 * 工作区个人资料页测试（ADR-0004 per-workspace）。
 * 验证：按 slug 解析 workspace → 拉取 workspaceProfile + portfolio（带 workspaceId）；
 * 跨 workspace 切换不串台；显示全局身份（displayName）+ per-workspace 字段。
 */

const { useAuthed } = vi.hoisted(() => ({ useAuthed: vi.fn() }));
const { useWorkspaceBySlug } = vi.hoisted(() => ({
	useWorkspaceBySlug: vi.fn(),
}));
const { fetchCurrentProfile, fetchWorkspaceProfile, fetchPortfolioItems, fetchProfileRoleSummary } =
	vi.hoisted(() => ({
		fetchCurrentProfile: vi.fn(),
		fetchWorkspaceProfile: vi.fn(),
		fetchPortfolioItems: vi.fn(),
		fetchProfileRoleSummary: vi.fn(),
	}));

vi.mock("@/lib/use-authed", () => ({ useAuthed }));
vi.mock("@/lib/use-workspace-by-slug", () => ({ useWorkspaceBySlug }));
vi.mock("@/lib/profile", async (importOriginal) => {
	const mod = (await importOriginal()) as Record<string, unknown>;
	return {
		...mod,
		fetchCurrentProfile,
		fetchWorkspaceProfile,
		fetchPortfolioItems,
		fetchProfileRoleSummary,
		pickRoleSummary: mod.pickRoleSummary,
	};
});

vi.mock("next/navigation", () => ({
	useParams: () => ({ slug: "cgc-camp" }),
	usePathname: () => "/w/cgc-camp/settings/account/profile",
	useRouter: () => ({ replace: vi.fn(), push: vi.fn() }),
}));

const ME = {
	id: "u_1",
	email: "xiaomei@example.com",
	displayName: "小美",
	isPlatformAdmin: false,
	memberNumber: "CGC-000042",
	joinedAt: "2026-08-02T03:00:00Z",
};

const WS_PROFILE = {
	id: "wsp_1",
	workspaceId: "ws_1",
	userId: "u_1",
	avatarUrl: null,
	location: "杭州",
	about: "camp 简介",
	skills: ["TS"],
	visibility: "only_me",
	uiThemePreference: "dark",
	portfolio: [],
};

const SUMMARIES = [
	{
		workspaceId: "ws_1",
		workspaceSlug: "cgc-camp",
		workspaceName: "CGC 成长营",
		myRoleNames: ["owner"],
	},
];

beforeEach(() => {
	vi.clearAllMocks();
	useAuthed.mockReturnValue({ authed: true, confirmed: true });
	useWorkspaceBySlug.mockReturnValue({
		ws: { id: "ws_1", slug: "cgc-camp", name: "CGC 成长营" },
		loading: false,
	});
	fetchCurrentProfile.mockResolvedValue(ME);
	fetchWorkspaceProfile.mockResolvedValue(WS_PROFILE);
	fetchPortfolioItems.mockResolvedValue([]);
	fetchProfileRoleSummary.mockResolvedValue(SUMMARIES);
});

afterEach(cleanup);

describe("工作区个人资料页（ADR-0004 per-workspace）", () => {
	it("按 workspaceId 拉取档案与作品集（per-workspace 数据路径）", async () => {
		render(<WorkspaceAccountProfilePage />);

		await waitFor(() => {
			expect(fetchWorkspaceProfile).toHaveBeenCalledWith("ws_1");
		});
		expect(fetchPortfolioItems).toHaveBeenCalledWith("ws_1");
		// 壳（WorkspaceShell 侧栏 ProfileEntry）与页面各消费一次 me
		expect(fetchCurrentProfile).toHaveBeenCalled();
	});

	it("渲染全局身份（displayName/邮箱）+ per-workspace 字段（location/about/skills）", async () => {
		render(<WorkspaceAccountProfilePage />);

		await waitFor(() => {
			expect(screen.getByTestId("profile-name-input")).toHaveValue("小美");
		});
		expect(screen.getByTestId("profile-email-input")).toHaveValue(
			"xiaomei@example.com",
		);
		expect(screen.getByTestId("profile-location-input")).toHaveValue("杭州");
		expect(screen.getByTestId("profile-about-input")).toHaveValue("camp 简介");
		// 技能标签渲染
		expect(screen.getByText("TS")).toBeInTheDocument();
	});

	it("workspace 解析中显示加载骨架", () => {
		useWorkspaceBySlug.mockReturnValue({
			ws: undefined,
			loading: true,
		});
		render(<WorkspaceAccountProfilePage />);
		expect(screen.getByLabelText("加载中")).toBeInTheDocument();
	});
});
