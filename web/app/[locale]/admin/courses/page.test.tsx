import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, screen, fireEvent, waitFor, within } from "@testing-library/react";
import { render } from "@/test-utils";
import AdminCoursesPage from "./page";

const adminLib = vi.hoisted(() => ({
	adminCancelCourse: vi.fn(),
	adminCloseCourse: vi.fn(),
	adminLaunchCourse: vi.fn(),
	adminUpdateCourse: vi.fn(),
	fetchAdminCourse: vi.fn(),
	fetchAdminCourses: vi.fn(),
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
	usePathname: () => "/admin/courses",
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

/** 占位标题课程：发布前置门，列表与详情都要标黄 */
const DRAFT_ROW = {
	id: "c-draft",
	workspaceId: "w1",
	title: "未命名课程",
	provisionalTitle: true,
	slug: "draft-course",
	status: "draft",
	visibility: "workspace",
	capacity: 20,
	registrationDeadline: null,
	startsAt: "2026-10-01T02:00:00Z",
	endsAt: null,
	pricingEnabled: false,
	insertedAt: "2026-09-01T00:00:00Z",
	updatedAt: "2026-09-01T00:00:00Z",
};

const OPEN_ROW = {
	id: "c-open",
	workspaceId: "w1",
	title: "Open Course",
	provisionalTitle: false,
	slug: "open-course",
	status: "open",
	visibility: "public",
	capacity: null,
	registrationDeadline: "2026-09-28T02:00:00Z",
	startsAt: "2026-09-30T02:00:00Z",
	endsAt: null,
	pricingEnabled: true,
	insertedAt: "2026-09-01T00:00:00Z",
	updatedAt: "2026-09-01T00:00:00Z",
};

const CLOSED_ROW = {
	...OPEN_ROW,
	id: "c-closed",
	title: "Closed Course",
	slug: "closed-course",
	status: "closed",
};

/** 详情 = 行 + 处置与排查投影（权威计数、简介）；Course 无 venue / 押金 / 主理人 */
const OPEN_DETAIL = {
	...OPEN_ROW,
	description: "course desc",
	confirmedCount: 3,
	paymentPendingCount: 2,
};

const DRAFT_DETAIL = {
	...DRAFT_ROW,
	description: null,
	confirmedCount: 0,
	paymentPendingCount: 0,
};

const FINDINGS = [
	{
		id: "f1",
		rule: "capacity_projection_drift",
		entityType: "course",
		entityId: "c-open",
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
	adminLib.fetchAdminCourses.mockResolvedValue([DRAFT_ROW, OPEN_ROW, CLOSED_ROW]);
	adminLib.fetchAdminCourse.mockResolvedValue(OPEN_DETAIL);
	adminLib.fetchReconciliationFindings.mockResolvedValue(FINDINGS);
	adminLib.fetchWorkspaces.mockResolvedValue(WORKSPACES);
	copyText.mockResolvedValue(true);
});

afterEach(cleanup);

describe("/admin/courses 列表与定位", () => {
	it("渲染全状态行、工作台名与状态徽章", async () => {
		render(<AdminCoursesPage />);

		const draftRow = (await screen.findByText("未命名课程")).closest("tr")!;
		const openRow = screen.getByText("Open Course").closest("tr")!;
		const closedRow = screen.getByText("Closed Course").closest("tr")!;
		expect(within(draftRow).getByText("草稿")).toBeInTheDocument();
		expect(within(openRow).getByText("开放报名")).toBeInTheDocument();
		expect(within(closedRow).getByText("已结束")).toBeInTheDocument();
		await waitFor(() => expect(screen.getAllByText("Hackerstart").length).toBeGreaterThan(0));
		expect(within(draftRow).getByText("20")).toBeInTheDocument();
		expect(within(openRow).getAllByText("不限").length).toBeGreaterThan(0);
	});

	it("搜索 / 状态 / 工作台过滤一起下发（offset 归零）", async () => {
		render(<AdminCoursesPage />);
		await screen.findAllByText("Hackerstart");

		fireEvent.change(screen.getByLabelText("搜索课程"), {
			target: { value: "course" },
		});
		fireEvent.change(screen.getByLabelText("课程状态过滤"), {
			target: { value: "open" },
		});
		fireEvent.change(screen.getByLabelText("工作台过滤"), {
			target: { value: "w1" },
		});
		fireEvent.click(screen.getByRole("button", { name: "过滤" }));

		await waitFor(() =>
			expect(adminLib.fetchAdminCourses).toHaveBeenLastCalledWith(
				{ search: "course", status: "open", workspaceId: "w1" },
				{ first: 20, after: "0" },
			),
		);
	});

	it("列表读失败：渲染错误提示且不落「暂无课程」假空态", async () => {
		adminLib.fetchAdminCourses.mockRejectedValue(new Error("network"));

		render(<AdminCoursesPage />);

		expect(await screen.findByRole("alert")).toHaveTextContent("加载失败。");
		expect(screen.queryByText("暂无课程。")).toBeNull();
	});

	it("分页：下一页按已返回条数推进 offset", async () => {
		const page = Array.from({ length: 20 }, (_, index) => ({
			...OPEN_ROW,
			id: `c-${index}`,
			slug: `slug-${index}`,
			title: `Course ${index}`,
		}));
		adminLib.fetchAdminCourses.mockResolvedValue(page);

		render(<AdminCoursesPage />);
		await screen.findByText("Course 0");

		fireEvent.click(screen.getByRole("button", { name: "下一页" }));

		await waitFor(() =>
			expect(adminLib.fetchAdminCourses).toHaveBeenLastCalledWith({}, { first: 20, after: "20" }),
		);
	});
});

describe("生命周期操作可见性矩阵", () => {
	it("draft 只有发布；open 有结束 + 取消；终态无生命周期按钮", async () => {
		render(<AdminCoursesPage />);

		const draftRow = (await screen.findByText("draft-course")).closest("tr")!;
		const openRow = screen.getByText("open-course").closest("tr")!;
		const closedRow = screen.getByText("closed-course").closest("tr")!;

		expect(within(draftRow).getByRole("button", { name: "发布" })).toBeInTheDocument();
		expect(within(draftRow).queryByRole("button", { name: "结束" })).toBeNull();
		expect(within(draftRow).queryByRole("button", { name: "取消课程" })).toBeNull();

		expect(within(openRow).getByRole("button", { name: "结束" })).toBeInTheDocument();
		expect(within(openRow).getByRole("button", { name: "取消课程" })).toBeInTheDocument();
		expect(within(openRow).queryByRole("button", { name: "发布" })).toBeNull();

		expect(within(closedRow).queryByRole("button", { name: "发布" })).toBeNull();
		expect(within(closedRow).queryByRole("button", { name: "结束" })).toBeNull();
		expect(within(closedRow).queryByRole("button", { name: "取消课程" })).toBeNull();
	});

	it("发布成功：列表行状态切为 open", async () => {
		adminLib.adminLaunchCourse.mockResolvedValue({
			result: { id: "c-draft", slug: "draft-course", status: "open" },
			errors: [],
		});
		adminLib.fetchAdminCourses
			.mockResolvedValueOnce([DRAFT_ROW, OPEN_ROW, CLOSED_ROW])
			.mockResolvedValue([{ ...DRAFT_ROW, status: "open" }, OPEN_ROW, CLOSED_ROW]);

		render(<AdminCoursesPage />);
		const draftRow = (await screen.findByText("draft-course")).closest("tr")!;
		fireEvent.click(within(draftRow).getByRole("button", { name: "发布" }));

		await waitFor(() =>
			expect(within(draftRow).getByRole("button", { name: "结束" })).toBeInTheDocument(),
		);
		expect(adminLib.adminLaunchCourse).toHaveBeenCalledWith("c-draft");
	});

	it("mutation 错误信封行内呈现（列表保留）", async () => {
		adminLib.adminLaunchCourse.mockResolvedValue({
			result: null,
			errors: [{ code: "invalid_changes", message: "invalid course transition" }],
		});

		render(<AdminCoursesPage />);
		const draftRow = (await screen.findByText("draft-course")).closest("tr")!;
		fireEvent.click(within(draftRow).getByRole("button", { name: "发布" }));

		expect(await screen.findByRole("alert")).toHaveTextContent("invalid course transition");
		expect(screen.getByText("open-course")).toBeInTheDocument();
	});

	it("slug 锁定错误按稳定 code 本地化（不透传英文原文）", async () => {
		adminLib.adminLaunchCourse.mockResolvedValue({
			result: null,
			errors: [{ code: "course_slug_locked", message: "slug is locked" }],
		});

		render(<AdminCoursesPage />);
		const draftRow = (await screen.findByText("draft-course")).closest("tr")!;
		fireEvent.click(within(draftRow).getByRole("button", { name: "发布" }));

		expect(await screen.findByRole("alert")).toHaveTextContent("slug 不可再修改");
	});
});

describe("取消课程（高危确认，KTD4）", () => {
	it("确认弹窗披露已付/待付笔数，确认后取消并刷新", async () => {
		const confirmSpy = vi.spyOn(window, "confirm").mockReturnValue(true);
		adminLib.adminCancelCourse.mockResolvedValue({
			result: { id: "c-open", slug: "open-course", status: "cancelled" },
			errors: [],
		});

		render(<AdminCoursesPage />);
		const openRow = (await screen.findByText("open-course")).closest("tr")!;
		fireEvent.click(within(openRow).getByRole("button", { name: "取消课程" }));

		await waitFor(() => expect(confirmSpy).toHaveBeenCalled());
		const message = String(confirmSpy.mock.calls[0][0]);
		expect(message).toContain("3");
		expect(message).toContain("2");
		await waitFor(() => expect(adminLib.adminCancelCourse).toHaveBeenCalledWith("c-open"));
		// 写成功后列表按当前过滤重取（状态刷新）
		expect(adminLib.fetchAdminCourses.mock.calls.length).toBeGreaterThan(1);
		confirmSpy.mockRestore();
	});

	it("取消确认被拒：不调用后端", async () => {
		const confirmSpy = vi.spyOn(window, "confirm").mockReturnValue(false);

		render(<AdminCoursesPage />);
		const openRow = (await screen.findByText("open-course")).closest("tr")!;
		fireEvent.click(within(openRow).getByRole("button", { name: "取消课程" }));

		await waitFor(() => expect(confirmSpy).toHaveBeenCalled());
		expect(adminLib.adminCancelCourse).not.toHaveBeenCalled();
		confirmSpy.mockRestore();
	});

	it("计数取不到时不落假值：确认文案按「不可用」披露", async () => {
		const confirmSpy = vi.spyOn(window, "confirm").mockReturnValue(false);
		adminLib.fetchAdminCourse.mockRejectedValue(new Error("network"));

		render(<AdminCoursesPage />);
		const openRow = (await screen.findByText("open-course")).closest("tr")!;
		fireEvent.click(within(openRow).getByRole("button", { name: "取消课程" }));

		await waitFor(() => expect(confirmSpy).toHaveBeenCalled());
		const message = String(confirmSpy.mock.calls[0][0]);
		expect(message).toContain("计数不可用");
		expect(message).not.toContain("{confirmed}");
		confirmSpy.mockRestore();
	});
});

describe("行展开详情（四类投影）", () => {
	it("展开按 (entityType=course, entityId) 拉对账发现并渲染计数与简介", async () => {
		render(<AdminCoursesPage />);
		await expandRow("open-course");

		expect(await screen.findByText("course desc")).toBeInTheDocument();
		expect(adminLib.fetchReconciliationFindings).toHaveBeenCalledWith({
			entityType: "course",
			entityId: "c-open",
		});
		expect(screen.getByText("名额展示投影漂移")).toBeInTheDocument();
	});

	it("计数不可用（null）→ 渲染不可用态而非 0", async () => {
		adminLib.fetchAdminCourse.mockResolvedValue({
			...OPEN_DETAIL,
			confirmedCount: null,
			paymentPendingCount: null,
		});

		render(<AdminCoursesPage />);
		await expandRow("open-course");

		expect(await screen.findByText("计数不可用")).toBeInTheDocument();
	});

	it("详情取数失败 → 展开行渲染不可用态", async () => {
		adminLib.fetchAdminCourse.mockResolvedValue(null);

		render(<AdminCoursesPage />);
		await expandRow("open-course");

		expect(
			await screen.findByText("该课程详情加载失败，或该 id 已不存在。"),
		).toBeInTheDocument();
	});

	it("?entity_id= 定位并自动展开该行（含 findings）", async () => {
		searchParams.value = new URLSearchParams("entity_id=c-open");

		render(<AdminCoursesPage />);

		await waitFor(() => expect(adminLib.fetchAdminCourse).toHaveBeenCalledWith("c-open"));
		expect(await screen.findByText("course desc")).toBeInTheDocument();
		expect(adminLib.fetchReconciliationFindings).toHaveBeenCalledWith({
			entityType: "course",
			entityId: "c-open",
		});
	});

	it("?entity_id= 指向不在当前列表的行：该行仍可见（对账跳转不落空）", async () => {
		searchParams.value = new URLSearchParams("entity_id=c-open");
		adminLib.fetchAdminCourses.mockResolvedValue([CLOSED_ROW]);

		render(<AdminCoursesPage />);

		expect(await screen.findByText("Open Course")).toBeInTheDocument();
		expect(screen.getByText("已按对账跳转定位（不在当前筛选结果内）")).toBeInTheDocument();
	});
});

describe("占位标题标记（U4 投影差异）", () => {
	it("占位标题行标黄；非占位行无徽章", async () => {
		render(<AdminCoursesPage />);

		const draftRow = (await screen.findByText("未命名课程")).closest("tr")!;
		const openRow = screen.getByText("Open Course").closest("tr")!;

		expect(within(draftRow).getByText("占位标题")).toBeInTheDocument();
		expect(within(openRow).queryByText("占位标题")).toBeNull();
	});

	it("展开占位标题课程：详情标记与发布前置门说明一并渲染", async () => {
		adminLib.fetchAdminCourse.mockResolvedValue(DRAFT_DETAIL);

		render(<AdminCoursesPage />);
		await expandRow("draft-course");

		expect(await screen.findByText(/这是发布前置门/)).toBeInTheDocument();
		// 行内徽章 + 详情徽章同现（占位标题一眼可辨）
		expect(screen.getAllByText("占位标题").length).toBeGreaterThan(1);
	});
});

describe("元数据编辑（R5 全集，只落变更键）", () => {
	it("提交标题/简介/容量/可见性/开始时间：update 只带变更键，成功后重取详情刷新计数", async () => {
		adminLib.adminUpdateCourse.mockResolvedValue({
			result: { id: "c-open", slug: "open-course", status: "open" },
			errors: [],
		});

		render(<AdminCoursesPage />);
		await openEditor("open-course");

		fireEvent.change(screen.getByLabelText("标题"), { target: { value: "Open Course 2" } });
		fireEvent.change(screen.getByLabelText("课程简介"), { target: { value: "新的课程简介" } });
		fireEvent.change(screen.getByLabelText("名额上限"), { target: { value: "42" } });
		fireEvent.change(screen.getByLabelText("可见性"), { target: { value: "workspace" } });
		fireEvent.change(screen.getByLabelText("开始时间"), {
			target: { value: "2026-10-01T10:30" },
		});
		fireEvent.click(screen.getByRole("button", { name: "保存" }));

		await waitFor(() =>
			expect(adminLib.adminUpdateCourse).toHaveBeenCalledWith("c-open", {
				title: "Open Course 2",
				description: "新的课程简介",
				capacity: 42,
				visibility: "workspace",
				startsAt: new Date("2026-10-01T10:30").toISOString(),
			}),
		);
		// KTD4：写成功后重取详情（权威计数刷新）——展开详情触发的读 + 写后重取
		await waitFor(() => expect(adminLib.fetchAdminCourse.mock.calls.length).toBeGreaterThan(1));
	});

	it("清空简介：下发 description: null（清列，不发空串）", async () => {
		adminLib.adminUpdateCourse.mockResolvedValue({
			result: { id: "c-open", slug: "open-course", status: "open" },
			errors: [],
		});

		render(<AdminCoursesPage />);
		await openEditor("open-course");

		fireEvent.change(screen.getByLabelText("课程简介"), { target: { value: "" } });
		fireEvent.click(screen.getByRole("button", { name: "保存" }));

		await waitFor(() =>
			expect(adminLib.adminUpdateCourse).toHaveBeenCalledWith("c-open", { description: null }),
		);
	});

	it("无变更（含仅首尾空白差异）点保存：不发 mutation，提示没有需要保存的变更", async () => {
		render(<AdminCoursesPage />);
		await openEditor("open-course");

		fireEvent.change(screen.getByLabelText("课程简介"), {
			target: { value: "  course desc  " },
		});
		fireEvent.click(screen.getByRole("button", { name: "保存" }));

		expect(await screen.findByText("没有需要保存的变更。")).toBeInTheDocument();
		expect(adminLib.adminUpdateCourse).not.toHaveBeenCalled();
	});

	it("名额上限非法就地拦截", async () => {
		render(<AdminCoursesPage />);
		await openEditor("open-course");

		fireEvent.change(screen.getByLabelText("名额上限"), { target: { value: "0" } });
		fireEvent.click(screen.getByRole("button", { name: "保存" }));

		expect(await screen.findByText("名额上限须为正整数，留空表示不限。")).toBeInTheDocument();
		expect(adminLib.adminUpdateCourse).not.toHaveBeenCalled();
	});

	it("slug 只读展示：编辑表单不允许改 slug", async () => {
		render(<AdminCoursesPage />);
		await openEditor("open-course");

		expect(screen.getByLabelText("Slug")).toHaveAttribute("readonly");
		expect(screen.getByText("公开链接已生效，slug 发布后不可修改")).toBeInTheDocument();
	});
});

describe("定价槽位关停（KTD4 单一取数契约）", () => {
	it("pending ≤ 200：确认弹窗现取计数并披露笔数，确认后提交 pricingEnabled:false", async () => {
		adminLib.adminUpdateCourse.mockResolvedValue({
			result: { id: "c-open", slug: "open-course", status: "open" },
			errors: [],
		});

		render(<AdminCoursesPage />);
		await openEditor("open-course");

		fireEvent.click(screen.getByLabelText("定价槽位"));
		fireEvent.click(screen.getByRole("button", { name: "保存" }));

		const dialog = await screen.findByRole("dialog");
		expect(within(dialog).getByText("即将关停：定价槽位")).toBeInTheDocument();
		// 弹窗内数字来自现取（OPEN_DETAIL.paymentPendingCount = 2）
		expect(await within(dialog).findByText(/批量免缴 2 笔/)).toBeInTheDocument();
		fireEvent.click(within(dialog).getByRole("button", { name: "确认关停" }));

		await waitFor(() =>
			expect(adminLib.adminUpdateCourse).toHaveBeenCalledWith("c-open", {
				pricingEnabled: false,
			}),
		);
	});

	it("关槽位同批改标题：单次提交含两个键", async () => {
		adminLib.adminUpdateCourse.mockResolvedValue({
			result: { id: "c-open", slug: "open-course", status: "open" },
			errors: [],
		});

		render(<AdminCoursesPage />);
		await openEditor("open-course");

		fireEvent.change(screen.getByLabelText("标题"), { target: { value: "Open Course 2" } });
		fireEvent.click(screen.getByLabelText("定价槽位"));
		fireEvent.click(screen.getByRole("button", { name: "保存" }));

		const dialog = await screen.findByRole("dialog");
		fireEvent.click(within(dialog).getByRole("button", { name: "确认关停" }));

		await waitFor(() =>
			expect(adminLib.adminUpdateCourse).toHaveBeenCalledWith("c-open", {
				title: "Open Course 2",
				pricingEnabled: false,
			}),
		);
	});

	it("弹窗取数中渲染 loading，取到前确认禁用", async () => {
		const deferred = Promise.withResolvers<unknown>();
		adminLib.fetchAdminCourse
			.mockResolvedValueOnce(OPEN_DETAIL)
			.mockImplementationOnce(() => deferred.promise);

		render(<AdminCoursesPage />);
		await openEditor("open-course");

		fireEvent.click(screen.getByLabelText("定价槽位"));
		fireEvent.click(screen.getByRole("button", { name: "保存" }));

		const dialog = await screen.findByRole("dialog");
		expect(within(dialog).getByText("正在现取权威计数…")).toBeInTheDocument();
		expect(within(dialog).getByRole("button", { name: "确认关停" })).toBeDisabled();

		deferred.resolve(OPEN_DETAIL);
		expect(await within(dialog).findByText(/批量免缴 2 笔/)).toBeInTheDocument();
		expect(within(dialog).getByRole("button", { name: "确认关停" })).toBeEnabled();
	});

	it("弹窗取数失败：渲染不可用态且确认禁用（不落假值）", async () => {
		adminLib.fetchAdminCourse
			.mockResolvedValueOnce(OPEN_DETAIL)
			.mockRejectedValue(new Error("network"));

		render(<AdminCoursesPage />);
		await openEditor("open-course");

		fireEvent.click(screen.getByLabelText("定价槽位"));
		fireEvent.click(screen.getByRole("button", { name: "保存" }));

		const dialog = await screen.findByRole("dialog");
		expect(await within(dialog).findByText(/计数不可用（现取失败）/)).toBeInTheDocument();
		expect(within(dialog).getByRole("button", { name: "确认关停" })).toBeDisabled();
		expect(adminLib.adminUpdateCourse).not.toHaveBeenCalled();
	});

	it("pending > 200：关槽位入口隐藏并引导走取消课程", async () => {
		adminLib.fetchAdminCourse.mockResolvedValue({
			...OPEN_DETAIL,
			paymentPendingCount: 250,
		});

		render(<AdminCoursesPage />);
		await openEditor("open-course");

		expect(screen.queryByLabelText("定价槽位")).toBeNull();
		expect(screen.getByText(/超过 200 笔批量免缴上限/)).toBeInTheDocument();
	});

	it("计数不可用：关槽位入口禁用并给出说明", async () => {
		adminLib.fetchAdminCourse.mockResolvedValue({
			...OPEN_DETAIL,
			paymentPendingCount: null,
		});

		render(<AdminCoursesPage />);
		await openEditor("open-course");

		expect(screen.getByLabelText("定价槽位")).toBeDisabled();
		expect(screen.getByText(/关槽位入口已禁用/)).toBeInTheDocument();
	});
});
