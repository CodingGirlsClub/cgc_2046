import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { render, screen, cleanup, waitFor } from "@testing-library/react";
import WorkspacePage from "./page";

/** 测试本地 fixture（#1 mock 已删除；页面只消费 fetchMyWorkspaces 返回值） */
const TEST_WORKSPACES = [
	{
		id: "ws_02",
		slug: "cgc-academy",
		name: "CGC 线上学院",
		joinPolicy: "request" as const,
		sponsorshipEnabled: true,
		myRoleNames: ["admin"],
		roles: ["admin"],
		myAbilities: [
			"view_workspace",
			"access_invite_only",
			"list_members",
			"manage_members",
			"assign_roles",
		],
		membershipStatus: "active" as const,
		memberCount: 342,
	},
	{
		id: "ws_01",
		slug: "cgc-shanghai",
		name: "CGC 上海分社",
		joinPolicy: "open" as const,
		sponsorshipEnabled: true,
		myRoleNames: ["member"],
		roles: ["member"],
		myAbilities: ["view_workspace", "access_invite_only"],
		membershipStatus: "active" as const,
		memberCount: 128,
	},
];

const { push, replace } = vi.hoisted(() => ({
	push: vi.fn(),
	replace: vi.fn(),
}));
const { isAuthenticated } = vi.hoisted(() => ({ isAuthenticated: vi.fn() }));
const { params } = vi.hoisted(() => ({
	params: { value: { slug: "cgc-academy" } },
}));
const { fetchCurrentProfile } = vi.hoisted(() => ({
	fetchCurrentProfile: vi.fn(),
}));
const { fetchMyWorkspaces } = vi.hoisted(() => ({
	fetchMyWorkspaces: vi.fn(),
}));

vi.mock("next/navigation", () => ({
	useRouter: () => ({ push, replace }),
	useParams: () => params.value,
}));

vi.mock("@/lib/auth", () => ({
	isAuthenticated,
	clearAuthToken: vi.fn(),
}));

vi.mock("@/lib/profile", async (importOriginal) => {
	const mod = (await importOriginal()) as Record<string, unknown>;
	return { ...mod, fetchCurrentProfile };
});

vi.mock("@/lib/workspaces", async (importOriginal) => {
	const mod = (await importOriginal()) as Record<string, unknown>;
	return {
		...mod,
		// #70 QA P1：工作区上下文经 useWorkspaceBySlug → fetchMyWorkspaces 解析
		fetchMyWorkspaces,
	};
});

beforeEach(() => {
	vi.clearAllMocks();
	isAuthenticated.mockReturnValue(true);
	params.value = { slug: "cgc-academy" };
	fetchMyWorkspaces.mockResolvedValue(TEST_WORKSPACES);
	fetchCurrentProfile.mockResolvedValue({
		id: "u_0202",
		email: "xiaomei@example.com",
		displayName: "小美",
		avatarUrl: null,
		isPlatformAdmin: false,
	});
});

afterEach(cleanup);

describe("工作区占位页 /w/[slug] (#63)", () => {
	it("未登录：重定向 /login", async () => {
		isAuthenticated.mockReturnValue(false);
		render(<WorkspacePage />);
		await waitFor(() => expect(replace).toHaveBeenCalledWith("/login"));
	});

	it("按 slug 匹配 mock：展示名称/slug/加入方式/赞助入口", async () => {
		render(<WorkspacePage />);
		expect(await screen.findByText("CGC 线上学院")).toBeInTheDocument();
		expect(screen.getByText("cgc-academy")).toBeInTheDocument();
		expect(screen.getByText("申请审批")).toBeInTheDocument();
		expect(screen.getByText("已开启")).toBeInTheDocument();
	});

	it("未知 slug：展示建设中占位", async () => {
		params.value = { slug: "not-exist" };
		render(<WorkspacePage />);
		expect(await screen.findByText(/建设中/)).toBeInTheDocument();
		expect(TEST_WORKSPACES.length).toBeGreaterThan(0); // 引用 fixture 防 tree-shake
	});

	it("真实模式（#70 QA P1）：fetchMyWorkspaces 返回真实 ws（不在 mock），详情页按真实数据渲染", async () => {
		fetchMyWorkspaces.mockResolvedValue([
			{
				id: "ws_real_detail",
				slug: "qa70-real-ws-333",
				name: "QA70 真实详情工作区",
				joinPolicy: "invite_only",
				sponsorshipEnabled: false,
				myRoleNames: ["member"],
				roles: ["member"],
				membershipStatus: "active",
				memberCount: 42,
			},
		]);
		params.value = { slug: "qa70-real-ws-333" };

		render(<WorkspacePage />);
		// 不再显示「建设中」，展示真实工作区信息
		expect(await screen.findByText("QA70 真实详情工作区")).toBeInTheDocument();
		expect(screen.getByText("qa70-real-ws-333")).toBeInTheDocument();
		expect(screen.getByText("仅邀请")).toBeInTheDocument();
		expect(screen.getByText("已关闭")).toBeInTheDocument();
		expect(screen.queryByText(/建设中/)).not.toBeInTheDocument();
		// 成员管理入口指向真实 slug
		const link = screen.getByRole("link", { name: /管理成员/ });
		expect(link).toHaveAttribute("href", "/w/qa70-real-ws-333/members");
	});

	it("P1：展示成员数量（meWorkspaces memberCount 计算字段）", async () => {
		fetchMyWorkspaces.mockResolvedValue([
			{
				id: "ws_mc",
				slug: "qa70-count-ws",
				name: "成员数工作区",
				joinPolicy: "open",
				sponsorshipEnabled: true,
				myRoleNames: ["member"],
				roles: ["member"],
				membershipStatus: "active",
				memberCount: 12,
			},
		]);
		params.value = { slug: "qa70-count-ws" };

		render(<WorkspacePage />);
		expect(await screen.findByText("成员数工作区")).toBeInTheDocument();
		expect(screen.getByTestId("workspace-member-count")).toHaveTextContent(
			"12 位成员",
		);
	});

	it("提供返回工作台链接", async () => {
		render(<WorkspacePage />);
		const back = await screen.findByRole("link", { name: /← 工作台/ });
		expect(back).toHaveAttribute("href", "/");
	});

	it("提供成员管理入口链接到 /w/[slug]/members (#65)", async () => {
		render(<WorkspacePage />);
		const link = await screen.findByRole("link", { name: /管理成员/ });
		expect(link).toHaveAttribute("href", "/w/cgc-academy/members");
	});

	it("header 提供个人资料入口链接到 /profile (#69)", async () => {
		render(<WorkspacePage />);
		const entry = await screen.findByTestId("profile-entry");
		expect(entry).toHaveAttribute("href", "/profile?ws=cgc-academy");
	});
});
