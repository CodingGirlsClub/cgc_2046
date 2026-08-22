import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import {
	cleanup,
	fireEvent,
	screen,
	waitFor,
	within,
} from "@testing-library/react";
import { render } from "@/test-utils";
import SettingsPage from "./page";

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
			"update_join_policy",
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
		myRoleNames: [],
		roles: [],
		// 普通成员：无 update_join_policy（#78 门控：只读）
		myAbilities: ["view_workspace", "access_invite_only"],
		membershipStatus: "active" as const,
		memberCount: 128,
	},
];

const { router } = vi.hoisted(() => ({
	router: { push: vi.fn(), replace: vi.fn() },
}));
const { isAuthenticated } = vi.hoisted(() => ({ isAuthenticated: vi.fn() }));
const { useAuthed } = vi.hoisted(() => ({ useAuthed: vi.fn() }));

vi.mock("@/lib/use-authed", () => ({ useAuthed }));
const { params } = vi.hoisted(() => ({
	params: { value: { slug: "cgc-academy" } },
}));
const { fetchCurrentProfile } = vi.hoisted(() => ({
	fetchCurrentProfile: vi.fn(),
}));
const { fetchMyWorkspaces } = vi.hoisted(() => ({
	fetchMyWorkspaces: vi.fn(),
}));
const { updateWorkspaceJoinPolicy } = vi.hoisted(() => ({
	updateWorkspaceJoinPolicy: vi.fn(),
}));

const { fetchWorkspaceBySlug } = vi.hoisted(() => ({
	fetchWorkspaceBySlug: vi.fn(),
}));
vi.mock("next/navigation", () => ({
	redirect: vi.fn(),
	permanentRedirect: vi.fn(),
	useRouter: () => router,
	useParams: () => params.value,
	// 壳导航激活态由 pathname 派生：加入策略页 pathname = /w/${slug}/settings/join-policy
	usePathname: () => `/w/${params.value.slug}/settings/join-policy`,
}));

vi.mock("@/lib/auth", () => ({
	isAuthenticated,
	clearAuthToken: vi.fn(),
	clearSession: vi.fn(),
}));

vi.mock("@/lib/workspaces", async (importOriginal) => {
	const mod = (await importOriginal()) as Record<string, unknown>;
	return { ...mod, fetchMyWorkspaces, updateWorkspaceJoinPolicy };
});
vi.mock("@/lib/profile", async (importOriginal) => {
	const mod = (await importOriginal()) as Record<string, unknown>;
	return { ...mod, fetchCurrentProfile };
});

vi.mock("@/lib/requests", async (importOriginal) => {
	const mod = (await importOriginal()) as Record<string, unknown>;
	return { ...mod, fetchWorkspaceBySlug };
});

beforeEach(() => {
	vi.clearAllMocks();
	isAuthenticated.mockReturnValue(true);
	useAuthed.mockReturnValue({ authed: true, confirmed: true });
	params.value = { slug: "cgc-academy" };
	fetchMyWorkspaces.mockResolvedValue(TEST_WORKSPACES);
	fetchCurrentProfile.mockResolvedValue({ isPlatformAdmin: false });
	fetchWorkspaceBySlug.mockReset();
	updateWorkspaceJoinPolicy.mockResolvedValue({ joinPolicy: "invite_only" });
});

afterEach(cleanup);

describe("/w/[slug]/settings 加入策略页（#79 IA 改名）", () => {
	it("未登录重定向到 /login", async () => {
		isAuthenticated.mockReturnValue(false);
		useAuthed.mockReturnValue({ authed: false, confirmed: true });
		render(<SettingsPage />);

		await waitFor(() => expect(router.replace).toHaveBeenCalledWith("/login"));
	});

	it("渲染壳 + 三态 radio + 当前策略选中 + 壳导航激活态", async () => {
		render(<SettingsPage />);

		expect(
			await screen.findByRole("heading", { name: "加入策略" }),
		).toBeInTheDocument();
		// 页面副标题与卡片 header 同文案（#79 改名后），用 getAllByText 断言存在
		expect(
			screen.getAllByText("决定谁能加入这个 Workspace").length,
		).toBeGreaterThan(0);
		// 三态选项（label = JOIN_POLICY_LABEL）
		const radioGroup = screen.getByRole("group", { name: "选择加入方式" });
		expect(
			within(radioGroup).getByRole("radio", { name: "公开" }),
		).toBeInTheDocument();
		expect(
			within(radioGroup).getByRole("radio", { name: "申请审批" }),
		).toBeChecked();
		expect(
			within(radioGroup).getByRole("radio", { name: "仅邀请" }),
		).toBeInTheDocument();
		// hint 文案（JOIN_POLICY_HINT 复用）
		expect(screen.getByText("公开直接加入")).toBeInTheDocument();
		expect(screen.getByText("公开申请审批")).toBeInTheDocument();
		expect(screen.getByText("私密仅邀请")).toBeInTheDocument();
		// 当前策略徽章
		expect(
			screen.getByText("申请审批", { selector: ".workspace-policy" }),
		).toBeInTheDocument();
		// 壳导航「加入策略」激活态（settings 模式：Workspace 分组）
		const workspaceNav = screen.getByRole("navigation", { name: "Workspace" });
		expect(
			within(workspaceNav).getByRole("link", { name: "加入策略" }),
		).toHaveAttribute("aria-current", "page");
		// 管理员可见保存按钮（当前策略未变时禁用）
		expect(screen.getByRole("button", { name: "保存更改" })).toBeDisabled();
	});

	it("切换策略并保存：调 updateWorkspaceJoinPolicy(id, policy) + 成功提示", async () => {
		render(<SettingsPage />);

		const inviteRadio = await screen.findByRole("radio", { name: "仅邀请" });
		fireEvent.click(inviteRadio);

		const save = screen.getByRole("button", { name: "保存更改" });
		expect(save).toBeEnabled();
		fireEvent.click(save);

		await waitFor(() =>
			expect(updateWorkspaceJoinPolicy).toHaveBeenCalledWith(
				"ws_02",
				"invite_only",
			),
		);
		expect(await screen.findByRole("status", { name: "" })).toHaveTextContent(
			"加入策略已更新",
		);
		// 保存后徽章同步为新策略
		expect(
			screen.getByText("仅邀请", { selector: ".workspace-policy" }),
		).toBeInTheDocument();
		// 已保存（无变更）→ 保存按钮回禁用
		expect(screen.getByRole("button", { name: "保存更改" })).toBeDisabled();
	});

	it("保存成功后改回原值：按钮启用且真实提交（review BLOCKING 钉测）", async () => {
		updateWorkspaceJoinPolicy.mockResolvedValue({ joinPolicy: "invite_only" });
		render(<SettingsPage />);

		// 第一次：request → invite_only 保存成功（服务端新值，hook 本地 ws.joinPolicy 仍为过期 request）
		const inviteRadio = await screen.findByRole("radio", { name: "仅邀请" });
		fireEvent.click(inviteRadio);
		fireEvent.click(screen.getByRole("button", { name: "保存更改" }));
		await waitFor(() =>
			expect(updateWorkspaceJoinPolicy).toHaveBeenCalledWith(
				"ws_02",
				"invite_only",
			),
		);

		// 改回原值 request：相对服务端新值（invite_only）这是真实变更 → 按钮必须启用
		const requestRadio = screen.getByRole("radio", { name: "申请审批" });
		fireEvent.click(requestRadio);
		expect(screen.getByRole("button", { name: "保存更改" })).toBeEnabled();

		// 点击保存必须真实提交（不得因 ws.joinPolicy 过期误判为无变更而静默 return）
		updateWorkspaceJoinPolicy.mockResolvedValue({ joinPolicy: "request" });
		fireEvent.click(screen.getByRole("button", { name: "保存更改" }));
		await waitFor(() =>
			expect(updateWorkspaceJoinPolicy).toHaveBeenLastCalledWith(
				"ws_02",
				"request",
			),
		);
	});

	it("保存失败：显示错误提示（role=alert）", async () => {
		updateWorkspaceJoinPolicy.mockRejectedValue(new Error("forbidden"));
		render(<SettingsPage />);

		const inviteRadio = await screen.findByRole("radio", { name: "仅邀请" });
		fireEvent.click(inviteRadio);
		fireEvent.click(screen.getByRole("button", { name: "保存更改" }));

		const alert = await screen.findByRole("alert");
		expect(alert).toHaveTextContent("forbidden");
	});

	it("PlatformAdmin 只读访客：展示策略但禁用保存", async () => {
		params.value = { slug: "audit-ws" };
		fetchMyWorkspaces.mockResolvedValue([]);
		fetchCurrentProfile.mockResolvedValue({ isPlatformAdmin: true });
		fetchWorkspaceBySlug.mockResolvedValue({
			id: "ws-audit",
			slug: "audit-ws",
			name: "审计工作台",
			joinPolicy: "request",
			sponsorshipEnabled: false,
		});

		render(<SettingsPage />);

		expect(
			await screen.findByTestId("settings-readonly-note"),
		).toHaveTextContent("平台管理员只读审计视图");
		expect(screen.getByRole("radio", { name: "公开" })).toBeDisabled();
		expect(screen.getByRole("button", { name: "保存更改" })).toBeDisabled();
		expect(updateWorkspaceJoinPolicy).not.toHaveBeenCalled();
	});

	it("非管理员（无 update_join_policy）：页面级拦截，渲染「需要管理权限」空态（2026-08-22 决策）", async () => {
		params.value = { slug: "cgc-shanghai" };
		render(<SettingsPage />);

		expect(
			await screen.findByTestId("shell-no-permission"),
		).toHaveTextContent("此页面需要管理权限");
		// 原只读降级 UI 不再对普通成员渲染（只读态保留给平台管理员审计访客）
		expect(screen.queryByRole("radio", { name: "公开" })).not.toBeInTheDocument();
		expect(
			screen.queryByRole("button", { name: "保存更改" }),
		).not.toBeInTheDocument();
		expect(updateWorkspaceJoinPolicy).not.toHaveBeenCalled();
		expect(screen.getByRole("link", { name: "返回概览" })).toHaveAttribute(
			"href",
			"/w/cgc-shanghai",
		);
		// 侧栏 Workspace 组同步门控：加入策略（update_join_policy）等管理项不渲染，
		// 仅剩恒显的 Agents/活动/课程工作面入口
		const workspaceNav = screen.getByRole("navigation", { name: "Workspace" });
		expect(
			within(workspaceNav).queryByRole("link", { name: "加入策略" }),
		).not.toBeInTheDocument();
		expect(
			within(workspaceNav).queryByRole("link", { name: "成员与角色" }),
		).not.toBeInTheDocument();
		expect(
			within(workspaceNav).getByRole("link", { name: "课程" }),
		).toBeInTheDocument();
	});

	it("未知 slug：壳渲染「工作区不可访问」", async () => {
		params.value = { slug: "no-such-ws" };
		fetchMyWorkspaces.mockResolvedValue(TEST_WORKSPACES);

		render(<SettingsPage />);

		expect(
			await screen.findByRole("heading", { name: "工作区不可访问" }),
		).toBeInTheDocument();
	});
});
