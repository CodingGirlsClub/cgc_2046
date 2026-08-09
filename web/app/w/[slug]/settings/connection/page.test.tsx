import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, fireEvent, screen, waitFor } from "@testing-library/react";
import { render } from "@/test-utils";
import ConnectionSettingsPage from "./page";

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
const { revokeMcpToken } = vi.hoisted(() => ({ revokeMcpToken: vi.fn() }));
const { clipboardWrite } = vi.hoisted(() => ({ clipboardWrite: vi.fn() }));

vi.mock("next/navigation", () => ({
	useRouter: () => router,
	useParams: () => params.value,
	usePathname: () => `/w/${params.value.slug}/settings/connection`,
}));

vi.mock("@/lib/use-authed", () => ({ useAuthed }));

vi.mock("@/lib/workspaces", async (importOriginal) => {
	const mod = (await importOriginal()) as Record<string, unknown>;
	return { ...mod, fetchMyWorkspaces };
});

vi.mock("@/lib/mcp", async (importOriginal) => {
	const mod = (await importOriginal()) as Record<string, unknown>;
	return { ...mod, fetchMyMcpTokens, issueMcpToken, revokeMcpToken };
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

const TEST_TOKENS = [
	{
		id: "tok_1",
		name: "我的 Mac",
		lastUsedAt: "2026-08-08T10:00:00Z",
		revokedAt: null,
		insertedAt: "2026-08-01T09:00:00Z",
		status: "active" as const,
	},
	{
		id: "tok_2",
		name: "公司服务器",
		lastUsedAt: null,
		revokedAt: "2026-08-05T12:00:00Z",
		insertedAt: "2026-07-20T09:00:00Z",
		status: "revoked" as const,
	},
];

beforeEach(() => {
	vi.clearAllMocks();
	clipboardWrite.mockResolvedValue(undefined);
	useAuthed.mockReturnValue({ authed: true, confirmed: true, userId: "u_1" });
	params.value = { slug: "cgc-academy" };
	fetchMyWorkspaces.mockResolvedValue(WORKSPACES);
	fetchMyMcpTokens.mockResolvedValue(TEST_TOKENS);
	issueMcpToken.mockResolvedValue({
		token: {
			id: "tok_new",
			name: "新设备",
			lastUsedAt: null,
			revokedAt: null,
			insertedAt: "2026-08-08T18:00:00Z",
			status: "active" as const,
		},
		plainToken: "cgc_test_plain_token_value",
	});
	revokeMcpToken.mockResolvedValue({
		...TEST_TOKENS[0],
		revokedAt: "2026-08-08T18:30:00Z",
		status: "revoked" as const,
	});
});

afterEach(cleanup);

describe("/w/[slug]/settings/connection 连接设置页", () => {
	it("渲染 token 列表：名称 + 状态（有效/已撤销）", async () => {
		render(<ConnectionSettingsPage />);

		expect(await screen.findByText("我的 Mac")).toBeInTheDocument();
		expect(screen.getByText("公司服务器")).toBeInTheDocument();
		expect(screen.getByText("有效")).toBeInTheDocument();
		expect(screen.getByText("已撤销")).toBeInTheDocument();
	});

	it("空态：无 token 时显示空提示", async () => {
		fetchMyMcpTokens.mockResolvedValue([]);
		render(<ConnectionSettingsPage />);

		expect(await screen.findByText("暂无连接 token")).toBeInTheDocument();
	});

	it("签发：表单提交后展示一次性明文（含只显示一次警告）并更新列表", async () => {
		render(<ConnectionSettingsPage />);

		fireEvent.click(
			await screen.findByRole("button", { name: /签发新 token/ }),
		);
		fireEvent.change(screen.getByPlaceholderText("如：我的 Mac"), {
			target: { value: "新设备" },
		});
		fireEvent.click(screen.getByRole("button", { name: "签发" }));

		await waitFor(() => {
			expect(issueMcpToken).toHaveBeenCalledWith("新设备");
		});
		// 明文一次性展示区
		expect(
			await screen.findByText("cgc_test_plain_token_value"),
		).toBeInTheDocument();
		expect(screen.getByText(/只显示这一次/)).toBeInTheDocument();
		// 列表更新（明文横幅与列表卡片都含名称，收窄到列表容器断言）
		const list = await waitFor(() => {
			const el = document.querySelector(".invitations-list");
			expect(el).toHaveTextContent("新设备");
			return el;
		});
		expect(list).toHaveTextContent("我的 Mac");
	});

	it("撤销需二次确认：点击撤销 → 确认撤销 → 状态变为已撤销", async () => {
		render(<ConnectionSettingsPage />);

		const revokeButton = await screen.findByRole("button", { name: "撤销" });
		fireEvent.click(revokeButton);
		// 未确认前不调用
		expect(revokeMcpToken).not.toHaveBeenCalled();

		fireEvent.click(
			await screen.findByRole("button", { name: "确认撤销" }),
		);

		await waitFor(() => {
			expect(revokeMcpToken).toHaveBeenCalledWith("tok_1");
		});
		// 两个 token 都已是已撤销状态
		expect((await screen.findAllByText("已撤销")).length).toBe(2);
	});

	it("配置片段 Tab：默认 OpenClacky，切到 opencode 显示对应片段，可复制", async () => {
		render(<ConnectionSettingsPage />);

		// 默认 openclacky 片段
		expect(
			await screen.findByText(/"mcpServers"/),
		).toBeInTheDocument();
		expect(screen.getByText(/<CGC_TOKEN>/)).toBeInTheDocument();

		// 切换 opencode
		fireEvent.click(screen.getByRole("tab", { name: "opencode" }));
		expect(await screen.findByText(/"oauth": false/)).toBeInTheDocument();
		expect(screen.getByText(/\{env:CGC_TOKEN\}/)).toBeInTheDocument();

		// 复制
		fireEvent.click(screen.getByRole("button", { name: "复制配置" }));
		await waitFor(() => {
			expect(clipboardWrite).toHaveBeenCalled();
		});
		expect(await screen.findByRole("button", { name: "已复制" }))
			.toBeInTheDocument();
		expect(clipboardWrite.mock.calls[0][0]).toContain("{env:CGC_TOKEN}");
	});

	it("复制被拒绝时显示失败提示而非静默（一次性明文场景的防呆）", async () => {
		clipboardWrite.mockRejectedValue(new Error("Write permission denied"));
		render(<ConnectionSettingsPage />);

		fireEvent.click(
			await screen.findByRole("button", { name: "复制配置" }),
		);

		expect(
			await screen.findByText("复制失败，请手动选择下方文本复制。"),
		).toBeInTheDocument();
		// 不出现成功态
		expect(
			screen.queryByRole("button", { name: "已复制" }),
		).not.toBeInTheDocument();
	});

	it("提供连接引导页入口", async () => {
		render(<ConnectionSettingsPage />);

		const link = await screen.findByRole("link", { name: /连接引导/ });
		expect(link).toHaveAttribute("href", "/w/cgc-academy/connect");
	});
});
