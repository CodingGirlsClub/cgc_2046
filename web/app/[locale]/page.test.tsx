import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, screen, fireEvent, waitFor } from "@testing-library/react";
import { render } from "@/test-utils";
import HomePage from "./page";

/**
 * 首页测试（M2：公开 Landing + 已登录分发器）。
 *
 * 行为：
 * 1. 未登录（confirmed && !authed）→ 渲染公开 Landing 页，不重定向、不拉取工作区列表；
 * 2. 有可进入（active）工作区 → replace 到默认 workspace（最近记忆 > 第一个 active）；
 * 3. 无任何工作区 → 渲染极简空态（去 /join），不 replace。
 * 加载失败 → 错误态 + 重试。
 */

const { replace, push } = vi.hoisted(() => ({
	replace: vi.fn(),
	push: vi.fn(),
}));
const { useAuthed } = vi.hoisted(() => ({
	useAuthed: vi.fn(),
}));
const { fetchMyWorkspaces } = vi.hoisted(() => ({
	fetchMyWorkspaces: vi.fn(),
}));
const { readLastWorkspace } = vi.hoisted(() => ({
	readLastWorkspace: vi.fn(),
}));

vi.mock("next/navigation", () => ({
	useRouter: () => ({ replace, push }),
	// ThemeProvider 依赖 usePathname 解析 workspace slug（ADR-0004）
	usePathname: () => "/",
	// redirect/permanentRedirect 供 next-intl createNavigation 顶层 import（i18n Phase 1）
	redirect: vi.fn(),
	permanentRedirect: vi.fn(),
}));

// i18n Phase 1：切换器自身在 language-switcher.test.tsx 以真实 provider 覆盖
vi.mock("@/components/language-switcher", () => ({
	default: () => null,
}));

vi.mock("@/lib/use-authed", () => ({
	useAuthed,
}));

vi.mock("@/lib/workspaces", async (importOriginal) => {
	const mod = (await importOriginal()) as Record<string, unknown>;
	return { ...mod, fetchMyWorkspaces };
});

vi.mock("@/lib/use-last-workspace", () => ({
	readLastWorkspace,
	writeLastWorkspace: vi.fn(),
}));

const { fetchPublicOfferings } = vi.hoisted(() => ({
	fetchPublicOfferings: vi.fn(),
}));

// Landing 页动态区块走公开 API；首页测试只关心分支，不关心条目数据
vi.mock("@/lib/public-offerings", () => ({
	fetchPublicOfferings,
}));

/** 分发 fixture：三个状态各异的工作区 */
const TEST_WORKSPACES = [
	{
		id: "ws_a",
		slug: "cgc-open",
		name: "CGC 公开社区",
		joinPolicy: "open",
		sponsorshipEnabled: true,
		myRoleNames: ["owner"],
		roles: ["owner"],
		membershipStatus: "active",
	},
	{
		id: "ws_b",
		slug: "cgc-camp",
		name: "CGC 成长营",
		joinPolicy: "open",
		sponsorshipEnabled: true,
		myRoleNames: ["owner"],
		roles: ["owner"],
		membershipStatus: "active",
	},
	{
		id: "ws_c",
		slug: "cgc-pending",
		name: "待审批工作区",
		joinPolicy: "request",
		sponsorshipEnabled: true,
		myRoleNames: [],
		roles: [],
		myMembershipId: "wm_p",
		membershipStatus: "pending",
	},
];

beforeEach(() => {
	vi.clearAllMocks();
	window.history.replaceState({}, "", "/");
	useAuthed.mockReturnValue({ authed: true, confirmed: true });
	readLastWorkspace.mockReturnValue(null);
	fetchPublicOfferings.mockResolvedValue([]);
});

afterEach(cleanup);

describe("首页（公开 Landing + 已登录分发）", () => {
	it("未登录：渲染公开 Landing，不重定向 /login、不拉取工作区列表", async () => {
		useAuthed.mockReturnValue({ authed: false, confirmed: true });
		render(<HomePage />);

		// Landing Hero 与登录/注册 CTA 可见
		expect(
			await screen.findByRole("heading", {
				name: "一桥飞架南北，天堑变通途",
			}),
		).toBeInTheDocument();
		expect(screen.getAllByRole("link", { name: "登录" })[0]).toHaveAttribute(
			"href",
			"/login",
		);
		expect(screen.getAllByRole("link", { name: "加入我们" })[0]).toHaveAttribute(
			"href",
			"/register",
		);
		expect(replace).not.toHaveBeenCalled();
		expect(fetchMyWorkspaces).not.toHaveBeenCalled();
	});

	it("登录态确认中：只渲染 spinner，不闪烁 Landing 或分发器内容", () => {
		useAuthed.mockReturnValue({ authed: false, confirmed: false });
		render(<HomePage />);

		expect(screen.getByText("正在确认登录状态…")).toBeInTheDocument();
		expect(
			screen.queryByRole("heading", {
				name: "一桥飞架南北，天堑变通途",
			}),
		).not.toBeInTheDocument();
		expect(replace).not.toHaveBeenCalled();
		expect(fetchMyWorkspaces).not.toHaveBeenCalled();
	});

	it("有 active 工作区且无记忆：分发到第一个 active", async () => {
		fetchMyWorkspaces.mockResolvedValue(TEST_WORKSPACES);
		render(<HomePage />);

		await waitFor(() =>
			expect(replace).toHaveBeenCalledWith("/w/cgc-open"),
		);
		// pending 工作区不参与分发
		expect(replace).not.toHaveBeenCalledWith("/w/cgc-pending");
	});

	it("记忆 slug 存在且 active：分发到记忆工作区（非第一个）", async () => {
		fetchMyWorkspaces.mockResolvedValue(TEST_WORKSPACES);
		readLastWorkspace.mockReturnValue("cgc-camp");
		render(<HomePage />);

		await waitFor(() =>
			expect(replace).toHaveBeenCalledWith("/w/cgc-camp"),
		);
	});

	it("记忆 slug 非 active：回退到第一个 active", async () => {
		fetchMyWorkspaces.mockResolvedValue(TEST_WORKSPACES);
		readLastWorkspace.mockReturnValue("cgc-pending");
		render(<HomePage />);

		await waitFor(() =>
			expect(replace).toHaveBeenCalledWith("/w/cgc-open"),
		);
	});

	it("记忆 slug 不在列表中：回退到第一个 active", async () => {
		fetchMyWorkspaces.mockResolvedValue(TEST_WORKSPACES);
		readLastWorkspace.mockReturnValue("some-gone-ws");
		render(<HomePage />);

		await waitFor(() =>
			expect(replace).toHaveBeenCalledWith("/w/cgc-open"),
		);
	});

	it("无任何工作区：渲染空态引导去 /join，不重定向", async () => {
		fetchMyWorkspaces.mockResolvedValue([]);
		render(<HomePage />);

		expect(
			await screen.findByRole("heading", { name: "你还没有加入任何工作区" }),
		).toBeInTheDocument();
		const joinLink = screen.getByRole("link", {
			name: "发现 / 申请加入工作区",
		});
		expect(joinLink).toHaveAttribute("href", "/join");
		expect(replace).not.toHaveBeenCalled();
	});

	it("加载失败：展示错误态，点重试恢复", async () => {
		fetchMyWorkspaces.mockRejectedValueOnce(new Error("network down"));
		render(<HomePage />);

		expect(await screen.findByRole("alert")).toBeInTheDocument();
		expect(screen.getByText("工作区加载失败")).toBeInTheDocument();

		// 重试成功（空列表）→ 空态
		fetchMyWorkspaces.mockResolvedValueOnce([]);
		fireEvent.click(screen.getByRole("button", { name: "重试" }));
		expect(
			await screen.findByRole("heading", { name: "你还没有加入任何工作区" }),
		).toBeInTheDocument();
		expect(screen.queryByRole("alert")).not.toBeInTheDocument();
	});
});
