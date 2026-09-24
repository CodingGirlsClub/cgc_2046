import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, screen, waitFor, within } from "@testing-library/react";
import { render } from "@/test-utils";
import type * as ApolloReact from "@apollo/client/react";
import type { TypedDocumentNode } from "@apollo/client";
import Journey from "./journey";
import {
	FLASHBACK_ENTER,
	FLASHBACK_MARK_REVEALED,
	FLASHBACK_SUBMIT_TODAY,
	FLASHBACK_SEND_TO_WALL,
	FLASHBACK_SET_QUOTE_LICENSE,
	FLASHBACK_REGISTER_BIND,
	FLASHBACK_ADJUST_FOG,
	type FlashbackEnterResult,
} from "@/lib/graphql/flashback";

/**
 * U4 首程旅程测试：记忆线/圆梦线分支、CTA 两态、兜底路径、相对年数、
 * 注册可跳过、失效三分支、reduced-motion 终态、token URL 清除。
 */

const pushMock = vi.fn();

vi.mock("@/i18n/navigation", () => ({
	Link: ({ href, children, ...rest }: { href: string; children: React.ReactNode } & Record<string, unknown>) => (
		<a href={href} {...rest}>
			{children}
		</a>
	),
	usePathname: () => "/flashback/enter",
	useRouter: () => ({ push: pushMock, replace: vi.fn() }),
}));

/** document → 延迟结果（render 前 preset，runner 首调时消费） */
const pendingResults = new Map<unknown, (opts: { variables: Record<string, unknown> }) => unknown>();

/** document → runner registry（按 gql document 身份分派；lazy 转发 pending 结果） */
const mutations = new Map<unknown, ReturnType<typeof vi.fn>>();

vi.mock("@apollo/client/react", async (importOriginal) => {
	const actual = await importOriginal<typeof ApolloReact>();
	return {
		...actual,
		useMutation: (doc: TypedDocumentNode<Record<string, unknown>, Record<string, unknown>>) => {
			let impl = mutations.get(doc);
			if (!impl) {
				impl = vi.fn((opts: { variables: Record<string, unknown> }) => {
					const pending = pendingResults.get(doc);
					if (pending) return pending(opts);
					return Promise.resolve({ data: {} });
				});
				mutations.set(doc, impl);
			}
			return [impl, { loading: false }];
		},
	};
});

vi.mock("@/lib/apollo-client", () => ({
	client: { query: vi.fn().mockResolvedValue({ data: { flashbackDreamTarget: null } }) },
}));

const memoryEntry: FlashbackEnterResult = {
	line: "memory",
	profile: {
		fullName: "王晓雨",
		surname: "王",
		city: "上海",
		occupationThen: "校对",
		gender: "女",
		role: "learner",
		participation: "attended",
		appliedAt: "2012-02-20T11:03:00Z",
		archive: { key: "2012-02-sh", name: "Rails Girls 上海", city: "上海", occurredOn: "2012-02-20" },
		answers: [
			{ id: "a1", questionKey: "self_intro", rawText: "一个刚毕业的文科生，在出版社做校对。", fogSpans: null },
		],
	},
	progress: { quoteLevel: "off", maskedPhone: "138****5678", maskedEmail: "w***@x.com" },
	scatter: {
		entries: [
			{ photoKey: "p-self", label: "2012 · 上海", dateStamp: "2012 02 20", isMine: true, surname: "王" },
			{ photoKey: "p-bj", label: "2014 · 北京", dateStamp: "2014 01 11", isMine: false, surname: "李" },
			{ photoKey: "p-gz", label: "2015 · 广州", dateStamp: "2015 08 15", isMine: false, surname: "张" },
		],
	},
};

const dreamEntry: FlashbackEnterResult = {
	line: "dream",
	profile: {
		fullName: "李一诺",
		surname: "李",
		city: "北京",
		role: "learner",
		participation: "not_selected",
		appliedAt: "2014-01-05T05:06:00Z",
		archive: { key: "2014-01-11-bj", name: "Rails Girls 北京", city: "北京", occurredOn: "2014-01-11" },
		answers: [{ id: "a2", questionKey: "self_intro", rawText: "我想亲眼看看是不是。", fogSpans: null }],
	},
	progress: { quoteLevel: "off", maskedPhone: null, maskedEmail: null },
};

function mockEnterResolve(result: FlashbackEnterResult) {
	pendingResults.set(FLASHBACK_ENTER, () => Promise.resolve({ data: { flashbackEnter: result } }));
}

function mockEnterReject(error: unknown) {
	pendingResults.set(FLASHBACK_ENTER, () => Promise.reject(error));
}

async function renderJourney(url = "/flashback/enter?token=tok-123") {
	window.history.replaceState({}, "", url);
	window.sessionStorage.clear();
	render(<Journey />);
	await waitFor(() => expect(screen.getByRole("heading", { level: 2 })).toBeInTheDocument());
}

/** 快进到指定阶段（记忆线：快门→散照桌面→同屏问答→原位显影→写字→寄出浮层）；自带 render */
async function walkTo(stage: "scatter" | "quiz" | "reveal" | "write" | "send") {
	await renderJourney();
	fireEvent.click(screen.getByRole("button", { name: "按下快门，回到那天" }));
	await screen.findByText("点开一张，放大看看——线索藏在照片里。");
	if (stage === "scatter") return;

	fireEvent.click(screen.getAllByRole("button", { name: /第 1 张照片/ })[0]);
	await screen.findByText("还记得……是哪一场吗？");
	if (stage === "quiz") return;

	fireEvent.click(screen.getAllByTestId("fb-quiz-option").find((el) => el.getAttribute("data-mine") === "true")!);
	await screen.findByTestId("fb-polaroid");
	if (stage === "reveal") return;

	fireEvent.click(screen.getByRole("button", { name: "翻过来，写今天的你" }));
	await screen.findByText("今天的你");
	if (stage === "write") return;

	fireEvent.submit(screen.getByRole("button", { name: "写好了，去寄出 →" }).closest("form")!);
	// 浮层化（E/F）：不换页；浮层打开先停检查步（本人自选雾面），确认才寄出
	await screen.findByText("寄出前，检查当年的你");
	fireEvent.click(screen.getByRole("button", { name: /^确认寄出/ }));
	await screen.findByRole("button", { name: "跳过，直接上墙" });
}

beforeEach(() => {
	// mockClear 保留 lazy 转发实现，只清调用记录；pending 每例重设
	mutations.forEach((impl) => impl.mockClear());
	pendingResults.clear();
	pushMock.mockReset();
	vi.spyOn(window, "matchMedia").mockReturnValue({
		matches: false,
		media: "(prefers-reduced-motion: reduce)",
		onchange: null,
		addListener: vi.fn(),
		removeListener: vi.fn(),
		addEventListener: vi.fn(),
		removeEventListener: vi.fn(),
		dispatchEvent: vi.fn(),
	} as unknown as MediaQueryList);
});

afterEach(() => {
	cleanup();
	vi.restoreAllMocks();
	window.history.replaceState({}, "", "/flashback/enter");
	window.sessionStorage.clear();
});

describe("Journey · 记忆线", () => {
	it("快门开场含产品名与可操作按钮；token 从 URL 读入后即刻清除", async () => {
		mockEnterResolve(memoryEntry);
		await renderJourney();

		expect(window.location.search).toBe("");
		expect(window.sessionStorage.getItem("flashback.token")).toBe("tok-123");
		expect(mutations.get(FLASHBACK_ENTER)).toHaveBeenCalledWith({ variables: { token: "tok-123" } });
		expect(screen.getByText("IN A FLASH · 闪念间")).toBeInTheDocument();
		expect(screen.getByRole("button", { name: "按下快门，回到那天" })).toBeInTheDocument();
	});

	it("散照→问答→显影：答案原文、结构化身份与相对年数（2012 → 14 年前）呈现", async () => {
		mockEnterResolve(memoryEntry);
		await walkTo("reveal");

		expect(screen.getByText("答对了。这张照片一直在等你。")).toBeInTheDocument();
		expect(screen.getByText("一个刚毕业的文科生，在出版社做校对。")).toBeInTheDocument();
		// 桌面与显影卡同屏（场景连续性）：结构化身份限定在卡面里断言
		const card = within(screen.getByTestId("fb-polaroid"));
		expect(card.getByText("上海")).toBeInTheDocument();
		expect(card.getByText("校对")).toBeInTheDocument();
		// 相对年数动态计算（R3/AE1）：2012-02 → 2026-09 为 14 年；日期为 ISO 日期部分（时区无关）
		expect(screen.getByText(/14 年前的 2012\.02\.20/)).toBeInTheDocument();
		expect(screen.getByText("王晓雨")).toBeInTheDocument();
		// 比特币提醒全场展示（session-settled 决策②）
		expect(screen.getByText(/比特币/)).toBeInTheDocument();
	});

	it("散照把玩（原型 B）：点一张放大到最前、可换一张；问答与散照同屏不换页", async () => {
		mockEnterResolve(memoryEntry);
		await renderJourney();
		fireEvent.click(screen.getByRole("button", { name: "按下快门，回到那天" }));
		await screen.findByText("点开一张，放大看看——线索藏在照片里。");

		const photos = screen.getAllByTestId("fb-scatter-photo");
		expect(photos).toHaveLength(3);
		expect(photos.every((photo) => photo.getAttribute("data-picked") === "false")).toBe(true);

		// 点第一张：放大到最前 + 同屏弹出问答 sheet（不跳页）
		fireEvent.click(photos[0]);
		await waitFor(() => expect(screen.getAllByTestId("fb-scatter-photo")[0]).toHaveAttribute("data-picked", "true"));
		expect(screen.getByTestId("fb-quiz-sheet")).toBeInTheDocument();
		expect(screen.getByText("散落一桌的拍立得，都还没显影")).toBeInTheDocument();

		// 换着看：点第三张 → 放大态转移，旧的那张回正
		fireEvent.click(screen.getAllByTestId("fb-scatter-photo")[2]);
		await waitFor(() => expect(screen.getAllByTestId("fb-scatter-photo")[2]).toHaveAttribute("data-picked", "true"));
		expect(screen.getAllByTestId("fb-scatter-photo")[0]).toHaveAttribute("data-picked", "false");

		// 「重挑一张」：关 sheet、取消放大，仍在同一场景
		fireEvent.click(screen.getByRole("button", { name: /重挑一张/ }));
		await waitFor(() => expect(screen.queryByTestId("fb-quiz-sheet")).not.toBeInTheDocument());
		expect(screen.getAllByTestId("fb-scatter-photo")[2]).toHaveAttribute("data-picked", "false");
		expect(screen.getByText("散落一桌的拍立得，都还没显影")).toBeInTheDocument();
	});

	it("原位显影：选定后同一场景里长出显影卡（桌面退到背景，不换页）", async () => {
		mockEnterResolve(memoryEntry);
		await renderJourney();
		fireEvent.click(screen.getByRole("button", { name: "按下快门，回到那天" }));
		await screen.findByText("点开一张，放大看看——线索藏在照片里。");
		fireEvent.click(screen.getAllByTestId("fb-scatter-photo")[1]);
		await screen.findByTestId("fb-quiz-sheet");
		fireEvent.click(screen.getAllByTestId("fb-quiz-option").find((el) => el.getAttribute("data-mine") === "true")!);

		// 显影卡出现 + 桌面仍在场（dimmed）——场景连续性
		expect(await screen.findByTestId("fb-polaroid")).toBeInTheDocument();
		expect(screen.getByTestId("fb-desk-reveal")).toBeInTheDocument();
		expect(screen.getAllByTestId("fb-scatter-photo")[1]).toHaveAttribute("data-picked", "true");
		expect(screen.getByText("散落一桌的拍立得，都还没显影")).toBeInTheDocument();
		expect(screen.queryByTestId("fb-quiz-sheet")).not.toBeInTheDocument();
	});

	it("圆梦线拆信：不走散照/问答，直接显影（R9）", async () => {
		mockEnterResolve(dreamEntry);
		await renderJourney();
		fireEvent.click(screen.getByTestId("fb-envelope"));
		await screen.findByTestId("fb-polaroid", {}, { timeout: 3000 });

		expect(screen.queryAllByTestId("fb-scatter-photo")).toHaveLength(0);
		expect(screen.queryByTestId("fb-quiz-sheet")).not.toBeInTheDocument();
	});

	it("「我不记得了」兜底：直接给正确答案、无挫败文案（AE2）", async () => {
		mockEnterResolve(memoryEntry);
		await walkTo("quiz");

		fireEvent.click(screen.getByRole("button", { name: /我不记得了/ }));

		expect(await screen.findByText("没关系——我们替你记得：Rails Girls 上海")).toBeInTheDocument();
		expect(screen.queryByText(/错误|失败|答错/)).not.toBeInTheDocument();
	});

	it("答错也有回报（三态 R5）：干扰项显影 + 指回本人场次线索", async () => {
		mockEnterResolve(memoryEntry);
		await renderJourney();
		fireEvent.click(screen.getByRole("button", { name: "按下快门，回到那天" }));
		await screen.findByText("点开一张，放大看看——线索藏在照片里。");
		fireEvent.click(screen.getAllByTestId("fb-scatter-photo")[1]);
		await screen.findByTestId("fb-quiz-sheet");
		fireEvent.click(screen.getAllByTestId("fb-quiz-option").find((el) => el.getAttribute("data-mine") === "false")!);

		expect(
			await screen.findByText("差一点——但也显影给你看。你的照片其实在 2012 · 上海。"),
		).toBeInTheDocument();
		expect(screen.getByTestId("fb-polaroid")).toBeInTheDocument();
	});

	it("单场自适应（pilot 初期）：候选仅一场 → 点照片直接原位显影、跳过问答", async () => {
		const single: FlashbackEnterResult = {
			...memoryEntry,
			scatter: { entries: [{ photoKey: "p-self", label: "2012 · 上海", dateStamp: "2012 02 20", isMine: true, surname: "王" }] },
		};
		mockEnterResolve(single);
		await renderJourney();
		fireEvent.click(screen.getByRole("button", { name: "按下快门，回到那天" }));
		await screen.findByText("点开一张，放大看看——线索藏在照片里。");
		fireEvent.click(screen.getAllByTestId("fb-scatter-photo")[0]);

		// 无谜不设谜：没有问答 sheet，直接显影；标题为默认（非对/错反馈）
		expect(screen.queryByTestId("fb-quiz-sheet")).not.toBeInTheDocument();
		expect(await screen.findByTestId("fb-polaroid")).toBeInTheDocument();
		expect(screen.getByText("慢慢显影——这是当年的你")).toBeInTheDocument();
	});

	it("放大 = 回报：线索标签显影（年份 · 城市）", async () => {
		mockEnterResolve(memoryEntry);
		await renderJourney();
		fireEvent.click(screen.getByRole("button", { name: "按下快门，回到那天" }));
		await screen.findByText("点开一张，放大看看——线索藏在照片里。");
		// 摆位按本人 id 哈希旋转（非固定第一张）——用日期戳定位本人那张
		const photos = screen.getAllByTestId("fb-scatter-photo");
		const mine = photos.find((el) => el.getAttribute("data-stamp") === "2012 02 20")!;
		fireEvent.click(mine);
		await waitFor(() => expect(mine).toHaveAttribute("data-picked", "true"));
		// 日期戳渐显（只含日期）；城市名不进散照 DOM——线索要经认知参与才成立
		const stamp = mine.querySelector('[data-testid="fb-scatter-stamp"]');
		expect(stamp).toHaveTextContent("2012 02 20");
		expect(within(mine).queryByText(/上海/)).not.toBeInTheDocument();
	});

	it("「重挑一张」出口回到散照", async () => {
		mockEnterResolve(memoryEntry);
		await walkTo("quiz");

		fireEvent.click(screen.getByRole("button", { name: /重挑一张/ }));

		expect(await screen.findByText("点开一张，放大看看——线索藏在照片里。")).toBeInTheDocument();
	});

	it("显影完成（animationend）写 revealed 行为事件（四时刻之二）", async () => {
		const revealed = mutations.get(FLASHBACK_MARK_REVEALED)!;
		revealed.mockResolvedValue({ data: { flashbackMarkRevealed: { recorded: true } } });
		mockEnterResolve(memoryEntry);
		await walkTo("reveal");

		fireEvent.animationEnd(screen.getByTestId("fb-polaroid"));

		await waitFor(() =>
			expect(revealed).toHaveBeenCalledWith({ variables: { token: "tok-123" } }),
		);
	});

	it("翻面写字表单：四个自由文本 + 勾选组 + 金句授权（非雾面句为候选）", async () => {
		mockEnterResolve(memoryEntry);
		await walkTo("write");

		expect(screen.getByLabelText("现在的我，在做什么")).toBeInTheDocument();
		expect(screen.getByLabelText("想做的事、想学的东西")).toBeInTheDocument();
		expect(screen.getByLabelText(/需要什么帮助/)).toBeInTheDocument();
		expect(screen.getByLabelText(/想对 CGC \/ 文洋说点什么/)).toBeInTheDocument();
		expect(screen.getByText("想参加什么 · 能帮上什么")).toBeInTheDocument();
		expect(screen.getByText("金句授权")).toBeInTheDocument();

		fireEvent.click(screen.getByRole("radio", { name: /匿名金句/ }));
		expect(await screen.findByText("选出可以展示的句子（可多选，平台从中挑选）：")).toBeInTheDocument();
		expect(
			screen.getByRole("button", { name: "一个刚毕业的文科生，在出版社做校对。" }),
		).toBeInTheDocument();
	});

	it("志愿者角色多一问（AE6），学员不出现", async () => {
		mockEnterResolve({ ...memoryEntry, profile: { ...memoryEntry.profile!, role: "volunteer" } });
		await walkTo("write");

		expect(screen.getByText("愿意牵头组织 1024 你城市的场")).toBeInTheDocument();
	});

	it("学员问卷不出现志愿者牵头一问（AE6 反向）", async () => {
		mockEnterResolve(memoryEntry);
		await walkTo("write");

		expect(screen.queryByText("愿意牵头组织 1024 你城市的场")).not.toBeInTheDocument();
	});

	it("雾面句不进金句候选（R14 纪律）", async () => {
		mockEnterResolve({
			...memoryEntry,
			profile: {
				...memoryEntry.profile!,
				answers: [
					{
						id: "a1",
						questionKey: "self_intro",
						rawText: "一个刚毕业的文科生，在出版社做校对。",
						fogSpans: [{ start: 0, len: 5 }],
					},
				],
			},
		});
		await walkTo("write");

		fireEvent.click(screen.getByRole("radio", { name: /匿名金句/ }));
		// 唯一句带雾面 → 无候选，展示占位说明
		expect(await screen.findByText(/都带着雾面/)).toBeInTheDocument();
	});

	it("寄出流程：submitToday + sendToWall 依次发出；跳过注册后仍寄出成功并进胶囊（R27/R29）", async () => {
		const submit = mutations.get(FLASHBACK_SUBMIT_TODAY)!;
		submit.mockResolvedValue({ data: { flashbackSubmitToday: { today: { nowStatus: null } } } });
		const wall = mutations.get(FLASHBACK_SEND_TO_WALL)!;
		wall.mockResolvedValue({
			data: { flashbackSendToWall: { sentToWallAt: "2026-09-18T00:00:00Z" } },
		});
		mockEnterResolve(memoryEntry);
		// 浮层打开先停检查步，确认后才寄出（照片正在贴上墙 = 过程陈述）
		await walkTo("send");

		// R29 期望管理文案在寄出成功后出现（与注册引导同屏）
		expect(await screen.findByText(/愿望不会消失/)).toBeInTheDocument();
		await waitFor(() => expect(wall).toHaveBeenCalledWith({ variables: { token: "tok-123" } }));
		expect(submit).toHaveBeenCalledTimes(1);

		fireEvent.click(screen.getByRole("button", { name: "跳过，直接上墙" }));
		await waitFor(() => expect(pushMock).toHaveBeenCalledWith("/flashback/capsule"));
	});

	it("寄出浮层（原型 E/F）：打开先停检查步、确认才寄出、不跳页；浮层盖在显影场景上", async () => {
		const submit = mutations.get(FLASHBACK_SUBMIT_TODAY)!;
		submit.mockResolvedValue({
			data: { flashbackSubmitToday: { today: {} } },
		});
		const wall = mutations.get(FLASHBACK_SEND_TO_WALL)!;
		wall.mockResolvedValue({ data: { flashbackSendToWall: { sentToWallAt: "2026-09-18T00:00:00Z" } } });
		mockEnterResolve(memoryEntry);
		await walkTo("write");

		fireEvent.submit(screen.getByRole("button", { name: "写好了，去寄出 →" }).closest("form")!);

		// 浮层出现：显影场景仍在 DOM（写字面 = 翻开的卡背面），路由未跳转
		expect(await screen.findByRole("dialog")).toBeInTheDocument();
		expect(screen.getByTestId("fb-desk-reveal")).toBeInTheDocument();
		expect(document.querySelector('form[data-face="back"]')).toBeTruthy();
		expect(pushMock).not.toHaveBeenCalled();

		// 旧「打开即寄出」语义的反向钉住：确认前 submitToday/sendToWall 都不发出
		expect(submit).not.toHaveBeenCalled();
		expect(wall).not.toHaveBeenCalled();

		fireEvent.click(screen.getByRole("button", { name: /^确认寄出/ }));

		await waitFor(() => expect(wall).toHaveBeenCalledTimes(1));
		expect(await screen.findByRole("button", { name: "跳过，直接上墙" })).toBeInTheDocument();
		expect(screen.getByText(/愿望不会消失/)).toBeInTheDocument();
	});

	it("注册引导：发码 → 绑定成功 → 进胶囊（R27 一句话术在场）", async () => {
		mutations.get(FLASHBACK_SUBMIT_TODAY)!.mockResolvedValue({
			data: { flashbackSubmitToday: { today: {} } },
		});
		mutations.get(FLASHBACK_SEND_TO_WALL)!.mockResolvedValue({
			data: { flashbackSendToWall: { sentToWallAt: "2026-09-18T00:00:00Z" } },
		});
		const requestPhoneCode = mutations.get(
			(await import("@/lib/graphql/auth")).REQUEST_PHONE_CODE,
		)!;
		requestPhoneCode.mockResolvedValue({ data: { requestPhoneCode: { sent: true } } });
		const bind = mutations.get(FLASHBACK_REGISTER_BIND)!;
		bind.mockResolvedValue({ data: { flashbackRegisterBind: { bound: true, maskedPhone: "138****0000" } } });
		mockEnterResolve(memoryEntry);
		await walkTo("send");

		expect(await screen.findByText(/想收好这张卡/)).toBeInTheDocument();

		fireEvent.change(screen.getByLabelText("手机号"), { target: { value: "13800000000" } });
		fireEvent.click(screen.getByRole("button", { name: "手机号验证收好" }));
		expect(await screen.findByLabelText("验证码")).toBeInTheDocument();

		fireEvent.change(screen.getByLabelText("验证码"), { target: { value: "123456" } });
		fireEvent.click(screen.getByRole("button", { name: "绑定账号" }));

		expect(await screen.findByText("账号已接管")).toBeInTheDocument();
		fireEvent.click(screen.getByRole("button", { name: "进入时间长廊 →" }));
		await waitFor(() => expect(pushMock).toHaveBeenCalledWith("/flashback/capsule"));
	});

	it("金句授权随寄出提交：选句后 setQuoteLicense 收到区间（R31）", async () => {
		pendingResults.set(
			FLASHBACK_SUBMIT_TODAY,
			() => Promise.resolve({ data: { flashbackSubmitToday: { today: {} } } }),
		);
		pendingResults.set(
			FLASHBACK_SET_QUOTE_LICENSE,
			() => Promise.resolve({ data: { flashbackSetQuoteLicense: { level: "anonymous" } } }),
		);
		pendingResults.set(
			FLASHBACK_SEND_TO_WALL,
			() => Promise.resolve({ data: { flashbackSendToWall: { sentToWallAt: "2026-09-18T00:00:00Z" } } }),
		);
		mockEnterResolve(memoryEntry);
		await walkTo("write");
		// 渲染后 registry 必有该 runner（所有 useMutation 已执行）
		const quote = mutations.get(FLASHBACK_SET_QUOTE_LICENSE)!;

		fireEvent.click(screen.getByRole("radio", { name: /匿名金句/ }));
		fireEvent.click(await screen.findByRole("button", { name: "一个刚毕业的文科生，在出版社做校对。" }));
		fireEvent.submit(screen.getByRole("button", { name: "写好了，去寄出 →" }).closest("form")!);
		// 检查步确认后才寄出：等注册引导出现即说明 submitToday/quote/sendToWall 已顺序发出
		await screen.findByText("寄出前，检查当年的你");
		fireEvent.click(screen.getByRole("button", { name: /^确认寄出/ }));
		await screen.findByRole("button", { name: "跳过，直接上墙" });

		await waitFor(() => expect(quote).toHaveBeenCalled());
		const variables = quote.mock.calls[0][0].variables;
		expect(variables.level).toBe("anonymous");
		expect(variables.chosenQuoteSpans).toEqual([{ questionKey: "self_intro", start: 0, len: 18 }]);
	});

	it("检查步调雾上链：确认寄出后 flashbackAdjustFog 带 token/answerId/spans 且先于上墙（R16/KTD4）", async () => {
		pendingResults.set(
			FLASHBACK_SUBMIT_TODAY,
			() => Promise.resolve({ data: { flashbackSubmitToday: { today: {} } } }),
		);
		pendingResults.set(
			FLASHBACK_SEND_TO_WALL,
			() => Promise.resolve({ data: { flashbackSendToWall: { sentToWallAt: "2026-09-18T00:00:00Z" } } }),
		);
		mockEnterResolve(memoryEntry);
		await walkTo("write");
		const adjust = mutations.get(FLASHBACK_ADJUST_FOG)!;
		adjust.mockResolvedValue({
			data: { flashbackAdjustFog: { answerId: "a1", fogSpans: [{ start: 0, len: 18 }] } },
		});
		const wall = mutations.get(FLASHBACK_SEND_TO_WALL)!;

		fireEvent.submit(screen.getByRole("button", { name: "写好了，去寄出 →" }).closest("form")!);
		await screen.findByText("寄出前，检查当年的你");
		// 确认前零 mutation（调雾也在其列）
		expect(adjust).not.toHaveBeenCalled();

		fireEvent.click(screen.getByRole("button", { name: "一个刚毕业的文科生，在出版社做校对。" }));
		fireEvent.click(screen.getByRole("button", { name: /^确认寄出/ }));

		await waitFor(() => expect(wall).toHaveBeenCalledTimes(1));
		expect(adjust).toHaveBeenCalledWith({
			variables: { token: "tok-123", answerId: "a1", spans: [{ start: 0, len: 18 }] },
		});
		expect(adjust.mock.invocationCallOrder[0]).toBeLessThan(wall.mock.invocationCallOrder[0]);
	});
});

describe("Journey · 圆梦线", () => {
	it("信封开场（寄了 N 年才到）；拆开显影答案 + 无场次兜底 CTA 落 Initiative 公开页（AE4）", async () => {
		mockEnterResolve(dreamEntry);
		await renderJourney();

		expect(screen.getByText("有一封信，寄了 12 年才到")).toBeInTheDocument();
		expect(screen.queryByText("按下快门，回到那天")).not.toBeInTheDocument();

		fireEvent.click(screen.getByRole("button", { name: "拆开这封信" }));
		// 第 6 件：拆信动画（flap 1s + 信纸升起 1.2s/延迟 0.8s）收尾才切显影
		expect(await screen.findByTestId("fb-polaroid", {}, { timeout: 3000 })).toBeInTheDocument();
		expect(screen.getByText("我想亲眼看看是不是。")).toBeInTheDocument();
		// CTA 两态之「无场次」：落 Initiative 公开页 + 兜底出口文案
		expect(screen.getByRole("link", { name: "看看正在发生的活动" })).toHaveAttribute("href", "/initiatives");
		expect(screen.getByText(/留下联系方式/)).toBeInTheDocument();
		// 圆梦线不展示比特币提醒（记忆线专属）
		expect(screen.queryByText(/比特币/)).not.toBeInTheDocument();
	});

	it("信封物件：点信封 → 翻盖旋开 + 信纸升起 → 动画收尾切显影（第 6 件，原型 C）", async () => {
		mockEnterResolve(dreamEntry);
		await renderJourney();

		const envelope = screen.getByTestId("fb-envelope");
		expect(envelope).toHaveAttribute("data-opened", "false");
		expect(screen.getByText("李一诺 亲启")).toBeInTheDocument();

		fireEvent.click(envelope);
		// 既有（此前死掉的）两条信封动画类在拆开瞬间挂上
		expect(screen.getByTestId("fb-envelope")).toHaveAttribute("data-opened", "true");
		expect(document.querySelector(".fb-envelope-flap.fb-flap")).toBeTruthy();
		expect(document.querySelector(".fb-envelope-letter.fb-letter-out")).toBeTruthy();
		// 动画收尾（2.0s）才切显影，拆信过程不被跳过
		expect(screen.queryByTestId("fb-polaroid")).not.toBeInTheDocument();
		expect(await screen.findByTestId("fb-polaroid", {}, { timeout: 3000 })).toBeInTheDocument();
	});

	it("reduced-motion：拆信直达显影（无动画、无 2s 等待）", async () => {
		vi.spyOn(window, "matchMedia").mockReturnValue({
			matches: true,
			media: "(prefers-reduced-motion: reduce)",
			onchange: null,
			addListener: vi.fn(),
			removeListener: vi.fn(),
			addEventListener: vi.fn(),
			removeEventListener: vi.fn(),
			dispatchEvent: vi.fn(),
		} as unknown as MediaQueryList);
		mockEnterResolve(dreamEntry);
		await renderJourney();

		fireEvent.click(screen.getByTestId("fb-envelope"));
		expect(await screen.findByTestId("fb-polaroid")).toBeInTheDocument();
		expect(screen.queryByTestId("fb-envelope")).not.toBeInTheDocument();
	});

	it("CTA 两态之「有场次」：直链本城 Event 报名页", async () => {
		const { client } = await import("@/lib/apollo-client");
		vi.mocked(client.query).mockResolvedValueOnce({
			data: {
				flashbackDreamTarget: {
					eventSlug: "1024-beijing-ride",
					eventTitle: "1024 北京骑行场",
					startsAt: null,
					initiativeSlug: "1024-2026",
				},
			},
		} as never);
		mockEnterResolve(dreamEntry);
		await renderJourney();

		fireEvent.click(screen.getByRole("button", { name: "拆开这封信" }));

		const cta = await screen.findByRole("link", { name: /报名「1024 北京骑行场」/ }, { timeout: 3000 });
		expect(cta).toHaveAttribute("href", "/events/1024-beijing-ride");
	});
});

describe("Journey · 失效与回访", () => {
	it("已注册（claimed）：引导登录并说明账号已接管", async () => {
		mockEnterReject({
			errors: [{ message: "claimed", extensions: { code: "flashback_token_claimed" } }],
		});
		await renderJourney();

		expect(await screen.findByText("这个档案已有主人")).toBeInTheDocument();
		expect(screen.getByRole("link", { name: "去登录" })).toHaveAttribute("href", "/login");
	});

	it("已删除（revoked）：告知清除 + 回首页出口", async () => {
		mockEnterReject({
			errors: [{ message: "revoked", extensions: { code: "flashback_token_revoked" } }],
		});
		await renderJourney();

		expect(await screen.findByText("这封信已被收回")).toBeInTheDocument();
		expect(screen.getByRole("link", { name: "回到闪念间首页" })).toHaveAttribute("href", "/flashback");
	});

	it("不存在（not_found）：自助找回入口", async () => {
		mockEnterReject({
			errors: [{ message: "nope", extensions: { code: "flashback_token_not_found" } }],
		});
		await renderJourney();

		expect(await screen.findByText("这枚链接不存在或已失效")).toBeInTheDocument();
		expect(screen.getByRole("link", { name: "自助找回我的档案" })).toHaveAttribute("href", "/flashback");
	});

	it("无 token 直达失效分支", async () => {
		await renderJourney("/flashback/enter");

		expect(await screen.findByText("这枚链接不存在或已失效")).toBeInTheDocument();
		expect(mutations.get(FLASHBACK_ENTER)).not.toHaveBeenCalled();
	});

	it("回访（已寄出）：跳过仪式直达胶囊（AE9 完成态）", async () => {
		mockEnterResolve({
			...memoryEntry,
			progress: {
				quoteLevel: "off",
				today: { nowStatus: "还在写东西", sentToWallAt: "2026-09-18T00:00:00Z" },
			},
		});
		window.history.replaceState({}, "", "/flashback/enter?token=tok-again");
		window.sessionStorage.clear();
		render(<Journey />);

		await waitFor(() => expect(pushMock).toHaveBeenCalledWith("/flashback/capsule"));
	});

	it("影卡点击卡面 3D 翻面到背面书写面，可翻回正面（第 3 件，原型 E「点击照片翻面写字」）", async () => {
		mockEnterResolve(memoryEntry);
		await walkTo("reveal");
		const card = screen.getByTestId("fb-polaroid");
		expect(card).toHaveAttribute("data-face", "front");

		fireEvent.click(card);
		// 换面分两段：先前半程转到侧棱（fb-flip-swap--out）
		await waitFor(() => expect(document.querySelector(".fb-flip-swap--out")).toBeTruthy());
		expect(await screen.findByText("今天的你")).toBeInTheDocument();
		expect(screen.getByRole("button", { name: "写好了，去寄出 →" })).toBeInTheDocument();

		fireEvent.click(screen.getByRole("button", { name: "翻回正面" }));
		await waitFor(() => expect(screen.getByTestId("fb-polaroid")).toHaveAttribute("data-face", "front"), {
			timeout: 2000,
		});
	});

	it("reduced-motion：翻面直达目标面（无换面动画相位）", async () => {
		vi.spyOn(window, "matchMedia").mockReturnValue({
			matches: true,
			media: "(prefers-reduced-motion: reduce)",
			onchange: null,
			addListener: vi.fn(),
			removeListener: vi.fn(),
			addEventListener: vi.fn(),
			removeEventListener: vi.fn(),
			dispatchEvent: vi.fn(),
		} as unknown as MediaQueryList);
		mockEnterResolve(memoryEntry);
		await walkTo("reveal");

		fireEvent.click(screen.getByTestId("fb-polaroid"));
		expect(screen.queryByTestId("fb-polaroid")).not.toBeInTheDocument();
		expect(screen.getByText("今天的你")).toBeInTheDocument();
		expect(document.querySelector(".fb-flip-swap--out")).toBeNull();
	});

	it("回访（已填今天但未寄出）：跳过仪式直达写字，不再被锁在胶囊外（e2e 实测死循环）", async () => {
		mockEnterResolve({
			...memoryEntry,
			progress: { quoteLevel: "off", today: { nowStatus: "还在写东西" } },
		});
		window.history.replaceState({}, "", "/flashback/enter?token=tok-again");
		window.sessionStorage.clear();
		render(<Journey />);

		expect(await screen.findByText("今天的你")).toBeInTheDocument();
		expect(pushMock).not.toHaveBeenCalled();
	});
});

describe("Journey · 无障碍", () => {
	it("reduced-motion：跳过白光直达终态（无 flash overlay）", async () => {
		vi.spyOn(window, "matchMedia").mockReturnValue({
			matches: true,
			media: "(prefers-reduced-motion: reduce)",
			onchange: null,
			addListener: vi.fn(),
			removeListener: vi.fn(),
			addEventListener: vi.fn(),
			removeEventListener: vi.fn(),
			dispatchEvent: vi.fn(),
		} as unknown as MediaQueryList);
		mockEnterResolve(memoryEntry);
		await renderJourney();

		fireEvent.click(screen.getByRole("button", { name: "按下快门，回到那天" }));
		expect(await screen.findByText("点开一张，放大看看——线索藏在照片里。")).toBeInTheDocument();
		expect(document.querySelector(".fb-flash-overlay")).toBeNull();
	});

	it("关键交互元素全部为原生按钮（键盘可操作）+ 阶段标题承接焦点", async () => {
		mockEnterResolve(memoryEntry);
		await walkTo("quiz");

		expect(screen.getByRole("button", { name: /我不记得了/ })).toBeInTheDocument();
		expect(screen.getByRole("button", { name: /重挑一张/ })).toBeInTheDocument();
		expect(screen.getByRole("heading", { name: "还记得……是哪一场吗？" })).toHaveAttribute(
			"tabindex",
			"-1",
		);
	});
});
