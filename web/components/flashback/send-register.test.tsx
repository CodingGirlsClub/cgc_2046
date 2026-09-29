import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, it, expect, vi, afterEach, beforeEach } from "vitest";
import { cleanup, fireEvent, screen, waitFor } from "@testing-library/react";
import { render } from "@/test-utils";
import SendRegister from "./send-register";
import type { TodayFormState } from "./write";
import type { FlashbackAnswer } from "@/lib/graphql/flashback";

/**
 * 寄出检查步：today 字段逐句雾选（建议 2 落地，U9 双入口 flashbackAdjustTodayFog）。
 *
 * 钉住的契约：
 * - review 步在「当年的你」答案区之外，另有「今天的你」区：TODAY_FIELDS 四字段
 *   （now/want/need/say）非空即列出，用户逐句切换雾/亮；
 * - 确认寄出链路顺序必须 = submitToday（先把新文本落库）→ adjustTodayFog
 * （按服务端最新文本校验雾区间）→（非 off 时 setQuoteLicense）→ sendToWall；
 *   若今天雾没调成功，寄出在此暂停（不 sendToWall），可重试；
 * - 一句未动（初始雾区间无变化）→ 一个 adjustTodayFog 都不发（零无谓 mutation）；
 * - need 字段也在候选里：它不进长廊投影，但其句子可被圈作公开金句——
 *   today 四字段全列，防的正是「need 被引用成公开金句」这条暗漏。
 */

vi.mock("next/navigation", () => ({
	usePathname: () => "/flashback/enter",
	useRouter: () => ({ push: vi.fn(), replace: vi.fn(), prefetch: vi.fn() }),
	useParams: () => ({}),
	redirect: vi.fn(),
	permanentRedirect: vi.fn(),
}));

vi.mock("@/lib/apollo-client", () => ({
	client: { mutate: vi.fn() },
}));

const { auth } = vi.hoisted(() => ({ auth: vi.fn() }));
vi.mock("@/lib/auth-provider", () => ({ useAuthed: auth }));

const TODAY_TEXTS = {
	nowStatus: "我在写代码，忽然想起当年跳闸的夜。",
	want: "想学好 AI 应用，做出能跑的东西。",
	need: "想找一位 mentor 带带我。",
	say: "谢谢你们当年拉我进教室。",
};

const FORM: TodayFormState = { ...TODAY_TEXTS };

const ANSWERS: FlashbackAnswer[] = [];

/** 本人身份与墙上署名（#1022 两按钮所需；与授权档一起，默认未授权） */
const IDENTITY = { fullName: "王晓雨", surname: "王", anonymousAttribution: "王** · 2014 · 北京", quoteLevel: "off" };

/** 句 1 [0,8) 我是一个文科生。 句 2 [8,13) 想亲眼看看代码是不是魔法。 */
const QUOTE_ANSWERS: FlashbackAnswer[] = [
	{ id: "a1", questionKey: "self_intro", rawText: "我是一个文科生。想亲眼看看代码是不是魔法。", fogSpans: null },
];

function makeHandlers(
	log: string[],
	overrides: { adjustTodayFogOk?: boolean; setQuoteLicenseOk?: boolean } = {},
) {
	return {
		log,
		onSubmitToday: vi.fn(async () => {
			log.push("submitToday");
			return true;
		}),
		onSendToWall: vi.fn(async () => {
			log.push("sendToWall");
			return true;
		}),
		onSetQuoteLicense: vi.fn(async () => {
			log.push("setQuoteLicense");
			return overrides.setQuoteLicenseOk !== false;
		}),
		onAdjustFog: vi.fn(async (answerId: string) => {
			log.push(`adjustFog(${answerId})`);
			return true;
		}),
		onAdjustTodayFog: vi.fn(async (field: string) => {
			log.push(`adjustTodayFog(${field})`);
			return overrides.adjustTodayFogOk !== false;
		}),
		onRegisterBind: vi.fn(async () => true),
		onRequestPhoneCode: vi.fn(async () => true),
		onBack: vi.fn(),
		onDone: vi.fn(),
	};
}

function renderStep(
	handlers: ReturnType<typeof makeHandlers>,
	formOverrides: Partial<TodayFormState> = {},
	initialTodayFogSpans: Record<string, { start: number; len: number }[]> | null = null,
	{ answers = ANSWERS, quoteLevel = "off" }: { answers?: FlashbackAnswer[]; quoteLevel?: string } = {},
) {
	return render(
		<SendRegister
			form={{ ...FORM, ...formOverrides }}
			initialTodayFogSpans={initialTodayFogSpans}
			answers={answers}
			fullName="王晓雨"
			surname="王"
			anonymousAttribution="王** · 2014 · 北京"
			quoteLevel={quoteLevel}
			onSubmitToday={handlers.onSubmitToday}
			onSendToWall={handlers.onSendToWall}
			onSetQuoteLicense={handlers.onSetQuoteLicense}
			onAdjustFog={handlers.onAdjustFog}
			onAdjustTodayFog={handlers.onAdjustTodayFog}
			onRegisterBind={handlers.onRegisterBind}
			onRequestPhoneCode={handlers.onRequestPhoneCode}
			onClaim={vi.fn()}
			onBack={handlers.onBack}
			onDone={handlers.onDone}
		/>,
	);
}

afterEach(() => {
	cleanup();
});

beforeEach(() => {
	vi.clearAllMocks();
	auth.mockReturnValue({ authed: false, confirmed: true });
});

describe("SendRegister 寄出检查步：today 逐句雾选", () => {
	it("review 步列出 today 四个字段（zh 文案），每句各自可选雾/亮", () => {
		renderStep(makeHandlers([]));
		for (const label of [
			/现在的我，在做什么/,
			/想做的事、想学的东西/,
			/需要什么帮助/,
			/想对 CGC/,
		]) {
			expect(screen.getByText(label)).toBeInTheDocument();
		}
		// 逐句按钮存在（含「雾」标记切换语义）
		expect(screen.getByText(/我在写代码/)).toBeInTheDocument();
	});

	it("确认寄出顺序：submitToday → adjustTodayFog(选中句) → sendToWall；off 不发 setQuoteLicense", async () => {
		const handlers = makeHandlers([]);
		renderStep(handlers);
		// 在「现在的我，在做什么」里把句子切成雾
		fireEvent.click(screen.getByText(/忽然想起当年跳闸的夜/).closest("button")!);
		fireEvent.click(screen.getByRole("button", { name: /确认寄出/ }));

		await waitFor(() => {
			const seq = handlers.log;
			expect(seq[0]).toBe("submitToday");
			expect(seq[seq.length - 1]).toBe("sendToWall");
			expect(seq.filter((x) => x.startsWith("adjustTodayFog"))).toEqual([
				"adjustTodayFog(now)",
			]);
			expect(handlers.onSetQuoteLicense).not.toHaveBeenCalled();
		});
		// 发送的 spans 命中被点句的 start/len（与文本的切分对齐）
		const todayFogArgs = handlers.onAdjustTodayFog.mock.calls[0] as unknown[];
		const spans = todayFogArgs[1] as { start: number; len: number }[];
		expect(spans).toHaveLength(1);
		expect(
			TODAY_TEXTS.nowStatus.slice(spans[0].start, spans[0].start + spans[0].len),
		).toContain("忽然想起当年跳闸的夜");
	});

	it("今天雾失败：寄出在此暂停（不调 sendToWall），进入失败态可重试", async () => {
		const handlers = makeHandlers([], { adjustTodayFogOk: false });
		renderStep(handlers);
		fireEvent.click(screen.getByText(/谢谢你们当年拉我进教室/).closest("button")!);
		fireEvent.click(screen.getByRole("button", { name: /确认寄出/ }));

		await waitFor(() => {
			expect(handlers.onAdjustTodayFog).toHaveBeenCalled();
			expect(handlers.onSendToWall).not.toHaveBeenCalled();
		});
		expect(screen.getByRole("button", { name: /再试一次/ })).toBeInTheDocument();
	});

	it("一句都没选：不发任何 adjustTodayFog", async () => {
		const handlers = makeHandlers([]);
		renderStep(handlers);
		fireEvent.click(screen.getByRole("button", { name: /确认寄出/ }));
		await waitFor(() => {
			expect(handlers.onSendToWall).toHaveBeenCalled();
		});
		expect(handlers.onAdjustTodayFog).not.toHaveBeenCalled();
	});

	it("服务端既有 today 雾区间预填（盲初值闭环）：命中句渲染为雾态（aria-pressed=true）", () => {
		renderStep(makeHandlers([]), {}, { now: [{ start: 0, len: 2 }] });
		const fogged = [...document.querySelectorAll(".fb-review-sentence--fog")];
		expect(fogged.length).toBeGreaterThan(0);
		// 按同一相交判定，span 覆盖到句子即整句标雾（本用例 span 落在 nowStatus 文本上）
		expect(fogged.some((b) => (b.textContent || "").includes("我在写代码"))).toBe(true);
	});

	it("相对服务端基线无变化：不发任何 adjustTodayFog（不打扰不产影变）", async () => {
		const handlers = makeHandlers([]);
		renderStep(handlers, {}, { now: [{ start: 0, len: 2 }] });
		fireEvent.click(screen.getByRole("button", { name: /确认寄出/ }));
		await waitFor(() => {
			expect(handlers.onSendToWall).toHaveBeenCalled();
		});
		expect(handlers.onAdjustTodayFog).not.toHaveBeenCalled();
	});

	it("把预填的雾全部切回亮也显式同步（清雾落库）：adjustTodayFog(field, [])", async () => {
		const handlers = makeHandlers([]);
		renderStep(handlers, {}, { now: [{ start: 0, len: 2 }] });
		// 把预填的那句切回亮
		fireEvent.click(screen.getByText(/我在写代码/).closest("button")!);
		fireEvent.click(screen.getByRole("button", { name: /确认寄出/ }));
		await waitFor(() => {
			expect(handlers.onAdjustTodayFog).toHaveBeenCalled();
		});
		const args = handlers.onAdjustTodayFog.mock.calls[0] as unknown[];
		expect(args[0]).toBe("now");
		expect(args[1]).toEqual([]);
	});

	it("寄出完成态标题说已经完成（sentTitle 活过来）：不再用「照片正在贴上墙。」", async () => {
		const handlers = makeHandlers([]);
		renderStep(handlers);
		fireEvent.click(screen.getByRole("button", { name: /确认寄出/ }));
		await waitFor(() => {
			expect(screen.getByRole("heading", { name: "已经寄出了" })).toBeInTheDocument();
		});
		// «照片正在贴上墙» 只存在于发送中（sending），寄出成功后不再谎报状态
		expect(screen.queryByText("照片正在贴上墙。")).not.toBeInTheDocument();
		expect(screen.getByText(/愿望不会消失/)).toBeInTheDocument();
	});

	// 收好被服务端拒绝时 mutation 抛错（未配置 errorPolicy）：按错误码提示，不能没反应或一律说验证码错
	it.each([
		["flashback_recover_account_conflict", "已经属于另一个账号"],
		["invalid_or_expired_code", "验证码不对或已过期"],
	])("收好被拒（%s）：按服务端错误码提示", async (code, copy) => {
		const handlers = makeHandlers([]);
		handlers.onRegisterBind.mockRejectedValue({ errors: [{ message: "x", extensions: { code } }] });
		renderStep(handlers);
		fireEvent.click(screen.getByRole("button", { name: /确认寄出/ }));
		fireEvent.change(await screen.findByLabelText("手机号"), { target: { value: "13900000001" } });
		fireEvent.click(screen.getByRole("button", { name: "发送验证码" }));
		fireEvent.change(await screen.findByLabelText("验证码"), { target: { value: "123456" } });
		fireEvent.click(screen.getByRole("button", { name: "收好这张卡" }));

		expect(await screen.findByRole("alert")).toHaveTextContent(copy);
	});
});


describe("收好账号归属", () => {
 it("已登录时只调用一键收好，成功后进入长廊，不出现手机号表单", async () => {
  auth.mockReturnValue({ authed: true, confirmed: true });
  const h = makeHandlers([]); const claim = vi.fn().mockResolvedValue(true);
  render(<SendRegister form={FORM} answers={[]} {...IDENTITY} {...h} bound={false} onClaim={claim} />);
  fireEvent.click(screen.getByRole("button", { name: /^确认寄出/ }));
  fireEvent.click(await screen.findByRole("button", { name: "收进当前账号" }));
  expect(await screen.findByRole("button", { name: /^进入时间长廊/ })).toBeInTheDocument();
  expect(claim).toHaveBeenCalledOnce();
  expect(h.onRegisterBind).not.toHaveBeenCalled();
  expect(h.onRequestPhoneCode).not.toHaveBeenCalled();
  expect(screen.queryByRole("textbox")).not.toBeInTheDocument();
 });
 it("已有主人时不出现手机号表单，给登录出口", async () => {
  const h = makeHandlers([]);
  render(<SendRegister form={FORM} answers={[]} {...IDENTITY} {...h} bound onClaim={vi.fn()} />);
  fireEvent.click(screen.getByRole("button", { name: /^确认寄出/ }));
  expect(await screen.findByText("这张卡已经收进账号，登录即可查看。")).toBeInTheDocument();
  expect(screen.getByRole("link", { name: "登录" })).toHaveAttribute("href", "/login?next=%2Fflashback%2Fcapsule");
  expect(screen.queryByRole("textbox")).not.toBeInTheDocument();
 });
 it("一键收好被拒时保留重试与登录出口", async () => {
  auth.mockReturnValue({ authed: true, confirmed: true });
  const h = makeHandlers([]); const claim = vi.fn().mockRejectedValue({ errors: [{ code: "flashback_recover_account_conflict" }] });
  render(<SendRegister form={FORM} answers={[]} {...IDENTITY} {...h} bound={false} onClaim={claim} />);
  fireEvent.click(screen.getByRole("button", { name: /^确认寄出/ }));
  fireEvent.click(await screen.findByRole("button", { name: "收进当前账号" }));
  expect(await screen.findByRole("alert")).toHaveClass("fb-error");
  expect(screen.getByRole("link", { name: "登录" })).toHaveAttribute("href", "/login?next=%2Fflashback%2Fcapsule");
  expect(screen.getByRole("button", { name: "收进当前账号" })).toBeEnabled();
 });
});

// PR #960 评审 2：登录链接只属于「收好动作被拒（卡属于别的账号）」这一支；
// 寄出失败页与验证码错误只显示错误 + 重试。
describe("错误里的登录出口（PR #960 评审 2）", () => {
 it("寄出失败页：只有错误和重试，无登录链接", async () => {
  const handlers = makeHandlers([], { adjustTodayFogOk: false });
  renderStep(handlers);
  fireEvent.click(screen.getByText(/谢谢你们当年拉我进教室/).closest("button")!);
  fireEvent.click(screen.getByRole("button", { name: /确认寄出/ }));
  expect(await screen.findByRole("alert")).toBeInTheDocument();
  expect(screen.queryByRole("link", { name: "登录" })).not.toBeInTheDocument();
 });

 it("验证码错误：只有错误和重试，无登录链接", async () => {
  const handlers = makeHandlers([]);
  handlers.onRegisterBind.mockRejectedValue({ errors: [{ message: "x", extensions: { code: "invalid_or_expired_code" } }] });
  renderStep(handlers);
  fireEvent.click(screen.getByRole("button", { name: /确认寄出/ }));
  fireEvent.change(await screen.findByLabelText("手机号"), { target: { value: "13900000001" } });
  fireEvent.click(screen.getByRole("button", { name: "发送验证码" }));
  fireEvent.change(await screen.findByLabelText("验证码"), { target: { value: "000000" } });
  fireEvent.click(screen.getByRole("button", { name: "收好这张卡" }));
  expect(await screen.findByRole("alert")).toBeInTheDocument();
  expect(screen.queryByRole("link", { name: "登录" })).not.toBeInTheDocument();
 });

 it("收好冲突（未登录）：错误下方给登录链接（回跳长廊）", async () => {
  const handlers = makeHandlers([]);
  handlers.onRegisterBind.mockRejectedValue({ errors: [{ message: "x", extensions: { code: "flashback_recover_account_conflict" } }] });
  renderStep(handlers);
  fireEvent.click(screen.getByRole("button", { name: /确认寄出/ }));
  fireEvent.change(await screen.findByLabelText("手机号"), { target: { value: "13900000001" } });
  fireEvent.click(screen.getByRole("button", { name: "发送验证码" }));
  fireEvent.change(await screen.findByLabelText("验证码"), { target: { value: "123456" } });
  fireEvent.click(screen.getByRole("button", { name: "收好这张卡" }));
  expect(await screen.findByRole("alert")).toBeInTheDocument();
  expect(screen.getByRole("link", { name: "登录" })).toHaveAttribute("href", "/login?next=%2Fflashback%2Fcapsule");
 });
});

// N10：收好邀请语不得再承诺「附议的场成真时收到通知」——该通知能力不存在。
describe("文案守卫", () => {
 it("registerPitch 不再承诺附议成真通知", () => {
  const zh = JSON.parse(readFileSync(fileURLToPath(new URL("../../messages/zh-CN.json", import.meta.url.split("?")[0])), "utf8"));
  const pitch = zh.flashback.sendRegister.registerPitch;
  expect(pitch).toContain("收好");
  expect(pitch).not.toContain("成真时收到通知");
 });
});

// #1022：寄出那一刻明确地问「要不要把这句放进金句墙」（单独同意：两按钮同分量，授权永不预选）
describe("寄出时的金句选择（#1022）", () => {
	const withQuote = () => screen.getByRole("button", { name: "寄出，并把这句匿名放进金句墙 →" });
	const albumOnly = () => screen.getByRole("button", { name: "寄出到相册" });

	it("有推荐句：预览这句与墙上署名，两个同分量按钮替代单个寄出", () => {
		renderStep(makeHandlers([]), {}, null, { answers: QUOTE_ANSWERS });

		expect(screen.getByText("「我是一个文科生。」")).toBeInTheDocument();
		expect(screen.getByText("王** · 2014 · 北京")).toBeInTheDocument();
		expect(withQuote().className).toBe(albumOnly().className);
		expect(screen.queryByRole("button", { name: /^确认寄出/ })).not.toBeInTheDocument();
	});

	it("「寄出，并把这句…」：先授权这一句，再寄出；完成页给金句墙入口", async () => {
		const handlers = makeHandlers([]);
		renderStep(handlers, {}, null, { answers: QUOTE_ANSWERS });
		fireEvent.click(withQuote());

		await waitFor(() => expect(handlers.log[handlers.log.length - 1]).toBe("sendToWall"));
		expect(handlers.onSetQuoteLicense).toHaveBeenCalledWith([{ questionKey: "self_intro", start: 0, len: 8 }]);
		expect(handlers.log.indexOf("setQuoteLicense")).toBeLessThan(handlers.log.indexOf("sendToWall"));
		expect(await screen.findByText("这句话已放进金句墙。")).toBeInTheDocument();
		expect(screen.getByRole("link", { name: "去金句墙看看 →" })).toHaveAttribute("href", "/flashback/voices");
	});

	it("「寄出到相册」：不发授权，照常寄出，完成页不提金句墙", async () => {
		const handlers = makeHandlers([]);
		renderStep(handlers, {}, null, { answers: QUOTE_ANSWERS });
		fireEvent.click(albumOnly());

		await waitFor(() => expect(handlers.onSendToWall).toHaveBeenCalled());
		expect(handlers.onSetQuoteLicense).not.toHaveBeenCalled();
		expect(await screen.findByRole("heading", { name: "已经寄出了" })).toBeInTheDocument();
		expect(screen.queryByText("这句话已放进金句墙。")).not.toBeInTheDocument();
	});

	it("换一句：预览换成下一句，授权带的是当前这句", async () => {
		const handlers = makeHandlers([]);
		renderStep(handlers, {}, null, { answers: QUOTE_ANSWERS });
		fireEvent.click(screen.getByRole("button", { name: /换一句/ }));

		expect(screen.getByText("「想亲眼看看代码是不是魔法。」")).toBeInTheDocument();
		fireEvent.click(withQuote());
		await waitFor(() =>
			expect(handlers.onSetQuoteLicense).toHaveBeenCalledWith([{ questionKey: "self_intro", start: 8, len: 13 }]),
		);
	});

	it("检查页把推荐句雾住：预览顺延到下一句；全部雾住 → 只剩单个寄出按钮", () => {
		renderStep(makeHandlers([]), {}, null, { answers: QUOTE_ANSWERS });

		fireEvent.click(screen.getByRole("button", { name: "我是一个文科生。" }));
		expect(screen.getByText("「想亲眼看看代码是不是魔法。」")).toBeInTheDocument();

		fireEvent.click(screen.getByRole("button", { name: "想亲眼看看代码是不是魔法。" }));
		expect(screen.queryByRole("button", { name: "寄出到相册" })).not.toBeInTheDocument();
		expect(screen.getByRole("button", { name: /^确认寄出/ })).toBeInTheDocument();
	});

	it("授权失败：寄出暂停（不调 sendToWall），重试仍带着这句", async () => {
		const handlers = makeHandlers([], { setQuoteLicenseOk: false });
		renderStep(handlers, {}, null, { answers: QUOTE_ANSWERS });
		fireEvent.click(withQuote());

		const retry = await screen.findByRole("button", { name: /再试一次/ });
		expect(handlers.onSendToWall).not.toHaveBeenCalled();
		fireEvent.click(retry);
		await waitFor(() => expect(handlers.onSetQuoteLicense).toHaveBeenCalledTimes(2));
		expect(handlers.onSetQuoteLicense).toHaveBeenLastCalledWith([{ questionKey: "self_intro", start: 0, len: 8 }]);
	});

	it("已开授权档（非 off）：不再询问，只有单个寄出按钮，也不改授权", async () => {
		const handlers = makeHandlers([]);
		renderStep(handlers, {}, null, { answers: QUOTE_ANSWERS, quoteLevel: "credited" });

		expect(screen.queryByRole("button", { name: "寄出到相册" })).not.toBeInTheDocument();
		fireEvent.click(screen.getByRole("button", { name: /^确认寄出/ }));
		await waitFor(() => expect(handlers.onSendToWall).toHaveBeenCalled());
		expect(handlers.onSetQuoteLicense).not.toHaveBeenCalled();
	});
});
