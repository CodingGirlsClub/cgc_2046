import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, fireEvent, screen, waitFor } from "@testing-library/react";
import { render } from "@/test-utils";
import ConnectGuidePage from "./page";

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
const { fetchMyMcpTokens } = vi.hoisted(() => ({ fetchMyMcpTokens: vi.fn() }));
const { issueMcpToken } = vi.hoisted(() => ({ issueMcpToken: vi.fn() }));
const { clipboardWrite } = vi.hoisted(() => ({ clipboardWrite: vi.fn() }));

vi.mock("next/navigation", () => ({
	useRouter: () => router,
	useParams: () => params.value,
	usePathname: () => `/w/${params.value.slug}/connect`,
}));

vi.mock("@/lib/use-authed", () => ({ useAuthed }));

vi.mock("@/lib/workspaces", async (importOriginal) => {
	const mod = (await importOriginal()) as Record<string, unknown>;
	return { ...mod, fetchMyWorkspaces };
});

vi.mock("@/lib/mcp", async (importOriginal) => {
	const mod = (await importOriginal()) as Record<string, unknown>;
	return { ...mod, fetchMyMcpTokens, issueMcpToken };
});

Object.defineProperty(navigator, "clipboard", {
	value: { writeText: clipboardWrite },
	configurable: true,
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
	clipboardWrite.mockResolvedValue(undefined);
	useAuthed.mockReturnValue({ authed: true, confirmed: true, userId: "u_1" });
	params.value = { slug: "cgc-academy" };
	fetchMyWorkspaces.mockResolvedValue(WORKSPACES);
	fetchMyMcpTokens.mockResolvedValue([]);
	issueMcpToken.mockResolvedValue({
		token: {
			id: "tok_new",
			name: "向导签发",
			lastUsedAt: null,
			revokedAt: null,
			insertedAt: "2026-08-08T18:00:00Z",
			status: "active" as const,
		},
		plainToken: "cgc_guide_plain_token",
	});
});

afterEach(cleanup);

describe("/w/[slug]/connect 连接引导页（三步向导）", () => {
	it("初始显示第 1 步（安装客户端）与三步进度", async () => {
		render(<ConnectGuidePage />);

		expect(await screen.findByText("安装 MCP 客户端")).toBeInTheDocument();
		// 进度指示包含三步名称
		expect(screen.getByText("生成连接 token")).toBeInTheDocument();
		expect(screen.getByText("拷贝配置")).toBeInTheDocument();
		// 三个客户端安装说明 Tab
		expect(screen.getByRole("tab", { name: "OpenClacky" }))
			.toBeInTheDocument();
		expect(screen.getByRole("tab", { name: "omp" })).toBeInTheDocument();
		expect(screen.getByRole("tab", { name: "opencode" }))
			.toBeInTheDocument();
	});

	it("按序走通：1 安装 → 2 签发明文展示 → 3 配置片段", async () => {
		render(<ConnectGuidePage />);

		// 第 1 步 → 第 2 步
		fireEvent.click(await screen.findByRole("button", { name: "下一步" }));
		expect(
			await screen.findByPlaceholderText("如：我的 Mac"),
		).toBeInTheDocument();

		// 第 2 步：签发
		fireEvent.change(screen.getByPlaceholderText("如：我的 Mac"), {
			target: { value: "向导签发" },
		});
		fireEvent.click(screen.getByRole("button", { name: "签发" }));
		await waitFor(() => {
			expect(issueMcpToken).toHaveBeenCalledWith("向导签发");
		});
		expect(
			await screen.findByText("cgc_guide_plain_token"),
		).toBeInTheDocument();
		expect(screen.getByText(/只显示这一次/)).toBeInTheDocument();

		// 第 2 步 → 第 3 步
		fireEvent.click(screen.getByRole("button", { name: "下一步" }));
		// 第 3 步：配置片段（默认 OpenClacky）
		expect(await screen.findByText(/"mcpServers"/)).toBeInTheDocument();
		fireEvent.click(screen.getByRole("tab", { name: "opencode" }));
		expect(await screen.findByText(/\{env:CGC_TOKEN\}/)).toBeInTheDocument();
	});

	it("已有有效 token 时第 2 步可跳过签发", async () => {
		fetchMyMcpTokens.mockResolvedValue([
			{
				id: "tok_1",
				name: "我的 Mac",
				lastUsedAt: null,
				revokedAt: null,
				insertedAt: "2026-08-01T09:00:00Z",
				status: "active" as const,
			},
		]);
		render(<ConnectGuidePage />);

		fireEvent.click(await screen.findByRole("button", { name: "下一步" }));
		expect(await screen.findByText(/已有有效 token/)).toBeInTheDocument();
		expect(issueMcpToken).not.toHaveBeenCalled();
	});

	it("上一步可回退", async () => {
		render(<ConnectGuidePage />);

		fireEvent.click(await screen.findByRole("button", { name: "下一步" }));
		expect(
			await screen.findByPlaceholderText("如：我的 Mac"),
		).toBeInTheDocument();

		fireEvent.click(screen.getByRole("button", { name: "上一步" }));
		expect(
			await screen.findByText("安装 MCP 客户端"),
		).toBeInTheDocument();
	});

	it("末步提供连接设置页入口", async () => {
		render(<ConnectGuidePage />);

		fireEvent.click(await screen.findByRole("button", { name: "下一步" }));
		fireEvent.click(
			await screen.findByRole("button", { name: "下一步" }),
		);

		const link = await screen.findByRole("link", { name: /连接设置/ });
		expect(link).toHaveAttribute("href", "/w/cgc-academy/settings/connection");
	});
});
