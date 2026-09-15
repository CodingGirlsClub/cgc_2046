import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import type { Mock } from "vitest";
import { cleanup, fireEvent, screen, waitFor } from "@testing-library/react";
import { render } from "@/test-utils";
import {
	OpencodeInstallCard,
	OpencodeModelCard,
	OpencodeLearnSpaceCard,
	OpencodeAuthorizeCard,
	OpencodeVerifyCard,
	OpencodeDeveloperOptions,
} from "./agent-connect-sections";

/**
 * opencode OAuth 五步卡链测试（U8，plan 2026-09-15 opencode-desktop-host）：
 * ①安装 → ②模型获取 → ③打开学习空间（下载 + 深链 + 版本指纹）→ ④授权连接
 * （等待态分支）→ ⑤验证；手动配置收在「开发者选项」折叠。
 * 原子页与向导共用这些卡，故在此按卡断言（页面测试只验装配）。
 */

/** 三键版本 JSON 夹具（download_path 故意不同于固定直链，验证产物契约被消费） */
const RELEASE = {
	version: "0.1.0",
	download_path: "/ext/learn-space-0.1.0.zip",
	sha256: "a".repeat(64),
};

const META_URL = "/ext/learn-space.json";

let fetchMock: Mock;

/** 客户端平台探测靠 UA：测试内改 UA 即模拟 Windows（happy-dom 默认非 Windows） */
async function withUserAgent(userAgent: string, body: () => Promise<void>) {
	const original = window.navigator.userAgent;
	Object.defineProperty(window.navigator, "userAgent", {
		value: userAgent,
		configurable: true,
	});
	try {
		await body();
	} finally {
		Object.defineProperty(window.navigator, "userAgent", {
			value: original,
			configurable: true,
		});
	}
}

beforeEach(() => {
	fetchMock = vi.fn().mockResolvedValue({
		ok: true,
		json: async () => RELEASE,
	});
	vi.stubGlobal("fetch", fetchMock);
});

afterEach(() => {
	cleanup();
	vi.unstubAllGlobals();
});

describe("opencode 五步卡链（U8，内容单源：原子页与向导共用）", () => {
	it("五步齐全：①安装 → ②模型 → ③学习空间 → ④授权 → ⑤验证", async () => {
		render(
			<>
				<OpencodeInstallCard stepNo="①" />
				<OpencodeModelCard stepNo="②" />
				<OpencodeLearnSpaceCard stepNo="③" />
				<OpencodeAuthorizeCard stepNo="④" />
				<OpencodeVerifyCard stepNo="⑤" />
			</>,
		);

		// ① 官方渠道安装（含最低版本与「界面不一样」出口）
		expect(
			screen.getByRole("heading", { name: "① 安装 opencode Desktop" }),
		).toBeInTheDocument();
		expect(
			screen.getByRole("link", { name: "打开官方下载页" }),
		).toHaveAttribute("href", "https://opencode.ai/download");
		expect(screen.getByText(/1\.18\.30 及以上版本/)).toBeInTheDocument();

		// ② 模型：推荐通道 + 费用 + 可自查的可用性检查
		expect(
			screen.getByRole("heading", { name: "② 获取一个可用的模型" }),
		).toBeInTheDocument();
		expect(screen.getByText(/DeepSeek 官方 API/)).toBeInTheDocument();
		expect(screen.getByText(/按用量计费/)).toBeInTheDocument();
		expect(screen.getByText(/发送一句「你好」/)).toBeInTheDocument();

		// ③ 学习空间：下载 + 深链 + 重启提示
		expect(
			screen.getByRole("heading", { name: "③ 打开学习空间" }),
		).toBeInTheDocument();
		expect(
			screen.getByRole("link", { name: "下载学习空间包" }),
		).toBeInTheDocument();
		expect(screen.getByText(/只在重新打开后生效/)).toBeInTheDocument();

		// ④ 授权连接：说明不需要 token
		expect(
			screen.getByRole("heading", { name: "④ 授权连接" }),
		).toBeInTheDocument();
		expect(screen.getByText(/全程不需要任何 token/)).toBeInTheDocument();

		// ⑤ 验证：一句话自查 + 判定来源
		expect(
			screen.getByRole("heading", { name: "⑤ 验证连接" }),
		).toBeInTheDocument();
		expect(screen.getByText("我在 2046 能做什么？")).toBeInTheDocument();
		expect(screen.getByText(/会把它标为「最近使用」/)).toBeInTheDocument();
	});

	it("深链按钮指向约定目录（KTD7）并做 URL 编码；手动回退文案并列", () => {
		render(<OpencodeLearnSpaceCard stepNo="③" />);

		const deepLink = screen.getByRole("link", {
			name: "用 opencode 打开学习空间",
		});
		expect(deepLink).toHaveAttribute(
			"href",
			`opencode://open-project?directory=${encodeURIComponent("~/Documents/CGC-2046")}`,
		);
		expect(deepLink.getAttribute("href")).toContain(
			"directory=~%2FDocuments%2FCGC-2046",
		);
		// U2 ① 结论待真机：按钮必须带手动回退
		expect(
			screen.getByText(/选择「打开文件夹」，手动选中上面那个 CGC-2046 文件夹/),
		).toBeInTheDocument();
	});

	it("学习空间：三键 JSON 的版本与 sha256 上屏，下载地址取 download_path", async () => {
		render(<OpencodeLearnSpaceCard stepNo="③" />);

		await waitFor(() =>
			expect(
				screen.getByTestId("learn-space-release"),
			).toHaveTextContent("当前发布版本 0.1.0"),
		);
		expect(screen.getByText(RELEASE.sha256)).toBeInTheDocument();
		expect(
			screen.getByRole("link", { name: "下载学习空间包" }),
		).toHaveAttribute(
			"href",
			"https://api.codingirlsclub.com/ext/learn-space-0.1.0.zip",
		);
		expect(fetchMock).toHaveBeenCalledWith(META_URL);
	});

	it("版本 JSON 取不到 → 降级为「直接下载最新包」，下载不受影响", async () => {
		fetchMock.mockRejectedValue(new Error("offline"));

		render(<OpencodeLearnSpaceCard stepNo="③" />);

		await waitFor(() =>
			expect(screen.getByText(/暂时取不到版本信息/)).toBeInTheDocument(),
		);
		expect(
			screen.getByRole("link", { name: "下载学习空间包" }),
		).toHaveAttribute(
			"href",
			"https://api.codingirlsclub.com/ext/learn-space.zip",
		);
	});

	it("Windows 平台差异：安装说明、文档目录与深链路径随平台切换", async () => {
		await withUserAgent(
			"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
			async () => {
				render(
					<>
						<OpencodeInstallCard stepNo="①" />
						<OpencodeLearnSpaceCard stepNo="③" />
					</>,
				);

				expect(
					await screen.findByText(/Windows：下载安装包并运行/),
				).toBeInTheDocument();
				expect(
					screen.queryByText(/macOS：下载 \.dmg/),
				).not.toBeInTheDocument();
				expect(screen.getByText(/OneDrive 接管/)).toBeInTheDocument();
				expect(
					screen.getByRole("link", { name: "用 opencode 打开学习空间" }),
				).toHaveAttribute(
					"href",
					`opencode://open-project?directory=${encodeURIComponent("%USERPROFILE%\\Documents\\CGC-2046")}`,
				);
			},
		);
	});
});

describe("opencode 第④步等待态（U8）", () => {
	it("idle = 尚未触发授权：回第②步或重启宿主后重开学习空间", () => {
		render(<OpencodeAuthorizeCard stepNo="④" phase="idle" />);

		expect(screen.getByText("还没看到授权页")).toBeInTheDocument();
		expect(
			screen.getByText(/回到第②步确认模型能正常回复/),
		).toBeInTheDocument();
		expect(screen.getByText(/完全退出 opencode 重新打开/)).toBeInTheDocument();
	});

	it("pending = 授权进行中：保持授权页打开 + 回调失败说明", () => {
		render(<OpencodeAuthorizeCard stepNo="④" phase="pending" />);

		expect(screen.getByText("授权进行中")).toBeInTheDocument();
		expect(screen.getByText(/保持该页面打开/)).toBeInTheDocument();
		expect(screen.getByText(/说明回调没有走通/)).toBeInTheDocument();
	});

	it("回调超时与端口占用的恢复入口在此卡（同意页不承载）", () => {
		render(<OpencodeAuthorizeCard stepNo="④" phase="pending" />);

		expect(screen.getByText("授权超时或回调失败")).toBeInTheDocument();
		expect(screen.getByText(/127\.0\.0\.1:19876/)).toBeInTheDocument();
		expect(screen.getByText(/重启 opencode 后重新打开学习空间/)).toBeInTheDocument();
	});

	it("active = 已授权连接；等待态与恢复文案退场", () => {
		render(<OpencodeAuthorizeCard stepNo="④" phase="active" />);

		expect(screen.getByText(/已授权连接，回到 opencode 的会话/)).toBeInTheDocument();
		expect(screen.queryByText("授权进行中")).not.toBeInTheDocument();
		expect(screen.queryByText("还没看到授权页")).not.toBeInTheDocument();
	});

	it("「我已授权，检查状态」触发重查回调；只读态不渲染该按钮", () => {
		const onRecheck = vi.fn();
		render(
			<OpencodeAuthorizeCard stepNo="④" phase="pending" onRecheck={onRecheck} />,
		);

		fireEvent.click(screen.getByRole("button", { name: "我已授权，检查状态" }));
		expect(onRecheck).toHaveBeenCalledTimes(1);

		cleanup();
		render(<OpencodeAuthorizeCard stepNo="④" phase="pending" />);
		expect(
			screen.queryByRole("button", { name: "我已授权，检查状态" }),
		).not.toBeInTheDocument();
	});
});

describe("opencode 开发者选项（U8：手动配置折叠，默认收起）", () => {
	it("默认收起，手动配置（签发入口 + opencode.json + 注意事项）仍在", () => {
		render(<OpencodeDeveloperOptions slug="cgc-academy" />);

		const fold = screen.getByTestId("opencode-developer-options");
		expect(fold.tagName).toBe("DETAILS");
		expect(fold).not.toHaveAttribute("open");

		expect(screen.getByText("开发者选项：手动配置（不推荐）")).toBeInTheDocument();
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
	});
});
