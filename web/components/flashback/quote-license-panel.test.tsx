import { describe, it, expect, vi, afterEach } from "vitest";
import { TypedDocumentNode } from "@apollo/client";
import { cleanup, fireEvent, screen, waitFor } from "@testing-library/react";
import { render } from "@/test-utils";
import QuoteLicensePanel from "./quote-license-panel";
import { FLASHBACK_SET_QUOTE_LICENSE, type FlashbackCapsuleMe } from "@/lib/graphql/flashback";

/**
 * 金句授权面板（M1/U9 回访端）钉住的契约：
 * - 档位三选一，当前档回显；圈选只从非雾面句取（R14 同源规则——雾住的句子不可选）；
 * - 保存时档位与圈选区间一起发（只发档位在 #941 前的覆盖语义下会清空区间）；
 * - 关档（off）不清圈选：区间原样随发，用户的挑句劳动保留；[] 才是显式清空；
 * - 面板不编辑实名补充（creditedNote 不随发，#941 后省略 = 保留）；
 * - 双入口：持链接带 token，登录态省略 token 走会话；成功后通知父级 reload。
 */

vi.mock("@/lib/auth-provider", () => ({ useAuthed: () => ({ authed: true, confirmed: true }) }));

const mutations = new Map<unknown, ReturnType<typeof vi.fn>>();
vi.mock("@apollo/client/react", async (importOriginal) => {
	const actual = await importOriginal<typeof import("@apollo/client/react")>();
	return {
		...actual,
		useMutation: (doc: TypedDocumentNode<Record<string, unknown>, Record<string, unknown>>) => {
			let impl = mutations.get(doc);
			if (!impl) {
				impl = vi.fn(() => Promise.resolve({ data: { flashbackSetQuoteLicense: {} } }));
				mutations.set(doc, impl);
			}
			return [impl, { loading: false }];
		},
	};
});

const me = (over: Partial<FlashbackCapsuleMe> = {}): FlashbackCapsuleMe => ({
	id: "p1",
	fullName: "储一苇",
	participation: "attended",
	quoteLevel: "off",
	quote: null,
	quoteSpans: null,
	quoteStats: null,
	answers: [
		{
			id: "a1",
			questionKey: "self_intro",
			rawText: "一个刚毕业的文科生。这段不想给人看。",
			fogSpans: [{ start: 10, len: 8, reason: "privacy" }],
			text: "一个刚毕业的文科生。▓▓▓▓",
		},
	],
	today: { nowStatus: "在做前端。", fogSpans: null },
	...over,
});

afterEach(() => {
	cleanup();
	mutations.clear();
});

describe("金句授权面板", () => {
	it("回显当前档位，雾住的句子不进候选", () => {
		render(<QuoteLicensePanel me={me({ quoteSpans: [{ questionKey: "today.now", start: 0, len: 5 }] })} token={null} />);
		expect(screen.getByRole("radio", { name: "关闭（默认）" })).toBeChecked();
		fireEvent.click(screen.getByRole("radio", { name: /匿名金句/ }));
		expect(screen.getByRole("button", { name: "在做前端。" })).toHaveAttribute("aria-pressed", "true");
		expect(screen.getByRole("button", { name: "一个刚毕业的文科生。" })).toHaveAttribute("aria-pressed", "false");
		expect(screen.queryByRole("button", { name: /这段不想给人看/ })).not.toBeInTheDocument();
	});

	it("换档保存：档位与圈选一起发，creditedNote 不随发", async () => {
		const onChanged = vi.fn();
		render(<QuoteLicensePanel me={me({ quoteLevel: "off", quoteSpans: [{ questionKey: "today.now", start: 0, len: 5 }] })} token="tok" onChanged={onChanged} />);
		fireEvent.click(screen.getByRole("radio", { name: /实名支持/ }));
		fireEvent.click(screen.getByRole("button", { name: "保存授权" }));
		await waitFor(() => expect(mutations.get(FLASHBACK_SET_QUOTE_LICENSE)).toHaveBeenCalled());
		const vars = mutations.get(FLASHBACK_SET_QUOTE_LICENSE)!.mock.calls[0][0].variables;
		expect(vars).toEqual({
			token: "tok",
			level: "credited",
			chosenQuoteSpans: [{ questionKey: "today.now", start: 0, len: 5 }],
		});
		expect(onChanged).toHaveBeenCalled();
	});

	it("关档不清圈选：off 也带上已选区间", async () => {
		render(<QuoteLicensePanel me={me({ quoteLevel: "anonymous", quoteSpans: [{ questionKey: "today.now", start: 0, len: 5 }] })} token={null} />);
		fireEvent.click(screen.getByRole("radio", { name: "关闭（默认）" }));
		fireEvent.click(screen.getByRole("button", { name: "保存授权" }));
		await waitFor(() => expect(mutations.get(FLASHBACK_SET_QUOTE_LICENSE)).toHaveBeenCalled());
		const vars = mutations.get(FLASHBACK_SET_QUOTE_LICENSE)!.mock.calls[0][0].variables;
		expect(vars.level).toBe("off");
		expect(vars.chosenQuoteSpans).toEqual([{ questionKey: "today.now", start: 0, len: 5 }]);
		expect(vars.token).toBeUndefined();
	});

	it("新增圈选只发区间三件套（不含渲染用 sentence 字段）", async () => {
		render(<QuoteLicensePanel me={me({ quoteLevel: "anonymous", quoteSpans: [{ questionKey: "today.now", start: 0, len: 5, __typename: "FlashbackQuoteSpan" } as never] })} token={null} />);
		fireEvent.click(screen.getByRole("button", { name: "一个刚毕业的文科生。" }));
		fireEvent.click(screen.getByRole("button", { name: "保存授权" }));
		await waitFor(() => expect(mutations.get(FLASHBACK_SET_QUOTE_LICENSE)).toHaveBeenCalled());
		expect(mutations.get(FLASHBACK_SET_QUOTE_LICENSE)!.mock.calls[0][0].variables.chosenQuoteSpans).toEqual([
			{ questionKey: "today.now", start: 0, len: 5 },
			{ questionKey: "self_intro", start: 0, len: 10 },
		]);
	});

	it("取消圈选后保存：[] 显式清空", async () => {
		render(<QuoteLicensePanel me={me({ quoteLevel: "anonymous", quoteSpans: [{ questionKey: "today.now", start: 0, len: 5 }] })} token={null} />);
		fireEvent.click(screen.getByRole("button", { name: "在做前端。" }));
		fireEvent.click(screen.getByRole("button", { name: "保存授权" }));
		await waitFor(() => expect(mutations.get(FLASHBACK_SET_QUOTE_LICENSE)).toHaveBeenCalled());
		expect(mutations.get(FLASHBACK_SET_QUOTE_LICENSE)!.mock.calls[0][0].variables.chosenQuoteSpans).toEqual([]);
	});
});
