import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, fireEvent, screen } from "@testing-library/react";
import { render } from "@/test-utils";
import OnboardingWizard from "./onboarding-wizard";

const { router } = vi.hoisted(() => ({
	router: { push: vi.fn(), replace: vi.fn() },
}));
const { issueMcpToken } = vi.hoisted(() => ({ issueMcpToken: vi.fn() }));

vi.mock("next/navigation", () => ({
	redirect: vi.fn(),
	permanentRedirect: vi.fn(),
	useRouter: () => router,
	useParams: () => ({ slug: "cgc-academy" }),
	usePathname: () => "/w/cgc-academy/settings/integrations/agents",
}));

vi.mock("@/lib/mcp", async (importOriginal) => {
	const mod = (await importOriginal()) as Record<string, unknown>;
	return { ...mod, issueMcpToken };
});

beforeEach(() => {
	vi.clearAllMocks();
	issueMcpToken.mockResolvedValue({
		token: {
			id: "tok_new",
			name: "新设备",
			lastUsedAt: null,
			revokedAt: null,
			insertedAt: "2026-08-22T18:00:00Z",
			status: "active" as const,
		},
		plainToken: "cgc_wizard_plain_token",
	});
});

afterEach(cleanup);

describe("OnboardingWizard（首公里接入向导，plan first-mile U4）", () => {
	it("默认推荐 OpenClacky：选中态 + 推荐徽标；② 渲染安装 iframe 与扩展指引；③ 渲染签收入口", async () => {
		render(<OnboardingWizard slug="cgc-academy" />);

		const host = await screen.findByRole("radio", { name: /OpenClacky/ });
		expect(host).toBeChecked();
		expect(screen.getByText("推荐")).toBeInTheDocument();

		// ② OpenClacky 内容段（共享组件，与原子页同源）
		expect(screen.getByTitle("下载 OpenClacky")).toBeInTheDocument();
		expect(
			screen.getByText(
				"openclacky ext install https://api.codingirlsclub.com/ext/cgc-2046.zip",
				{ selector: "code" },
			),
		).toBeInTheDocument();
		expect(
			screen.getByRole("button", { name: "复制命令" }),
		).toBeInTheDocument();

		// ③ OpenClacky 默认路径由宿主内置助手发起；OMP/opencode 仍覆盖 token fallback。
	});

	it("DSH 卡已启用：无「即将推出」badge；选中后 ②③ 可见，② 渲染安装指引，③ 渲染签发面板（U10/R17）", async () => {
		render(<OnboardingWizard slug="cgc-academy" />);

		// DSH 卡无「即将推出」badge 与占位说明
		expect(screen.queryByText("即将推出")).not.toBeInTheDocument();

		fireEvent.click(await screen.findByRole("radio", { name: /DSH/ }));

		// 选中 DSH 后 ②③ 可见（不再 hidden 隐藏）
		expect(screen.getByTestId("onboarding-step-2")).toBeVisible();
		expect(screen.getByTestId("onboarding-step-3")).toBeVisible();

		// ② 安装指引：安装命令（--profile web 必带，KTD9）+ 最低 DSH 版本
		expect(
			screen.getByRole("heading", { name: "安装 DSH 插件家族" }),
		).toBeInTheDocument();
		expect(
			screen.getByText("dsh plugin --profile web add dsh-cgc-all"),
		).toBeInTheDocument();
		expect(screen.getByText("0.1.2")).toBeInTheDocument();
		// 包名完整性提示指向 CodingGirlsClub org（RSK1）+ 粘贴后清空剪贴板指引（RSK7）
		expect(screen.getByText(/CodingGirlsClub 官方组织发布/)).toBeInTheDocument();
		expect(screen.getByText(/清空剪贴板/)).toBeInTheDocument();

		// ③ 复用 McpTokenIssuePanel 签发面板
		expect(
			screen.getByRole("button", { name: /签发新 token/ }),
		).toBeVisible();
	});

	it("回归（P2）：签发后切 DSH 再切回，一次性明文不丢（②③ 不再隐藏/卸载）", async () => {
		render(<OnboardingWizard slug="cgc-academy" />);
		fireEvent.click(await screen.findByRole("radio", { name: /OMP/ }));

		fireEvent.click(
			await screen.findByRole("button", { name: /签发新 token/ }),
		);
		fireEvent.change(
			screen.getByPlaceholderText("如：我的 MacBook · OMP"),
			{ target: { value: "新设备" } },
		);
		fireEvent.click(screen.getByRole("button", { name: "签发" }));

		// 一次性明文已展示（服务端 token 已签发，用户尚未点「我已保存」）
		expect(await screen.findByText("cgc_wizard_plain_token")).toBeVisible();

		// 切 DSH：②③ 不再 hidden 隐藏，签发面板与明文保持可见
		fireEvent.click(screen.getByRole("radio", { name: /DSH/ }));
		expect(screen.getByText("cgc_wizard_plain_token")).toBeVisible();
		expect(screen.getByTestId("onboarding-step-2")).toBeVisible();
		expect(screen.getByTestId("onboarding-step-3")).toBeVisible();

		// 切回 OMP：组件未被卸载，明文仍可见
		fireEvent.click(screen.getByRole("radio", { name: /OMP/ }));
		expect(screen.getByText("cgc_wizard_plain_token")).toBeVisible();
	});

	it("宿主映射：选中 OMP 后 ② 渲染 .mcp.json 配置（AE3）", async () => {
		render(<OnboardingWizard slug="cgc-academy" />);

		fireEvent.click(await screen.findByRole("radio", { name: /OMP/ }));

		const pre = screen.getByText(
			(_, el) =>
				el?.tagName === "CODE" && el.textContent?.includes('"mcpServers"'),
		);
		expect(pre).toHaveTextContent('"type": "http"');
		expect(pre).toHaveTextContent("${CGC_TOKEN}");
		expect(screen.queryByTitle("下载 OpenClacky")).not.toBeInTheDocument();
	});

	it("宿主映射：选中 opencode 后 ② 渲染 opencode.json 配置（AE3）", async () => {
		render(<OnboardingWizard slug="cgc-academy" />);

		fireEvent.click(await screen.findByRole("radio", { name: /opencode/ }));

		const pre = screen.getByText(
			(_, el) =>
				el?.tagName === "CODE" && el.textContent?.includes('"type": "remote"'),
		);
		expect(pre).toHaveTextContent('"oauth": false');
		expect(pre).toHaveTextContent("{env:CGC_TOKEN}");
	});

	it("OpenClacky 路径提供一键连接入口；切 OMP 后进入手工配置", async () => {
		render(<OnboardingWizard slug="cgc-academy" />);

		expect(await screen.findByRole("link", { name: /打开 CGC OpenClacky/ })).toHaveAttribute(
			"href",
			"http://127.0.0.1:7070",
		);

		fireEvent.click(screen.getByRole("radio", { name: /OMP/ }));
		expect(screen.getByRole("button", { name: /签发新 token/ })).toBeInTheDocument();
	});

	it("签发成功 → 明文一次性展示 → 「我已保存」→ 完成态（种子话术卡 + 两出口）（AE4 前半）", async () => {
		render(<OnboardingWizard slug="cgc-academy" />);

		fireEvent.click(await screen.findByRole("radio", { name: /OMP/ }));
		fireEvent.click(
			screen.getByRole("button", { name: /签发新 token/ }),
		);
		fireEvent.change(
			screen.getByPlaceholderText("如：我的 MacBook · OMP"),
			{
				target: { value: "新设备" },
			},
		);
		fireEvent.click(screen.getByRole("button", { name: "签发" }));

		// 一次性明文
		expect(
			await screen.findByText("cgc_wizard_plain_token"),
		).toBeInTheDocument();
		expect(screen.getByText(/只显示这一次/)).toBeInTheDocument();

		fireEvent.click(screen.getByRole("button", { name: "我已保存" }));

		// 完成态：种子话术卡 + 出口
		expect(await screen.findByText("我在 2046 能做什么？"))
			.toBeInTheDocument();
		expect(
			screen.getByRole("link", { name: /去概览/ }),
		).toHaveAttribute("href", "/w/cgc-academy");
		expect(
			screen.getByRole("link", { name: /看活动/ }),
		).toHaveAttribute("href", "/w/cgc-academy/events");
		// 签发面不再出现
		expect(
			screen.queryByRole("button", { name: /签发新 token/ }),
		).not.toBeInTheDocument();
	});

	it("签发失败（如上限）→ 内联 role=alert，向导不前进不丢进度", async () => {
		issueMcpToken.mockRejectedValue(new Error("errors.issueMcpTokenFailed"));
		render(<OnboardingWizard slug="cgc-academy" />);

		// 先切到 OMP，验证失败后选择不丢（placeholder 命名建议跟随宿主）
		fireEvent.click(await screen.findByRole("radio", { name: /OMP/ }));
		fireEvent.click(screen.getByRole("button", { name: /签发新 token/ }));
		fireEvent.change(screen.getByPlaceholderText("如：我的 MacBook · OMP"), {
			target: { value: "x" },
		});
		fireEvent.click(screen.getByRole("button", { name: "签发" }));

		expect(await screen.findByRole("alert")).toHaveTextContent("签发失败");
		// 不进完成态
		expect(screen.queryByText("我在 2046 能做什么？")).not.toBeInTheDocument();
		// 进度保留：仍是向导态且 OMP 选择仍在
		expect(screen.getByRole("radio", { name: /OMP/ })).toBeChecked();
	});

	it("有 token 记录（含全撤销）的用户在向导态保留管理态入口（链 mcp tab）", async () => {
		// hasTokenHistory 由调用方从 useOnboardingState().tokens 派生传入（同一数据源）
		render(<OnboardingWizard slug="cgc-academy" hasTokenHistory />);

		const link = await screen.findByRole("link", { name: /MCP 页管理/ });
		expect(link).toHaveAttribute(
			"href",
			"/w/cgc-academy/settings/integrations/agents/mcp",
		);
	});

	it("无 token 记录的用户不显示管理态入口", async () => {
		render(<OnboardingWizard slug="cgc-academy" />);

		await screen.findByRole("radio", { name: /OpenClacky/ });
		expect(
			screen.queryByRole("link", { name: /MCP 页管理/ }),
		).not.toBeInTheDocument();
	});

	it("readOnly 回看：stepper 内容在，但无签发面（签发归 mcp tab）", async () => {
		render(<OnboardingWizard slug="cgc-academy" readOnly />);

		expect(
			await screen.findByRole("radio", { name: /OpenClacky/ }),
		).toBeInTheDocument();
		expect(
			screen.queryByRole("button", { name: /签发新 token/ }),
		).not.toBeInTheDocument();
		// ③ 只给 MCP 页链接
		const link = screen.getByRole("link", { name: "MCP 页" });
		expect(link).toHaveAttribute(
			"href",
			"/w/cgc-academy/settings/integrations/agents/mcp",
		);
		// 回看态仍附 OpenClacky 接入指引（指引不是签发面）
		expect(
			screen.getByText(/回到 OpenClacky 打开「CGC-2046 助手」会话/),
		).toBeInTheDocument();
		// 回看态不显示管理态入口（即使调用方误传 hasTokenHistory）
		expect(
			screen.queryByRole("link", { name: /MCP 页管理/ }),
		).not.toBeInTheDocument();
	});

	it("stepper 当前步（C：选中态样式与 aria-current）：四宿主一致停在 ③ 签发", async () => {
		render(<OnboardingWizard slug="cgc-academy" />);

		await screen.findByRole("radio", { name: /OpenClacky/ });
		expect(screen.getByTestId("onboarding-step-3")).toHaveAttribute(
			"aria-current",
			"step",
		);
		expect(screen.getByTestId("onboarding-step-1")).not.toHaveAttribute(
			"aria-current",
		);

		// 选中 DSH：②③ 可见且当前步仍停在 ③（DSH 启用后与其他宿主一致）
		fireEvent.click(screen.getByRole("radio", { name: /DSH/ }));
		expect(screen.getByTestId("onboarding-step-3")).toBeVisible();
		expect(screen.getByTestId("onboarding-step-3")).toHaveAttribute(
			"aria-current",
			"step",
		);
		expect(screen.getByTestId("onboarding-step-1")).not.toHaveAttribute(
			"aria-current",
		);
	});

	it("向导内共享卡为裸标题（D：编号由 stepper 供给，无「② 内嵌 ①②」双重编号）", async () => {
		render(<OnboardingWizard slug="cgc-academy" />);

		await screen.findByRole("radio", { name: /OpenClacky/ });
		// 裸标题（原子页经 stepNo 传「①」前缀，向导不传）
		expect(
			screen.getByRole("heading", { name: "安装 OpenClacky" }),
		).toBeInTheDocument();
		expect(
			screen.queryByRole("heading", { name: /① 安装 OpenClacky/ }),
		).not.toBeInTheDocument();
	});
});
