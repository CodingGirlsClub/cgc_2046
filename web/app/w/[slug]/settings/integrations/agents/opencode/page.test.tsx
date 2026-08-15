import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, screen, within } from "@testing-library/react";
import { render } from "@/test-utils";
import AgentsOpencodePage from "./page";

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

vi.mock("next/navigation", () => ({
	useRouter: () => router,
	useParams: () => params.value,
	usePathname: () =>
		`/w/${params.value.slug}/settings/integrations/agents/opencode`,
}));

vi.mock("@/lib/use-authed", () => ({ useAuthed }));

vi.mock("@/lib/workspaces", async (importOriginal) => {
	const mod = (await importOriginal()) as Record<string, unknown>;
	return { ...mod, fetchMyWorkspaces };
});

const WORKSPACES = [
	{
		id: "ws_02",
		slug: "cgc-academy",
		name: "CGC 线上学院",
		joinPolicy: "request" as const,
		sponsorshipEnabled: true,
		myRoleNames: [],
		roles: [],
		myAbilities: ["view_workspace", "access_invite_only"],
		membershipStatus: "active" as const,
	},
];

beforeEach(() => {
	vi.clearAllMocks();
	useAuthed.mockReturnValue({ authed: true, confirmed: true, userId: "u_1" });
	params.value = { slug: "cgc-academy" };
	fetchMyWorkspaces.mockResolvedValue(WORKSPACES);
});

afterEach(cleanup);

describe("/w/[slug]/settings/integrations/agents/opencode 集成 opencode 页", () => {
	it("渲染 H1 与 MCP 页 token 入口链接", async () => {
		render(<AgentsOpencodePage />);

		expect(
			screen.getByRole("heading", { name: "opencode" }),
		).toBeInTheDocument();
		const mcpLink = screen.getByRole("link", { name: "MCP 页" });
		expect(mcpLink).toHaveAttribute(
			"href",
			"/w/cgc-academy/settings/integrations/agents/mcp",
		);
	});

	it("渲染 opencode.json 配置：type remote + oauth:false + env 插值", async () => {
		render(<AgentsOpencodePage />);

		expect(
			screen.getByRole("heading", { name: "2. 写入 opencode.json" }),
		).toBeInTheDocument();
		// 配置片段含 remote / oauth / env 插值
		const pre = screen.getByText(
			(_, el) => el?.tagName === "CODE" && el.textContent?.includes('"type": "remote"'),
		);
		expect(pre).toHaveTextContent('"oauth": false');
		expect(pre).toHaveTextContent("{env:CGC_TOKEN}");
		expect(pre).toHaveTextContent('"cgc-2046"');
	});

	it("渲染 MCP URL 与 token 替换说明", async () => {
		render(<AgentsOpencodePage />);

		expect(screen.getByText(/localhost:4102\/mcp/)).toBeInTheDocument();
		expect(
			screen.getByText(/opencode 支持环境变量插值/),
		).toBeInTheDocument();
		expect(screen.getAllByText(/绑用户不绑工作区/).length).toBeGreaterThan(0);
	});

	it("页内 Tab：四 tab 齐全且 opencode 高亮", async () => {
		render(<AgentsOpencodePage />);

		const tabs = await screen.findByRole("navigation", {
			name: "工作区设置页签",
		});
		for (const label of ["MCP", "OpenClacky", "opencode", "OMP"]) {
			expect(within(tabs).getByRole("link", { name: label }))
				.toBeInTheDocument();
		}
		expect(within(tabs).getByRole("link", { name: "opencode" }))
			.toHaveAttribute(
				"href",
				"/w/cgc-academy/settings/integrations/agents/opencode",
			);
	});
});
