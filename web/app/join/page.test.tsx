import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, screen, fireEvent } from "@testing-library/react";
import { render } from "@/test-utils";
import JoinPage from "./page";

const { router } = vi.hoisted(() => ({
	router: { push: vi.fn(), replace: vi.fn() },
}));
const { useAuthed } = vi.hoisted(() => ({ useAuthed: vi.fn() }));
const { searchParams } = vi.hoisted(() => ({
	searchParams: { get: vi.fn() },
}));
const { fetchWorkspaceBySlug } = vi.hoisted(() => ({
	fetchWorkspaceBySlug: vi.fn(),
}));
const { joinWorkspace } = vi.hoisted(() => ({ joinWorkspace: vi.fn() }));
const { createJoinRequest } = vi.hoisted(() => ({
	createJoinRequest: vi.fn(),
}));
const { validateInvitation } = vi.hoisted(() => ({
	validateInvitation: vi.fn(),
}));
const { acceptInvitation } = vi.hoisted(() => ({
	acceptInvitation: vi.fn(),
}));

vi.mock("next/navigation", () => ({
	useRouter: () => router,
	useSearchParams: () => searchParams,
	// ThemeProvider 依赖 usePathname 解析 workspace slug（ADR-0004）
	usePathname: () => "/join",
}));

vi.mock("@/lib/use-authed", () => ({ useAuthed }));

vi.mock("@/lib/requests", () => ({
	fetchWorkspaceBySlug,
	joinWorkspace,
	createJoinRequest,
}));

vi.mock("@/lib/invitations", () => ({
	validateInvitation,
	acceptInvitation,
	invitationRoleLabel: (role: string) =>
		role === "member" ? "成员（无标签）" : role,
}));

beforeEach(() => {
	vi.clearAllMocks();
	useAuthed.mockReturnValue({ authed: true, confirmed: true, userId: "u1" });
	searchParams.get.mockReturnValue(null);
});

afterEach(cleanup);

describe("/join 统一加入入口页", () => {
	it("未登录显示登录提示", async () => {
		useAuthed.mockReturnValue({ authed: false, confirmed: true, userId: null });
		render(<JoinPage />);

		expect(
			await screen.findByRole("link", { name: "去登录" }),
		).toBeInTheDocument();
	});

	it("已登录显示 slug 输入框", async () => {
		render(<JoinPage />);

		expect(
			await screen.findByPlaceholderText("输入工作区 slug，如 cgc-shanghai"),
		).toBeInTheDocument();
		expect(screen.getByRole("button", { name: "查找" })).toBeInTheDocument();
	});

	it("输入 slug 后查找工作台 → open 策略显示直接加入按钮", async () => {
		fetchWorkspaceBySlug.mockResolvedValue({
			id: "ws_1",
			slug: "test-open",
			name: "开放工作台",
			joinPolicy: "open",
			sponsorshipEnabled: true,
		});

		render(<JoinPage />);

		const input = await screen.findByPlaceholderText(
			"输入工作区 slug，如 cgc-shanghai",
		);
		fireEvent.change(input, { target: { value: "test-open" } });
		fireEvent.click(screen.getByRole("button", { name: "查找" }));

		expect(
			await screen.findByRole("heading", { name: "开放工作台" }),
		).toBeInTheDocument();
		expect(
			screen.getByRole("button", { name: "直接加入" }),
		).toBeInTheDocument();
	});

	it("request 策略显示申请表单", async () => {
		fetchWorkspaceBySlug.mockResolvedValue({
			id: "ws_2",
			slug: "test-request",
			name: "申请工作台",
			joinPolicy: "request",
			sponsorshipEnabled: true,
		});

		render(<JoinPage />);

		const input = await screen.findByPlaceholderText(
			"输入工作区 slug，如 cgc-shanghai",
		);
		fireEvent.change(input, { target: { value: "test-request" } });
		fireEvent.click(screen.getByRole("button", { name: "查找" }));

		expect(
			await screen.findByRole("heading", { name: "申请工作台" }),
		).toBeInTheDocument();
		expect(
			screen.getByRole("button", { name: "提交申请" }),
		).toBeInTheDocument();
		expect(
			screen.getByPlaceholderText("简单介绍一下自己…"),
		).toBeInTheDocument();
	});

	it("invite_only 策略显示邀请提示", async () => {
		fetchWorkspaceBySlug.mockResolvedValue({
			id: "ws_3",
			slug: "test-invite",
			name: "邀请工作台",
			joinPolicy: "invite_only",
			sponsorshipEnabled: true,
		});

		render(<JoinPage />);

		const input = await screen.findByPlaceholderText(
			"输入工作区 slug，如 cgc-shanghai",
		);
		fireEvent.change(input, { target: { value: "test-invite" } });
		fireEvent.click(screen.getByRole("button", { name: "查找" }));

		expect(
			await screen.findByRole("heading", { name: "邀请工作台" }),
		).toBeInTheDocument();
		expect(
			screen.getByText("该工作区为邀请制，需要有效邀请链接才能加入。"),
		).toBeInTheDocument();
	});

	it("open 直接加入 → 成功", async () => {
		fetchWorkspaceBySlug.mockResolvedValue({
			id: "ws_1",
			slug: "test-open",
			name: "开放工作台",
			joinPolicy: "open",
			sponsorshipEnabled: true,
		});
		joinWorkspace.mockResolvedValue({
			id: "ws_1",
			slug: "test-open",
			name: "开放工作台",
		});

		render(<JoinPage />);

		const input = await screen.findByPlaceholderText(
			"输入工作区 slug，如 cgc-shanghai",
		);
		fireEvent.change(input, { target: { value: "test-open" } });
		fireEvent.click(screen.getByRole("button", { name: "查找" }));

		await screen.findByRole("heading", { name: "开放工作台" });
		fireEvent.click(screen.getByRole("button", { name: "直接加入" }));

		expect(await screen.findByText("加入成功")).toBeInTheDocument();
	});

	it("request 提交申请 → 显示申请审批中", async () => {
		fetchWorkspaceBySlug.mockResolvedValue({
			id: "ws_2",
			slug: "test-request",
			name: "申请工作台",
			joinPolicy: "request",
			sponsorshipEnabled: true,
		});
		createJoinRequest.mockResolvedValue({
			id: "jr_new",
			workspaceId: "ws_2",
			userId: "me",
			status: "pending",
		});

		render(<JoinPage />);

		const input = await screen.findByPlaceholderText(
			"输入工作区 slug，如 cgc-shanghai",
		);
		fireEvent.change(input, { target: { value: "test-request" } });
		fireEvent.click(screen.getByRole("button", { name: "查找" }));

		await screen.findByRole("heading", { name: "申请工作台" });
		fireEvent.click(screen.getByRole("button", { name: "提交申请" }));

		expect(await screen.findByText("申请已提交")).toBeInTheDocument();
		expect(screen.getByText("申请审批中")).toBeInTheDocument();
	});

	it("?token=xxx 参数优先走邀请流程", async () => {
		searchParams.get.mockImplementation((key: string) =>
			key === "token" ? "valid_token" : null,
		);		validateInvitation.mockResolvedValue({
			id: "inv_1",
			workspaceId: "ws_1",
			tokenHash: "hash",
			inviterId: "admin_1",
			status: "active",
			workspaceName: "受邀工作台",
			workspaceSlug: "invite-ws",
			workspaceJoinPolicy: "invite_only",
			preauthorizedRoleNames: ["member"],
		});

		render(<JoinPage />);

		expect(
			await screen.findByRole("heading", { name: "受邀工作台" }),
		).toBeInTheDocument();
		expect(screen.getByText("成员（无标签）")).toBeInTheDocument();
		expect(screen.queryByText("member")).not.toBeInTheDocument();
		expect(
			screen.getByRole("button", { name: "确认加入" }),
		).toBeInTheDocument();
	});

	it("邀请 token 无效 → 显示错误", async () => {
		searchParams.get.mockImplementation((key: string) =>
			key === "token" ? "bad_token" : null,
		);
		validateInvitation.mockResolvedValue(null);

		render(<JoinPage />);

		expect(await screen.findByText("邀请无效")).toBeInTheDocument();
	});

	it("邀请已撤销 → 错误文案无重复「已」字（回归：曾显示「邀请已已撤销」）", async () => {
		searchParams.get.mockImplementation((key: string) =>
			key === "token" ? "revoked_token" : null,
		);
		validateInvitation.mockResolvedValue({
			id: "inv_revoked",
			workspaceId: "ws_1",
			tokenHash: "hash",
			inviterId: "admin_1",
			status: "revoked",
			workspaceName: "受邀工作台",
			workspaceSlug: "invite-ws",
			workspaceJoinPolicy: "invite_only",
			preauthorizedRoleNames: [],
		});

		render(<JoinPage />);

		expect(await screen.findByText("邀请已撤销")).toBeInTheDocument();
		expect(document.body.textContent).not.toContain("已已");
	});

	it("工作台不存在 → 显示错误", async () => {
		fetchWorkspaceBySlug.mockResolvedValue(null);

		render(<JoinPage />);

		const input = await screen.findByPlaceholderText(
			"输入工作区 slug，如 cgc-shanghai",
		);
		fireEvent.change(input, { target: { value: "no-such-ws" } });
		fireEvent.click(screen.getByRole("button", { name: "查找" }));

		expect(
			await screen.findByText(/工作区「no-such-ws」不存在/),
		).toBeInTheDocument();
	});

	it("?workspace=<slug> 参数预填并自动查找（E-9 expired join_request 重提链接落点）", async () => {
		searchParams.get.mockImplementation((key: string) =>
			key === "workspace" ? "auto-ws" : null,
		);
		fetchWorkspaceBySlug.mockResolvedValue({
			id: "ws_auto",
			slug: "auto-ws",
			name: "自动工作台",
			joinPolicy: "open",
			sponsorshipEnabled: true,
		});

		render(<JoinPage />);

		expect(
			await screen.findByRole("heading", { name: "自动工作台" }),
		).toBeInTheDocument();
		expect(fetchWorkspaceBySlug).toHaveBeenCalledWith("auto-ws");
		expect(
			screen.getByRole("button", { name: "直接加入" }),
		).toBeInTheDocument();
	});

	it("?workspace= 与 ?token= 并存 → token 流程优先，不自动查找", async () => {
		searchParams.get.mockImplementation((key: string) =>
			key === "token" ? "valid_token" : key === "workspace" ? "auto-ws" : null,
		);
		validateInvitation.mockResolvedValue({
			id: "inv_ws",
			workspaceId: "ws_1",
			tokenHash: "hash",
			inviterId: "admin_1",
			status: "active",
			workspaceName: "受邀工作台",
			workspaceSlug: "invite-ws",
			workspaceJoinPolicy: "invite_only",
			preauthorizedRoleNames: ["member"],
		});

		render(<JoinPage />);

		expect(
			await screen.findByRole("heading", { name: "受邀工作台" }),
		).toBeInTheDocument();
		expect(fetchWorkspaceBySlug).not.toHaveBeenCalled();
	});
});
