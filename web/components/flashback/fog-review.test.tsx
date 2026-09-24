import { afterEach, describe, expect, it, vi } from "vitest";
import { act, cleanup, fireEvent, screen, waitFor, within } from "@testing-library/react";
import { render } from "@/test-utils";
import SendRegister from "./send-register";
import { emptyTodayForm, type TodayFormState } from "./write";
import type { FlashbackAnswer, FlashbackFogSpan } from "@/lib/graphql/flashback";

/**
 * 寄出前检查步（「检查当年的你」，本人自选雾面，KTD4）单测。
 *
 * 钉住的行为契约：
 * - 浮层打开先停检查步：题干 + 全部当年答案逐句列出，任何 mutation 都不发出；
 * - 初始雾态按 enter 载荷 fogSpans 渲染（不写死空）；
 * - 句选切雾 → spans 按 grapheme 构造（中文多字节 / emoji / 中英混排，与后端对齐）；
 * - 确认后仅「相对载荷有变化」的 answer 依次调雾，全部成功才继续原寄出序列；
 * - 任一调雾失败即中止寄出（上墙未发生）+ 错误态 + 「再试一次」从未完成处继续；
 * - 「再想想」返回写字步，零 mutation；
 * - 无障碍：句选 button + aria-pressed，阶段标题 tabindex=-1 承接焦点。
 */

/** 中文多字节：句1「当年我在出版社做校对。」start 0 len 11；句2 start 11 len 8 */
const CN_ANSWER: FlashbackAnswer = {
	id: "a-cn",
	questionKey: "self_intro",
	rawText: "当年我在出版社做校对。后来我去了北京。",
	fogSpans: null,
};

/** emoji（grapheme 口径 😀 记 1）：「写了第一个😀程序！」start 0 len 9；「Cool stuff.」start 9 len 11 */
const EMOJI_ANSWER: FlashbackAnswer = {
	id: "a-emoji",
	questionKey: "funny_thing",
	rawText: "写了第一个😀程序！Cool stuff.",
	fogSpans: null,
};

/** 中英混排：「I love CGC。」start 0 len 11；「我爱这里。」start 11 len 5 */
const MIXED_ANSWER: FlashbackAnswer = {
	id: "a-mixed",
	questionKey: "os",
	rawText: "I love CGC。我爱这里。",
	fogSpans: null,
};

/** 载荷已带雾（span 0-5 命中唯一句） */
const FOGGED_ANSWER: FlashbackAnswer = {
	id: "a-fog",
	questionKey: "self_intro",
	rawText: "一个刚毕业的文科生，在出版社做校对。",
	fogSpans: [{ start: 0, len: 5 }],
};

type Stubs = {
	onSubmitToday: ReturnType<typeof vi.fn<(input: TodayFormState) => Promise<boolean>>>;
	onSendToWall: ReturnType<typeof vi.fn<() => Promise<boolean>>>;
	onSetQuoteLicense: ReturnType<typeof vi.fn<(form: TodayFormState) => Promise<boolean>>>;
	onRegisterBind: ReturnType<typeof vi.fn<(phone: string, code: string) => Promise<boolean>>>;
	onRequestPhoneCode: ReturnType<
		typeof vi.fn<(phone: string, purpose: "REGISTER" | "CHANGE_PHONE") => Promise<boolean>>
	>;
	onAdjustFog: ReturnType<typeof vi.fn<(answerId: string, spans: FlashbackFogSpan[]) => Promise<boolean>>>;
	onDone: ReturnType<typeof vi.fn<() => void>>;
	onBack: ReturnType<typeof vi.fn<() => void>>;
};

function makeStubs(): Stubs {
	return {
		onSubmitToday: vi.fn<(input: TodayFormState) => Promise<boolean>>().mockResolvedValue(true),
		onSendToWall: vi.fn<() => Promise<boolean>>().mockResolvedValue(true),
		onSetQuoteLicense: vi.fn<(form: TodayFormState) => Promise<boolean>>().mockResolvedValue(true),
		onRegisterBind: vi.fn<(phone: string, code: string) => Promise<boolean>>().mockResolvedValue(true),
		onRequestPhoneCode:
			vi.fn<(phone: string, purpose: "REGISTER" | "CHANGE_PHONE") => Promise<boolean>>().mockResolvedValue(true),
		onAdjustFog:
			vi.fn<(answerId: string, spans: FlashbackFogSpan[]) => Promise<boolean>>().mockResolvedValue(true),
		onDone: vi.fn<() => void>(),
		onBack: vi.fn<() => void>(),
	};
}

function renderSend(stubs: Stubs, answers: FlashbackAnswer[], form: TodayFormState = emptyTodayForm) {
	return render(<SendRegister answers={answers} form={form} {...stubs} />);
}

/** 确认寄出（检查步 CTA） */
function confirmSend() {
	fireEvent.click(screen.getByRole("button", { name: /^确认寄出/ }));
}

afterEach(() => cleanup());

describe("SendRegister · 检查当年的你（雾面自选）", () => {
	it("浮层打开先停检查步：题干 + 全部当年答案逐句列出，打开即寄出的旧行为不再发生", async () => {
		const stubs = makeStubs();
		renderSend(stubs, [CN_ANSWER, EMOJI_ANSWER]);

		expect(await screen.findByText("寄出前，检查当年的你")).toBeInTheDocument();
		// 题干来自 flashback.questionLabels；答案逐句列出
		expect(screen.getByText("请简单的介绍一下自己")).toBeInTheDocument();
		expect(screen.getByText("你做过的有意思的事情")).toBeInTheDocument();
		expect(screen.getByRole("button", { name: "当年我在出版社做校对。" })).toBeInTheDocument();
		expect(screen.getByRole("button", { name: "后来我去了北京。" })).toBeInTheDocument();
		expect(screen.getByRole("button", { name: "写了第一个😀程序！" })).toBeInTheDocument();
		expect(screen.getByRole("button", { name: "Cool stuff." })).toBeInTheDocument();
		// 提示文案说清三件事：a) 带雾句对外是雾块；b) 本人永远完整原文；c) 寄出后小程序可继续调
		expect(screen.getByText(/雾块/)).toBeInTheDocument();
		expect(screen.getByText(/完整原文/)).toBeInTheDocument();
		expect(screen.getByText(/小程序/)).toBeInTheDocument();

		// 等待越过 timer 0：打开不触发任何 mutation（旧「打开即寄出」的反向钉住）
		await act(() => new Promise((resolve) => setTimeout(resolve, 20)));
		expect(stubs.onSubmitToday).not.toHaveBeenCalled();
		expect(stubs.onSetQuoteLicense).not.toHaveBeenCalled();
		expect(stubs.onSendToWall).not.toHaveBeenCalled();
		expect(stubs.onAdjustFog).not.toHaveBeenCalled();
	});

	it("初始雾态按 enter 载荷渲染（不写死空）：命中句 aria-pressed= true 并带雾徽章", async () => {
		const stubs = makeStubs();
		renderSend(stubs, [FOGGED_ANSWER]);

		const sentence = await screen.findByRole("button", { name: "一个刚毕业的文科生，在出版社做校对。" });
		expect(sentence).toHaveAttribute("aria-pressed", "true");
		expect(within(sentence).getByText("雾")).toBeInTheDocument();
	});

	it("句选切雾 → spans 按 grapheme 构造（中文多字节）；确认后仅变化 answer 调雾且先于寄出其余步骤", async () => {
		const stubs = makeStubs();
		const calls: string[] = [];
		stubs.onAdjustFog.mockImplementation(async (answerId: string) => {
			calls.push(`fog:${answerId}`);
			return true;
		});
		stubs.onSubmitToday.mockImplementation(async () => {
			calls.push("submit");
			return true;
		});
		stubs.onSendToWall.mockImplementation(async () => {
			calls.push("wall");
			return true;
		});
		renderSend(stubs, [CN_ANSWER, EMOJI_ANSWER]);

		// 只点 a-cn 的第二句：a-emoji 无变化不调雾
		fireEvent.click(await screen.findByRole("button", { name: "后来我去了北京。" }));
		confirmSend();

		// 顺序钉死：调雾 → submitToday → sendToWall
		await waitFor(() => expect(calls).toEqual(["fog:a-cn", "submit", "wall"]));
		expect(stubs.onAdjustFog).toHaveBeenCalledTimes(1);
		expect(stubs.onAdjustFog).toHaveBeenCalledWith("a-cn", [{ start: 11, len: 8 }]);
		expect(await screen.findByText(/愿望不会消失/)).toBeInTheDocument();
	});

	it("emoji 句 spans 按 grapheme 计（😀 记 1，与后端 FogSpans 对齐）：首句 {0,9}", async () => {
		const stubs = makeStubs();
		renderSend(stubs, [EMOJI_ANSWER]);

		fireEvent.click(await screen.findByRole("button", { name: "写了第一个😀程序！" }));
		confirmSend();

		await waitFor(() =>
			expect(stubs.onAdjustFog).toHaveBeenCalledWith("a-emoji", [{ start: 0, len: 9 }]),
		);
	});

	it("emoji 后接句的 start 同样按 grapheme 算：「Cool stuff.」start 9 len 11", async () => {
		const stubs = makeStubs();
		renderSend(stubs, [EMOJI_ANSWER]);

		fireEvent.click(await screen.findByRole("button", { name: "Cool stuff." }));
		confirmSend();

		await waitFor(() =>
			expect(stubs.onAdjustFog).toHaveBeenCalledWith("a-emoji", [{ start: 9, len: 11 }]),
		);
	});

	it("中英混排句 spans：「我爱这里。」start 11 len 5", async () => {
		const stubs = makeStubs();
		renderSend(stubs, [MIXED_ANSWER]);

		fireEvent.click(await screen.findByRole("button", { name: "我爱这里。" }));
		confirmSend();

		await waitFor(() =>
			expect(stubs.onAdjustFog).toHaveBeenCalledWith("a-mixed", [{ start: 11, len: 5 }]),
		);
	});

	it("未改动任何句子：确认后零 adjustFog，直接走原寄出序列", async () => {
		const stubs = makeStubs();
		renderSend(stubs, [CN_ANSWER]);

		confirmSend();

		await waitFor(() => expect(stubs.onSendToWall).toHaveBeenCalledTimes(1));
		expect(stubs.onAdjustFog).not.toHaveBeenCalled();
		expect(stubs.onSubmitToday).toHaveBeenCalledTimes(1);
	});

	it("载荷已有雾 → 点回亮：相对载荷有变化，确认后以空 spans 落库", async () => {
		const stubs = makeStubs();
		renderSend(stubs, [FOGGED_ANSWER]);

		fireEvent.click(
			await screen.findByRole("button", { name: "一个刚毕业的文科生，在出版社做校对。" }),
		);
		confirmSend();

		await waitFor(() => expect(stubs.onAdjustFog).toHaveBeenCalledWith("a-fog", []));
		await waitFor(() => expect(stubs.onSendToWall).toHaveBeenCalledTimes(1));
	});

	it("任一 adjustFog 失败即中止寄出：上墙未发生，错误态 +「再试一次」从未完成处继续", async () => {
		const stubs = makeStubs();
		stubs.onAdjustFog.mockResolvedValueOnce(false); // 首次失败；重试回到默认成功
		renderSend(stubs, [CN_ANSWER]);

		fireEvent.click(await screen.findByRole("button", { name: "后来我去了北京。" }));
		confirmSend();

		expect(await screen.findByText("这次没贴上")).toBeInTheDocument();
		expect(screen.getByRole("alert")).toHaveTextContent(/雾/);
		// 中止点在上墙前：submit/wall 均未发出
		expect(stubs.onSubmitToday).not.toHaveBeenCalled();
		expect(stubs.onSendToWall).not.toHaveBeenCalled();

		fireEvent.click(screen.getByRole("button", { name: "再试一次" }));

		await waitFor(() => expect(stubs.onSendToWall).toHaveBeenCalledTimes(1));
		expect(stubs.onAdjustFog).toHaveBeenCalledTimes(2);
		expect(stubs.onAdjustFog).toHaveBeenLastCalledWith("a-cn", [{ start: 11, len: 8 }]);
		expect(await screen.findByText(/愿望不会消失/)).toBeInTheDocument();
	});

	it("「再想想」返回写字步：不触发任何 mutation", async () => {
		const stubs = makeStubs();
		renderSend(stubs, [CN_ANSWER]);

		fireEvent.click(await screen.findByRole("button", { name: "再想想" }));

		expect(stubs.onBack).toHaveBeenCalledTimes(1);
		expect(stubs.onSubmitToday).not.toHaveBeenCalled();
		expect(stubs.onSetQuoteLicense).not.toHaveBeenCalled();
		expect(stubs.onSendToWall).not.toHaveBeenCalled();
		expect(stubs.onAdjustFog).not.toHaveBeenCalled();
	});

	it("无障碍：句选为 button + aria-pressed 切换，阶段标题 tabindex=-1 承接焦点", async () => {
		const stubs = makeStubs();
		renderSend(stubs, [CN_ANSWER]);

		const title = await screen.findByText("寄出前，检查当年的你");
		expect(title).toHaveAttribute("tabindex", "-1");

		const sentence = screen.getByRole("button", { name: "后来我去了北京。" });
		expect(sentence).toHaveAttribute("aria-pressed", "false");
		fireEvent.click(sentence);
		expect(sentence).toHaveAttribute("aria-pressed", "true");
		expect(within(sentence).getByText("雾")).toBeInTheDocument();
	});
});
