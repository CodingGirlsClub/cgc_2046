import { describe, it, expect, vi, afterEach } from "vitest";
import { cleanup, screen } from "@testing-library/react";
import { render } from "@/test-utils";
import OnboardingWizard from "./onboarding-wizard";

const { router } = vi.hoisted(() => ({
	router: { push: vi.fn(), replace: vi.fn() },
}));

vi.mock("next/navigation", () => ({
	redirect: vi.fn(),
	permanentRedirect: vi.fn(),
	useRouter: () => router,
	useParams: () => ({ slug: "cgc-academy" }),
	usePathname: () => "/w/cgc-academy/settings/integrations/agents",
}));

afterEach(cleanup);

describe("OnboardingWizard（首公里接入向导，单一路径）", () => {
	it("三步直接渲染 OpenClacky 路径：安装 iframe → 扩展命令 → 一键连接 + 助手提示", async () => {
		render(<OnboardingWizard slug="cgc-academy" />);

		// ① 安装 OpenClacky（官方下载页 iframe，与原子页同一内容源）
		expect(await screen.findByTitle("下载 OpenClacky")).toBeInTheDocument();
		expect(
			screen.getByRole("heading", { name: "安装 OpenClacky" }),
		).toBeInTheDocument();

		// ② 连接器扩展：一条命令 + 复制按钮
		expect(
			screen.getByRole("heading", { name: "安装 CGC-2046 连接器扩展" }),
		).toBeInTheDocument();
		expect(
			screen.getByText(
				"openclacky ext install https://api.codingirlsclub.com/ext/cgc-2046.zip",
				{ selector: "code" },
			),
		).toBeInTheDocument();
		expect(
			screen.getByRole("button", { name: "复制命令" }),
		).toBeInTheDocument();

		// ③ 连接：一键连接为主 + 手动 token 备用 + 助手提示
		expect(
			screen.getByRole("heading", { name: "连接 CGC-2046" }),
		).toBeInTheDocument();
		expect(
			screen.getByRole("link", { name: /打开 CGC OpenClacky/ }),
		).toHaveAttribute("href", "http://127.0.0.1:7070");
		expect(
			screen.getByRole("link", { name: /生成 token/ }),
		).toHaveAttribute(
			"href",
			"/w/cgc-academy/settings/integrations/agents/mcp",
		);
		expect(
			screen.getByText(/回到 OpenClacky 打开「CGC-2046 助手」会话/),
		).toBeInTheDocument();
	});

	it("不再渲染宿主选择器（opencode / DSH 已下线）", async () => {
		render(<OnboardingWizard slug="cgc-academy" />);

		await screen.findByTitle("下载 OpenClacky");
		expect(screen.queryByRole("radiogroup")).not.toBeInTheDocument();
		expect(screen.queryByRole("radio")).not.toBeInTheDocument();
		expect(screen.queryByText(/opencode/)).not.toBeInTheDocument();
		expect(screen.queryByText(/DSH/)).not.toBeInTheDocument();
	});

	it("有 token 记录（含全撤销）的用户在向导态保留管理态入口（链 mcp tab）", async () => {
		render(<OnboardingWizard slug="cgc-academy" hasTokenHistory />);

		const link = await screen.findByRole("link", { name: /MCP 页管理/ });
		expect(link).toHaveAttribute(
			"href",
			"/w/cgc-academy/settings/integrations/agents/mcp",
		);
	});

	it("无 token 记录的用户不显示管理态入口", async () => {
		render(<OnboardingWizard slug="cgc-academy" />);

		await screen.findByTitle("下载 OpenClacky");
		expect(
			screen.queryByRole("link", { name: /MCP 页管理/ }),
		).not.toBeInTheDocument();
	});

	it("readOnly 回看：stepper 内容在，但 ③ 只给 MCP 页链接（签发归 mcp tab）", async () => {
		render(<OnboardingWizard slug="cgc-academy" readOnly />);

		expect(await screen.findByTitle("下载 OpenClacky")).toBeInTheDocument();
		expect(
			screen.getByRole("heading", { name: "安装 CGC-2046 连接器扩展" }),
		).toBeInTheDocument();
		// ③ 无签发面与一键连接
		expect(
			screen.queryByRole("link", { name: /打开 CGC OpenClacky/ }),
		).not.toBeInTheDocument();
		const link = screen.getByRole("link", { name: "MCP 页" });
		expect(link).toHaveAttribute(
			"href",
			"/w/cgc-academy/settings/integrations/agents/mcp",
		);
		// 回看态不显示管理态入口（即使调用方误传 hasTokenHistory）
		expect(
			screen.queryByRole("link", { name: /MCP 页管理/ }),
		).not.toBeInTheDocument();
	});

	it("stepper 当前步（aria-current）：停在 ③ 连接", async () => {
		render(<OnboardingWizard slug="cgc-academy" />);

		await screen.findByTitle("下载 OpenClacky");
		expect(screen.getByTestId("onboarding-step-3")).toHaveAttribute(
			"aria-current",
			"step",
		);
		expect(screen.getByTestId("onboarding-step-1")).not.toHaveAttribute(
			"aria-current",
		);
		expect(screen.getByTestId("onboarding-step-2")).not.toHaveAttribute(
			"aria-current",
		);
	});
});
