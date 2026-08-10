import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, screen, within } from "@testing-library/react";
import { render } from "@/test-utils";
import AgentsOpenclackyPage from "./page";

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
		`/w/${params.value.slug}/settings/integrations/agents/openclacky`,
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

describe("/w/[slug]/settings/integrations/agents/openclacky 集成 OpenClacky 页", () => {
	it("渲染四步接入引导 + 官方下载 iframe", async () => {
		render(<AgentsOpenclackyPage />);

		expect(
			screen.getByRole("heading", { name: "① 安装 OpenClacky" }),
		).toBeInTheDocument();
		expect(
			screen.getByRole("heading", { name: "② 安装 CGC-2046 连接器扩展" }),
		).toBeInTheDocument();
		expect(
			screen.getByRole("heading", { name: "③ 生成连接 token" }),
		).toBeInTheDocument();

		// 官方下载 iframe
		const installFrame = screen.getByTitle("下载 OpenClacky");
		expect(installFrame).toHaveAttribute(
			"src",
			"https://www.openclacky.com/claw/cgc?embed=1",
		);
	});

	it("扩展市场路径：含 #extensions 链接与搜索关键词", async () => {
		render(<AgentsOpenclackyPage />);

		expect(screen.getByText(/扩展市场中搜索安装/)).toBeInTheDocument();
		expect(screen.getByText("CGC-2046")).toBeInTheDocument();
		const mktLink = screen.getByRole("link", {
			name: "http://localhost:7070/#extensions",
		});
		expect(mktLink).toHaveAttribute("href", "http://localhost:7070/#extensions");
	});

	it("生成 token 按钮指向 MCP 页", async () => {
		render(<AgentsOpenclackyPage />);

		const tokenLink = screen.getByRole("link", { name: /生成 token/ });
		expect(tokenLink).toHaveAttribute(
			"href",
			"/w/cgc-academy/settings/integrations/agents/mcp",
		);
	});

	it("页内 Tab：OpenClacky 选中，其余三 tab 链接存在", async () => {
		render(<AgentsOpenclackyPage />);

		const tabs = await screen.findByRole("navigation", {
			name: "工作区设置页签",
		});
		for (const label of ["MCP", "OpenClacky", "opencode", "OMP"]) {
			expect(within(tabs).getByRole("link", { name: label }))
				.toBeInTheDocument();
		}
		expect(within(tabs).getByRole("link", { name: "OpenClacky" }))
			.toHaveAttribute(
				"href",
				"/w/cgc-academy/settings/integrations/agents/openclacky",
			);
	});
});
