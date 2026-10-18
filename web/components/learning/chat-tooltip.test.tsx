import { afterEach, describe, expect, it } from "vitest";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import TooltipButton from "./chat-tooltip";

afterEach(cleanup);

describe("TooltipButton", () => {
	it("悬停或聚焦时显示 Tooltip，移出或失焦后消失", () => {
		render(
			<TooltipButton label="新开对话">
				<span>+</span>
			</TooltipButton>,
		);
		const button = screen.getByRole("button", { name: "新开对话" });
		expect(screen.queryByRole("tooltip")).toBeNull();

		fireEvent.mouseEnter(button);
		expect(screen.getByRole("tooltip")).toHaveTextContent("新开对话");
		fireEvent.mouseLeave(button);
		expect(screen.queryByRole("tooltip")).toBeNull();

		fireEvent.focus(button);
		expect(screen.getByRole("tooltip")).toHaveTextContent("新开对话");
		expect(button).toHaveAttribute("aria-describedby", screen.getByRole("tooltip").id);
		fireEvent.blur(button);
		expect(screen.queryByRole("tooltip")).toBeNull();
	});

	it("点击等原有事件仍会透传", () => {
		let clicked = 0;
		render(
			<TooltipButton label="关闭" onClick={() => (clicked += 1)}>
				×
			</TooltipButton>,
		);
		fireEvent.click(screen.getByRole("button", { name: "关闭" }));
		expect(clicked).toBe(1);
	});
});
