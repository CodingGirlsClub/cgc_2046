import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, screen, fireEvent } from "@testing-library/react";
import { render } from "@/test-utils";
import AdminWorkspaceDetailPage from "./page";

const { router } = vi.hoisted(() => ({
	router: { push: vi.fn(), replace: vi.fn() },
}));
const { params } = vi.hoisted(() => ({ params: { id: "ws1" } }));
const { fetchWorkspaceMembers } = vi.hoisted(() => ({
	fetchWorkspaceMembers: vi.fn(),
}));
const { fetchInvitations, revokeInvitation } = vi.hoisted(() => ({
	fetchInvitations: vi.fn(),
	revokeInvitation: vi.fn(),
}));
const { fetchUsers, reassignWorkspaceOwner } = vi.hoisted(() => ({
	fetchUsers: vi.fn(),
	reassignWorkspaceOwner: vi.fn(),
}));
const { client } = vi.hoisted(() => ({
	client: { query: vi.fn(), mutate: vi.fn() },
}));

vi.mock("next/navigation", () => ({
	redirect: vi.fn(),
	permanentRedirect: vi.fn(),
	useRouter: () => router,
	useParams: () => params,
	usePathname: () => `/admin/workspaces/${params.id}`,
}));

vi.mock("@/lib/workspaces", () => ({ fetchWorkspaceMembers }));
vi.mock("@/lib/invitations", () => ({ fetchInvitations, revokeInvitation }));
vi.mock("@/lib/admin", () => ({ fetchUsers, reassignWorkspaceOwner }));
vi.mock("@/lib/apollo-client", () => ({ client }));

const workspaceShape = {
	id: "ws1",
	slug: "cgc-academy",
	name: "CGC 学院",
	joinPolicy: "request",
	sponsorshipEnabled: true,
};

/** 有 Owner 的成员列表（Alice=owner） */
const membersShape = {
	members: [
		{
			membershipId: "m1",
			userId: "u1",
			email: "alice@example.com",
			displayName: "Alice",
			roles: ["owner"],
		},
		{
			membershipId: "m2",
			userId: "u2",
			email: "bob@example.com",
			displayName: "Bob",
			roles: [],
		},
	],
	endKeyset: null,
	count: 2,
};

/** 无 Owner 的成员列表（pending-owner 状态） */
const membersNoOwner = {
	members: [
		{
			membershipId: "m2",
			userId: "u2",
			email: "bob@example.com",
			displayName: "Bob",
			roles: [],
		},
	],
	endKeyset: null,
	count: 1,
};

function inviteShape(
	status: string,
	roleNames: string[] | null,
	expiresAt: string | null = null,
) {
	return {
		items: [
			{
				id: "inv1",
				workspaceId: "ws1",
				targetEmail: "newbie@example.com",
				preauthorizedRoleNames: roleNames,
				status,
				expiresAt,
			},
		],
		endKeyset: null,
		count: 1,
	};
}

const emptyInvitations = { items: [], endKeyset: null, count: 0 };

beforeEach(() => {
	vi.clearAllMocks();
	client.query.mockReset().mockResolvedValue({
		data: { getWorkspaceById: workspaceShape },
	} as never);
	fetchWorkspaceMembers.mockReset().mockResolvedValue(membersShape);
	fetchInvitations.mockReset().mockResolvedValue(emptyInvitations);
	revokeInvitation.mockReset();
	fetchUsers.mockReset();
	reassignWorkspaceOwner.mockReset();
});

afterEach(cleanup);

describe("/admin/workspaces/[id] 工作台详情", () => {
	it("渲染工作台信息与成员列表", async () => {
		render(<AdminWorkspaceDetailPage />);

		expect(await screen.findByText("CGC 学院")).toBeInTheDocument();
		expect(screen.getByText(/cgc-academy/)).toBeInTheDocument();
		expect(screen.getByText("Alice")).toBeInTheDocument();
		expect(screen.getByText("Bob")).toBeInTheDocument();
		expect(screen.getByText("暂无角色")).toBeInTheDocument();
	});

	it("有 Owner 成员时不显示任何 Owner 状态提示（即使有 active Owner 邀请）", async () => {
		fetchInvitations.mockResolvedValue(inviteShape("active", ["owner"]));

		render(<AdminWorkspaceDetailPage />);

		await screen.findByText("CGC 学院");

		expect(screen.queryByText(/待指定 Owner/)).not.toBeInTheDocument();
		expect(screen.queryByText(/Owner 未就位/)).not.toBeInTheDocument();
		expect(screen.queryByText(/重指派 Owner/)).not.toBeInTheDocument();
	});

	it("无 Owner + active Owner 邀请 → 显示待指定 badge（含有效期）", async () => {
		fetchWorkspaceMembers.mockResolvedValue(membersNoOwner);
		fetchInvitations.mockResolvedValue(
			inviteShape("active", ["owner"], "2026-09-01T00:00:00Z"),
		);

		render(<AdminWorkspaceDetailPage />);

		const expectedDate = new Date("2026-09-01T00:00:00Z").toLocaleDateString(
			"zh-CN",
		);
		expect(
			await screen.findByText(
				`待指定 Owner（邀请待接受，有效期至 ${expectedDate}）`,
			),
		).toBeInTheDocument();
	});

	it("无 Owner + active Owner 邀请无 expiresAt → badge 不带日期段", async () => {
		fetchWorkspaceMembers.mockResolvedValue(membersNoOwner);
		fetchInvitations.mockResolvedValue(inviteShape("active", ["owner"]));

		render(<AdminWorkspaceDetailPage />);

		expect(
			await screen.findByText("待指定 Owner（邀请待接受）"),
		).toBeInTheDocument();
	});

	it("无 Owner + 无 active Owner 邀请 → 显示「Owner 未就位（无有效邀请）」", async () => {
		fetchWorkspaceMembers.mockResolvedValue(membersNoOwner);
		fetchInvitations.mockResolvedValue(inviteShape("used", ["owner"]));

		render(<AdminWorkspaceDetailPage />);

		expect(
			await screen.findByText("Owner 未就位（无有效邀请）"),
		).toBeInTheDocument();
		expect(screen.queryByText(/待指定 Owner/)).not.toBeInTheDocument();
	});

	it("取消邀请：点击调 revokeInvitation(inv.id) 并重新拉取数据", async () => {
		fetchWorkspaceMembers.mockResolvedValue(membersNoOwner);
		fetchInvitations.mockResolvedValue(inviteShape("active", ["owner"]));
		revokeInvitation.mockResolvedValue(
			inviteShape("revoked", ["owner"]).items[0],
		);

		render(<AdminWorkspaceDetailPage />);

		fireEvent.click(
			await screen.findByRole("button", { name: "取消邀请" }),
		);

		await vi.waitFor(() => {
			expect(revokeInvitation).toHaveBeenCalledWith("inv1");
		});
		// 成功后重新拉取 invitations（初始 1 次 + 撤销后 1 次）
		await vi.waitFor(() => {
			expect(fetchInvitations).toHaveBeenCalledTimes(2);
		});
	});

	it("重指派 Owner（ownerEmail 分支）：调 mutation 并展示返回的一次性 token", async () => {
		fetchWorkspaceMembers.mockResolvedValue(membersNoOwner);
		reassignWorkspaceOwner.mockResolvedValue({
			result: workspaceShape,
			errors: [],
			metadata: { ownerInvitationToken: "tok-reassign-1" },
		});

		render(<AdminWorkspaceDetailPage />);

		// 等待初始加载完成（无邀请 → 未就位 badge）
		await screen.findByText("Owner 未就位（无有效邀请）");

		// 切到邀请模式并填写邮箱
		fireEvent.click(screen.getByLabelText(/邀请新用户/));
		fireEvent.change(screen.getByLabelText(/邀请邮箱/), {
			target: { value: "newowner@example.com" },
		});

		fireEvent.click(screen.getByRole("button", { name: "重指派 Owner" }));

		await vi.waitFor(() => {
			expect(reassignWorkspaceOwner).toHaveBeenCalledWith("ws1", {
				ownerEmail: "newowner@example.com",
			});
		});
		expect(await screen.findByText(/tok-reassign-1/)).toBeInTheDocument();
	});

	it("重指派失败：展示后端 errors[].message", async () => {
		fetchWorkspaceMembers.mockResolvedValue(membersNoOwner);
		reassignWorkspaceOwner.mockResolvedValue({
			result: null,
			errors: [
				{
					message: "工作台已有 Owner，重指派仅适用于 pending-owner 期间",
					code: "invalid",
				},
			],
		});

		render(<AdminWorkspaceDetailPage />);

		await screen.findByText("Owner 未就位（无有效邀请）");

		fireEvent.click(screen.getByLabelText(/邀请新用户/));
		fireEvent.change(screen.getByLabelText(/邀请邮箱/), {
			target: { value: "newowner@example.com" },
		});

		fireEvent.click(screen.getByRole("button", { name: "重指派 Owner" }));

		expect(
			await screen.findByText(
				"工作台已有 Owner，重指派仅适用于 pending-owner 期间",
			),
		).toBeInTheDocument();
	});
});
