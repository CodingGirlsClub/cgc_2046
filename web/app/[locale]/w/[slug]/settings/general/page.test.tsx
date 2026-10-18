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
		// 普通成员：无 update_join_policy（门控：shell 空态）
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
const { updateWorkspaceName } = vi.hoisted(() => ({
	updateWorkspaceName: vi.fn(),
}));
const { fetchWorkspaceBySlug } = vi.hoisted(() => ({
	fetchWorkspaceBySlug: vi.fn(),
}));

vi.mock("next/navigation", () => ({
	redirect: vi.fn(),
	permanentRedirect: vi.fn(),
	useRouter: () => router,
	useParams: () => params.value,
	// 壳导航激活态由 pathname 派生：工作台设置页 pathname = /w/${slug}/settings/general
	usePathname: () => `/w/${params.value.slug}/settings/general`,
}));

vi.mock("@/lib/auth", () => ({
	isAuthenticated,
	clearAuthToken: vi.fn(),
	clearSession: vi.fn(),
}));

vi.mock("@/lib/workspaces", async (importOriginal) => {
	const mod = (await importOriginal()) as Record<string, unknown>;
	return { ...mod, fetchMyWorkspaces, updateWorkspaceName };
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
	updateWorkspaceName.mockResolvedValue({ name: "CGC 线上学院（新）" });
});

afterEach(cleanup);

describe("/w/[slug]/settings/general 工作台设置页（改名）", () => {
	it("未登录重定向到 /login", async () => {
		isAuthenticated.mockReturnValue(false);
		useAuthed.mockReturnValue({ authed: false, confirmed: true });
		render(<SettingsPage />);

		await waitFor(() => expect(router.replace).toHaveBeenCalledWith("/login"));
	});

	it("渲染壳 + 名称输入初值 + 无变更时保存禁用 + 壳导航激活态", async () => {
		render(<SettingsPage />);

		expect(
			await screen.findByRole("heading", { name: "工作台设置" }),
		).toBeInTheDocument();
		expect(await screen.findByTestId("workspace-name-input")).toHaveValue(
			"CGC 线上学院",
		);
		expect(screen.getByRole("button", { name: "保存更改" })).toBeDisabled();
		// 壳导航「工作台设置」激活态（settings 模式：Workspace 分组）
		const workspaceNav = screen.getByRole("navigation", { name: "Workspace" });
		expect(
			within(workspaceNav).getByRole("link", { name: "工作台设置" }),
		).toHaveAttribute("aria-current", "page");
	});

	it("改名保存：trim 后调 updateWorkspaceName(id, name) + 成功提示 + 按钮回禁用", async () => {
		render(<SettingsPage />);

		const input = await screen.findByTestId("workspace-name-input");
		fireEvent.change(input, { target: { value: "  CGC 线上学院（新）  " } });

		const save = screen.getByRole("button", { name: "保存更改" });
		expect(save).toBeEnabled();
		fireEvent.click(save);

		await waitFor(() =>
			expect(updateWorkspaceName).toHaveBeenCalledWith(
				"ws_02",
				"CGC 线上学院（新）",
			),
		);
		expect(await screen.findByRole("status")).toHaveTextContent(
			"工作台名称已更新",
		);
		// 保存成功后输入框归一化为服务端返回的新名；无变更 → 按钮回禁用
		expect(screen.getByTestId("workspace-name-input")).toHaveValue(
			"CGC 线上学院（新）",
		);
		expect(screen.getByRole("button", { name: "保存更改" })).toBeDisabled();
	});

	it("纯空白输入：保存按钮禁用且不发请求", async () => {
		render(<SettingsPage />);

		const input = await screen.findByTestId("workspace-name-input");
		fireEvent.change(input, { target: { value: "   " } });

		const save = screen.getByRole("button", { name: "保存更改" });
		expect(save).toBeDisabled();
		fireEvent.click(save);
		expect(updateWorkspaceName).not.toHaveBeenCalled();
	});

	it("保存成功后改回 hook 里过期的原名：按钮启用且真实提交（lastPersisted 用服务端值钉测）", async () => {
		render(<SettingsPage />);

		const input = await screen.findByTestId("workspace-name-input");
		const save = screen.getByRole("button", { name: "保存更改" });

		// 第一次：改成「中间态」保存成功（服务端新值；hook 本地 ws.name 仍是「CGC 线上学院」）
		fireEvent.change(input, { target: { value: "中间态" } });
		fireEvent.click(save);
		await waitFor(() =>
			expect(updateWorkspaceName).toHaveBeenCalledWith("ws_02", "中间态"),
		);

		// 改回 hook 里过期的原名：相对服务端新值这是真实变更 → 按钮必须启用
		fireEvent.change(input, { target: { value: "CGC 线上学院" } });
		expect(save).toBeEnabled();

		// 点击必须真实提交（不得因 ws.name 过期误判为无变更而静默 return）
		fireEvent.click(save);
		await waitFor(() =>
			expect(updateWorkspaceName).toHaveBeenLastCalledWith(
				"ws_02",
				"CGC 线上学院",
			),
		);
	});

	it("保存失败：显示错误提示（role=alert，透传后端 message）", async () => {
		updateWorkspaceName.mockRejectedValue(new Error("forbidden"));
		render(<SettingsPage />);

		const input = await screen.findByTestId("workspace-name-input");
		fireEvent.change(input, { target: { value: "新名" } });
		fireEvent.click(screen.getByRole("button", { name: "保存更改" }));

		const alert = await screen.findByRole("alert");
		expect(alert).toHaveTextContent("forbidden");
	});

	it("普通成员（无 update_join_policy）：shell 空态，不渲染输入框与保存按钮", async () => {
		params.value = { slug: "cgc-shanghai" };
		render(<SettingsPage />);

		expect(
			await screen.findByTestId("shell-no-permission"),
		).toHaveTextContent("此页面需要管理权限");
		expect(
			screen.queryByTestId("workspace-name-input"),
		).not.toBeInTheDocument();
		expect(
			screen.queryByRole("button", { name: "保存更改" }),
		).not.toBeInTheDocument();
		expect(updateWorkspaceName).not.toHaveBeenCalled();
	});

	it("PlatformAdmin 只读访客：输入框禁用 + 只读说明", async () => {
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
		expect(screen.getByTestId("workspace-name-input")).toBeDisabled();
		expect(screen.getByRole("button", { name: "保存更改" })).toBeDisabled();
		expect(updateWorkspaceName).not.toHaveBeenCalled();
	});
});
