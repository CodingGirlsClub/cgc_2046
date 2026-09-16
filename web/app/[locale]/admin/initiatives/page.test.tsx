import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, screen, fireEvent, waitFor, within } from "@testing-library/react";
import { render } from "@/test-utils";
import { formatDateTime } from "@/lib/format";
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

const { copyText } = vi.hoisted(() => ({ copyText: vi.fn() }));

vi.mock("@/lib/clipboard", () => ({ copyText }));

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

/* ---- #595 fixtures：四项规则 + 三场挂载（draft / open+定价 / closed） ---- */

const DEPOSIT_JSON = '{"enabled":true,"amount_cents":6900}';

/**
 * 真正变更过的押金值。新语义"无脏草稿不提交"（F1）下，React 对**同值**不派发
 * onChange → 无草稿 → 不提交、不弹层；验证确认流必须真的改值。
 */
const CHANGED_DEPOSIT_JSON = '{"enabled":true,"amount_cents":7000}';

const RULES = [
	{ id: "r1", initiativeId: "i2", key: "deposit", valueJson: DEPOSIT_JSON, locked: true },
	{ id: "r2", initiativeId: "i2", key: "age_gate", valueJson: '{"min_age":18}', locked: false },
	{ id: "r3", initiativeId: "i2", key: "min_participants", valueJson: '{"count":8}', locked: true },
	{ id: "r4", initiativeId: "i2", key: "deadline_rule", valueJson: '{"hours_before_start":72}', locked: false },
];

const MOUNTS = [
	{
		id: "e1",
		initiativeId: "i2",
		slug: "draft-venue",
		title: "Draft Venue",
		status: "draft",
		startsAt: "2026-10-01T10:00:00Z",
		registrationDeadline: "2026-09-28T10:00:00Z",
		venue: JSON.stringify({ country: "China", province: "Hunan", city: "Changsha", district: "Yuelu" }),
		workspaceId: "w1",
		workspaceName: "Workspace A",
		confirmedCount: 2,
		pricingEnabled: false,
		depositEnabled: true,
		depositAmountCents: 6900,
		minAge: 18,
		minParticipants: 8,
	},
	{
		id: "e2",
		initiativeId: "i2",
		slug: "open-priced",
		title: "Open Priced",
		status: "open",
		startsAt: "2026-10-05T10:00:00Z",
		registrationDeadline: null,
		venue: null,
		workspaceId: "w2",
		workspaceName: "Workspace B",
		confirmedCount: 3,
		pricingEnabled: true,
		depositEnabled: false,
		depositAmountCents: null,
		minAge: null,
		minParticipants: 8,
	},
	{
		id: "e3",
		initiativeId: "i2",
		slug: "closed-one",
		title: "Closed One",
		status: "closed",
		startsAt: null,
		registrationDeadline: null,
		venue: null,
		workspaceId: "w3",
		workspaceName: "Workspace C",
		confirmedCount: 5,
		pricingEnabled: false,
		depositEnabled: false,
		depositAmountCents: null,
		minAge: null,
		minParticipants: null,
	},
];

const DETAIL_ROW = { ...DRAFT_ROW, rules: RULES, mountedEvents: MOUNTS };

const savedRule = (key: string, valueJson: string, locked: boolean) => ({
	result: { id: `r-${key}`, initiativeId: "i2", key, valueJson, locked },
	errors: [],
});

beforeEach(() => {
	vi.clearAllMocks();
	adminLib.fetchInitiatives.mockResolvedValue([OPEN_ROW, DRAFT_ROW]);
	adminLib.fetchInitiative.mockResolvedValue(DRAFT_ROW);
	copyText.mockResolvedValue(true);
});

afterEach(() => {
	cleanup();
	vi.unstubAllEnvs();
});

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
			expect(within(openRow).getByText("已结束")).toBeInTheDocument(),
		);
		expect(adminLib.closeInitiative).toHaveBeenCalledWith("i1");
	});
});

describe("公开链接出口（Patch 3）", () => {
	it("每行可复制与 sitemap/canonical 同源的公开链接", async () => {
		vi.stubEnv("NEXT_PUBLIC_WEB_BASE_URL", "https://codingirlsclub.com");

		render(<AdminInitiativesPage />);
		const openRow = (await screen.findByText("hackerstart1024")).closest("tr")!;
		const draftRow = screen.getByText("e2e-drive").closest("tr")!;
		expect(
			within(openRow).getByRole("button", { name: "复制公开链接" }),
		).toBeInTheDocument();
		expect(
			within(draftRow).getByRole("button", { name: "复制公开链接" }),
		).toBeInTheDocument();

		fireEvent.click(
			within(openRow).getByRole("button", { name: "复制公开链接" }),
		);

		await waitFor(() =>
			expect(copyText).toHaveBeenCalledWith(
				"https://codingirlsclub.com/initiatives/hackerstart1024",
			),
		);
		await waitFor(() =>
			expect(
				within(openRow).getByRole("button", { name: "已复制" }),
			).toBeInTheDocument(),
		);
	});

	it("复制失败保持原文案（不假装成功）", async () => {
		copyText.mockResolvedValue(false);

		render(<AdminInitiativesPage />);
		const openRow = (await screen.findByText("hackerstart1024")).closest("tr")!;
		fireEvent.click(
			within(openRow).getByRole("button", { name: "复制公开链接" }),
		);

		await waitFor(() => expect(copyText).toHaveBeenCalled());
		expect(
			within(openRow).getByRole("button", { name: "复制公开链接" }),
		).toBeInTheDocument();
		expect(within(openRow).queryByRole("button", { name: "已复制" })).toBeNull();
	});
});

describe("结构 / 设计系统接入", () => {
	it("列表表格使用 admin 表格形制", async () => {
		render(<AdminInitiativesPage />);
		await screen.findByText("Hackerstart 1024");

		const table = document.querySelector("table")!;
		expect(table.className).toContain("admin-table");
		expect(table.parentElement?.className).toContain("admin-card");
		expect(table.parentElement?.className).toContain("admin-table-wrap");
	});

	it("状态列渲染为本地化徽章", async () => {
		render(<AdminInitiativesPage />);
		const openRow = (await screen.findByText("hackerstart1024")).closest(
			"tr",
		)!;

		const badge = openRow.querySelector("td:nth-child(3) span")!;
		expect(badge.className).toContain("l-badge");
		expect(badge).toHaveTextContent("开放报名");
	});

	it("操作按钮带 admin 按钮形制类", async () => {
		render(<AdminInitiativesPage />);
		const openRow = (await screen.findByText("hackerstart1024")).closest(
			"tr",
		)!;

		expect(
			within(openRow).getByRole("button", { name: "结束" }).className,
		).toContain("l-btn-outline");
	});

	it("后端错误以 admin 警示条呈现", async () => {
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

		const alert = await screen.findByRole("alert");
		expect(alert.className).toContain("admin-alert--error");
	});
});

const SLUG_LOCKED_COPY = "公开链接已生效，slug 发布后不可修改";

describe("slug 发布后锁定（#588）", () => {
	it("编辑 open 行：slug 输入禁用 + 锁定说明，其余字段仍可编辑", async () => {
		render(<AdminInitiativesPage />);
		const openRow = (await screen.findByText("hackerstart1024")).closest("tr")!;
		fireEvent.click(within(openRow).getByRole("button", { name: "编辑" }));

		expect(screen.getByLabelText("Slug")).toBeDisabled();
		expect(screen.getByText(SLUG_LOCKED_COPY)).toBeInTheDocument();
		expect(screen.getByLabelText("名称")).not.toBeDisabled();
	});

	it("编辑 draft 行：slug 输入可用、无锁定说明", async () => {
		render(<AdminInitiativesPage />);
		const draftRow = (await screen.findByText("e2e-drive")).closest("tr")!;
		fireEvent.click(within(draftRow).getByRole("button", { name: "编辑" }));

		expect(screen.getByLabelText("Slug")).not.toBeDisabled();
		expect(screen.queryByText(SLUG_LOCKED_COPY)).toBeNull();
	});

	it("编辑 open 行只改 name 后保存：payload 仍带未变的旧 slug（同值不触发锁定）", async () => {
		adminLib.updateInitiative.mockResolvedValue({
			result: { ...OPEN_ROW, name: "改名后的活动" },
			errors: [],
		});

		render(<AdminInitiativesPage />);
		const openRow = (await screen.findByText("hackerstart1024")).closest("tr")!;
		fireEvent.click(within(openRow).getByRole("button", { name: "编辑" }));
		fireEvent.change(screen.getByLabelText("名称"), {
			target: { value: "改名后的活动" },
		});
		fireEvent.click(screen.getByRole("button", { name: "保存" }));

		await waitFor(() =>
			expect(adminLib.updateInitiative).toHaveBeenCalledWith("i1", {
				name: "改名后的活动",
				slug: "hackerstart1024",
				description: "",
			}),
		);
		expect(screen.queryByRole("alert")).toBeNull();
		expect(await screen.findByText("改名后的活动")).toBeInTheDocument();
	});

	it("open 行保存被后端锁定拒：警示条呈现后端消息", async () => {
		adminLib.updateInitiative.mockResolvedValue({
			result: null,
			errors: [
				{
					code: "initiative_slug_locked",
					message:
						"slug is locked once the initiative is published (editable in draft only)",
				},
			],
		});

		render(<AdminInitiativesPage />);
		const openRow = (await screen.findByText("hackerstart1024")).closest("tr")!;
		fireEvent.click(within(openRow).getByRole("button", { name: "编辑" }));
		fireEvent.click(screen.getByRole("button", { name: "保存" }));

		expect(await screen.findByRole("alert")).toHaveTextContent(
			"slug is locked",
		);
	});

	it("en locale：锁定说明走 i18n", async () => {
		render(<AdminInitiativesPage />, { locale: "en" });
		const openRow = (await screen.findByText("hackerstart1024")).closest("tr")!;
		fireEvent.click(within(openRow).getByRole("button", { name: "Edit" }));

		expect(
			screen.getByText(
				"Public link is live — the slug is locked after publish",
			),
		).toBeInTheDocument();
	});
});

/**
 * #595：挂载场可见性 + 锁死规则变更影响预览与二次确认。
 *
 * 验收钉子：取消（按钮 / Escape / 遮罩）一律不发 mutation 且草稿回滚；
 * 确认后才发；拒绝路径按 fields 定位到具体场/工作台。
 */
describe("#595 挂载场视图与规则变更确认", () => {
	async function openEditor() {
		adminLib.fetchInitiative.mockResolvedValue(DETAIL_ROW);
		render(<AdminInitiativesPage />);
		const draftRow = (await screen.findByText("e2e-drive")).closest("tr")!;
		fireEvent.click(within(draftRow).getByRole("button", { name: "编辑" }));
		await screen.findByText("挂载场（3）");
	}

	function depositTextarea(): HTMLTextAreaElement {
		return screen.getByLabelText("押金规则") as HTMLTextAreaElement;
	}

	it("挂载场清单渲染工作台 / 场 / 状态 / 地点 / 已确认 / 资金 / 规则快照", async () => {
		await openEditor();

		const draftRow = screen.getByText("Draft Venue").closest("tr")!;
		expect(within(draftRow).getByText("Workspace A")).toBeInTheDocument();
		expect(within(draftRow).getByText("草稿")).toBeInTheDocument();
		expect(within(draftRow).getByText("China Hunan Changsha Yuelu")).toBeInTheDocument();
		expect(within(draftRow).getByText("2")).toBeInTheDocument();
		expect(within(draftRow).getByText("定价 关")).toBeInTheDocument();
		expect(within(draftRow).getByText("押金 开")).toBeInTheDocument();
		// 截止时间走被测代码同一个格式化函数推导期望值：不得写死本地时间字面量
		// （"2026-09-28 18:00" 是 UTC+8 的渲染结果，CI runner 为 UTC 会渲染成 10:00）
		expect(
			within(draftRow).getByText(
				`年龄 ≥ 18 · 成班 ≥ 8 · 截止 ${formatDateTime(MOUNTS[0].registrationDeadline)}`,
			),
		).toBeInTheDocument();

		const openRow = screen.getByText("Open Priced").closest("tr")!;
		expect(within(openRow).getByText("开放报名")).toBeInTheDocument();
		expect(within(openRow).getByText("地点待定")).toBeInTheDocument();
		expect(within(openRow).getByText("定价 开")).toBeInTheDocument();
		expect(within(openRow).getByText("押金 关")).toBeInTheDocument();

		const closedRow = screen.getByText("Closed One").closest("tr")!;
		expect(within(closedRow).getByText("已结束")).toBeInTheDocument();
		expect(within(closedRow).getByText("5")).toBeInTheDocument();
		// 规则快照全空 → 单元格为空（不渲染占位噪音）
		expect(closedRow.querySelectorAll("td")[6].textContent).toBe("");
	});

	it("无挂载场时显示空态", async () => {
		adminLib.fetchInitiative.mockResolvedValue({ ...DETAIL_ROW, mountedEvents: [] });
		render(<AdminInitiativesPage />);
		const draftRow = (await screen.findByText("e2e-drive")).closest("tr")!;
		fireEvent.click(within(draftRow).getByRole("button", { name: "编辑" }));

		expect(await screen.findByText("挂载场（0）")).toBeInTheDocument();
		expect(screen.getByText("尚未挂载任何场")).toBeInTheDocument();
	});

	it("锁死规则失焦：弹影响预览（分组数字 / 已确认人数 / 定价阻断提示），未确认不发 mutation", async () => {
		await openEditor();

		fireEvent.change(depositTextarea(), { target: { value: '{"enabled":false}' } });
		fireEvent.blur(depositTextarea());

		const dialog = await screen.findByRole("dialog");
		expect(within(dialog).getByText("规则：押金规则")).toBeInTheDocument();
		expect(
			within(dialog).getByText(
				"锁死规则将立即传播到该 Initiative 的挂载场：共 3 场（草稿 1 / 开放 1 / 终态 1）。",
			),
		).toBeInTheDocument();
		expect(within(dialog).getByText("累计已确认报名 10 人。")).toBeInTheDocument();
		expect(
			within(dialog).getByText(
				"其中 1 场已开定价：押金规则变更可能被服务端拒绝，请先关闭这些场的定价。",
			),
		).toBeInTheDocument();
		expect(within(dialog).getByText("实际影响范围以服务端返回为准。")).toBeInTheDocument();

		expect(adminLib.upsertInitiativeRule).not.toHaveBeenCalled();
	});

	it("弹出层取消：不发 mutation，且 textarea 草稿回滚到已存值", async () => {
		await openEditor();

		fireEvent.change(depositTextarea(), { target: { value: '{"enabled":false}' } });
		fireEvent.blur(depositTextarea());
		const dialog = await screen.findByRole("dialog");
		fireEvent.click(within(dialog).getByRole("button", { name: "取消" }));

		await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
		expect(adminLib.upsertInitiativeRule).not.toHaveBeenCalled();
		expect(depositTextarea().value).toBe(DEPOSIT_JSON);
	});

	it("Escape 与遮罩取消：与取消按钮同语义（不发 mutation + 草稿回滚）", async () => {
		await openEditor();

		fireEvent.change(depositTextarea(), { target: { value: '{"enabled":false}' } });
		fireEvent.blur(depositTextarea());
		await screen.findByRole("dialog");
		fireEvent.keyDown(document, { key: "Escape" });

		await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
		expect(adminLib.upsertInitiativeRule).not.toHaveBeenCalled();
		expect(depositTextarea().value).toBe(DEPOSIT_JSON);

		// 遮罩：role="dialog" 挂在遮罩层上，点它即取消
		fireEvent.change(depositTextarea(), { target: { value: '{"enabled":false}' } });
		fireEvent.blur(depositTextarea());
		fireEvent.click(await screen.findByRole("dialog"));

		await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
		expect(adminLib.upsertInitiativeRule).not.toHaveBeenCalled();
		expect(depositTextarea().value).toBe(DEPOSIT_JSON);
	});

	it("确认后按原值与 locked=true 发 mutation，并关闭弹层", async () => {
		adminLib.upsertInitiativeRule.mockResolvedValue(
			savedRule("deposit", '{"enabled":false}', true),
		);
		await openEditor();

		fireEvent.change(depositTextarea(), { target: { value: '{"enabled":false}' } });
		fireEvent.blur(depositTextarea());
		const dialog = await screen.findByRole("dialog");
		fireEvent.click(within(dialog).getByRole("button", { name: "确认写入" }));

		await waitFor(() =>
			expect(adminLib.upsertInitiativeRule).toHaveBeenCalledWith(
				"i2",
				"deposit",
				'{"enabled":false}',
				true,
			),
		);
		await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
	});

	it("勾上锁死开关同样走确认流（确认前真值不变）", async () => {
		adminLib.upsertInitiativeRule.mockResolvedValue(
			savedRule("age_gate", '{"min_age":18}', true),
		);
		await openEditor();

		const ageGateCheckbox = screen.getAllByRole("checkbox")[1] as HTMLInputElement;
		expect(ageGateCheckbox.checked).toBe(false);

		fireEvent.click(ageGateCheckbox);
		await screen.findByRole("dialog");
		expect(adminLib.upsertInitiativeRule).not.toHaveBeenCalled();
		expect(ageGateCheckbox.checked).toBe(false);

		fireEvent.click(within(screen.getByRole("dialog")).getByRole("button", { name: "取消" }));
		await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
		expect(adminLib.upsertInitiativeRule).not.toHaveBeenCalled();
		expect(ageGateCheckbox.checked).toBe(false);
	});

	it("非锁死规则失焦：不弹层直接写", async () => {
		adminLib.upsertInitiativeRule.mockResolvedValue(
			savedRule("age_gate", '{"min_age":21}', false),
		);
		await openEditor();

		const ageGate = screen.getByLabelText("年龄门槛") as HTMLTextAreaElement;
		fireEvent.change(ageGate, { target: { value: '{"min_age":21}' } });
		fireEvent.blur(ageGate);

		await waitFor(() =>
			expect(adminLib.upsertInitiativeRule).toHaveBeenCalledWith(
				"i2",
				"age_gate",
				'{"min_age":21}',
				false,
			),
		);
		expect(screen.queryByRole("dialog")).toBeNull();
	});

	it("规则被拒：按 fields 的 event_id 呈现「场 + 工作台」并本地化文案", async () => {
		adminLib.upsertInitiativeRule.mockResolvedValue({
			result: null,
			errors: [
				{
					code: "event_payment_mode_exclusive",
					message: "disable pricing before applying the deposit rule to this event",
					fields: ["event_id=e2"],
				},
			],
		});
		await openEditor();

		fireEvent.change(depositTextarea(), { target: { value: CHANGED_DEPOSIT_JSON } });
		fireEvent.blur(depositTextarea());
		fireEvent.click(
			within(await screen.findByRole("dialog")).getByRole("button", { name: "确认写入" }),
		);

		const alert = await screen.findByRole("alert");
		expect(alert).toHaveTextContent(
			"场「Open Priced」（工作台 Workspace B）：同一场活动只能选择一种缴费模式：请先关闭收费（或押金）再开启另一种。",
		);
		expect(alert).not.toHaveTextContent("disable pricing");
	});

	it("fields 指向未知场时退化为显示 event_id", async () => {
		adminLib.upsertInitiativeRule.mockResolvedValue({
			result: null,
			errors: [
				{
					code: "event_payment_mode_exclusive",
					message: "conflict",
					fields: ["event_id=e-unknown"],
				},
			],
		});
		await openEditor();

		fireEvent.change(depositTextarea(), { target: { value: CHANGED_DEPOSIT_JSON } });
		fireEvent.blur(depositTextarea());
		fireEvent.click(
			within(await screen.findByRole("dialog")).getByRole("button", { name: "确认写入" }),
		);

		const alert = await screen.findByRole("alert");
		expect(alert).toHaveTextContent("场 e-unknown：");
	});

	it("已知 code 且无 fields：只渲染本地化文案（不透传英文）", async () => {
		adminLib.upsertInitiativeRule.mockResolvedValue({
			result: null,
			errors: [
				{
					code: "event_payment_mode_exclusive",
					message: "disable pricing before applying the deposit rule to this event",
					fields: [],
				},
			],
		});
		await openEditor();

		fireEvent.change(depositTextarea(), { target: { value: CHANGED_DEPOSIT_JSON } });
		fireEvent.blur(depositTextarea());
		fireEvent.click(
			within(await screen.findByRole("dialog")).getByRole("button", { name: "确认写入" }),
		);

		const alert = await screen.findByRole("alert");
		expect(alert).toHaveTextContent(
			"同一场活动只能选择一种缴费模式：请先关闭收费（或押金）再开启另一种。",
		);
		expect(alert).not.toHaveTextContent("disable pricing");
	});

	// A3：invalid_input 是 web 契约层字面量（#241 规定不得进 domain 契约），
	// errors 命名空间里没有它的文案 → 必须走页面兜底，不能英文直出。
	it("未知 code（invalid_input）：走页面兜底文案，不英文直出", async () => {
		adminLib.upsertInitiativeRule.mockResolvedValue({
			result: null,
			errors: [
				{
					code: "invalid_input",
					message: "rule value_json must be valid JSON",
					fields: [],
				},
			],
		});
		await openEditor();

		fireEvent.change(depositTextarea(), { target: { value: "not-json" } });
		fireEvent.blur(depositTextarea());
		fireEvent.click(
			within(await screen.findByRole("dialog")).getByRole("button", { name: "确认写入" }),
		);

		const alert = await screen.findByRole("alert");
		expect(alert).toHaveTextContent("规则未保存：请检查规则值的格式与取值后重试。");
		expect(alert).not.toHaveTextContent("rule value_json");
	});

	// R1：锁死传播会改写押金/年龄/成班/截止列 → 写入成功后必须重拉清单快照
	it("确认锁死写入后重拉挂载场，表格反映传播结果", async () => {
		adminLib.upsertInitiativeRule.mockResolvedValue(
			savedRule("deposit", '{"enabled":false}', true),
		);
		const propagated = {
			...DETAIL_ROW,
			mountedEvents: MOUNTS.map((mount) =>
				mount.id === "e1"
					? { ...mount, depositEnabled: false, depositAmountCents: null }
					: mount,
			),
		};
		adminLib.fetchInitiative
			.mockResolvedValueOnce(DETAIL_ROW)
			.mockResolvedValueOnce(propagated);

		render(<AdminInitiativesPage />);
		const draftRow = (await screen.findByText("e2e-drive")).closest("tr")!;
		fireEvent.click(within(draftRow).getByRole("button", { name: "编辑" }));

		const beforeRow = (await screen.findByText("Draft Venue")).closest("tr")!;
		expect(within(beforeRow).getByText("押金 开")).toBeInTheDocument();

		fireEvent.change(depositTextarea(), { target: { value: '{"enabled":false}' } });
		fireEvent.blur(depositTextarea());
		fireEvent.click(
			within(await screen.findByRole("dialog")).getByRole("button", { name: "确认写入" }),
		);

		await waitFor(() =>
			expect(
				within(screen.getByText("Draft Venue").closest("tr")!).getByText("押金 关"),
			).toBeInTheDocument(),
		);
		expect(adminLib.fetchInitiative).toHaveBeenCalledTimes(2);
	});

	// R2：真实事件序 mousedown→focusout→click 下，失焦不得先按旧 locked 直写
	// N6：真实焦点序列（mousedown 真的把焦点移到 checkbox → 弹层 effect 再把焦点拉进弹层）。
	// 用 fireEvent.click 不移动焦点，测不到这条缝——必须显式 focus()。
	it("脏 textarea 后点锁死开关（真实焦点序）：弹层不被焦点拉回关掉、0 写入", async () => {
		await openEditor();

		const ageGate = screen.getByLabelText("年龄门槛") as HTMLTextAreaElement;
		const lockBox = screen.getAllByRole("checkbox")[1] as HTMLInputElement;
		expect(lockBox.checked).toBe(false);

		ageGate.focus();
		fireEvent.change(ageGate, { target: { value: '{"min_age":21}' } });
		// mousedown 的真实效果：焦点先移到本规则 checkbox（容器内 → 不提交）
		lockBox.focus();
		// click → onChange → 打开锁死确认弹层
		fireEvent.click(lockBox);

		const dialog = await screen.findByRole("dialog");
		// 弹层 effect 会把焦点拉进弹层（F6），那会从 checkbox 发出一次容器 focusout；
		// 若容器在弹层打开期间提交，就绕过确认并发出 locked=false 写入（N6）
		expect(adminLib.upsertInitiativeRule).not.toHaveBeenCalled();
		expect(lockBox.checked).toBe(false);
		expect(screen.getByRole("dialog")).toBeInTheDocument();

		fireEvent.click(within(dialog).getByRole("button", { name: "取消" }));
		await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
		expect(adminLib.upsertInitiativeRule).not.toHaveBeenCalled();
		expect(ageGate.value).toBe('{"min_age":18}');
	});

	it("锁死规则取消勾选：不弹层、只按 locked=false 写一次", async () => {
		adminLib.upsertInitiativeRule.mockResolvedValue(
			savedRule("deposit", DEPOSIT_JSON, false),
		);
		await openEditor();

		const deposit = depositTextarea();
		const lockBox = screen.getAllByRole("checkbox")[0] as HTMLInputElement;
		expect(lockBox.checked).toBe(true);

		fireEvent.change(deposit, { target: { value: DEPOSIT_JSON } });
		fireEvent.blur(deposit, { relatedTarget: lockBox });
		fireEvent.click(lockBox);

		await waitFor(() =>
			expect(adminLib.upsertInitiativeRule).toHaveBeenCalledWith(
				"i2",
				"deposit",
				DEPOSIT_JSON,
				false,
			),
		);
		expect(screen.queryByRole("dialog")).toBeNull();
		expect(adminLib.upsertInitiativeRule).toHaveBeenCalledTimes(1);
	});

	// R3：附挂读面失败不得打掉规则编辑区，且失败状态必须可见
	it("挂载场加载失败：显示失败提示，规则仍可编辑", async () => {
		adminLib.fetchInitiative.mockResolvedValue({ ...DETAIL_ROW, mountedEvents: null });

		render(<AdminInitiativesPage />);
		const draftRow = (await screen.findByText("e2e-drive")).closest("tr")!;
		fireEvent.click(within(draftRow).getByRole("button", { name: "编辑" }));

		expect(await screen.findByText(/挂载场清单加载失败/)).toBeInTheDocument();
		expect(depositTextarea()).toBeInTheDocument();
		expect(screen.queryByText("尚未挂载任何场")).toBeNull();
	});

	it("详情读失败：可见告警而不是空白面板", async () => {
		adminLib.fetchInitiative.mockRejectedValue(new Error("boom"));

		render(<AdminInitiativesPage />);
		const draftRow = (await screen.findByText("e2e-drive")).closest("tr")!;
		fireEvent.click(within(draftRow).getByRole("button", { name: "编辑" }));

		expect(await screen.findByRole("alert")).toHaveTextContent("加载失败。");
	});

	it("详情不存在（列表与详情之间被删）：告警且不进编辑态，不出现空规则面板", async () => {
		adminLib.fetchInitiative.mockResolvedValue(null);

		render(<AdminInitiativesPage />);
		const draftRow = (await screen.findByText("e2e-drive")).closest("tr")!;
		fireEvent.click(within(draftRow).getByRole("button", { name: "编辑" }));

		expect(await screen.findByRole("alert")).toHaveTextContent("加载失败。");
		expect(screen.queryByLabelText("押金规则")).toBeNull();
		expect(screen.queryByRole("checkbox")).toBeNull();
	});

	// A1 + F4 判据 B：写入在途时禁止切换编辑对象，否则"读早于写、落地晚于写"会让旧快照盖新状态
	it("规则写入在途时禁用「编辑」，落定后切换加载干净状态", async () => {
		let resolveWrite: (value: unknown) => void = () => {};
		adminLib.upsertInitiativeRule.mockImplementation(
			() => new Promise((resolve) => { resolveWrite = resolve; }),
		);
		await openEditor();

		const depositLock = screen.getAllByRole("checkbox")[0] as HTMLInputElement;
		expect(depositLock.checked).toBe(true);
		fireEvent.click(depositLock); // 取消锁死 → 直写（locked=false），请求挂起

		const openRow = screen.getByText("hackerstart1024").closest("tr")!;
		const editButton = within(openRow).getByRole("button", { name: "编辑" }) as HTMLButtonElement;
		await waitFor(() => expect(editButton.disabled).toBe(true));
		fireEvent.click(editButton);
		expect(adminLib.fetchInitiative).toHaveBeenCalledTimes(1);

		resolveWrite(savedRule("deposit", DEPOSIT_JSON, false));
		await waitFor(() => expect(editButton.disabled).toBe(false));
		// i2 面板仍反映写入结果（锁定已解除）
		expect((screen.getAllByRole("checkbox")[0] as HTMLInputElement).checked).toBe(false);

		// 落定后切换：i1 从服务端重新加载，拿到自己的锁死态
		fireEvent.click(editButton);
		await waitFor(() => expect(adminLib.fetchInitiative).toHaveBeenCalledTimes(2));
		await waitFor(() =>
			expect((screen.getAllByRole("checkbox")[0] as HTMLInputElement).checked).toBe(true),
		);
	});

	// F4 判据 A：同 id 连点两次「编辑」→ 只有最新一次读的回包可以落地
	it("同一 Initiative 的旧读回包不覆盖新读", async () => {
		let resolveFirst: (value: unknown) => void = () => {};
		let resolveSecond: (value: unknown) => void = () => {};
		adminLib.fetchInitiative
			.mockImplementationOnce(() => new Promise((resolve) => { resolveFirst = resolve; }))
			.mockImplementationOnce(() => new Promise((resolve) => { resolveSecond = resolve; }));

		render(<AdminInitiativesPage />);
		const draftRow = (await screen.findByText("e2e-drive")).closest("tr")!;
		const editButton = within(draftRow).getByRole("button", { name: "编辑" });
		fireEvent.click(editButton);
		fireEvent.click(editButton);
		expect(adminLib.fetchInitiative).toHaveBeenCalledTimes(2);

		resolveSecond({
			...DETAIL_ROW,
			mountedEvents: [],
			rules: [
				{ id: "r1", initiativeId: "i2", key: "deposit", valueJson: '{"enabled":false}', locked: true },
			],
		});
		await screen.findByText("挂载场（0）");

		// 旧回包（先发起、后落地）不得覆盖新读结果
		resolveFirst(DETAIL_ROW);
		await new Promise((resolve) => setTimeout(resolve, 0));
		expect(screen.getByText("挂载场（0）")).toBeInTheDocument();
		expect((screen.getByLabelText("押金规则") as HTMLTextAreaElement).value).toBe(
			'{"enabled":false}',
		);
	});

	// F1：容器级提交边界——焦点在本规则字段容器内移动不提交，真正离开容器必须提交
	it("Tab 离开规则字段（先到本规则锁死框、再离开容器）不丢编辑", async () => {
		adminLib.upsertInitiativeRule.mockResolvedValue(
			savedRule("age_gate", '{"min_age":21}', false),
		);
		await openEditor();

		const ageTextarea = screen.getByLabelText("年龄门槛") as HTMLTextAreaElement;
		const ageLock = screen.getAllByRole("checkbox")[1] as HTMLInputElement;

		fireEvent.change(ageTextarea, { target: { value: '{"min_age":21}' } });
		// Tab 第 1 步：焦点到本规则的锁死框（容器内）→ 不提交
		fireEvent.blur(ageTextarea, { relatedTarget: ageLock });
		expect(adminLib.upsertInitiativeRule).not.toHaveBeenCalled();

		// Tab 第 2 步：焦点离开容器 → 提交（与鼠标点别处同语义）
		fireEvent.blur(ageLock, { relatedTarget: document.body });
		await waitFor(() =>
			expect(adminLib.upsertInitiativeRule).toHaveBeenCalledWith(
				"i2",
				"age_gate",
				'{"min_age":21}',
				false,
			),
		);
	});

	it("Tab 离开锁死规则字段：与鼠标路径一致地弹出影响预览", async () => {
		await openEditor();

		const deposit = depositTextarea();
		const depositLock = screen.getAllByRole("checkbox")[0] as HTMLInputElement;

		fireEvent.change(deposit, { target: { value: CHANGED_DEPOSIT_JSON } });
		fireEvent.blur(deposit, { relatedTarget: depositLock });
		expect(screen.queryByRole("dialog")).toBeNull();

		fireEvent.blur(depositLock, { relatedTarget: document.body });
		expect(await screen.findByRole("dialog")).toBeInTheDocument();
		expect(adminLib.upsertInitiativeRule).not.toHaveBeenCalled();
	});

	// F2：附挂读面不可用时，弹层必须明说不可用，不给假 0
	it("挂载清单不可用时弹层明说不可用（不给假 0 数字）", async () => {
		adminLib.fetchInitiative.mockResolvedValue({ ...DETAIL_ROW, mountedEvents: null });
		render(<AdminInitiativesPage />);
		const draftRow = (await screen.findByText("e2e-drive")).closest("tr")!;
		fireEvent.click(within(draftRow).getByRole("button", { name: "编辑" }));
		await screen.findByText(/挂载场清单加载失败/);
		expect(screen.getByText("挂载场（数量不可用）")).toBeInTheDocument();
		expect(screen.queryByText("挂载场（0）")).toBeNull();

		fireEvent.change(depositTextarea(), { target: { value: CHANGED_DEPOSIT_JSON } });
		fireEvent.blur(depositTextarea(), { relatedTarget: document.body });

		const dialog = await screen.findByRole("dialog");
		expect(within(dialog).getByText(/影响面不可用/)).toBeInTheDocument();
		expect(within(dialog).queryByText(/共 0 场/)).toBeNull();
		expect(within(dialog).queryByText(/累计已确认报名 0 人/)).toBeNull();
	});

	// F5：规则写入的传输层/顶层错误必须可见
	it("规则写入被拒（传输层错误）：显示「规则未保存」告警而非静默", async () => {
		adminLib.upsertInitiativeRule.mockRejectedValue(new Error("boom"));
		await openEditor();

		fireEvent.change(depositTextarea(), { target: { value: CHANGED_DEPOSIT_JSON } });
		fireEvent.blur(depositTextarea(), { relatedTarget: document.body });
		fireEvent.click(
			within(await screen.findByRole("dialog")).getByRole("button", { name: "确认写入" }),
		);

		const alert = await screen.findByRole("alert");
		expect(alert).toHaveTextContent("规则未保存：网络或服务暂时不可用，请稍后重试。");
		// N5：不得说成"页面加载失败"
		expect(alert).not.toHaveTextContent("加载失败。");
	});

	// F6：弹层焦点约束（打开即聚焦确认按钮 + Tab 在两个按钮间循环）
	it("弹层把焦点收进自身：打开聚焦确认按钮，Tab 循环不回背后面板", async () => {
		await openEditor();

		fireEvent.change(depositTextarea(), { target: { value: CHANGED_DEPOSIT_JSON } });
		fireEvent.blur(depositTextarea(), { relatedTarget: document.body });

		const dialog = await screen.findByRole("dialog");
		expect(dialog).toHaveAttribute("aria-modal", "true");
		const confirmButton = within(dialog).getByRole("button", { name: "确认写入" });
		const cancelButton = within(dialog).getByRole("button", { name: "取消" });
		await waitFor(() => expect(document.activeElement).toBe(confirmButton));

		fireEvent.keyDown(confirmButton, { key: "Tab" });
		expect(document.activeElement).toBe(cancelButton);
		fireEvent.keyDown(cancelButton, { key: "Tab", shiftKey: true });
		expect(document.activeElement).toBe(confirmButton);
	});

	// N4：点弹层正文（h2/p）会把焦点落到 body，此时挂在弹层元素上的处理器收不到 keydown
	it("焦点逃出弹层后，下一次 Tab 被拉回弹层（N4）", async () => {
		await openEditor();

		fireEvent.change(depositTextarea(), { target: { value: CHANGED_DEPOSIT_JSON } });
		fireEvent.blur(depositTextarea(), { relatedTarget: document.body });

		const dialog = await screen.findByRole("dialog");
		const confirmButton = within(dialog).getByRole("button", { name: "确认写入" });
		await waitFor(() => expect(document.activeElement).toBe(confirmButton));

		// 模拟"点弹层正文"：焦点离开两个按钮（落到 body）
		(confirmButton as HTMLButtonElement).blur();
		expect(document.activeElement).toBe(document.body);

		fireEvent.keyDown(document, { key: "Tab" });
		expect(document.activeElement).toBe(confirmButton);
	});

	// N1：写入在途时重新输入的新值不得被回包清掉（compare-and-clear）
	it("写入在途重输：回包不清新草稿，最新值仍可提交（N1）", async () => {
		let resolveWrite: (value: unknown) => void = () => {};
		adminLib.upsertInitiativeRule
			.mockImplementationOnce(() => new Promise((resolve) => { resolveWrite = resolve; }))
			.mockResolvedValueOnce(savedRule("age_gate", '{"min_age":19}', false));
		await openEditor();

		const ageGate = screen.getByLabelText("年龄门槛") as HTMLTextAreaElement;
		fireEvent.change(ageGate, { target: { value: '{"min_age":19}' } });
		fireEvent.blur(ageGate, { relatedTarget: document.body });
		await waitFor(() => expect(adminLib.upsertInitiativeRule).toHaveBeenCalledTimes(1));

		// 在途期间重新输入 v2
		fireEvent.change(ageGate, { target: { value: '{"min_age":20}' } });

		// 回包落地：不得把受控 textarea 拉回 v1
		resolveWrite(savedRule("age_gate", '{"min_age":19}', false));
		await waitFor(() =>
			expect((screen.getByLabelText("年龄门槛") as HTMLTextAreaElement).value).toBe(
				'{"min_age":20}',
			),
		);

		// v2 仍在草稿里，可以继续提交
		fireEvent.blur(ageGate, { relatedTarget: document.body });
		await waitFor(() => expect(adminLib.upsertInitiativeRule).toHaveBeenCalledTimes(2));
		expect(adminLib.upsertInitiativeRule).toHaveBeenLastCalledWith(
			"i2",
			"age_gate",
			'{"min_age":20}',
			false,
		);
	});

	// N2：在途写未落定时，退出编辑态也不得放开「编辑」（计数不随 resetRuleEditing 清零）
	it("在途写未落定时「取消编辑」，切换仍被禁用直到落定（N2）", async () => {
		let resolveWrite: (value: unknown) => void = () => {};
		adminLib.upsertInitiativeRule.mockImplementation(
			() => new Promise((resolve) => { resolveWrite = resolve; }),
		);
		await openEditor();

		const ageGate = screen.getByLabelText("年龄门槛") as HTMLTextAreaElement;
		fireEvent.change(ageGate, { target: { value: '{"min_age":19}' } });
		fireEvent.blur(ageGate, { relatedTarget: document.body });

		const openRow = screen.getByText("hackerstart1024").closest("tr")!;
		const editButton = within(openRow).getByRole("button", { name: "编辑" }) as HTMLButtonElement;
		await waitFor(() => expect(editButton.disabled).toBe(true));

		fireEvent.click(screen.getByRole("button", { name: "取消" }));
		await waitFor(() => expect(screen.queryByLabelText("年龄门槛")).toBeNull());
		expect(editButton.disabled).toBe(true);

		resolveWrite(savedRule("age_gate", '{"min_age":19}', false));
		await waitFor(() => expect(editButton.disabled).toBe(false));
	});

	// N7：在途锁死写入期间 ruleLocks 还是旧值 → blur 提交必须用"锁死意图"
	it("在途锁死写入期间的 blur 提交用用户的锁死意图，不用过期渲染态（N7）", async () => {
		let resolveUnlock: (value: unknown) => void = () => {};
		adminLib.upsertInitiativeRule
			.mockImplementationOnce(() => new Promise((resolve) => { resolveUnlock = resolve; }))
			.mockResolvedValueOnce(
				savedRule("deposit", '{"enabled":true,"amount_cents":7100}', false),
			);
		await openEditor();

		const deposit = depositTextarea();
		const depositLock = screen.getAllByRole("checkbox")[0] as HTMLInputElement;
		expect(depositLock.checked).toBe(true);

		// 取消锁死 → 直写（locked=false），写入在途
		fireEvent.click(depositLock);
		await waitFor(() => expect(adminLib.upsertInitiativeRule).toHaveBeenCalledTimes(1));
		expect(depositLock.checked).toBe(true); // 渲染态仍是旧值

		// 在途期间编辑并离开容器 → 必须沿用意图 locked=false
		fireEvent.change(deposit, { target: { value: '{"enabled":true,"amount_cents":7100}' } });
		fireEvent.blur(deposit, { relatedTarget: document.body });
		await waitFor(() => expect(adminLib.upsertInitiativeRule).toHaveBeenCalledTimes(2));
		expect(adminLib.upsertInitiativeRule).toHaveBeenLastCalledWith(
			"i2",
			"deposit",
			'{"enabled":true,"amount_cents":7100}',
			false,
		);

		resolveUnlock(savedRule("deposit", DEPOSIT_JSON, false));
	});

	// N8：确认按钮 disabled 时对它 focus() 是空操作 → Tab 拉回要取可用按钮
	it("确认按钮禁用时 Tab 拉回落在可用的取消按钮上（N8）", async () => {
		let resolveWrite: (value: unknown) => void = () => {};
		adminLib.upsertInitiativeRule.mockImplementation(
			() => new Promise((resolve) => { resolveWrite = resolve; }),
		);
		await openEditor();

		const ageGate = screen.getByLabelText("年龄门槛") as HTMLTextAreaElement;
		const ageLock = screen.getAllByRole("checkbox")[1] as HTMLInputElement;

		// 勾锁死 → 确认 → 写入在途（挂起）
		fireEvent.click(ageLock);
		fireEvent.click(
			within(await screen.findByRole("dialog")).getByRole("button", { name: "确认写入" }),
		);
		await waitFor(() => expect(adminLib.upsertInitiativeRule).toHaveBeenCalledTimes(1));

		// 在途期间再编辑并离开容器 → 又开弹层（意图 locked=true），确认按钮此时 disabled
		fireEvent.change(ageGate, { target: { value: '{"min_age":22}' } });
		fireEvent.blur(ageGate, { relatedTarget: document.body });
		const dialog = await screen.findByRole("dialog");
		const confirmButton = within(dialog).getByRole("button", {
			name: "确认写入",
		}) as HTMLButtonElement;
		const cancelButton = within(dialog).getByRole("button", { name: "取消" }) as HTMLButtonElement;
		await waitFor(() => expect(confirmButton.disabled).toBe(true));

		// 确认按钮 disabled → 打开时的聚焦是空操作，焦点仍在弹层外（背景）
		expect(confirmButton.disabled).toBe(true);
		expect(document.activeElement).toBe(document.body);
		// 焦点逃出弹层 → Tab 必须落到"可用"的取消按钮，而不是被白拦
		fireEvent.keyDown(document, { key: "Tab" });
		expect(document.activeElement).toBe(cancelButton);

		resolveWrite(savedRule("age_gate", '{"min_age":21}', true));
	});

	// N9：旧写入的迟到 rejection 不得在新写入成功之后弹"未保存"
	it("旧写入的迟到 rejection 不弹告警（N9）", async () => {
		let rejectFirst: (reason?: unknown) => void = () => {};
		adminLib.upsertInitiativeRule
			.mockImplementationOnce(
				() => new Promise((_resolve, reject) => { rejectFirst = reject; }),
			)
			.mockResolvedValueOnce(savedRule("age_gate", '{"min_age":22}', false));
		await openEditor();

		const ageGate = screen.getByLabelText("年龄门槛") as HTMLTextAreaElement;
		fireEvent.change(ageGate, { target: { value: '{"min_age":21}' } });
		fireEvent.blur(ageGate, { relatedTarget: document.body }); // W1（挂起）
		await waitFor(() => expect(adminLib.upsertInitiativeRule).toHaveBeenCalledTimes(1));

		fireEvent.change(ageGate, { target: { value: '{"min_age":22}' } });
		fireEvent.blur(ageGate, { relatedTarget: document.body }); // W2（更新）
		await waitFor(() => expect(adminLib.upsertInitiativeRule).toHaveBeenCalledTimes(2));

		rejectFirst(new Error("stale boom"));
		await new Promise((resolve) => setTimeout(resolve, 0));
		expect(screen.queryByRole("alert")).toBeNull();
	});

	// N11：resolve 出空 errors 也是"没保存成功"，不得落回"页面加载失败"
	it("写入 resolve 出空 errors：给未保存文案而非加载失败（N11）", async () => {
		adminLib.upsertInitiativeRule.mockResolvedValue({ result: null, errors: [] });
		await openEditor();

		fireEvent.change(depositTextarea(), { target: { value: CHANGED_DEPOSIT_JSON } });
		fireEvent.blur(depositTextarea(), { relatedTarget: document.body });
		fireEvent.click(
			within(await screen.findByRole("dialog")).getByRole("button", { name: "确认写入" }),
		);

		const alert = await screen.findByRole("alert");
		expect(alert).toHaveTextContent("规则未保存：网络或服务暂时不可用，请稍后重试。");
		expect(alert).not.toHaveTextContent("加载失败。");
	});

	// F1（第五轮）：弹层打开期间，背景 checkbox 的 onChange 也不得写出未确认变更。
	// 前置态：该 key 有在途写 → 确认按钮 disabled → 焦点不会被拉进弹层 → 背景控件仍可被 Space 激活。
	it("弹层打开期间背景 checkbox 的变更请求被唯一入口拦住（F1）", async () => {
		let resolveWrite: (value: unknown) => void = () => {};
		adminLib.upsertInitiativeRule.mockImplementation(
			() => new Promise((resolve) => { resolveWrite = resolve; }),
		);
		await openEditor();

		const ageGate = screen.getByLabelText("年龄门槛") as HTMLTextAreaElement;
		const ageLock = screen.getAllByRole("checkbox")[1] as HTMLInputElement;

		// 勾锁死 → 确认 → 写入在途（挂起）
		fireEvent.click(ageLock);
		fireEvent.click(
			within(await screen.findByRole("dialog")).getByRole("button", { name: "确认写入" }),
		);
		await waitFor(() => expect(adminLib.upsertInitiativeRule).toHaveBeenCalledTimes(1));

		// 在途期间再编辑并离开容器 → 又开弹层（确认按钮 disabled，焦点不会进弹层）
		fireEvent.change(ageGate, { target: { value: '{"min_age":22}' } });
		fireEvent.blur(ageGate, { relatedTarget: document.body });
		const dialog = await screen.findByRole("dialog");
		expect(
			(within(dialog).getByRole("button", { name: "确认写入" }) as HTMLButtonElement).disabled,
		).toBe(true);

		// 背景 checkbox 被激活（Space 等价于 click）：不得触发任何写入或替换弹层
		const otherLock = screen.getAllByRole("checkbox")[2] as HTMLInputElement;
		fireEvent.click(otherLock);
		await new Promise((resolve) => setTimeout(resolve, 0));
		expect(adminLib.upsertInitiativeRule).toHaveBeenCalledTimes(1);
		expect(screen.getByRole("dialog")).toBeInTheDocument();

		resolveWrite(savedRule("age_gate", '{"min_age":21}', true));
	});

	// F2（第五轮）：确认按钮 disabled 时，从「取消」按正向 Tab 也必须被拦截
	it("确认按钮禁用时从「取消」按 Tab 被拦截并留在弹层内（F2）", async () => {
		let resolveWrite: (value: unknown) => void = () => {};
		adminLib.upsertInitiativeRule.mockImplementation(
			() => new Promise((resolve) => { resolveWrite = resolve; }),
		);
		await openEditor();

		const ageGate = screen.getByLabelText("年龄门槛") as HTMLTextAreaElement;
		const ageLock = screen.getAllByRole("checkbox")[1] as HTMLInputElement;
		fireEvent.click(ageLock);
		fireEvent.click(
			within(await screen.findByRole("dialog")).getByRole("button", { name: "确认写入" }),
		);
		await waitFor(() => expect(adminLib.upsertInitiativeRule).toHaveBeenCalledTimes(1));

		fireEvent.change(ageGate, { target: { value: '{"min_age":22}' } });
		fireEvent.blur(ageGate, { relatedTarget: document.body });
		const dialog = await screen.findByRole("dialog");
		const cancelButton = within(dialog).getByRole("button", { name: "取消" }) as HTMLButtonElement;
		cancelButton.focus();

		// fireEvent 返回 !defaultPrevented：false 表示事件被拦截（默认 Tab 不会跑出去）
		expect(fireEvent.keyDown(cancelButton, { key: "Tab" })).toBe(false);
		expect(document.activeElement).toBe(cancelButton);

		resolveWrite(savedRule("age_gate", '{"min_age":21}', true));
	});

	// F3（第五轮）：被拒的锁死写入必须撤掉意图，否则之后每次值编辑都被拖进锁死分支再被拒
	it("锁死写入被拒后撤掉意图：随后值编辑按服务器真值（未锁死）提交（F3）", async () => {
		adminLib.upsertInitiativeRule
			.mockResolvedValueOnce({
				result: null,
				errors: [
					{
						code: "event_payment_mode_exclusive",
						message: "conflict",
						fields: ["event_id=e2"],
					},
				],
			})
			.mockResolvedValueOnce(savedRule("age_gate", '{"min_age":22}', false));
		await openEditor();

		const ageGate = screen.getByLabelText("年龄门槛") as HTMLTextAreaElement;
		const ageLock = screen.getAllByRole("checkbox")[1] as HTMLInputElement;

		// 勾锁死 → 确认 → 被服务端拒绝（意图=true，ruleLocks 仍为 false）
		fireEvent.click(ageLock);
		fireEvent.click(
			within(await screen.findByRole("dialog")).getByRole("button", { name: "确认写入" }),
		);
		expect(await screen.findByRole("alert")).toHaveTextContent("Open Priced");
		await waitFor(() => expect(adminLib.upsertInitiativeRule).toHaveBeenCalledTimes(1));

		// 之后的值编辑 + 离开容器：必须按"未锁死"直写，而不是再弹锁死确认
		fireEvent.change(ageGate, { target: { value: '{"min_age":22}' } });
		fireEvent.blur(ageGate, { relatedTarget: document.body });
		await waitFor(() => expect(adminLib.upsertInitiativeRule).toHaveBeenCalledTimes(2));
		expect(adminLib.upsertInitiativeRule).toHaveBeenLastCalledWith(
			"i2",
			"age_gate",
			'{"min_age":22}',
			false,
		);
		expect(screen.queryByRole("dialog")).toBeNull();
	});

	// F3b：传输失败同样撤掉意图（catch 分支）
	it("锁死写入传输失败后同样撤掉意图（F3b）", async () => {
		adminLib.upsertInitiativeRule
			.mockRejectedValueOnce(new Error("boom"))
			.mockResolvedValueOnce(savedRule("age_gate", '{"min_age":22}', false));
		await openEditor();

		const ageGate = screen.getByLabelText("年龄门槛") as HTMLTextAreaElement;
		const ageLock = screen.getAllByRole("checkbox")[1] as HTMLInputElement;

		fireEvent.click(ageLock);
		fireEvent.click(
			within(await screen.findByRole("dialog")).getByRole("button", { name: "确认写入" }),
		);
		expect(await screen.findByRole("alert")).toHaveTextContent(
			"规则未保存：网络或服务暂时不可用，请稍后重试。",
		);
		await waitFor(() => expect(adminLib.upsertInitiativeRule).toHaveBeenCalledTimes(1));

		fireEvent.change(ageGate, { target: { value: '{"min_age":22}' } });
		fireEvent.blur(ageGate, { relatedTarget: document.body });
		await waitFor(() => expect(adminLib.upsertInitiativeRule).toHaveBeenCalledTimes(2));
		expect(adminLib.upsertInitiativeRule).toHaveBeenLastCalledWith(
			"i2",
			"age_gate",
			'{"min_age":22}',
			false,
		);
		expect(screen.queryByRole("dialog")).toBeNull();
	});

	// F4（第五轮）：锁死态以服务器回显为准，而不是请求值
	it("锁死开关以服务器回显的 locked 为准（F4）", async () => {
		adminLib.upsertInitiativeRule.mockResolvedValue(
			savedRule("age_gate", '{"min_age":21}', false), // 请求 locked=true，服务器回显 false
		);
		await openEditor();

		const ageLock = screen.getAllByRole("checkbox")[1] as HTMLInputElement;
		expect(ageLock.checked).toBe(false);
		fireEvent.click(ageLock); // 勾上 → 弹层 → 确认（请求 locked=true，回显 false）
		fireEvent.click(
			within(await screen.findByRole("dialog")).getByRole("button", { name: "确认写入" }),
		);

		await waitFor(() => expect(adminLib.upsertInitiativeRule).toHaveBeenCalledTimes(1));
		expect(adminLib.upsertInitiativeRule).toHaveBeenLastCalledWith(
			"i2",
			"age_gate",
			'{"min_age":18}',
			true,
		);
		await waitFor(() => expect(ageLock.checked).toBe(false));
	});

	// T1：切走再进来必须清掉上一场的锁死意图（否则新场首个 blur 走错分支）
	it("切换 Initiative 后不继承上一场的锁死意图（T1）", async () => {
		adminLib.upsertInitiativeRule.mockResolvedValue(
			savedRule("deposit", CHANGED_DEPOSIT_JSON, false),
		);
		await openEditor();

		// 在 i2 制造"意图=false"：取消 deposit 锁死（直写）
		fireEvent.click(screen.getAllByRole("checkbox")[0]);
		await waitFor(() => expect(adminLib.upsertInitiativeRule).toHaveBeenCalledTimes(1));

		// 切到另一行（loadInitiative 清意图）
		const openRow = screen.getByText("hackerstart1024").closest("tr")!;
		fireEvent.click(within(openRow).getByRole("button", { name: "编辑" }));
		await waitFor(() => expect(adminLib.fetchInitiative).toHaveBeenCalledTimes(2));

		// 新面板 deposit 是锁死态（fixture）→ 编辑后 blur 必须走锁死分支（弹层），不得继承旧意图直写
		const deposit = depositTextarea();
		fireEvent.change(deposit, { target: { value: CHANGED_DEPOSIT_JSON } });
		fireEvent.blur(deposit, { relatedTarget: document.body });
		expect(await screen.findByRole("dialog")).toBeInTheDocument();
		expect(adminLib.upsertInitiativeRule).toHaveBeenCalledTimes(1);
	});

	// N3：refreshMounts 与 loadInitiative 共用读序号 → 更旧的 refresh 回包不得覆盖更新的清单
	it("更旧的挂载场刷新回包不覆盖更新的清单（N3）", async () => {
		let resolveRefresh: (value: unknown) => void = () => {};
		adminLib.upsertInitiativeRule.mockResolvedValue(
			savedRule("deposit", CHANGED_DEPOSIT_JSON, true),
		);
		adminLib.fetchInitiative
			.mockResolvedValueOnce(DETAIL_ROW)
			.mockImplementationOnce(() => new Promise((resolve) => { resolveRefresh = resolve; }))
			.mockResolvedValueOnce({ ...DETAIL_ROW, mountedEvents: [] });

		render(<AdminInitiativesPage />);
		const draftRow = (await screen.findByText("e2e-drive")).closest("tr")!;
		fireEvent.click(within(draftRow).getByRole("button", { name: "编辑" }));
		await screen.findByText("挂载场（3）");

		fireEvent.change(depositTextarea(), { target: { value: CHANGED_DEPOSIT_JSON } });
		fireEvent.blur(depositTextarea(), { relatedTarget: document.body });
		fireEvent.click(
			within(await screen.findByRole("dialog")).getByRole("button", { name: "确认写入" }),
		);
		// 写后 refresh 已发出（挂起）
		await waitFor(() => expect(adminLib.fetchInitiative).toHaveBeenCalledTimes(2));

		// 重新进入 → 更新的读落地（写已落定，允许）
		fireEvent.click(within(draftRow).getByRole("button", { name: "编辑" }));
		await waitFor(() => expect(adminLib.fetchInitiative).toHaveBeenCalledTimes(3));
		await screen.findByText("挂载场（0）");

		// 旧的 refresh 迟到 → 丢弃
		resolveRefresh(DETAIL_ROW);
		await new Promise((resolve) => setTimeout(resolve, 0));
		expect(screen.getByText("挂载场（0）")).toBeInTheDocument();
	});

	// A2：上一条规则告警（含场/工作台名）不得挂到另一个 Initiative 的面板上
	it("切换 Initiative 清掉上一条规则告警", async () => {
		adminLib.upsertInitiativeRule.mockResolvedValue({
			result: null,
			errors: [
				{
					code: "event_payment_mode_exclusive",
					message: "conflict",
					fields: ["event_id=e2"],
				},
			],
		});
		await openEditor();

		fireEvent.change(depositTextarea(), { target: { value: CHANGED_DEPOSIT_JSON } });
		fireEvent.blur(depositTextarea());
		fireEvent.click(
			within(await screen.findByRole("dialog")).getByRole("button", { name: "确认写入" }),
		);
		expect(await screen.findByRole("alert")).toHaveTextContent("Open Priced");

		const openRow = screen.getByText("hackerstart1024").closest("tr")!;
		fireEvent.click(within(openRow).getByRole("button", { name: "编辑" }));

		await waitFor(() => expect(screen.queryByRole("alert")).toBeNull());
	});
});
