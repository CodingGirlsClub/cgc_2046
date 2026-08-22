import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, fireEvent, screen, waitFor } from "@testing-library/react";
import { render } from "@/test-utils";
import InvitationsPage from "./page";

const { router } = vi.hoisted(() => ({
	router: { push: vi.fn(), replace: vi.fn() },
}));
const { useAuthed } = vi.hoisted(() => ({ useAuthed: vi.fn() }));
const { params } = vi.hoisted(() => ({
	params: { value: { slug: "cgc-academy" } },
}));
const { fetchMyWorkspaces } = vi.hoisted(() => ({
	fetchMyWorkspaces: vi.fn(),
}));
const { fetchInvitations } = vi.hoisted(() => ({
	fetchInvitations: vi.fn(),
}));
const { createInvitation } = vi.hoisted(() => ({
	createInvitation: vi.fn(),
}));
const { revokeInvitation } = vi.hoisted(() => ({
	revokeInvitation: vi.fn(),
}));

vi.mock("next/navigation", () => ({
	redirect: vi.fn(),
	permanentRedirect: vi.fn(),
	useRouter: () => router,
	useParams: () => params.value,
	usePathname: () => `/w/${params.value.slug}/settings/invitations`,
}));

vi.mock("@/lib/use-authed", () => ({ useAuthed }));

vi.mock("@/lib/workspaces", async (importOriginal) => {
	const mod = (await importOriginal()) as Record<string, unknown>;
	return { ...mod, fetchMyWorkspaces };
});

vi.mock("@/lib/invitations", () => ({
	fetchInvitations,
	createInvitation,
	revokeInvitation,
	invitationRoleLabel: (role: string) =>
		role === "member" ? "成员（无标签）" : role,
}));

const ADMIN_WORKSPACES = [
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
	},
];

const MEMBER_WORKSPACES = [
	{
		id: "ws_01",
		slug: "cgc-shanghai",
		name: "CGC 上海分社",
		joinPolicy: "open" as const,
		sponsorshipEnabled: true,
		myRoleNames: [],
		roles: [],
		myAbilities: ["view_workspace", "access_invite_only"],
		membershipStatus: "active" as const,
	},
];

const TEST_INVITATIONS = [
	{
		id: "inv_1",
		workspaceId: "ws_02",
		tokenHash: "hash_abc",
		inviterId: "admin_1",
		targetEmail: "user1@test.com",
		preauthorizedRoleNames: ["learner"],
		expiresAt: "2026-08-20T03:00:00Z",
		status: "active" as const,
	},
	{
		id: "inv_2",
		workspaceId: "ws_02",
		tokenHash: "hash_def",
		inviterId: "admin_1",
		targetEmail: null,
		preauthorizedRoleNames: null,
		expiresAt: null,
		status: "used" as const,
		acceptedBy: "u_1",
		acceptedAt: "2026-08-06T10:00:00Z",
	},
	{
		id: "inv_3",
		workspaceId: "ws_02",
		tokenHash: "hash_ghi",
		inviterId: "admin_1",
		targetEmail: "user3@test.com",
		preauthorizedRoleNames: ["member"],
		expiresAt: "2026-08-15T03:00:00Z",
		status: "revoked" as const,
	},
];

beforeEach(() => {
	vi.clearAllMocks();
	useAuthed.mockReturnValue({
		authed: true,
		confirmed: true,
		userId: "admin_1",
	});
	params.value = { slug: "cgc-academy" };
	fetchMyWorkspaces.mockResolvedValue(ADMIN_WORKSPACES);
	fetchInvitations.mockResolvedValue({
		items: TEST_INVITATIONS,
		endKeyset: null,
		count: 3,
	});
	createInvitation.mockResolvedValue({
		id: "inv_new",
		workspaceId: "ws_02",
		plainToken: "token_new",
		status: "active",
	});
	revokeInvitation.mockResolvedValue({ id: "inv_3", status: "revoked" });
});

afterEach(cleanup);

describe("/w/[slug]/settings/invitations 邀请管理页", () => {
	it("能力门控：无 manage_members 页面级拦截且不加载", async () => {
		params.value = { slug: "cgc-shanghai" };
		fetchMyWorkspaces.mockResolvedValue(MEMBER_WORKSPACES);
		render(<InvitationsPage />);

		// 页面级拦截（2026-08-22 决策）：壳渲染「需要管理权限」空态替代页面内容
		expect(
			await screen.findByTestId("shell-no-permission"),
		).toHaveTextContent("此页面需要管理权限");
		expect(fetchInvitations).not.toHaveBeenCalled();
	});

	it("管理员可见邀请列表", async () => {
		render(<InvitationsPage />);

		expect(await screen.findByText("user1@test.com")).toBeInTheDocument();
		expect(screen.getByText("user3@test.com")).toBeInTheDocument();
	});

	it("历史 member 预授权显示为成员（无标签）", async () => {
		render(<InvitationsPage />);

		expect(await screen.findByText("成员（无标签）")).toBeInTheDocument();
		expect(screen.queryByText("member")).not.toBeInTheDocument();
	});

	it("邀请列表显示状态标签", async () => {
		render(<InvitationsPage />);

		expect(await screen.findByText("有效")).toBeInTheDocument();
		expect(screen.getByText("已使用")).toBeInTheDocument();
		expect(screen.getByText("已撤销")).toBeInTheDocument();
	});

	it("active 邀请显示复制链接和撤销按钮（历史邀请无明文 token，复制按钮禁用）", async () => {
		render(<InvitationsPage />);

		const copyButtons = await screen.findAllByRole("button", {
			name: "复制链接",
		});
		expect(copyButtons).toHaveLength(1);
		// 列表项无 plainToken（来自 fetchInvitations，后端不返回明文），复制按钮禁用
		expect(copyButtons[0]).toBeDisabled();
		const revokeButtons = await screen.findAllByRole("button", {
			name: "撤销",
		});
		expect(revokeButtons).toHaveLength(1);
	});

	it("used/revoked 邀请不显示操作按钮", async () => {
		render(<InvitationsPage />);

		// 等待列表加载
		expect(await screen.findByText("user1@test.com")).toBeInTheDocument();
		// 只有 active 的 inv_1 有操作按钮
		expect(screen.getAllByRole("button", { name: "复制链接" })).toHaveLength(1);
	});

	it("创建表单：填写并提交", async () => {
		render(<InvitationsPage />);

		// 点击创建邀请按钮（header 中的）
		const createButtons = await screen.findAllByRole("button", {
			name: /创建邀请/,
		});
		// header 中的创建按钮（不含 plus icon 文本）
		fireEvent.click(createButtons[0]);

		// 表单出现
		expect(
			await screen.findByRole("heading", { name: "创建新邀请" }),
		).toBeInTheDocument();

		// 填写邮箱
		const emailInput = screen.getByPlaceholderText("user@example.com");
		fireEvent.change(emailInput, { target: { value: "newuser@test.com" } });

		// 选择角色
		const learnerCheckbox = screen.getByRole("checkbox", {
			name: "learner 角色",
		});
		fireEvent.click(learnerCheckbox);

		// 提交（表单中的创建按钮）
		const submitButtons = screen.getAllByRole("button", { name: "创建邀请" });
		// 表单中的按钮是第二个
		fireEvent.click(submitButtons[submitButtons.length - 1]);

		await waitFor(() => {
			expect(createInvitation).toHaveBeenCalledWith({
				workspaceId: "ws_02",
				inviterId: "admin_1",
				targetEmail: "newuser@test.com",
				preauthorizedRoleNames: ["learner"],
				expiresAt: null,
			});
		});
	});

	it("撤销邀请", async () => {
		render(<InvitationsPage />);

		const revokeButtons = await screen.findAllByRole("button", {
			name: "撤销",
		});
		fireEvent.click(revokeButtons[0]);

		await waitFor(() => {
			expect(revokeInvitation).toHaveBeenCalledWith("inv_1");
		});
	});

	it("无邀请时显示空态", async () => {
		fetchInvitations.mockResolvedValue({
			items: [],
			endKeyset: null,
			count: 0,
		});
		render(<InvitationsPage />);

		expect(await screen.findByText("暂无邀请记录")).toBeInTheDocument();
	});
});
