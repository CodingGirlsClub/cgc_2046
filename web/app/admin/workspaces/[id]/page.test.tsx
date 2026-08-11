import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, screen } from "@testing-library/react";
import { render } from "@/test-utils";
import AdminWorkspaceDetailPage from "./page";

const { router } = vi.hoisted(() => ({
	router: { push: vi.fn(), replace: vi.fn() },
}));
const { params } = vi.hoisted(() => ({ params: { id: "ws1" } }));
const { fetchWorkspaceMembers } = vi.hoisted(() => ({
	fetchWorkspaceMembers: vi.fn(),
}));
const { fetchInvitations } = vi.hoisted(() => ({
	fetchInvitations: vi.fn(),
}));
const { client } = vi.hoisted(() => ({
	client: { query: vi.fn(), mutate: vi.fn() },
}));

vi.mock("next/navigation", () => ({
	useRouter: () => router,
	useParams: () => params,
	usePathname: () => `/admin/workspaces/${params.id}`,
}));

vi.mock("@/lib/workspaces", () => ({ fetchWorkspaceMembers }));
vi.mock("@/lib/invitations", () => ({ fetchInvitations }));
vi.mock("@/lib/apollo-client", () => ({ client }));

const workspaceShape = {
	id: "ws1",
	slug: "cgc-academy",
	name: "CGC 学院",
	joinPolicy: "request",
	sponsorshipEnabled: true,
};

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
			roles: ["member"],
		},
	],
	endKeyset: null,
	count: 2,
};

function inviteShape(status: string, roleNames: string[] | null) {
	return {
		items: [
			{
				id: "inv1",
				workspaceId: "ws1",
				targetEmail: "newbie@example.com",
				preauthorizedRoleNames: roleNames,
				status,
				expiresAt: null,
			},
		],
		endKeyset: null,
		count: 1,
	};
}

beforeEach(() => {
	vi.clearAllMocks();
	client.query.mockReset().mockResolvedValue({
		data: { getWorkspaceById: workspaceShape },
	} as never);
	fetchWorkspaceMembers.mockReset().mockResolvedValue(membersShape);
});

afterEach(cleanup);

describe("/admin/workspaces/[id] 工作台详情", () => {
	it("渲染工作台信息与成员列表", async () => {
		fetchInvitations.mockResolvedValue({ items: [], endKeyset: null, count: 0 });

		render(<AdminWorkspaceDetailPage />);

		expect(await screen.findByText("CGC 学院")).toBeInTheDocument();
		expect(screen.getByText(/cgc-academy/)).toBeInTheDocument();
		expect(screen.getByText("Alice")).toBeInTheDocument();
		expect(screen.getByText("Bob")).toBeInTheDocument();
	});

	it("有 active Owner 邀请时显示 pending-owner 状态", async () => {
		fetchInvitations.mockResolvedValue(inviteShape("active", ["owner"]));

		render(<AdminWorkspaceDetailPage />);

		expect(await screen.findByText(/待指定 Owner/)).toBeInTheDocument();
	});

	it("无 active Owner 邀请时不显示 pending-owner", async () => {
		fetchInvitations.mockResolvedValue(inviteShape("used", ["owner"]));

		render(<AdminWorkspaceDetailPage />);

		await screen.findByText("CGC 学院");

		expect(screen.queryByText(/待指定 Owner/)).not.toBeInTheDocument();
	});
});
