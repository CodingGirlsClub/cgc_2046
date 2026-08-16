import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import StepHandoffCopy, { buildHandoffText } from "./step-handoff-copy";

const { copyText } = vi.hoisted(() => ({ copyText: vi.fn() }));

vi.mock("@/lib/clipboard", () => ({ copyText }));

const PROPS = {
	workspaceSlug: "cgc-academy",
	workspaceId: "ws_02",
	runId: "run_1",
	stepKey: "final_reflection",
};

beforeEach(() => {
	vi.clearAllMocks();
	copyText.mockResolvedValue(true);
});

afterEach(cleanup);

describe("buildHandoffText（plan 020 U2.2 交接文本模板）", () => {
	it("文本含 workspace slug(id) / run / step / save_step_output 工具提示", () => {
		const text = buildHandoffText(PROPS);
		expect(text).toBe("workspace: cgc-academy(ws_02) / run: run_1 / step: final_reflection / 工具提示：用 save_step_output 写回该 step");
	});
});

describe("StepHandoffCopy", () => {
	it("点击复制：copyText 收到完整交接文本；成功显示「已复制」", async () => {
		render(<StepHandoffCopy {...PROPS} />);

		const button = screen.getByRole("button", { name: "复制交接文本" });
		fireEvent.click(button);

		expect(copyText).toHaveBeenCalledWith(
			"workspace: cgc-academy(ws_02) / run: run_1 / step: final_reflection / 工具提示：用 save_step_output 写回该 step",
		);
		expect(await screen.findByText("已复制")).toBeInTheDocument();
	});

	it("复制失败：显示「复制失败」", async () => {
		copyText.mockResolvedValue(false);
		render(<StepHandoffCopy {...PROPS} />);

		fireEvent.click(screen.getByRole("button", { name: "复制交接文本" }));
		expect(await screen.findByText("复制失败")).toBeInTheDocument();
	});
});
