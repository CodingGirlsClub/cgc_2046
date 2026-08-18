import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, screen, fireEvent } from "@testing-library/react";
import { render } from "@/test-utils";
import AdminWorkspacesCreatePage from "./page";

const { router } = vi.hoisted(() => ({
	router: { push: vi.fn(), replace: vi.fn() },
}));
const { createWorkspaceWithOwner, fetchUsers } = vi.hoisted(() => ({
	createWorkspaceWithOwner: vi.fn(),
	fetchUsers: vi.fn(),
}));

vi.mock("next/navigation", () => ({
	redirect: vi.fn(),
	permanentRedirect: vi.fn(),
	useRouter: () => router,
	usePathname: () => "/admin/workspaces/create",
}));

vi.mock("@/lib/admin", () => ({ createWorkspaceWithOwner, fetchUsers }));

beforeEach(() => {
	vi.clearAllMocks();
});

afterEach(cleanup);

describe("/admin/workspaces/create 创建工作台", () => {
	it("填写元数据 + 选择已有用户 Owner → 提交 createWorkspaceWithOwner", async () => {
		fetchUsers.mockResolvedValue([
			{
				id: "u1",
				email: "alice@example.com",
				displayName: "Alice",
				isPlatformAdmin: false,
				insertedAt: "2026-08-01T00:00:00Z",
				workspaceMembershipCount: 0,
			},
		]);
		createWorkspaceWithOwner.mockResolvedValue({
			result: { id: "ws1", slug: "new-ws", name: "新工作台", joinPolicy: "request", sponsorshipEnabled: true },
			metadata: null,
			errors: [],
		});

		render(<AdminWorkspacesCreatePage />);

		fireEvent.change(screen.getByLabelText(/名称/), {
			target: { value: "新工作台" },
		});
		fireEvent.change(screen.getByLabelText(/slug/), {
			target: { value: "new-ws" },
		});

		// 选择已有用户：搜索 → 点击结果
		fireEvent.change(screen.getByPlaceholderText(/搜索用户/), {
			target: { value: "alice" },
		});
		fireEvent.click(screen.getByRole("button", { name: "搜索" }));

		fireEvent.click(await screen.findByText(/Alice/));

		fireEvent.click(screen.getByRole("button", { name: "创建工作台" }));

		await vi.waitFor(() => {
			expect(createWorkspaceWithOwner).toHaveBeenCalledWith({
				slug: "new-ws",
				name: "新工作台",
				joinPolicy: "request",
				ownerUserId: "u1",
			});
		});
	});

	it("邀请新用户 Owner（ownerEmail）→ 提交并显示邀请 token", async () => {
		createWorkspaceWithOwner.mockResolvedValue({
			result: { id: "ws2", slug: "invite-ws", name: "邀请工作台", joinPolicy: "request", sponsorshipEnabled: true },
			metadata: { ownerInvitationToken: "tok456" },
			errors: [],
		});

		render(<AdminWorkspacesCreatePage />);

		fireEvent.change(screen.getByLabelText(/名称/), {
			target: { value: "邀请工作台" },
		});
		fireEvent.change(screen.getByLabelText(/slug/), {
			target: { value: "invite-ws" },
		});

		// 切到邀请模式
		fireEvent.click(screen.getByLabelText(/邀请新用户/));
		fireEvent.change(screen.getByLabelText(/邀请邮箱/), {
			target: { value: "newbie@example.com" },
		});

		fireEvent.click(screen.getByRole("button", { name: "创建工作台" }));

		await vi.waitFor(() => {
			expect(createWorkspaceWithOwner).toHaveBeenCalledWith({
				slug: "invite-ws",
				name: "邀请工作台",
				joinPolicy: "request",
				ownerEmail: "newbie@example.com",
			});
		});

		expect(await screen.findByText(/tok456/)).toBeInTheDocument();
	});

	it("提交失败显示错误信息", async () => {
		createWorkspaceWithOwner.mockResolvedValue({
			result: null,
			errors: [{ message: "slug 已被占用", code: "invalid" }],
		});

		render(<AdminWorkspacesCreatePage />);

		fireEvent.change(screen.getByLabelText(/名称/), {
			target: { value: "新工作台" },
		});
		fireEvent.change(screen.getByLabelText(/slug/), {
			target: { value: "taken" },
		});

		fireEvent.click(screen.getByRole("button", { name: "创建工作台" }));

		expect(await screen.findByText("slug 已被占用")).toBeInTheDocument();
	});
});
