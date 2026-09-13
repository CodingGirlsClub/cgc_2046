import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, screen, fireEvent, waitFor, within } from "@testing-library/react";
import { render } from "@/test-utils";
import AdminInitiativesPage from "./page";

const adminLib = vi.hoisted(() => ({
	closeInitiative: vi.fn(),
	createInitiative: vi.fn(),
	fetchInitiative: vi.fn(),
	fetchInitiatives: vi.fn(),
	openInitiative: vi.fn(),
	updateInitiative: vi.fn(),
	upsertInitiativeRule: vi.fn(),
}));

vi.mock("next/navigation", () => ({
	redirect: vi.fn(),
	permanentRedirect: vi.fn(),
	useRouter: () => ({ push: vi.fn(), replace: vi.fn() }),
	usePathname: () => "/admin/initiatives",
}));

vi.mock("@/lib/admin", () => adminLib);

const OPEN_ROW = {
	id: "i1",
	name: "Hackerstart 1024",
	slug: "hackerstart1024",
	hashtag: "#hackerstart1024",
	description: null,
	status: "open",
	windowStartsAt: null,
	windowEndsAt: null,
	rules: [],
};

const DRAFT_ROW = {
	id: "i2",
	name: "E2E Drive",
	slug: "e2e-drive",
	hashtag: null,
	description: null,
	status: "draft",
	windowStartsAt: null,
	windowEndsAt: null,
	rules: [],
};

beforeEach(() => {
	vi.clearAllMocks();
	adminLib.fetchInitiatives.mockResolvedValue([OPEN_ROW, DRAFT_ROW]);
	adminLib.fetchInitiative.mockResolvedValue(DRAFT_ROW);
});

afterEach(cleanup);

describe("/admin/initiatives", () => {
	it("渲染列表行与状态操作按钮", async () => {
		render(<AdminInitiativesPage />);

		expect(await screen.findByText("Hackerstart 1024")).toBeInTheDocument();
		expect(screen.getByText("hackerstart1024")).toBeInTheDocument();
		expect(screen.getByText("E2E Drive")).toBeInTheDocument();

		const openRow = screen.getByText("hackerstart1024").closest("tr")!;
		const draftRow = screen.getByText("e2e-drive").closest("tr")!;
		expect(
			within(openRow).getByRole("button", { name: "结束" }),
		).toBeInTheDocument();
		expect(
			within(draftRow).getByRole("button", { name: "开放" }),
		).toBeInTheDocument();
	});

	it("创建成功追加新行", async () => {
		adminLib.createInitiative.mockResolvedValue({
			result: { ...DRAFT_ROW, id: "i3", name: "新活动", slug: "fresh" },
			errors: [],
		});

		render(<AdminInitiativesPage />);
		await screen.findByText("Hackerstart 1024");

		fireEvent.change(screen.getByLabelText("名称"), {
			target: { value: "新活动" },
		});
		fireEvent.change(screen.getByLabelText("Slug"), {
			target: { value: "fresh" },
		});
		fireEvent.click(screen.getByRole("button", { name: "保存" }));

		expect(await screen.findByText("新活动")).toBeInTheDocument();
		expect(adminLib.createInitiative).toHaveBeenCalledWith({
			name: "新活动",
			slug: "fresh",
			description: "",
		});
	});

	it("无规则草稿点开放：展示后端错误消息且列表保留", async () => {
		adminLib.openInitiative.mockResolvedValue({
			result: null,
			errors: [
				{
					code: "invalid_changes",
					message: "invalid initiative transition or missing all four rules",
				},
			],
		});

		render(<AdminInitiativesPage />);
		const draftRow = (await screen.findByText("e2e-drive")).closest("tr")!;
		fireEvent.click(
			within(draftRow).getByRole("button", { name: "开放" }),
		);

		expect(
			await screen.findByRole("alert"),
		).toHaveTextContent(
			"invalid initiative transition or missing all four rules",
		);
		expect(screen.getByText("hackerstart1024")).toBeInTheDocument();
		expect(screen.getByText("e2e-drive")).toBeInTheDocument();
	});

	it("开放中的 Initiative 点结束：状态切为 closed", async () => {
		adminLib.closeInitiative.mockResolvedValue({
			result: { ...OPEN_ROW, status: "closed" },
			errors: [],
		});

		render(<AdminInitiativesPage />);
		const openRow = (await screen.findByText("hackerstart1024")).closest(
			"tr",
		)!;
		fireEvent.click(
			within(openRow).getByRole("button", { name: "结束" }),
		);

		await waitFor(() =>
			expect(within(openRow).getByText("closed")).toBeInTheDocument(),
		);
		expect(adminLib.closeInitiative).toHaveBeenCalledWith("i1");
	});
});
