import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { screen, cleanup, within } from "@testing-library/react";
import { render } from "@/test-utils";
import WorkspaceShell from "./workspace-shell";

/**
 * EN locale 回归钉测：URL 带 /en 前缀时壳的 pathname 判定（isSettings /
 * navSection 激活态）必须仍然成立。
 *
 * 根因（2026-08-22 诊断）：壳曾用裸 next/navigation 的 usePathname，EN
 * （localePrefix "as-needed"，非默认 locale 带 /en）下返回 /en/w/...，
 * startsWith(`/w/${slug}/settings`) 恒 false —— 设置页错渲染工作区导航、
 * 激活态失效；zh-CN 默认 locale 无前缀不受影响。
 */

const ADMIN_WS = {
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
		"manage_events",
	],
	membershipStatus: "active" as const,
	memberCount: 3,
};

const { pathnameRef } = vi.hoisted(() => ({
	pathnameRef: { value: "/w/cgc-academy" },
}));
const { useAuthed } = vi.hoisted(() => ({ useAuthed: vi.fn() }));
const { fetchMyWorkspaces, fetchCurrentProfile } = vi.hoisted(() => ({
	fetchMyWorkspaces: vi.fn(),
	fetchCurrentProfile: vi.fn(),
}));

vi.mock("next/navigation", () => ({
	// 真实环境：next/navigation 的 usePathname 返回浏览器地址原样（含 locale 前缀）
	usePathname: () => pathnameRef.value,
	useRouter: () => ({ push: vi.fn(), replace: vi.fn(), prefetch: vi.fn() }),
	useParams: () => ({}),
	redirect: vi.fn(),
	permanentRedirect: vi.fn(),
}));
vi.mock("@/lib/use-authed", () => ({ useAuthed }));
vi.mock("@/lib/auth", () => ({
	isAuthenticated: () => true,
	clearAuthToken: vi.fn(),
	clearSession: vi.fn().mockResolvedValue({ ok: true }),
}));
vi.mock("@/lib/workspaces", async (importOriginal) => {
	const mod = (await importOriginal()) as Record<string, unknown>;
	return { ...mod, fetchMyWorkspaces };
});
vi.mock("@/lib/profile", async (importOriginal) => {
	const mod = (await importOriginal()) as Record<string, unknown>;
	return { ...mod, fetchCurrentProfile };
});

beforeEach(() => {
	vi.clearAllMocks();
	useAuthed.mockReturnValue({ authed: true, confirmed: true });
	fetchMyWorkspaces.mockResolvedValue([ADMIN_WS]);
	fetchCurrentProfile.mockResolvedValue({
		id: "u_01",
		email: "admin@example.com",
		displayName: "Admin",
		avatarUrl: null,
		isPlatformAdmin: false,
	});
});

afterEach(cleanup);

describe("WorkspaceShell 的 locale 前缀路径判定", () => {
	it("EN（/en 前缀）：设置路由仍渲染设置侧栏（Back to app + 激活态）", async () => {
		pathnameRef.value = "/en/w/cgc-academy/settings/join-policy";
		render(
			<WorkspaceShell slug="cgc-academy">
				<div>content</div>
			</WorkspaceShell>,
			{ locale: "en" },
		);

		// isSettings 判定成立 → 设置侧栏的「Back to app」出现
		expect(
			await screen.findByRole("link", { name: "Back to app" }),
		).toBeInTheDocument();
		// navSection 激活态成立 → 加入策略项 aria-current=page
		const current = screen
			.getAllByRole("link")
			.filter((l) => l.getAttribute("aria-current") === "page");
		expect(current).toHaveLength(1);
		expect(current[0].getAttribute("href")).toContain("/settings/join-policy");
	});

	it("zh-CN（默认 locale 无前缀）：设置路由渲染设置侧栏（回归对照）", async () => {
		pathnameRef.value = "/w/cgc-academy/settings/join-policy";
		render(
			<WorkspaceShell slug="cgc-academy">
				<div>content</div>
			</WorkspaceShell>,
		);

		expect(
			await screen.findByRole("link", { name: "Back to app" }),
		).toBeInTheDocument();
		const current = screen
			.getAllByRole("link")
			.filter((l) => l.getAttribute("aria-current") === "page");
		expect(current).toHaveLength(1);
		expect(current[0].getAttribute("href")).toContain("/settings/join-policy");
	});
});

describe("WorkspaceShell 设置侧栏 Agents 入口（P2 回归）", () => {
	it("侧栏 Agents 链接指向区根（不带 /mcp 后缀），区根路径下激活态命中", async () => {
		// 直达 /mcp 子页时，已接入用户全站无路可达区入口页（管理态与「重新查看引导」）
		pathnameRef.value = "/w/cgc-academy/settings/integrations/agents";
		render(
			<WorkspaceShell slug="cgc-academy">
				<div>content</div>
			</WorkspaceShell>,
		);

		const nav = await screen.findByRole("navigation", { name: "集成" });
		const link = within(nav).getByRole("link", { name: "Agents" });
		expect(link).toHaveAttribute(
			"href",
			"/w/cgc-academy/settings/integrations/agents",
		);
		// navSection 的 startsWith 前缀匹配：区根与子页同样命中激活态
		expect(link).toHaveAttribute("aria-current", "page");
	});
});
