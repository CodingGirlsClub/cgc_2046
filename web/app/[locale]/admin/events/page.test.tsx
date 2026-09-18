import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, screen, fireEvent, waitFor, within } from "@testing-library/react";
import { render } from "@/test-utils";
import AdminEventsPage from "./page";

const adminLib = vi.hoisted(() => ({
	adminCancelEvent: vi.fn(),
	adminCloseEvent: vi.fn(),
	adminLaunchEvent: vi.fn(),
	adminUpdateEvent: vi.fn(),
	fetchAdminEvent: vi.fn(),
	fetchAdminEvents: vi.fn(),
	fetchReconciliationFindings: vi.fn(),
	fetchWorkspaces: vi.fn(),
}));

vi.mock("@/lib/admin", () => adminLib);

const { copyText } = vi.hoisted(() => ({ copyText: vi.fn() }));
vi.mock("@/lib/clipboard", () => ({ copyText }));

/** 搜索参数（对账跳转落点测试按需改写） */
const searchParams = vi.hoisted(() => ({ value: new URLSearchParams() }));

vi.mock("next/navigation", () => ({
	redirect: vi.fn(),
	permanentRedirect: vi.fn(),
	useSearchParams: () => searchParams.value,
	useRouter: () => ({ push: vi.fn(), replace: vi.fn() }),
	usePathname: () => "/admin/events",
}));

const WORKSPACES = [
	{
		id: "w1",
		slug: "hackerstart",
		name: "Hackerstart",
		joinPolicy: "open",
		sponsorshipEnabled: false,
		insertedAt: "2026-01-01T00:00:00Z",
		memberCount: 12,
	},
];

const DRAFT_ROW = {
	id: "e-draft",
	workspaceId: "w1",
	title: "Draft Workshop",
	slug: "draft-workshop",
	status: "draft",
	visibility: "workspace",
	capacity: 20,
	registrationDeadline: null,
	startsAt: "2026-10-01T02:00:00Z",
	endsAt: null,
	pricingEnabled: false,
	depositEnabled: false,
	depositAmountCents: null,
	insertedAt: "2026-09-01T00:00:00Z",
	updatedAt: "2026-09-01T00:00:00Z",
};

const OPEN_ROW = {
	id: "e-open",
	workspaceId: "w1",
	title: "Open Meetup",
	slug: "open-meetup",
	status: "open",
	visibility: "public",
	capacity: null,
	registrationDeadline: "2026-09-28T02:00:00Z",
	startsAt: "2026-09-30T02:00:00Z",
	endsAt: null,
	pricingEnabled: true,
	depositEnabled: true,
	depositAmountCents: 6900,
	insertedAt: "2026-09-01T00:00:00Z",
	updatedAt: "2026-09-01T00:00:00Z",
};

const CLOSED_ROW = {
	...OPEN_ROW,
	id: "e-closed",
	title: "Closed Meetup",
	slug: "closed-meetup",
	status: "closed",
};

/** 详情 = 行 + 四类投影字段（计数、主理人、挂载来源标记、场地） */
const OPEN_DETAIL = {
	...OPEN_ROW,
	description: "desc",
	venue: JSON.stringify({
		country: "China",
		province: "Shanghai",
		city: "Shanghai",
		district: "Xuhui",
	}),
	confirmedCount: 3,
	paymentPendingCount: 2,
	moderators: [{ id: "m1", userId: "u-owner" }],
	detachedRuleProvenance: null,
};

const FINDINGS = [
	{
		id: "f1",
		rule: "open_offering_without_ledger",
		entityType: "event",
		entityId: "e-open",
		workspaceId: "w1",
		firstSeenAt: "2026-09-10T00:00:00Z",
		lastSeenAt: "2026-09-11T00:00:00Z",
		insertedAt: "2026-09-10T00:00:00Z",
	},
];

/** 展开某行的详情（列表 → 「详情」） */
async function expandRow(slug: string) {
	const row = (await screen.findByText(slug)).closest("tr")!;
	fireEvent.click(within(row).getByRole("button", { name: "详情" }));
	return row;
}

/** 展开详情 → 打开元数据编辑表单 */
async function openEditor(slug: string) {
	await expandRow(slug);
	fireEvent.click(await screen.findByRole("button", { name: "编辑元数据" }));
}

beforeEach(() => {
	vi.clearAllMocks();
	searchParams.value = new URLSearchParams();
	// happy-dom 未实现 window.confirm（undefined），vi.spyOn 会抛
	window.confirm = () => false;
	adminLib.fetchAdminEvents.mockResolvedValue([DRAFT_ROW, OPEN_ROW, CLOSED_ROW]);
	adminLib.fetchAdminEvent.mockResolvedValue(OPEN_DETAIL);
	adminLib.fetchReconciliationFindings.mockResolvedValue(FINDINGS);
	adminLib.fetchWorkspaces.mockResolvedValue(WORKSPACES);
	copyText.mockResolvedValue(true);
});

afterEach(cleanup);

describe("/admin/events 列表与定位", () => {
	it("渲染全状态行、工作台名与状态徽章", async () => {
		render(<AdminEventsPage />);

		const draftRow = (await screen.findByText("Draft Workshop")).closest("tr")!;
		const openRow = screen.getByText("Open Meetup").closest("tr")!;
		const closedRow = screen.getByText("Closed Meetup").closest("tr")!;
		expect(within(draftRow).getByText("草稿")).toBeInTheDocument();
		expect(within(openRow).getByText("开放报名")).toBeInTheDocument();
		expect(within(closedRow).getByText("已结束")).toBeInTheDocument();
		await waitFor(() => expect(screen.getAllByText("Hackerstart").length).toBeGreaterThan(0));
		expect(within(draftRow).getByText("20")).toBeInTheDocument();
		expect(within(openRow).getAllByText("不限").length).toBeGreaterThan(0);
	});

	it("搜索 / 状态 / 工作台过滤一起下发（offset 归零）", async () => {
		render(<AdminEventsPage />);
		await screen.findAllByText("Hackerstart");

		fireEvent.change(screen.getByLabelText("搜索活动"), {
			target: { value: "meetup" },
		});
		fireEvent.change(screen.getByLabelText("活动状态过滤"), {
			target: { value: "open" },
		});
		fireEvent.change(screen.getByLabelText("工作台过滤"), {
			target: { value: "w1" },
		});
		fireEvent.click(screen.getByRole("button", { name: "过滤" }));

		await waitFor(() =>
			expect(adminLib.fetchAdminEvents).toHaveBeenLastCalledWith(
				{ search: "meetup", status: "open", workspaceId: "w1" },
				{ first: 20, after: "0" },
			),
		);
	});

	it("列表读失败：渲染错误提示且不落「暂无活动」假空态", async () => {
		adminLib.fetchAdminEvents.mockRejectedValue(new Error("network"));

		render(<AdminEventsPage />);

		expect(await screen.findByRole("alert")).toHaveTextContent("加载失败。");
		expect(screen.queryByText("暂无活动。")).toBeNull();
	});

	it("分页：下一页按已返回条数推进 offset", async () => {
		const page = Array.from({ length: 20 }, (_, index) => ({
			...OPEN_ROW,
			id: `e-${index}`,
			slug: `slug-${index}`,
			title: `Event ${index}`,
		}));
		adminLib.fetchAdminEvents.mockResolvedValue(page);

		render(<AdminEventsPage />);
		await screen.findByText("Event 0");

		fireEvent.click(screen.getByRole("button", { name: "下一页" }));

		await waitFor(() =>
			expect(adminLib.fetchAdminEvents).toHaveBeenLastCalledWith({}, { first: 20, after: "20" }),
		);
	});
});

describe("生命周期操作可见性矩阵", () => {
	it("draft 只有发布；open 有结束 + 取消；终态无生命周期按钮", async () => {
		render(<AdminEventsPage />);

		const draftRow = (await screen.findByText("draft-workshop")).closest("tr")!;
		const openRow = screen.getByText("open-meetup").closest("tr")!;
		const closedRow = screen.getByText("closed-meetup").closest("tr")!;

		expect(within(draftRow).getByRole("button", { name: "发布" })).toBeInTheDocument();
		expect(within(draftRow).queryByRole("button", { name: "结束" })).toBeNull();
		expect(within(draftRow).queryByRole("button", { name: "取消活动" })).toBeNull();

		expect(within(openRow).getByRole("button", { name: "结束" })).toBeInTheDocument();
		expect(within(openRow).getByRole("button", { name: "取消活动" })).toBeInTheDocument();
		expect(within(openRow).queryByRole("button", { name: "发布" })).toBeNull();

		expect(within(closedRow).queryByRole("button", { name: "发布" })).toBeNull();
		expect(within(closedRow).queryByRole("button", { name: "结束" })).toBeNull();
		expect(within(closedRow).queryByRole("button", { name: "取消活动" })).toBeNull();
	});

	it("发布成功：列表行状态切为 open", async () => {
		adminLib.adminLaunchEvent.mockResolvedValue({
			result: { id: "e-draft", slug: "draft-workshop", status: "open" },
			errors: [],
		});
		adminLib.fetchAdminEvents
			.mockResolvedValueOnce([DRAFT_ROW, OPEN_ROW, CLOSED_ROW])
			.mockResolvedValue([{ ...DRAFT_ROW, status: "open" }, OPEN_ROW, CLOSED_ROW]);

		render(<AdminEventsPage />);
		const draftRow = (await screen.findByText("draft-workshop")).closest("tr")!;
		fireEvent.click(within(draftRow).getByRole("button", { name: "发布" }));

		await waitFor(() =>
			expect(within(draftRow).getByRole("button", { name: "结束" })).toBeInTheDocument(),
		);
		expect(adminLib.adminLaunchEvent).toHaveBeenCalledWith("e-draft");
	});

	it("mutation 错误信封行内呈现（列表保留）", async () => {
		adminLib.adminLaunchEvent.mockResolvedValue({
			result: null,
			errors: [{ code: "invalid_changes", message: "invalid event transition" }],
		});

		render(<AdminEventsPage />);
		const draftRow = (await screen.findByText("draft-workshop")).closest("tr")!;
		fireEvent.click(within(draftRow).getByRole("button", { name: "发布" }));

		expect(await screen.findByRole("alert")).toHaveTextContent("invalid event transition");
		expect(screen.getByText("open-meetup")).toBeInTheDocument();
	});

	it("slug 锁定错误按稳定 code 本地化（不透传英文原文）", async () => {
		adminLib.adminLaunchEvent.mockResolvedValue({
			result: null,
			errors: [{ code: "event_slug_locked", message: "slug is locked" }],
		});

		render(<AdminEventsPage />);
		const draftRow = (await screen.findByText("draft-workshop")).closest("tr")!;
		fireEvent.click(within(draftRow).getByRole("button", { name: "发布" }));

		expect(await screen.findByRole("alert")).toHaveTextContent("slug 不可再修改");
	});
});

describe("取消活动（高危确认，KTD4）", () => {
	it("确认弹窗披露已付/待付笔数，确认后取消并刷新", async () => {
		const confirmSpy = vi.spyOn(window, "confirm").mockReturnValue(true);
		adminLib.adminCancelEvent.mockResolvedValue({
			result: { id: "e-open", slug: "open-meetup", status: "cancelled" },
			errors: [],
		});

		render(<AdminEventsPage />);
		const openRow = (await screen.findByText("open-meetup")).closest("tr")!;
		fireEvent.click(within(openRow).getByRole("button", { name: "取消活动" }));

		await waitFor(() => expect(confirmSpy).toHaveBeenCalled());
		const message = String(confirmSpy.mock.calls[0][0]);
		expect(message).toContain("3");
		expect(message).toContain("2");
		await waitFor(() => expect(adminLib.adminCancelEvent).toHaveBeenCalledWith("e-open"));
		// 写成功后列表按当前过滤重取（状态刷新）
		expect(adminLib.fetchAdminEvents.mock.calls.length).toBeGreaterThan(1);
		confirmSpy.mockRestore();
	});

	it("取消确认被拒：不调用后端", async () => {
		const confirmSpy = vi.spyOn(window, "confirm").mockReturnValue(false);

		render(<AdminEventsPage />);
		const openRow = (await screen.findByText("open-meetup")).closest("tr")!;
		fireEvent.click(within(openRow).getByRole("button", { name: "取消活动" }));

		await waitFor(() => expect(confirmSpy).toHaveBeenCalled());
		expect(adminLib.adminCancelEvent).not.toHaveBeenCalled();
		confirmSpy.mockRestore();
	});

	it("计数取不到时不落假值：确认文案按「不可用」披露", async () => {
		const confirmSpy = vi.spyOn(window, "confirm").mockReturnValue(false);
		adminLib.fetchAdminEvent.mockRejectedValue(new Error("network"));

		render(<AdminEventsPage />);
		const openRow = (await screen.findByText("open-meetup")).closest("tr")!;
		fireEvent.click(within(openRow).getByRole("button", { name: "取消活动" }));

		await waitFor(() => expect(confirmSpy).toHaveBeenCalled());
		const message = String(confirmSpy.mock.calls[0][0]);
		expect(message).toContain("计数不可用");
		expect(message).not.toContain("{confirmed}");
		confirmSpy.mockRestore();
	});
});

describe("行展开详情（四类投影）", () => {
	it("展开按 (entityType, entityId) 拉对账发现并渲染计数/主理人/场地", async () => {
		render(<AdminEventsPage />);
		await expandRow("open-meetup");

		expect(await screen.findByText("China Shanghai Xuhui")).toBeInTheDocument();
		expect(screen.getByText("u-owner")).toBeInTheDocument();
		expect(adminLib.fetchReconciliationFindings).toHaveBeenCalledWith({
			entityType: "event",
			entityId: "e-open",
		});
		expect(screen.getByText("开放供给物无名额账本行")).toBeInTheDocument();
	});

	it("计数不可用（null）→ 渲染不可用态而非 0", async () => {
		adminLib.fetchAdminEvent.mockResolvedValue({
			...OPEN_DETAIL,
			confirmedCount: null,
			paymentPendingCount: null,
		});

		render(<AdminEventsPage />);
		await expandRow("open-meetup");

		expect(await screen.findByText("计数不可用")).toBeInTheDocument();
	});

	it("详情取数失败 → 展开行渲染不可用态", async () => {
		adminLib.fetchAdminEvent.mockResolvedValue(null);

		render(<AdminEventsPage />);
		await expandRow("open-meetup");

		expect(
			await screen.findByText("该活动详情加载失败，或该 id 已不存在。"),
		).toBeInTheDocument();
	});

	it("?entity_id= 定位并自动展开该行（含 findings）", async () => {
		searchParams.value = new URLSearchParams("entity_id=e-open");

		render(<AdminEventsPage />);

		await waitFor(() =>
			expect(adminLib.fetchAdminEvent).toHaveBeenCalledWith("e-open"),
		);
		expect(await screen.findByText("China Shanghai Xuhui")).toBeInTheDocument();
		expect(adminLib.fetchReconciliationFindings).toHaveBeenCalledWith({
			entityType: "event",
			entityId: "e-open",
		});
	});

	it("?entity_id= 指向不在当前列表的行：该行仍可见（对账跳转不落空）", async () => {
		searchParams.value = new URLSearchParams("entity_id=e-open");
		adminLib.fetchAdminEvents.mockResolvedValue([CLOSED_ROW]);

		render(<AdminEventsPage />);

		expect(await screen.findByText("Open Meetup")).toBeInTheDocument();
		expect(screen.getByText("已按对账跳转定位（不在当前筛选结果内）")).toBeInTheDocument();
	});
});

describe("元数据编辑（R5 全集，只落变更键）", () => {
	it("提交标题/容量/可见性变更：update 只带变更键，成功后重取详情刷新计数", async () => {
		adminLib.adminUpdateEvent.mockResolvedValue({
			result: { id: "e-open", slug: "open-meetup", status: "open" },
			errors: [],
		});

		render(<AdminEventsPage />);
		await openEditor("open-meetup");

		fireEvent.change(screen.getByLabelText("标题"), { target: { value: "Open Meetup 2" } });
		fireEvent.change(screen.getByLabelText("名额上限"), { target: { value: "42" } });
		fireEvent.change(screen.getByLabelText("可见性"), { target: { value: "workspace" } });
		fireEvent.click(screen.getByRole("button", { name: "保存" }));

		await waitFor(() =>
			expect(adminLib.adminUpdateEvent).toHaveBeenCalledWith("e-open", {
				title: "Open Meetup 2",
				capacity: 42,
				visibility: "workspace",
			}),
		);
		// KTD4：写成功后重取详情（权威计数刷新）——展开详情触发的读 + 写后重取
		await waitFor(() =>
			expect(adminLib.fetchAdminEvent.mock.calls.length).toBeGreaterThan(1),
		);
	});

	it("无变更点保存：不发 mutation，提示没有需要保存的变更", async () => {
		render(<AdminEventsPage />);
		await openEditor("open-meetup");

		fireEvent.click(screen.getByRole("button", { name: "保存" }));

		expect(await screen.findByText("没有需要保存的变更。")).toBeInTheDocument();
		expect(adminLib.adminUpdateEvent).not.toHaveBeenCalled();
	});

	it("场地四项不齐就地拦截（不下发）", async () => {
		render(<AdminEventsPage />);
		await openEditor("open-meetup");

		fireEvent.change(screen.getByLabelText("区县"), { target: { value: "" } });
		fireEvent.click(screen.getByRole("button", { name: "保存" }));

		expect(
			await screen.findByText("活动地点需国家、省份、城市、区县四项齐全，或全部留空。"),
		).toBeInTheDocument();
		expect(adminLib.adminUpdateEvent).not.toHaveBeenCalled();
	});

	it("名额上限非法就地拦截", async () => {
		render(<AdminEventsPage />);
		await openEditor("open-meetup");

		fireEvent.change(screen.getByLabelText("名额上限"), { target: { value: "0" } });
		fireEvent.click(screen.getByRole("button", { name: "保存" }));

		expect(await screen.findByText("名额上限须为正整数，留空表示不限。")).toBeInTheDocument();
		expect(adminLib.adminUpdateEvent).not.toHaveBeenCalled();
	});

	it("slug 只读展示：编辑表单不允许改 slug", async () => {
		render(<AdminEventsPage />);
		await openEditor("open-meetup");

		expect(screen.getByLabelText("Slug")).toHaveAttribute("readonly");
		expect(screen.getByText("公开链接已生效，slug 发布后不可修改")).toBeInTheDocument();
	});
});

describe("押金槽位关停（AE3 / KTD4 单一取数契约）", () => {
	it("pending ≤ 200：确认弹窗现取计数并披露笔数，确认后提交 depositEnabled:false", async () => {
		adminLib.adminUpdateEvent.mockResolvedValue({
			result: { id: "e-open", slug: "open-meetup", status: "open" },
			errors: [],
		});

		render(<AdminEventsPage />);
		await openEditor("open-meetup");

		fireEvent.click(screen.getByLabelText(/押金槽位/));
		fireEvent.click(screen.getByRole("button", { name: "保存" }));

		const dialog = await screen.findByRole("dialog");
		// 弹窗内数字来自现取（OPEN_DETAIL.paymentPendingCount = 2）
		expect(await within(dialog).findByText(/批量免缴 2 笔/)).toBeInTheDocument();
		fireEvent.click(within(dialog).getByRole("button", { name: "确认关停" }));

		await waitFor(() =>
			expect(adminLib.adminUpdateEvent).toHaveBeenCalledWith("e-open", {
				depositEnabled: false,
			}),
		);
	});

	it("同批关停两个槽位：弹窗逐条披露，单次提交含两个键", async () => {
		adminLib.adminUpdateEvent.mockResolvedValue({
			result: { id: "e-open", slug: "open-meetup", status: "open" },
			errors: [],
		});

		render(<AdminEventsPage />);
		await openEditor("open-meetup");

		fireEvent.click(screen.getByLabelText("定价槽位"));
		fireEvent.click(screen.getByLabelText("押金槽位"));
		fireEvent.click(screen.getByRole("button", { name: "保存" }));

		const dialog = await screen.findByRole("dialog");
		expect(within(dialog).getByText("即将关停：定价槽位")).toBeInTheDocument();
		expect(within(dialog).getByText("即将关停：押金槽位")).toBeInTheDocument();
		fireEvent.click(within(dialog).getByRole("button", { name: "确认关停" }));

		await waitFor(() =>
			expect(adminLib.adminUpdateEvent).toHaveBeenCalledWith("e-open", {
				pricingEnabled: false,
				depositEnabled: false,
			}),
		);
	});

	it("弹窗取数中渲染 loading，取到前确认禁用", async () => {
		const deferred = Promise.withResolvers<unknown>();
		adminLib.fetchAdminEvent
			.mockResolvedValueOnce(OPEN_DETAIL)
			.mockImplementationOnce(() => deferred.promise);

		render(<AdminEventsPage />);
		await openEditor("open-meetup");

		fireEvent.click(screen.getByLabelText(/押金槽位/));
		fireEvent.click(screen.getByRole("button", { name: "保存" }));

		const dialog = await screen.findByRole("dialog");
		expect(within(dialog).getByText("正在现取权威计数…")).toBeInTheDocument();
		expect(within(dialog).getByRole("button", { name: "确认关停" })).toBeDisabled();

		deferred.resolve(OPEN_DETAIL);
		expect(await within(dialog).findByText(/批量免缴 2 笔/)).toBeInTheDocument();
		expect(within(dialog).getByRole("button", { name: "确认关停" })).toBeEnabled();
	});

	it("弹窗取数失败：渲染不可用态且确认禁用（不落假值）", async () => {
		adminLib.fetchAdminEvent
			.mockResolvedValueOnce(OPEN_DETAIL)
			.mockRejectedValue(new Error("network"));

		render(<AdminEventsPage />);
		await openEditor("open-meetup");

		fireEvent.click(screen.getByLabelText(/押金槽位/));
		fireEvent.click(screen.getByRole("button", { name: "保存" }));

		const dialog = await screen.findByRole("dialog");
		expect(await within(dialog).findByText(/计数不可用（现取失败）/)).toBeInTheDocument();
		expect(within(dialog).getByRole("button", { name: "确认关停" })).toBeDisabled();
		expect(adminLib.adminUpdateEvent).not.toHaveBeenCalled();
	});

	it("pending > 200：关槽位入口隐藏并引导走取消", async () => {
		adminLib.fetchAdminEvent.mockResolvedValue({
			...OPEN_DETAIL,
			paymentPendingCount: 250,
		});

		render(<AdminEventsPage />);
		await openEditor("open-meetup");

		expect(screen.queryByLabelText(/押金槽位/)).toBeNull();
		expect(screen.queryByLabelText(/定价槽位/)).toBeNull();
		expect(screen.getAllByText(/超过 200 笔批量免缴上限/).length).toBeGreaterThan(0);
	});

	it("计数不可用：关槽位入口禁用并给出说明", async () => {
		adminLib.fetchAdminEvent.mockResolvedValue({
			...OPEN_DETAIL,
			paymentPendingCount: null,
		});

		render(<AdminEventsPage />);
		await openEditor("open-meetup");

		expect(screen.getByLabelText(/押金槽位/)).toBeDisabled();
		expect(screen.getAllByText(/关槽位入口已禁用/).length).toBeGreaterThan(0);
	});
});
