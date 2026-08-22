import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, fireEvent, screen, within } from "@testing-library/react";
import { render } from "@/test-utils";
import AgentsIntegrationsPage from "./page";

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
const { useOnboardingState } = vi.hoisted(() => ({
	useOnboardingState: vi.fn(),
}));
const { fetchMyMcpTokens } = vi.hoisted(() => ({ fetchMyMcpTokens: vi.fn() }));

vi.mock("next/navigation", () => ({
	redirect: vi.fn(),
	permanentRedirect: vi.fn(),
	useRouter: () => router,
	useParams: () => params.value,
	usePathname: () => `/w/${params.value.slug}/settings/integrations/agents`,
}));

vi.mock("@/lib/use-authed", () => ({ useAuthed }));

vi.mock("@/lib/workspaces", async (importOriginal) => {
	const mod = (await importOriginal()) as Record<string, unknown>;
	return { ...mod, fetchMyWorkspaces };
});

vi.mock("@/lib/onboarding", async (importOriginal) => {
	const mod = (await importOriginal()) as Record<string, unknown>;
	return { ...mod, useOnboardingState };
});

vi.mock("@/lib/mcp", async (importOriginal) => {
	const mod = (await importOriginal()) as Record<string, unknown>;
	return { ...mod, fetchMyMcpTokens };
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

const ONBOARDING_BASE = {
	dismissed: false,
	hasActiveToken: false,
	connected: false,
	loading: false,
	error: null,
};

beforeEach(() => {
	vi.clearAllMocks();
	useAuthed.mockReturnValue({ authed: true, confirmed: true, userId: "u_1" });
	params.value = { slug: "cgc-academy" };
	fetchMyWorkspaces.mockResolvedValue(WORKSPACES);
	fetchMyMcpTokens.mockResolvedValue([]);
	useOnboardingState.mockReturnValue({ ...ONBOARDING_BASE });
});

afterEach(cleanup);

describe("/w/[slug]/settings/integrations/agents 区入口页（向导/管理两态）", () => {
	it("loading → 骨架占位（KTD5 消费契约：先判 loading）", () => {
		useOnboardingState.mockReturnValue({ ...ONBOARDING_BASE, loading: true });
		render(<AgentsIntegrationsPage />);

		expect(screen.getByLabelText("加载中")).toBeInTheDocument();
		// 两态都不出现
		expect(
			screen.queryByRole("heading", { name: "接入你的 Agent" }),
		).not.toBeInTheDocument();
		expect(
			screen.queryByRole("navigation", { name: "工作区设置页签" }),
		).not.toBeInTheDocument();
	});

	it("error → 回退管理态（tabs + 四子页入口卡），无「重新查看引导」", async () => {
		useOnboardingState.mockReturnValue({
			...ONBOARDING_BASE,
			error: new Error("errors.noResponse"),
		});
		render(<AgentsIntegrationsPage />);

		const tabs = await screen.findByRole("navigation", {
			name: "工作区设置页签",
		});
		for (const label of ["MCP", "OpenClacky", "opencode", "OMP"]) {
			expect(within(tabs).getByRole("link", { name: label }))
				.toBeInTheDocument();
		}
		expect(screen.getByTestId("agent-entry-cards")).toBeInTheDocument();
		expect(
			screen.queryByRole("button", { name: "重新查看引导" }),
		).not.toBeInTheDocument();
	});

	it("无 active token → 向导态（AE3/AE4 入口）", async () => {
		render(<AgentsIntegrationsPage />);

		expect(
			await screen.findByRole("heading", { name: "接入你的 Agent" }),
		).toBeInTheDocument();
		expect(
			screen.getByRole("radio", { name: /OpenClacky/ }),
		).toBeChecked();
		// 向导态不渲染管理 tabs（两态互斥，R7）
		expect(
			screen.queryByRole("navigation", { name: "工作区设置页签" }),
		).not.toBeInTheDocument();
	});

	it("有 active token → 管理态 + 「已接入 ✓ · 重新查看引导」入口（AE4 后半）", async () => {
		useOnboardingState.mockReturnValue({
			...ONBOARDING_BASE,
			hasActiveToken: true,
			connected: true,
		});
		render(<AgentsIntegrationsPage />);

		expect(
			await screen.findByRole("navigation", { name: "工作区设置页签" }),
		).toBeInTheDocument();
		expect(screen.getByText(/已接入/)).toBeInTheDocument();
		expect(
			screen.getByRole("button", { name: "重新查看引导" }),
		).toBeInTheDocument();

		// 四子页入口卡
		const cards = screen.getByTestId("agent-entry-cards");
		const links = within(cards).getAllByRole("link");
		expect(links.map((l) => l.getAttribute("href"))).toEqual([
			"/w/cgc-academy/settings/integrations/agents/mcp",
			"/w/cgc-academy/settings/integrations/agents/openclacky",
			"/w/cgc-academy/settings/integrations/agents/opencode",
			"/w/cgc-academy/settings/integrations/agents/omp",
		]);
	});

	it("管理态「重新查看引导」→ 只读向导（无签发面），可返回管理态", async () => {
		useOnboardingState.mockReturnValue({
			...ONBOARDING_BASE,
			hasActiveToken: true,
		});
		render(<AgentsIntegrationsPage />);

		fireEvent.click(
			await screen.findByRole("button", { name: "重新查看引导" }),
		);

		// 只读向导：有 stepper，无签发面
		expect(
			await screen.findByRole("radio", { name: /OpenClacky/ }),
		).toBeInTheDocument();
		expect(
			screen.queryByRole("button", { name: /签发新 token/ }),
		).not.toBeInTheDocument();

		fireEvent.click(screen.getByRole("button", { name: "返回管理" }));
		expect(
			await screen.findByRole("button", { name: "重新查看引导" }),
		).toBeInTheDocument();
	});

	it("AE6/R10：普通成员（myAbilities 仅成员基准、myRoleNames 空）向导态与管理态均可用", async () => {
		// fixture WORKSPACES 已是普通成员（myAbilities 仅 view_workspace/access_invite_only，
		// myRoleNames 空）——该区不做能力门控，两态都应正常渲染
		const first = render(<AgentsIntegrationsPage />);
		expect(
			await screen.findByRole("heading", { name: "接入你的 Agent" }),
		).toBeInTheDocument();
		first.unmount();

		useOnboardingState.mockReturnValue({
			...ONBOARDING_BASE,
			hasActiveToken: true,
			connected: true,
		});
		render(<AgentsIntegrationsPage />);
		expect(
			await screen.findByRole("navigation", { name: "工作区设置页签" }),
		).toBeInTheDocument();
		expect(screen.getByTestId("agent-entry-cards")).toBeInTheDocument();
	});
});
