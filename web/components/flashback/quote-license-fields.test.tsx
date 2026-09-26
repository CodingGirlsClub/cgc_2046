import { describe, it, expect, vi, afterEach } from "vitest";
import { cleanup, fireEvent, screen } from "@testing-library/react";
import { render } from "@/test-utils";
import QuoteLicenseFields from "./quote-license-fields";

/**
 * 金句授权「档位 + 圈选」共用字段组（PR #960 评审 4b）：首程（write）与
 * 长廊授权面板（quote-license-panel）的规则只写一处——
 * - 三档 radio（off/anonymous/credited），当前档回显；
 * - off 不渲染圈选器；候选句 aria-pressed 回显选中；
 * - 圈选 toggle 上抛区间三件套（questionKey/start/len）；
 * - 候选为空给 quoteNoCandidate 提示。
 */

const candidates = [
	{ questionKey: "self_intro", start: 0, len: 10, sentence: "一个刚毕业的文科生。" },
	{ questionKey: "today.now", start: 0, len: 5, sentence: "在做前端。" },
];

afterEach(cleanup);

describe("QuoteLicenseFields（共用档位 + 圈选）", () => {
	it("off 不渲染圈选器；切档上抛档位", () => {
		const onLevelChange = vi.fn();
		render(
			<QuoteLicenseFields level="off" onLevelChange={onLevelChange} candidates={candidates} picks={[]} onTogglePick={() => {}} />,
		);
		expect(screen.queryByRole("list")).not.toBeInTheDocument();
		fireEvent.click(screen.getByRole("radio", { name: /实名支持/ }));
		expect(onLevelChange).toHaveBeenCalledWith("credited");
	});

	it("圈选只上抛区间三件套；选中态回显；空候选给提示", () => {
		const onTogglePick = vi.fn();
		render(
			<QuoteLicenseFields level="anonymous" onLevelChange={() => {}} candidates={candidates} picks={[]} onTogglePick={onTogglePick} />,
		);
		fireEvent.click(screen.getByRole("button", { name: "一个刚毕业的文科生。" }));
		expect(onTogglePick).toHaveBeenCalledWith({ questionKey: "self_intro", start: 0, len: 10 });

		cleanup();
		const rerender = render(
			<QuoteLicenseFields
				level="anonymous"
				onLevelChange={() => {}}
				candidates={candidates}
				picks={[{ questionKey: "today.now", start: 0, len: 5 }]}
				onTogglePick={() => {}}
			/>,
		);
		expect(screen.getByRole("button", { name: "在做前端。" })).toHaveAttribute("aria-pressed", "true");

		rerender.rerender(
			<QuoteLicenseFields level="credited" onLevelChange={() => {}} candidates={[]} picks={[]} onTogglePick={() => {}} />,
		);
		expect(screen.getByText(/当年的句子里都带着雾面/)).toBeInTheDocument();
	});
});
