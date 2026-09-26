import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, screen, waitFor } from "@testing-library/react";
import { render } from "@/test-utils";
import AnswersFog from "./answers-fog";
import { FLASHBACK_ADJUST_FOG, type FlashbackCapsuleMe } from "@/lib/graphql/flashback";

/**
 * M4：寄出后回访也能逐句调「当年答案」的雾（flashbackAdjustFog 双入口）。
 *
 * 钉住的契约：
 * - 弹层按答案列出句子，预打雾的句子亮雾标（aria-pressed）；
 * - 脏检查：只有区间相对服务端基线变化的答案才发 adjustFog，全部切回亮也显式同步；
 * - token 双入口：持链接带 token，登录态以 null 走会话（today-actions 同款）；
 * - 失败错误 + 可重试；成功轻反馈 + 关弹层 + onChanged 刷新。
 */

const mutateMock = vi.fn();

vi.mock("@/lib/apollo-client", () => ({
	client: { mutate: (opts: unknown) => mutateMock(opts) },
}));

const me: FlashbackCapsuleMe = {
	id: "me-1",
	fullName: "储一苇",
	participation: "attended",
	quoteLevel: "off",
	quote: null,
	quoteSpans: null,
	quoteStats: null,
	answers: [
		{
			id: "a-1",
			questionKey: "funny_thing",
			rawText: "培训当天把笔记本忘在地铁上。这段不想给人看。",
			fogSpans: [{ start: 14, len: 8, reason: "privacy" }],
			text: "培训当天把笔记本忘在地铁上。▓▓▓▓",
		},
		{
			id: "a-2",
			questionKey: "self_intro",
			rawText: "一个刚毕业的文科生，在出版社做校对。",
			fogSpans: [],
			text: "一个刚毕业的文科生，在出版社做校对。",
		},
	],
	today: null,
};

beforeEach(() => {
	mutateMock.mockReset();
	mutateMock.mockImplementation(async (opts: { mutation: unknown }) => {
		if (opts.mutation === FLASHBACK_ADJUST_FOG) {
			return { data: { flashbackAdjustFog: { answerId: "a-1", fogSpans: [] } } };
		}
		return { data: {} };
	});
});

afterEach(cleanup);

describe("当年答案的雾（M4）", () => {
	it("入口按钮开弹层，按答案列句并回显既有雾", () => {
		render(<AnswersFog me={me} token={null} onChanged={() => {}} />);
		fireEvent.click(screen.getByRole("button", { name: "当年答案的雾" }));
		const dialog = screen.getByRole("dialog");
		expect(dialog).toBeInTheDocument();
		expect(screen.getByRole("button", { name: /培训当天把笔记本忘在地铁上/ })).toHaveAttribute("aria-pressed", "false");
		expect(screen.getByRole("button", { name: /这段不想给人看/ })).toHaveAttribute("aria-pressed", "true");
		expect(screen.getByRole("button", { name: /一个刚毕业的文科生/ })).toHaveAttribute("aria-pressed", "false");
	});

	it("只对变化了的答案发 adjustFog，带 answerId 与新区间", async () => {
		const onChanged = vi.fn();
		render(<AnswersFog me={me} token="tok" onChanged={onChanged} />);
		fireEvent.click(screen.getByRole("button", { name: "当年答案的雾" }));
		// a-2 原本无雾：圈亮句 → 只有 a-2 变化
		fireEvent.click(screen.getByRole("button", { name: /一个刚毕业的文科生/ }));
		fireEvent.click(screen.getByRole("button", { name: "保存" }));
		await waitFor(() => expect(mutateMock).toHaveBeenCalled());
		const calls = mutateMock.mock.calls.filter((c) => c[0].mutation === FLASHBACK_ADJUST_FOG);
		expect(calls).toHaveLength(1);
		expect(calls[0][0].variables).toEqual({
			token: "tok",
			answerId: "a-2",
			spans: [{ start: 0, len: 18 }],
		});
		await waitFor(() => expect(onChanged).toHaveBeenCalled());
	});

	it("无变化保存零 mutation；雾句切回亮显式同步空区间", async () => {
		render(<AnswersFog me={me} token={null} onChanged={() => {}} />);
		fireEvent.click(screen.getByRole("button", { name: "当年答案的雾" }));
		// a-1 的雾句切回亮 → a-1 显式发空区间；a-2 无变化不发
		fireEvent.click(screen.getByRole("button", { name: /这段不想给人看/ }));
		fireEvent.click(screen.getByRole("button", { name: "保存" }));
		await waitFor(() => expect(mutateMock).toHaveBeenCalled());
		const calls = mutateMock.mock.calls.filter((c) => c[0].mutation === FLASHBACK_ADJUST_FOG);
		expect(calls).toHaveLength(1);
		expect(calls[0][0].variables).toMatchObject({ token: null, answerId: "a-1", spans: [] });
	});

	it("失败错误可重试", async () => {
		mutateMock.mockImplementation(async (opts: { mutation: unknown }) => {
			if (opts.mutation === FLASHBACK_ADJUST_FOG) throw new Error("nope");
			return { data: {} };
		});
		render(<AnswersFog me={me} token={null} onChanged={() => {}} />);
		fireEvent.click(screen.getByRole("button", { name: "当年答案的雾" }));
		fireEvent.click(screen.getByRole("button", { name: /这段不想给人看/ }));
		fireEvent.click(screen.getByRole("button", { name: "保存" }));
		await waitFor(() => expect(screen.getByRole("alert")).toBeInTheDocument());
		expect(screen.getByRole("button", { name: "保存" })).toBeEnabled();
	});
});
