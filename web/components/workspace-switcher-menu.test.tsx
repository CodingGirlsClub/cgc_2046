import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, fireEvent, screen } from "@testing-library/react";
import { render } from "@/test-utils";
import WorkspaceSwitcherMenu from "./workspace-switcher-menu";
import type { WorkspaceListItem } from "@/lib/workspaces";
import { PENDING_APPROVALS_COUNT } from "@/lib/graphql/approvals";

const { useAuthed } = vi.hoisted(() => ({ useAuthed: vi.fn() }));
const { useQuery } = vi.hoisted(() => ({ useQuery: vi.fn() }));

vi.mock("@/lib/use-authed", () => ({ useAuthed }));
vi.mock("@apollo/client/react", () => ({ useQuery }));


// ThemeToggle 在二级菜单渲染时依赖 apollo singleton；mock 掉避免真实 client 副作用
vi.mock("@/lib/apollo-client", () => ({
	client: {
		mutate: vi.fn().mockResolvedValue({
			data: { setWorkspaceTheme: { id: "u1", uiThemePreference: "light" } },
		}),
	},
}));

const WORKSPACES: WorkspaceListItem[] = [
	{
		id: "ws_02",
		slug: "cgc-academy",
		name: "CGC 线上学院",
		joinPolicy: "request",
		sponsorshipEnabled: true,
		myRoleNames: ["admin"],
		roles: ["admin"],
		myAbilities: ["manage_members"],
		membershipStatus: "active",
	},
];

function renderMenu(abilities: string[]) {
	return render(
		<WorkspaceSwitcherMenu
			workspaces={WORKSPACES}
			currentSlug="cgc-academy"
			currentWorkspaceId="ws_02"
			abilities={abilities}
			profile={{
				id: "u_0202",
				email: "chenyu@cgc2046.org",
				displayName: "陈雨",
				isPlatformAdmin: false,
			}}
			onNavigate={() => {}}
			onSignOut={() => {}}
		/>,
	);
}

function mockCountQuery(count: number | undefined, error?: Error) {
	useQuery.mockReturnValue({
		data: count === undefined ? undefined : { pendingApprovalsCount: count },
		loading: false,
		error,
	});
}

function openAccountMenu() {
	fireEvent.click(screen.getByRole("menuitem", { name: "Switch workspace" }));
	return screen.getAllByRole("menu")[1];
}


describe("WorkspaceSwitcherMenu（plan 016：邀请管理链接按 manage_members 门控）", () => {
	beforeEach(() => {
		vi.clearAllMocks();
		useAuthed.mockReturnValue({ authed: true, confirmed: true });
		mockCountQuery(0);
	});
	afterEach(() => cleanup());

	it("无 manage_members：一级菜单不渲染邀请管理，Settings 仍可见", () => {
		renderMenu(["view_workspace", "access_invite_only"]);
		expect(
			screen.queryByRole("menuitem", { name: "邀请管理" }),
		).not.toBeInTheDocument();
		expect(screen.getByRole("menuitem", { name: "Settings" })).toHaveAttribute(
			"href",
			"/w/cgc-academy/settings/account/preferences",
		);
	});

	it("plan 020 U1：一级菜单渲染 Agents 项（当前 workspace agents 页）", () => {
		renderMenu([]);
		expect(screen.getByRole("menuitem", { name: "Agents" })).toHaveAttribute(
			"href",
			"/w/cgc-academy/agents",
		);
	});

	it("P2 回归：MCP 项指向 Agents 区根（直达 /mcp 会让已接入用户无路可达入口页）", () => {
		renderMenu([]);
		expect(screen.getByRole("menuitem", { name: "MCP" })).toHaveAttribute(
			"href",
			"/w/cgc-academy/settings/integrations/agents",
		);
	});

	it("有 manage_members：渲染邀请管理链接", () => {
		renderMenu(["manage_members"]);
		expect(screen.getByRole("menuitem", { name: "邀请管理" })).toHaveAttribute(
			"href",
			"/w/cgc-academy/settings/invitations",
		);
	});
	it("count 3：审批入口显示角标且 accessible name 含待办数", () => {
		mockCountQuery(3);
		renderMenu(["manage_members"]);

		const sub = openAccountMenu();
		const approvals = screen.getByRole("menuitem", { name: "审批中心，3 项待办" });

		expect(approvals).toHaveAttribute("href", "/approvals");
		expect(approvals.querySelector(".l-badge.l-badge-pending")).toHaveTextContent("3");
		expect(sub).toContainElement(approvals);
	});

	it("count 0：审批入口不渲染角标", () => {
		mockCountQuery(0);
		renderMenu(["manage_members"]);
		openAccountMenu();

		const approvals = screen.getByRole("menuitem", { name: "审批中心" });
		expect(approvals.querySelector(".l-badge")).not.toBeInTheDocument();
	});

	it("未登录：跳过计数查询且不渲染角标", () => {
		useAuthed.mockReturnValue({ authed: false, confirmed: true });
		mockCountQuery(undefined);
		renderMenu(["manage_members"]);

		expect(useQuery).toHaveBeenCalledWith(
			PENDING_APPROVALS_COUNT,
			expect.objectContaining({ skip: true, fetchPolicy: "no-cache" }),
		);
		openAccountMenu();
		expect(screen.getByRole("menuitem", { name: "审批中心" })).toBeInTheDocument();
	});

	it("计数查询错误：菜单正常渲染且静默不显示角标", () => {
		mockCountQuery(undefined, new Error("network"));
		renderMenu(["manage_members"]);
		openAccountMenu();

		expect(screen.getByRole("menuitem", { name: "审批中心" })).toBeInTheDocument();
		expect(screen.queryByText("network")).not.toBeInTheDocument();
	});

	it("count 大于 99：角标显示 99+", () => {
		mockCountQuery(120);
		renderMenu(["manage_members"]);
		openAccountMenu();

		const approvals = screen.getByRole("menuitem", { name: "审批中心，120 项待办" });
		expect(approvals.querySelector(".l-badge.l-badge-pending")).toHaveTextContent("99+");
	});

	it("重挂载获取新计数，并固定 no-cache 查询策略", () => {
		useQuery.mockReset();
		useQuery.mockReturnValue({
			data: { pendingApprovalsCount: 2 },
			loading: false,
			error: undefined,
		});

		const first = renderMenu(["manage_members"]);
		openAccountMenu();
		expect(screen.getByRole("menuitem", { name: "审批中心，2 项待办" })).toBeInTheDocument();
		first.unmount();
		useQuery.mockReturnValue({
			data: { pendingApprovalsCount: 4 },
			loading: false,
			error: undefined,
		});

		renderMenu(["manage_members"]);
		openAccountMenu();
		expect(screen.getByRole("menuitem", { name: "审批中心，4 项待办" })).toBeInTheDocument();
		expect(useQuery).toHaveBeenNthCalledWith(
			1,
			PENDING_APPROVALS_COUNT,
			expect.objectContaining({ fetchPolicy: "no-cache" }),
		);
		expect(useQuery).toHaveBeenNthCalledWith(
			2,
			PENDING_APPROVALS_COUNT,
			expect.objectContaining({ fetchPolicy: "no-cache" }),
		);
	});

	it("与 plan 014 的「我的参与」入口共存", () => {
		mockCountQuery(3);
		renderMenu(["manage_members"]);
		openAccountMenu();

		expect(screen.getByRole("menuitem", { name: "我的参与" })).toHaveAttribute(
			"href",
			"/participations",
		);
		expect(screen.getByRole("menuitem", { name: "审批中心，3 项待办" })).toHaveAttribute(
			"href",
			"/approvals",
		);
	});
});
