import { afterEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, screen } from "@testing-library/react";
import { render } from "@/test-utils";
import LearningMate from "./learning-mate";

// 抽屉只负责入口/开合，不重复测对话面板本身：把子组件换成可观察的 stub
vi.mock("./host-chat-panel", () => ({
	default: ({ onClose, pinned, onTogglePin }: { onClose?: () => void; pinned?: boolean; onTogglePin?: () => void }) => (
		<div data-testid="mate-content" data-pinned={pinned === true}>
			<button type="button" onClick={onClose}>
				stub-close
			</button>
			<button type="button" onClick={onTogglePin}>
				stub-pin
			</button>
		</div>
	),
}));

afterEach(() => {
	cleanup();
	document.body.style.overflow = "";
	document.body.classList.remove("learning-mate-docked");
	window.localStorage.clear();
});

const props = { courseId: "course", userId: "user", locale: "zh-CN", workspaceId: "ws", courseVersion: 1, unitId: null };

describe("学习搭子抽屉（课程页默认收起）", () => {
	it("默认只显示「问学习搭子」入口，不挂载对话面板、不锁滚动", () => {
		render(<LearningMate {...props} />);

		expect(screen.getByRole("button", { name: "问学习搭子" })).toBeInTheDocument();
		expect(screen.queryByTestId("mate-content")).toBeNull();
		expect(screen.queryByRole("dialog")).toBeNull();
		expect(document.body.style.overflow).toBe("");
	});

	it("点入口打开抽屉：挂载对话面板、锁滚动；Esc 收起", () => {
		render(<LearningMate {...props} />);

		fireEvent.click(screen.getByRole("button", { name: "问学习搭子" }));
		expect(screen.getByRole("dialog", { name: "学习搭子" })).toBeInTheDocument();
		expect(screen.getByTestId("mate-content")).toBeInTheDocument();
		expect(document.body.style.overflow).toBe("hidden");

		fireEvent.keyDown(document, { key: "Escape" });
		expect(screen.queryByRole("dialog")).toBeNull();
		expect(document.body.style.overflow).toBe("");
	});

	it("收起后面板保持挂载：重开不重建连接（隐藏而不是卸载）", () => {
		render(<LearningMate {...props} />);
		fireEvent.click(screen.getByRole("button", { name: "问学习搭子" }));
		const content = screen.getByTestId("mate-content");
		fireEvent.click(screen.getByRole("button", { name: "stub-close" }));
		expect(screen.queryByRole("dialog")).toBeNull();
		expect(screen.getByTestId("mate-content")).toBe(content); // 还是同一个节点，没有被卸载/重建
		fireEvent.click(screen.getByRole("button", { name: "问学习搭子" }));
		expect(screen.getByTestId("mate-content")).toBe(content);
	});

	it("固定到右侧：body 让出右栏、不锁滚动、无遮罩；偏好按课程记进 localStorage", () => {
		render(<LearningMate {...props} />);
		fireEvent.click(screen.getByRole("button", { name: "问学习搭子" }));
		expect(document.body.style.overflow).toBe("hidden"); // 覆盖式才锁滚动

		fireEvent.click(screen.getByRole("button", { name: "stub-pin" }));
		expect(document.body.classList.contains("learning-mate-docked")).toBe(true);
		expect(document.body.style.overflow).toBe(""); // 固定成右栏后页面要能滚动
		expect(document.querySelector(".learning-mate__backdrop")).toBeNull();
		expect(screen.getByTestId("mate-content")).toHaveAttribute("data-pinned", "true");
		expect(window.localStorage.getItem("cgc-learning-mate-pinned:course")).toBe("1");

		// 收起时撤销让位；重新打开恢复固定（同一会话内）
		fireEvent.click(screen.getByRole("button", { name: "stub-close" }));
		expect(document.body.classList.contains("learning-mate-docked")).toBe(false);
		fireEvent.click(screen.getByRole("button", { name: "问学习搭子" }));
		expect(document.body.classList.contains("learning-mate-docked")).toBe(true);

		// 取消固定：回到覆盖式抽屉，重新锁滚动
		fireEvent.click(screen.getByRole("button", { name: "stub-pin" }));
		expect(document.body.classList.contains("learning-mate-docked")).toBe(false);
		expect(document.body.style.overflow).toBe("hidden");
		expect(window.localStorage.getItem("cgc-learning-mate-pinned:course")).toBe("0");
	});

	it("重新进入课程页：打开后按课程恢复固定偏好", () => {
		window.localStorage.setItem("cgc-learning-mate-pinned:course", "1");
		render(<LearningMate {...props} />);
		fireEvent.click(screen.getByRole("button", { name: "问学习搭子" }));
		expect(screen.getByTestId("mate-content")).toHaveAttribute("data-pinned", "true");
		expect(document.body.classList.contains("learning-mate-docked")).toBe(true);
	});

	it("点遮罩或关闭按钮也能收起，收起后入口重新出现", () => {
		render(<LearningMate {...props} />);
		const open = () => fireEvent.click(screen.getByRole("button", { name: "问学习搭子" }));

		open();
		fireEvent.click(document.querySelector(".learning-mate__backdrop")!);
		expect(screen.queryByRole("dialog")).toBeNull();
		expect(screen.getByRole("button", { name: "问学习搭子" })).toBeInTheDocument();

		open();
		fireEvent.click(screen.getByRole("button", { name: "stub-close" }));
		expect(screen.queryByRole("dialog")).toBeNull();
	});
});
