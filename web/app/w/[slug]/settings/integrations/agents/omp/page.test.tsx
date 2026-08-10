import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, screen, within } from "@testing-library/react";
import { render } from "@/test-utils";
import AgentsOmpPage from "./page";

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
	usePathname: () => `/w/${params.value.slug}/settings/integrations/agents/omp`,
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
		myRoleNames: ["member"],
		roles: ["member"],
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

describe("/w/[slug]/settings/integrations/agents/omp 集成 OMP 页", () => {
	it("渲染 H1 与 MCP 页 token 入口链接", async () => {
		render(<AgentsOmpPage />);

		expect(screen.getByRole("heading", { name: "OMP" })).toBeInTheDocument();
		const mcpLink = screen.getByRole("link", { name: "MCP 页" });
		expect(mcpLink).toHaveAttribute(
			"href",
			"/w/cgc-academy/settings/integrations/agents/mcp",
		);
	});

	it("渲染 .mcp.json 配置：mcpServers + type http + 环境变量插值", async () => {
		render(<AgentsOmpPage />);

		expect(
			screen.getByRole("heading", { name: "2. 写入 .mcp.json" }),
		).toBeInTheDocument();
		const pre = screen.getByText(
			(_, el) => el?.tagName === "CODE" && el.textContent?.includes('"mcpServers"'),
		);
		expect(pre).toHaveTextContent('"type": "http"');
		expect(pre).toHaveTextContent("${CGC_TOKEN}");
		expect(pre).toHaveTextContent('"cgc-2046"');
	});

	it("渲染 MCP URL 与 token 替换说明", async () => {
		render(<AgentsOmpPage />);

		expect(screen.getByText(/localhost:4102\/mcp/)).toBeInTheDocument();
		expect(
			screen.getByText(/omp 支持环境变量插值/),
		).toBeInTheDocument();
		expect(screen.getAllByText(/绑用户不绑工作区/).length).toBeGreaterThan(0);
	});

	it("页内 Tab：四 tab 齐全且 OMP 高亮", async () => {
		render(<AgentsOmpPage />);

		const tabs = await screen.findByRole("navigation", {
			name: "工作区设置页签",
		});
		for (const label of ["MCP", "OpenClacky", "opencode", "OMP"]) {
			expect(within(tabs).getByRole("link", { name: label }))
				.toBeInTheDocument();
		}
		expect(within(tabs).getByRole("link", { name: "OMP" })).toHaveAttribute(
			"href",
			"/w/cgc-academy/settings/integrations/agents/omp",
		);
	});
});
