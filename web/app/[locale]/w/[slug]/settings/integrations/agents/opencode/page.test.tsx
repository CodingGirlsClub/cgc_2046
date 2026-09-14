import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, fireEvent, screen, within } from "@testing-library/react";
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
const { fetchMyOauthAuthorizations } = vi.hoisted(() => ({
	fetchMyOauthAuthorizations: vi.fn(),
}));

vi.mock("next/navigation", () => ({
	redirect: vi.fn(),
	permanentRedirect: vi.fn(),
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

vi.mock("@/lib/mcp", async (importOriginal) => {
	const mod = (await importOriginal()) as Record<string, unknown>;
	return { ...mod, fetchMyOauthAuthorizations };
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

const RELEASE = {
	version: "0.1.0",
	download_path: "/ext/learn-space.zip",
	sha256: "b".repeat(64),
};

/** 授权夹具：默认 pending（同意行已存在、宿主尚未换得凭证） */
const grant = {
	clientId: "cli_1",
	clientName: "opencode",
	scope: "cgc",
	grantedAt: null,
	lastUsedAt: null,
	status: "pending" as const,
};

beforeEach(() => {
	vi.clearAllMocks();
	useAuthed.mockReturnValue({ authed: true, confirmed: true, userId: "u_1" });
	params.value = { slug: "cgc-academy" };
	fetchMyWorkspaces.mockResolvedValue(WORKSPACES);
	fetchMyOauthAuthorizations.mockResolvedValue([]);
	vi.stubGlobal(
		"fetch",
		vi.fn().mockResolvedValue({ ok: true, json: async () => RELEASE }),
	);
});

afterEach(() => {
	cleanup();
	vi.unstubAllGlobals();
});

describe("/w/[slug]/settings/integrations/agents/opencode 集成 opencode 页（U8 五步链）", () => {
	it("五步卡链渲染完整：①安装 → ②模型 → ③学习空间 → ④授权 → ⑤验证", async () => {
		render(<AgentsOpencodePage />);

		expect(
			screen.getByRole("heading", { name: "opencode" }),
		).toBeInTheDocument();
		for (const label of [
			"① 安装 opencode Desktop",
			"② 获取一个可用的模型",
			"③ 打开学习空间",
			"④ 授权连接",
			"⑤ 验证连接",
		]) {
			expect(screen.getByRole("heading", { name: label })).toBeInTheDocument();
		}
		// 五步旅程不含任何 token 操作；判定来源与重启提示在链内明示
		expect(screen.getByText(/全程不需要任何 token/)).toBeInTheDocument();
		expect(screen.getByText(/会把它标为「最近使用」/)).toBeInTheDocument();
		expect(screen.getByText(/只在重新打开后生效/)).toBeInTheDocument();
	});

	it("③ 深链按钮指向约定目录（URL 编码）并带手动回退；下载为 zip 直链", async () => {
		render(<AgentsOpencodePage />);

		const deepLink = screen.getByRole("link", {
			name: "用 opencode 打开学习空间",
		});
		expect(deepLink).toHaveAttribute(
			"href",
			`opencode://open-project?directory=${encodeURIComponent("~/Documents/CGC-2046")}`,
		);
		expect(
			screen.getByText(/手动选中上面那个 CGC-2046 文件夹/),
		).toBeInTheDocument();
		expect(
			screen.getByRole("link", { name: "下载学习空间包" }),
		).toHaveAttribute(
			"href",
			"https://api.codingirlsclub.com/ext/learn-space.zip",
		);
	});

	it("③ 展示发布版本与 sha256（三键 JSON）", async () => {
		render(<AgentsOpencodePage />);

		const release = await screen.findByTestId("learn-space-release");
		expect(release).toHaveTextContent("当前发布版本 0.1.0");
		expect(release).toHaveTextContent(RELEASE.sha256);
	});

	it("开发者选项默认收起，仍含手动配置（签发入口 + opencode.json + 注意事项）", async () => {
		render(<AgentsOpencodePage />);

		const fold = screen.getByTestId("opencode-developer-options");
		expect(fold).not.toHaveAttribute("open");
		expect(
			screen.getByText("开发者选项：手动配置（不推荐）"),
		).toBeInTheDocument();
		const pre = screen.getByText(
			(_, el) =>
				el?.tagName === "CODE" && el.textContent?.includes('"type": "remote"'),
		);
		expect(pre).toHaveTextContent('"oauth": false');
		expect(pre).toHaveTextContent("{env:CGC_TOKEN}");
		expect(screen.getByRole("link", { name: "MCP 页" })).toHaveAttribute(
			"href",
			"/w/cgc-academy/settings/integrations/agents/mcp",
		);
		// 手动路径的注意事项（合并条目）也随折叠保留
		expect(screen.getByText(/勿整体覆盖/)).toBeInTheDocument();
	});

	it("④ 等待态：有同意行 → 「授权进行中」；「检查状态」重查后 → 已授权", async () => {
		fetchMyOauthAuthorizations.mockResolvedValue([grant]);
		render(<AgentsOpencodePage />);

		expect(await screen.findByText("授权进行中")).toBeInTheDocument();

		fetchMyOauthAuthorizations.mockResolvedValue([
			{ ...grant, status: "active", grantedAt: "2026-09-15T10:00:00Z" },
		]);
		fireEvent.click(
			screen.getByRole("button", { name: "我已授权，检查状态" }),
		);

		expect(
			await screen.findByText(/已授权连接，回到 opencode 的会话/),
		).toBeInTheDocument();
	});

	it("④ 等待态：无授权记录 → 「尚未触发授权」并给回第②步 / 重启宿主恢复动作", async () => {
		render(<AgentsOpencodePage />);

		expect(await screen.findByText("还没看到授权页")).toBeInTheDocument();
		expect(
			screen.getByText(/回到第②步确认模型能正常回复/),
		).toBeInTheDocument();
		// 回调超时 / 端口占用恢复入口在此卡（同意页不承载）
		expect(screen.getByText(/127\.0\.0\.1:19876/)).toBeInTheDocument();
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
