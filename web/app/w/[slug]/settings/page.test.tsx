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
		myRoleNames: ["member"],
		roles: ["member"],
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
const { params } = vi.hoisted(() => ({
	params: { value: { slug: "cgc-academy" } },
}));
const { fetchMyWorkspaces } = vi.hoisted(() => ({
	fetchMyWorkspaces: vi.fn(),
}));
const { updateWorkspaceJoinPolicy } = vi.hoisted(() => ({
	updateWorkspaceJoinPolicy: vi.fn(),
}));

vi.mock("next/navigation", () => ({
	useRouter: () => router,
	useParams: () => params.value,
	// 壳导航激活态由 pathname 派生：设置页 pathname 前缀 /w/${slug}/settings
	usePathname: () => `/w/${params.value.slug}/settings`,
}));

vi.mock("@/lib/auth", () => ({
	isAuthenticated,
	clearAuthToken: vi.fn(),
}));

vi.mock("@/lib/workspaces", async (importOriginal) => {
	const mod = (await importOriginal()) as Record<string, unknown>;
	return { ...mod, fetchMyWorkspaces, updateWorkspaceJoinPolicy };
});

beforeEach(() => {
	vi.clearAllMocks();
	isAuthenticated.mockReturnValue(true);
	params.value = { slug: "cgc-academy" };
	fetchMyWorkspaces.mockResolvedValue(TEST_WORKSPACES);
	updateWorkspaceJoinPolicy.mockResolvedValue({ joinPolicy: "invite_only" });
});

afterEach(cleanup);

describe("/w/[slug]/settings 加入策略页（#79 IA 改名）", () => {
	it("未登录重定向到 /login", async () => {
		isAuthenticated.mockReturnValue(false);
		render(<SettingsPage />);

		await waitFor(() => expect(router.replace).toHaveBeenCalledWith("/login"));
	});

	it("渲染壳 + 三态 radio + 当前策略选中 + 壳导航激活态", async () => {
		render(<SettingsPage />);

		expect(
			await screen.findByRole("heading", { name: "加入策略" }),
		).toBeInTheDocument();
		// 页面副标题与卡片 header 同文案（#79 改名后），用 getAllByText 断言存在
		expect(screen.getAllByText("决定谁能加入这个 Workspace").length).toBeGreaterThan(
			0,
		);
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
		// 壳导航「加入策略」激活态（#79 改名）
		const shellNav = screen.getByRole("navigation", { name: "工作区设置" });
		expect(
			within(shellNav).getByRole("link", { name: "加入策略" }),
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

	it("非管理员（无 update_join_policy）：radio 禁用 + 只读提示 + 保存禁用", async () => {
		params.value = { slug: "cgc-shanghai" };
		render(<SettingsPage />);

		expect(
			await screen.findByTestId("settings-readonly-note"),
		).toHaveTextContent("仅 Owner / Admin 可修改加入策略");
		expect(screen.getByRole("radio", { name: "公开" })).toBeDisabled();
		expect(screen.getByRole("radio", { name: "申请审批" })).toBeDisabled();
		expect(screen.getByRole("radio", { name: "仅邀请" })).toBeDisabled();
		expect(screen.getByRole("button", { name: "保存更改" })).toBeDisabled();
		expect(updateWorkspaceJoinPolicy).not.toHaveBeenCalled();
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
