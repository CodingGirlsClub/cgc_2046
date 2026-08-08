import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, screen } from "@testing-library/react";
import { render } from "@/test-utils";
import WorkspaceSwitcherMenu from "./workspace-switcher-menu";
import type { WorkspaceListItem } from "@/lib/workspaces";

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
	render(
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

describe("WorkspaceSwitcherMenu（plan 016：邀请管理链接按 manage_members 门控）", () => {
	beforeEach(() => vi.clearAllMocks());
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

	it("有 manage_members：渲染邀请管理链接", () => {
		renderMenu(["manage_members"]);
		expect(screen.getByRole("menuitem", { name: "邀请管理" })).toHaveAttribute(
			"href",
			"/w/cgc-academy/settings/invitations",
		);
	});
});
