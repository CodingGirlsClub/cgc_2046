import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, screen, fireEvent } from "@testing-library/react";
import { render } from "@/test-utils";
import AdminUsersPage from "./page";

const { useAuthed } = vi.hoisted(() => ({ useAuthed: vi.fn() }));
const { fetchUsers, promoteUser, demoteUser } = vi.hoisted(() => ({
	fetchUsers: vi.fn(),
	promoteUser: vi.fn(),
	demoteUser: vi.fn(),
}));

vi.mock("@/lib/use-authed", () => ({ useAuthed }));
vi.mock("@/lib/admin", () => ({ fetchUsers, promoteUser, demoteUser }));

const users = [
	{
		id: "u1",
		email: "alice@example.com",
		displayName: "Alice",
		isPlatformAdmin: false,
		insertedAt: "2026-08-01T00:00:00Z",
		workspaceMembershipCount: 3,
	},
	{
		id: "u2",
		email: "bob@example.com",
		displayName: "Bob",
		isPlatformAdmin: true,
		insertedAt: "2026-08-02T00:00:00Z",
		workspaceMembershipCount: 1,
	},
];

beforeEach(() => {
	vi.clearAllMocks();
	useAuthed.mockReturnValue({ authed: true, confirmed: true, userId: "u1" });
});

afterEach(cleanup);

describe("/admin/users 用户列表", () => {
	it("渲染用户行（email/displayName/admin 徽章/membership 概要）", async () => {
		fetchUsers.mockResolvedValue(users);

		render(<AdminUsersPage />);

		expect(await screen.findByText("alice@example.com")).toBeInTheDocument();
		expect(screen.getByText("Alice")).toBeInTheDocument();
		expect(screen.getByText("bob@example.com")).toBeInTheDocument();
		expect(screen.getAllByText(/个成员/).length).toBeGreaterThan(0);
	});

	it("promote 非 admin 用户调用 promoteUser", async () => {
		fetchUsers.mockResolvedValue(users);
		promoteUser.mockResolvedValue({
			id: "u1",
			email: "alice@example.com",
			isPlatformAdmin: true,
			errors: [],
		});

		render(<AdminUsersPage />);
		await screen.findByText("alice@example.com");

		fireEvent.click(screen.getByRole("button", { name: /提升/ }));
		await vi.waitFor(() => expect(promoteUser).toHaveBeenCalledWith("u1"));
	});

	it("demote 其他 admin 用户直接调用 demoteUser（无确认弹窗）", async () => {
		fetchUsers.mockResolvedValue(users);
		demoteUser.mockResolvedValue({
			id: "u2",
			email: "bob@example.com",
			isPlatformAdmin: false,
			errors: [],
		});

		render(<AdminUsersPage />);
		await screen.findByText("bob@example.com");

		fireEvent.click(screen.getByRole("button", { name: /降级/ }));
		await vi.waitFor(() => expect(demoteUser).toHaveBeenCalledWith("u2"));
	});

	it("demote 自己（u1 是 admin）时弹确认框，确认后调用 demoteUser", async () => {
		const selfAdmin = [
			{
				id: "u1",
				email: "alice@example.com",
				displayName: "Alice",
				isPlatformAdmin: true,
				insertedAt: "2026-08-01T00:00:00Z",
				workspaceMembershipCount: 3,
			},
		];
		fetchUsers.mockResolvedValue(selfAdmin);
		demoteUser.mockResolvedValue({
			id: "u1",
			email: "alice@example.com",
			isPlatformAdmin: false,
			errors: [],
		});

		render(<AdminUsersPage />);
		await screen.findByText("alice@example.com");

		// 触发自降级 → 确认弹窗出现
		fireEvent.click(screen.getByRole("button", { name: /降级/ }));
		expect(await screen.findByText(/确认.*降级|确认降级/)).toBeInTheDocument();

		// 确认后调用 demoteUser
		fireEvent.click(screen.getByRole("button", { name: /确认/ }));
		await vi.waitFor(() => expect(demoteUser).toHaveBeenCalledWith("u1"));
	});

	it("demote 后端返回 last_admin_denied 错误时展示错误消息", async () => {
		fetchUsers.mockResolvedValue(users);
		demoteUser.mockResolvedValue({
			id: "u2",
			email: "bob@example.com",
			isPlatformAdmin: true,
			errors: [{ message: "cannot demote the last remaining platform admin", code: "last_admin_denied" }],
		});

		render(<AdminUsersPage />);
		await screen.findByText("bob@example.com");

		fireEvent.click(screen.getByRole("button", { name: /降级/ }));
		expect(await screen.findByText(/last remaining platform admin/i)).toBeInTheDocument();
	});

	it("搜索后 fetchUsers 带 search 重新拉取", async () => {
		fetchUsers.mockResolvedValue(users);

		render(<AdminUsersPage />);
		await screen.findByText("alice@example.com");

		fireEvent.change(screen.getByPlaceholderText(/搜索/), {
			target: { value: "alice" },
		});
		fireEvent.click(screen.getByRole("button", { name: "搜索" }));

		await vi.waitFor(() => {
			expect(fetchUsers).toHaveBeenLastCalledWith("alice", {
				first: 50,
				after: "0",
			});
		});
	});
});
