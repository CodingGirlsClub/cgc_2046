import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { cleanup, fireEvent, screen, within } from "@testing-library/react";
import { render } from "@/test-utils";
import CourseContentViewer from "./course-content-viewer";
import { COURSE_CONTENT } from "@/lib/graphql/course-content";
import { COURSE_LEARNING_DETAIL } from "@/lib/graphql/participations";

/**
 * 课程阅读组件默认渲染：总览与单元两种状态的 markup 由快照钉住。
 *
 * 教研预览页与草稿面板同样按默认 prop 使用本组件，快照保证它们的布局与改动前一致
 * （几何另由 ego-browser 在教研预览页实测）。
 */

const { useQuery } = vi.hoisted(() => ({ useQuery: vi.fn() }));
vi.mock("@apollo/client/react", () => ({ useQuery }));

const CONTENT = {
	chapters: [{ id: "ch1", title: "第一章" }],
	issues: [
		{
			id: "issue-a",
			kind: "handwork",
			title: "单元 A",
			chapter_id: "ch1",
			story: { goal: "写出第一个程序", materials: [{ kind: "text", body: "阅读材料" }] },
			objectives: [{ id: "obj-a", title: "能运行程序", assessment: "提交运行截图" }],
		},
		{
			id: "issue-b",
			kind: "thoughtwork",
			title: "单元 B",
			chapter_id: "ch1",
			story: { goal: "讲清楚变量" },
			objectives: [{ id: "obj-b", title: "能讲懂变量" }],
		},
	],
};

beforeEach(() => {
	useQuery.mockImplementation((query) => {
		if (query === COURSE_CONTENT) {
			return {
				loading: false,
				error: undefined,
				data: {
					courseContent: {
						courseId: "course-1",
						title: "Python 入门",
						description: null,
						revisionNumber: 3,
						publishedAt: null,
						content: JSON.stringify(CONTENT),
					},
				},
			};
		}
		if (query === COURSE_LEARNING_DETAIL) {
			return {
				loading: false,
				error: undefined,
				data: { courseLearningDetail: { objectives: [{ id: "obj-a", mastery: "developing" }] } },
			};
		}
		throw new Error("unexpected query");
	});
});

afterEach(() => {
	cleanup();
	vi.clearAllMocks();
});

it("默认 prop（教研预览页、草稿面板的用法）：总览与单元两种状态的 markup 与改动前一致", () => {
	const { container } = render(<CourseContentViewer courseId="course-1" />);
	expect(container.innerHTML).toMatchSnapshot("overview");

	fireEvent.click(screen.getByRole("button", { name: /单元 A/ }));
	expect(container.innerHTML).toMatchSnapshot("unit");
});

it("单元页的「课程目录」打开大纲浮层，点选单元后收起", () => {
	render(<CourseContentViewer courseId="course-1" />);
	expect(screen.getByRole("complementary", { name: "学习进度" })).toBeInTheDocument();

	fireEvent.click(screen.getByRole("button", { name: /单元 A/ }));
	fireEvent.click(screen.getByRole("button", { name: "‹ 课程目录" }));
	const overlay = screen.getByRole("dialog", { name: "课程目录" });
	fireEvent.click(within(overlay).getByRole("link", { name: "单元 B" }));
	expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
	expect(screen.getByRole("heading", { name: "单元 B" })).toBeInTheDocument();
});

