import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, screen } from "@testing-library/react";
import { render } from "@/test-utils";
import LearningMate from "./learning-mate";

// 抽屉只负责入口/开合，不重复测对话面板本身：把子组件换成可观察的 stub
vi.mock("./host-chat-panel", () => ({
	default: ({ onClose, pinned, onTogglePin }: { onClose?: () => void; pinned?: boolean; onTogglePin?: () => void }) => (
		<div data-testid="mate-content" data-pinned={pinned === true} data-can-pin={onTogglePin ? "true" : "false"}>
			<button type="button" onClick={onClose}>
				stub-close
			</button>
			<button type="button" onClick={onTogglePin}>
				stub-pin
			</button>
		</div>
	),
}));

/** 与组件里 PIN_QUERY 对齐：默认宽屏，可切窄屏 */
function mockWide(matches: boolean) {
	vi.stubGlobal("matchMedia", (query: string) => ({
		matches,
		media: query,
		onchange: null,
		addEventListener: vi.fn(),
		removeEventListener: vi.fn(),
		addListener: vi.fn(),
		removeListener: vi.fn(),
		dispatchEvent: vi.fn(),
	}));
}

beforeEach(() => mockWide(true));

afterEach(() => {
	cleanup();
	document.body.style.overflow = "";
	document.body.classList.remove("learning-mate-docked");
	window.localStorage.clear();
	vi.unstubAllGlobals();
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

	it("打开覆盖式抽屉时焦点移入面板，Tab 在面板内循环", () => {
		render(<LearningMate {...props} />);
		fireEvent.click(screen.getByRole("button", { name: "问学习搭子" }));

		const dialog = screen.getByRole("dialog", { name: "学习搭子" });
		expect(dialog).toHaveFocus(); // 不是留在被遮住的课程页

		const first = screen.getByRole("button", { name: "stub-close" });
		const last = screen.getByRole("button", { name: "stub-pin" });
		last.focus();
		fireEvent.keyDown(document, { key: "Tab" });
		expect(first).toHaveFocus();

		first.focus();
		fireEvent.keyDown(document, { key: "Tab", shiftKey: true });
		expect(last).toHaveFocus();
	});

	it("焦点被 disabled 按钮丢到 body 后，Tab/Shift+Tab 仍被拉回面板", () => {
		render(<LearningMate {...props} />);
		fireEvent.click(screen.getByRole("button", { name: "问学习搭子" }));
		(document.activeElement as HTMLElement | null)?.blur();
		expect(document.activeElement).toBe(document.body);

		fireEvent.keyDown(document, { key: "Tab" });
		expect(screen.getByRole("button", { name: "stub-close" })).toHaveFocus();

		(document.activeElement as HTMLElement | null)?.blur();
		fireEvent.keyDown(document, { key: "Tab", shiftKey: true });
		expect(screen.getByRole("button", { name: "stub-pin" })).toHaveFocus();
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

	it("固定到右侧：body 让出右栏、不锁滚动、无遮罩；收起后恢复", () => {
		const onDockChange = vi.fn();
		render(<LearningMate {...props} onDockChange={onDockChange} />);
		fireEvent.click(screen.getByRole("button", { name: "问学习搭子" }));
		expect(document.body.style.overflow).toBe("hidden"); // 覆盖式才锁滚动

		fireEvent.click(screen.getByRole("button", { name: "stub-pin" }));
		expect(document.body.classList.contains("learning-mate-docked")).toBe(true);
		expect(document.querySelector(".learning-mate")).toHaveClass("learning-mate--pinned"); // 固定态靠这个类让全屏容器不接收点击
		expect(onDockChange).toHaveBeenLastCalledWith(true); // 页面据此把阅读区切紧凑布局
		expect(document.body.style.overflow).toBe(""); // 固定成右栏后页面要能滚动
		expect(document.querySelector(".learning-mate__backdrop")).toBeNull();
		expect(screen.getByTestId("mate-content")).toHaveAttribute("data-pinned", "true");

		// 收起时撤销让位；重新打开恢复固定（同一会话内）
		fireEvent.click(screen.getByRole("button", { name: "stub-close" }));
		expect(document.body.classList.contains("learning-mate-docked")).toBe(false);
		expect(onDockChange).toHaveBeenLastCalledWith(false);
		fireEvent.click(screen.getByRole("button", { name: "问学习搭子" }));
		expect(document.body.classList.contains("learning-mate-docked")).toBe(true);

		// 取消固定：回到覆盖式抽屉，重新锁滚动
		fireEvent.click(screen.getByRole("button", { name: "stub-pin" }));
		expect(document.body.classList.contains("learning-mate-docked")).toBe(false);
		expect(document.body.style.overflow).toBe("hidden");
	});

	it("窄屏不提供固定：点面板里的固定也不会进入固定态（避免全屏容器挡课程点击）", () => {
		mockWide(false);
		render(<LearningMate {...props} />);
		fireEvent.click(screen.getByRole("button", { name: "问学习搭子" }));
		fireEvent.click(screen.getByRole("button", { name: "stub-pin" }));

		expect(screen.getByTestId("mate-content")).toHaveAttribute("data-can-pin", "false"); // 窄屏不把固定能力传给面板
		expect(screen.getByTestId("mate-content")).toHaveAttribute("data-pinned", "false");
		expect(document.body.classList.contains("learning-mate-docked")).toBe(false);
		expect(document.body.style.overflow).toBe("hidden"); // 仍是覆盖式，正常锁滚动
	});

	it("固定只在本次打开有效：重新挂载（刷新页面）后回到未固定的覆盖式抽屉", () => {
		const first = render(<LearningMate {...props} />);
		fireEvent.click(screen.getByRole("button", { name: "问学习搭子" }));
		fireEvent.click(screen.getByRole("button", { name: "stub-pin" }));
		expect(document.body.classList.contains("learning-mate-docked")).toBe(true);
		expect(document.querySelector(".learning-mate")).toHaveClass("learning-mate--pinned"); // 固定态靠这个类让全屏容器不接收点击
		first.unmount();

		render(<LearningMate {...props} />);
		fireEvent.click(screen.getByRole("button", { name: "问学习搭子" }));
		expect(screen.getByTestId("mate-content")).toHaveAttribute("data-pinned", "false");
		expect(document.body.classList.contains("learning-mate-docked")).toBe(false);
		expect(document.body.style.overflow).toBe("hidden"); // 回到覆盖式，重新锁滚动
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
