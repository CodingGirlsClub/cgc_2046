import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, screen, waitFor } from "@testing-library/react";
import { render } from "@/test-utils";
import LearningTab, {
	ParticipationsTabs,
	learningSessionPrompt,
} from "@/components/learning/learning-tab";
import {
	COURSE_LEARNING_DETAIL,
	type CourseLearningDetail,
	type MyLearningRun,
} from "@/lib/graphql/participations";

const { useQuery } = vi.hoisted(() => ({ useQuery: vi.fn() }));
vi.mock("@apollo/client/react", () => ({ useQuery }));

const RUN_DONE: MyLearningRun = {
	runId: "run-done",
	enrollmentId: "enr-1",
	targetTitle: "Python 入门",
	status: "running",
	doneIssues: 2,
	totalIssues: 2,
	currentIssueId: null,
	currentIssueTitle: null,
	currentIssueKey: null,
	courseId: "course-1",
};

const RUN_PARTIAL: MyLearningRun = {
	runId: "run-partial",
	enrollmentId: "enr-2",
	targetTitle: "Python 入门",
	status: "waiting",
	doneIssues: 1,
	totalIssues: 3,
	currentIssueId: "py-02",
	currentIssueTitle: "变量与数据",
	currentIssueKey: "PYTH-02",
	courseId: "course-1",
};

const RUN_TODO: MyLearningRun = {
	runId: "run-todo",
	enrollmentId: "enr-3",
	targetTitle: "写作课",
	status: "running",
	doneIssues: 0,
	totalIssues: 4,
	currentIssueId: "wr-01",
	currentIssueTitle: "第一个句子",
	currentIssueKey: "WR-01",
	courseId: "course-2",
};

const DETAIL: CourseLearningDetail = {
	courseId: "course-1",
	title: "Python 入门",
	slug: "python-intro",
	goals: ["能写程序"],
	progress: {
		doneIssues: 1,
		totalIssues: 2,
		currentIssueId: "py-02",
		currentIssueTitle: "变量与数据",
		currentIssueKey: "PYTH-02",
	},
	issues: [
		{
			key: "PYTH-01",
			id: "py-01",
			title: "第一个程序",
			kind: "handwork",
			status: "done",
			story: {
				asA: "学员",
				given: [],
				goal: "写问候程序",
				materials: [{ title: "Python 教程", ref: "https://ex.io" }],
				checklist: [
					{ id: "c1", text: "程序能运行", done: true, evidence: "跑通了", recordedAt: null },
					{ id: "c2", text: "能讲懂代码", done: true, evidence: "讲过了", recordedAt: null },
				],
			},
		},
		{
			key: "PYTH-02",
			id: "py-02",
			title: "变量与数据",
			kind: "thoughtwork",
			status: "todo",
			story: {
				asA: "学员",
				given: ["py-01"],
				goal: "理解变量绑定",
				materials: [],
				checklist: [{ id: "c1", text: "能解释绑定", done: false, evidence: null, recordedAt: null }],
			},
		},
	],
};

beforeEach(() => {
	vi.clearAllMocks();
});

afterEach(cleanup);

describe("LearningTab 三态行渲染(plan U8 场景 1)", () => {
	it("状态图标 + issue key + 标题 + kind 标签 + n/m 计数", () => {
		render(<LearningTab runs={[RUN_DONE, RUN_PARTIAL, RUN_TODO]} />);

		// 按课程分组:course-1 两行 + course-2 一行
		expect(screen.getAllByTestId("learning-group")).toHaveLength(2);

		// 三态图标:done / in_progress / todo
		expect(screen.getAllByTestId("issue-status-done")).toHaveLength(1);
		expect(screen.getAllByTestId("issue-status-in_progress")).toHaveLength(1);
		expect(screen.getAllByTestId("issue-status-todo")).toHaveLength(1);

		// issue key + 标题 + n/m(kind 标签在抽屉 issue 行——run 投影无 kind)
		expect(screen.getByText("PYTH-02")).toBeInTheDocument();
		expect(screen.getByText("变量与数据")).toBeInTheDocument();
		expect(screen.getByText("WR-01")).toBeInTheDocument();
		expect(screen.getByText("第一个句子")).toBeInTheDocument();
		expect(
			screen.getByText((_, el) => el?.textContent === "学习进度：1/3 节"),
		).toBeInTheDocument();
		expect(
			screen.getByText((_, el) => el?.textContent === "学习进度：2/2 节"),
		).toBeInTheDocument();
	});

	it("无在学课程空态(边界)", () => {
		render(<LearningTab runs={[]} />);
		expect(screen.getByTestId("learning-empty")).toBeInTheDocument();
	});
});

describe("抽屉开合与字段(plan U8 场景 2)", () => {
	it("点击行 → 抽屉开 → issue 展开 story/checklist/evidence → Esc 关", async () => {
		useQuery.mockReturnValue({ data: { courseLearningDetail: DETAIL }, loading: false, error: undefined });

		render(<LearningTab runs={[RUN_PARTIAL]} />);

		fireEvent.click(screen.getByTestId("learning-run-row"));

		const drawer = await screen.findByTestId("issue-drawer");
		expect(drawer).toBeInTheDocument();

		// 抽屉头部进度
		expect(screen.getByText(/1\/2 节已完成/)).toBeInTheDocument();

		// 展开 issue 1:story 全文 + checklist 逐条 evidence + 材料列表
		fireEvent.click(screen.getByTestId("drawer-issue-py-01"));
		expect(screen.getByTestId("drawer-story-py-01")).toBeInTheDocument();
		expect(screen.getByText(/写问候程序/)).toBeInTheDocument();
		expect(screen.getByText(/Python 教程/)).toBeInTheDocument();

		// 抽屉 issue 行:kind 标签(R11 行规范)
		expect(screen.getByTestId("issue-kind-handwork")).toBeInTheDocument();
		expect(screen.getByTestId("issue-kind-thoughtwork")).toBeInTheDocument();

		const doneItem = screen.getByTestId("checklist-py-01-c1");
		expect(doneItem.getAttribute("data-done")).toBe("true");
		expect(screen.getByText(/证据：跑通了/)).toBeInTheDocument();

		// 展开 issue 2:未完成条目 done=false、无证据行
		fireEvent.click(screen.getByTestId("drawer-issue-py-02"));
		const openItem = screen.getByTestId("checklist-py-02-c1");
		expect(openItem.getAttribute("data-done")).toBe("false");
		expect(screen.queryByText(/证据：/)).not.toBeInTheDocument();

		// Esc 关闭
		fireEvent.keyDown(window, { key: "Escape" });
		await waitFor(() => expect(screen.queryByTestId("issue-drawer")).not.toBeInTheDocument());
	});

	it("CTA 复制学习指令(Rsk3 降级路径)", async () => {
		useQuery.mockReturnValue({ data: { courseLearningDetail: DETAIL }, loading: false, error: undefined });
		const writeText = vi.fn().mockResolvedValue(undefined);
		Object.assign(navigator, { clipboard: { writeText } });

		render(<LearningTab runs={[RUN_PARTIAL]} />);
		fireEvent.click(screen.getByTestId("learning-run-row"));
		await screen.findByTestId("issue-drawer");

		fireEvent.click(screen.getByTestId("drawer-issue-py-02"));
		const cta = screen.getByTestId("cta-learn-py-02");
		expect(cta).toBeInTheDocument();
		fireEvent.click(cta);

		await waitFor(() => expect(writeText).toHaveBeenCalledOnce());
		const prompt = writeText.mock.calls[0][0] as string;
		expect(prompt).toContain("Python 入门");
		expect(prompt).toContain("PYTH-02");
		expect(prompt).toContain("变量与数据");
	});

	it("指令文本构造:课程/issue/八步循环引导", () => {
		const issue = DETAIL.issues[1];
		const text = learningSessionPrompt(DETAIL, issue);
		expect(text).toContain("《Python 入门》");
		expect(text).toContain("PYTH-02「变量与数据」");
		expect(text).toContain("理解变量绑定");
		expect(text).toContain("八步循环");
	});
});

describe("tab 切换(plan U8 场景 3:URL 制,导航态)", () => {
	it("学习默认 aria-current;报名/赞助各指 ?tab=", () => {
		render(<ParticipationsTabs tab="learning" />);
		expect(screen.getByTestId("tab-learning").getAttribute("aria-current")).toBe("page");
		expect(screen.getByTestId("tab-enrollments").getAttribute("aria-current")).toBeNull();
		expect(screen.getByTestId("tab-enrollments").getAttribute("href")).toBe(
			"/participations?tab=enrollments",
		);
		expect(screen.getByTestId("tab-sponsorships").getAttribute("href")).toBe(
			"/participations?tab=sponsorships",
		);
	});
});

describe("抽屉加载态与错误态", () => {
	it("detail 查询 null(无权限/无课程)→ 抽屉空标题不炸", async () => {
		useQuery.mockReturnValue({ data: { courseLearningDetail: null }, loading: false, error: undefined });
		render(<LearningTab runs={[RUN_PARTIAL]} />);
		fireEvent.click(screen.getByTestId("learning-run-row"));
		expect(await screen.findByTestId("issue-drawer")).toBeInTheDocument();
		expect(screen.queryByTestId("drawer-issues")).not.toBeInTheDocument();
	});
});
