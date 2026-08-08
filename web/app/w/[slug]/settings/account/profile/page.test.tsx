import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import {
	render,
	screen,
	cleanup,
	waitFor,
	fireEvent,
	within,
} from "@testing-library/react";
import WorkspaceAccountProfilePage from "./page";
import type { CurrentProfile } from "@/lib/profile";

/**
 * 工作区个人资料页测试（ADR-0004 per-workspace）。
 * 验证：按 slug 解析 workspace → 拉取 workspaceProfile + portfolio（带 workspaceId）；
 * 跨 workspace 切换不串台；显示全局身份（displayName）+ per-workspace 字段。
 */

const { useAuthed } = vi.hoisted(() => ({ useAuthed: vi.fn() }));
const { useWorkspaceBySlug } = vi.hoisted(() => ({
	useWorkspaceBySlug: vi.fn(),
}));
const {
	fetchCurrentProfile,
	fetchWorkspaceProfile,
	fetchPortfolioItems,
	fetchProfileRoleSummary,
	updateDisplayName,
	updateWorkspaceProfile,
	createPortfolioItem,
	updatePortfolioItem,
	deletePortfolioItem,
} = vi.hoisted(() => ({
	fetchCurrentProfile: vi.fn(),
	fetchWorkspaceProfile: vi.fn(),
	fetchPortfolioItems: vi.fn(),
	fetchProfileRoleSummary: vi.fn(),
	updateDisplayName: vi.fn(),
	updateWorkspaceProfile: vi.fn(),
	createPortfolioItem: vi.fn(),
	updatePortfolioItem: vi.fn(),
	deletePortfolioItem: vi.fn(),
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
		updateDisplayName,
		updateWorkspaceProfile,
		createPortfolioItem,
		updatePortfolioItem,
		deletePortfolioItem,
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

const PORTFOLIO_ITEM_A = {
	id: "pf_1",
	workspaceId: "ws_1",
	title: "作品A",
	description: "desc A",
	url: null,
	icon: "document" as const,
};

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
	updateDisplayName.mockResolvedValue(ME);
	updateWorkspaceProfile.mockResolvedValue(WS_PROFILE);
	createPortfolioItem.mockResolvedValue({
		id: "pf_new",
		workspaceId: "ws_1",
		title: "新作品",
		description: "",
		url: null,
		icon: "document",
	});
	updatePortfolioItem.mockResolvedValue(PORTFOLIO_ITEM_A);
	deletePortfolioItem.mockResolvedValue(undefined);
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

describe("个人资料保存路径（编排与幂等）", () => {
	/** 渲染页面并等待表单就绪（数据拉取完成） */
	async function renderForm() {
		render(<WorkspaceAccountProfilePage />);
		await waitFor(() => {
			expect(screen.getByTestId("profile-name-input")).toHaveValue("小美");
		});
	}

	it("保存编排：updateDisplayName 与 updateWorkspaceProfile 各调一次、参数正确", async () => {
		await renderForm();
		fireEvent.change(screen.getByTestId("profile-name-input"), {
			target: { value: "小美新名" },
		});
		fireEvent.click(screen.getByRole("button", { name: "保存更改" }));

		await waitFor(() => {
			expect(updateDisplayName).toHaveBeenCalledTimes(1);
		});
		expect(updateDisplayName).toHaveBeenCalledWith("小美新名");
		expect(updateWorkspaceProfile).toHaveBeenCalledTimes(1);
		expect(updateWorkspaceProfile).toHaveBeenCalledWith("ws_1", {
			avatarUrl: null,
			location: "杭州",
			about: "camp 简介",
			skills: ["TS"],
			visibility: "only_me",
		});
		await waitFor(() => {
			expect(screen.getByText("资料已保存")).toBeInTheDocument();
		});
	});

	it("portfolio diff 新增：新条目仅 create 一次，update/delete 不触发", async () => {
		fetchPortfolioItems.mockResolvedValue([PORTFOLIO_ITEM_A]);
		await renderForm();

		fireEvent.click(screen.getByRole("button", { name: "添加作品" }));
		const rows = screen.getAllByTestId("portfolio-edit-row");
		expect(rows).toHaveLength(2);
		fireEvent.change(within(rows[1]).getByLabelText("作品标题"), {
			target: { value: "新作品" },
		});
		fireEvent.click(screen.getByRole("button", { name: "保存更改" }));

		await waitFor(() => {
			expect(createPortfolioItem).toHaveBeenCalledTimes(1);
		});
		expect(createPortfolioItem).toHaveBeenCalledWith("ws_1", {
			title: "新作品",
			description: "",
			url: "",
			icon: "document",
		});
		expect(updatePortfolioItem).not.toHaveBeenCalled();
		expect(deletePortfolioItem).not.toHaveBeenCalled();
	});

	it("portfolio diff 删除：被移除条目以正确 id 调 deletePortfolioItem", async () => {
		const itemB = { ...PORTFOLIO_ITEM_A, id: "pf_2", title: "作品B" };
		fetchPortfolioItems.mockResolvedValue([PORTFOLIO_ITEM_A, itemB]);
		await renderForm();

		const rows = screen.getAllByTestId("portfolio-edit-row");
		expect(rows).toHaveLength(2);
		fireEvent.click(
			within(rows[0]).getByRole("button", { name: /删除作品/ }),
		);
		fireEvent.click(screen.getByRole("button", { name: "保存更改" }));

		await waitFor(() => {
			expect(deletePortfolioItem).toHaveBeenCalledTimes(1);
		});
		expect(deletePortfolioItem).toHaveBeenCalledWith("pf_1", "ws_1");
		expect(createPortfolioItem).not.toHaveBeenCalled();
		expect(updatePortfolioItem).not.toHaveBeenCalled();
	});

	it("重试不重复：首次保存部分成功（create 已落库）后，重试不再重复 create", async () => {
		const serverItem = {
			...PORTFOLIO_ITEM_A,
			id: "pf_created",
			title: "作品A",
		};
		// 页面加载：空作品集；之后每次 reconcile：只含已成功创建的条目
		fetchPortfolioItems.mockResolvedValueOnce([]);
		fetchPortfolioItems.mockResolvedValue([serverItem]);
		// 首次保存：条目 A 的 create 成功、条目 B 的 create 失败 → 保存失败
		createPortfolioItem
			.mockResolvedValueOnce(serverItem)
			.mockRejectedValueOnce(new Error("create 失败"));
		await renderForm();

		fireEvent.click(screen.getByRole("button", { name: "添加作品" }));
		fireEvent.click(screen.getByRole("button", { name: "添加作品" }));
		const rows = screen.getAllByTestId("portfolio-edit-row");
		expect(rows).toHaveLength(2);
		fireEvent.change(within(rows[0]).getByLabelText("作品标题"), {
			target: { value: "作品A" },
		});
		fireEvent.change(within(rows[1]).getByLabelText("作品标题"), {
			target: { value: "作品B" },
		});

		// 第一次保存：A 落库、B 失败 → 报错，按钮恢复可用
		fireEvent.click(screen.getByRole("button", { name: "保存更改" }));
		await waitFor(() => {
			expect(screen.getByRole("alert")).toHaveTextContent("create 失败");
			expect(
				screen.getByRole("button", { name: "保存更改" }),
			).toBeEnabled();
		});
		// 首次保存内 create 被调 2 次：A 成功落库、B 失败
		expect(createPortfolioItem).toHaveBeenCalledTimes(2);
		const createCallsAfterFirstSave = createPortfolioItem.mock.calls.length;

		// 重试：finally reconcile 已把 lastSyncedRef/草稿重置为 [serverItem]，
		// 不会再以临时 id 重复 create
		fireEvent.click(screen.getByRole("button", { name: "保存更改" }));
		await waitFor(() => {
			expect(screen.getByText("资料已保存")).toBeInTheDocument();
		});
		// 第二次保存没有新增任何 create 调用（数量与首次保存后持平）
		expect(createPortfolioItem.mock.calls.length).toBe(
			createCallsAfterFirstSave,
		);
		expect(createPortfolioItem).toHaveBeenNthCalledWith(1, "ws_1", {
			title: "作品A",
			description: "",
			url: "",
			icon: "document",
		});
	});

	it("保存中禁用提交按钮与输入框（saving 期间不可编辑）", async () => {
		let release!: (value: CurrentProfile) => void;
		updateDisplayName.mockReturnValue(
			new Promise<CurrentProfile>((resolve) => {
				release = resolve;
			}),
		);
		await renderForm();

		fireEvent.click(screen.getByRole("button", { name: "保存更改" }));
		await waitFor(() => {
			expect(
				screen.getByRole("button", { name: "保存中…" }),
			).toBeDisabled();
		});
		expect(screen.getByTestId("profile-name-input")).toBeDisabled();
		expect(screen.getByTestId("profile-location-input")).toBeDisabled();
		expect(screen.getByTestId("profile-about-input")).toBeDisabled();
		expect(screen.getByTestId("profile-visibility-input")).toBeDisabled();
		expect(
			screen.getByRole("button", { name: "添加作品" }),
		).toBeDisabled();

		// 释放保存 promise，让保存流程走完，避免悬挂状态
		release(ME);
		await waitFor(() => {
			expect(
				screen.getByRole("button", { name: "保存更改" }),
			).toBeEnabled();
		});
	});
});
