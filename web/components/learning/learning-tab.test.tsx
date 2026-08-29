import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, screen, waitFor } from "@testing-library/react";
import { render } from "@/test-utils";
import LearningTab, {
	ParticipationsTabs,
	learningSessionPrompt,
} from "@/components/learning/learning-tab";
import {
	type CourseLearningDetail,
	type MyLearningRun,
} from "@/lib/graphql/participations";

const { useQuery } = vi.hoisted(() => ({ useQuery: vi.fn() }));
vi.mock("@apollo/client/react", () => ({ useQuery }));

// S8（ADR-0011）：objective 口径 fixtures
const RUN_DONE: MyLearningRun = {
	runId: "run-done",
	enrollmentId: "enr-1",
	targetTitle: "Python 入门",
	status: "succeeded",
	staleRevision: false,
	progress: { masteredRequired: 2, totalRequired: 2, complete: true },
	nextAction: null,
	courseId: "course-1",
};

const RUN_PARTIAL: MyLearningRun = {
	runId: "run-partial",
	enrollmentId: "enr-2",
	targetTitle: "Python 入门",
	status: "running",
	staleRevision: false,
	progress: { masteredRequired: 1, totalRequired: 2, complete: false },
	nextAction: {
		kind: "developing",
		objectiveId: "obj-explain",
		reason: "继续攻克「能讲懂代码」——已有尝试但尚未达到掌握标准",
	},
	courseId: "course-1",
};

const RUN_STALE: MyLearningRun = {
	runId: "run-stale",
	enrollmentId: "enr-3",
	targetTitle: "写作课",
	status: "running",
	staleRevision: true,
	progress: { masteredRequired: 0, totalRequired: 4, complete: false },
	nextAction: {
		kind: "next_required",
		objectiveId: "wr-obj-1",
		reason: "下一个必修目标是「写第一个句子」，从这里开始",
	},
	courseId: "course-2",
};

const DETAIL: CourseLearningDetail = {
	courseId: "course-1",
	title: "Python 入门",
	slug: "python-intro",
	run: {
		id: "run-partial",
		status: "running",
		revisionId: "rev-1",
		revisionNumber: 1,
	},
	revisionNumber: 1,
	staleRevision: false,
	objectives: [
		{
			id: "obj-run",
			title: "能运行问候程序",
			required: true,
			issueId: "py-01",
			prereqIds: [],
			mastery: "mastered",
			everMastered: true,
			locked: false,
			missingPrereqIds: [],
			attemptCount: 2,
			lastAttemptAt: "2026-08-30T00:00:00Z",
		},
		{
			id: "obj-explain",
			title: "能讲懂代码",
			required: true,
			issueId: "py-01",
			prereqIds: ["obj-run"],
			mastery: "developing",
			everMastered: false,
			locked: false,
			missingPrereqIds: [],
			attemptCount: 1,
			lastAttemptAt: "2026-08-30T01:00:00Z",
		},
		{
			id: "obj-extra",
			title: "挑战：改写成函数",
			required: false,
			issueId: "py-02",
			prereqIds: ["obj-run"],
			mastery: "unassessed",
			everMastered: false,
			locked: false,
			missingPrereqIds: [],
			attemptCount: 0,
			lastAttemptAt: null,
		},
		{
			id: "obj-locked",
			title: "调试程序",
			required: true,
			issueId: "py-03",
			prereqIds: ["obj-run", "obj-explain"],
			mastery: "unassessed",
			everMastered: false,
			locked: true,
			missingPrereqIds: [
				{ id: "obj-explain", title: "能讲懂代码" },
			],
			attemptCount: 0,
			lastAttemptAt: null,
		},
	],
	nextAction: {
		kind: "developing",
		objectiveId: "obj-explain",
		reason: "继续攻克「能讲懂代码」——已有尝试但尚未达到掌握标准",
	},
	progress: { masteredRequired: 1, totalRequired: 3, complete: false },
};

beforeEach(() => {
	type UseQueryResult = {
		data: { courseLearningDetail: CourseLearningDetail | null } | undefined;
		loading: boolean;
		error: unknown;
	};
	vi.mocked(useQuery).mockReturnValue({
		data: { courseLearningDetail: DETAIL },
		loading: false,
		error: null,
	} as unknown as UseQueryResult);
});

afterEach(() => {
	cleanup();
	vi.clearAllMocks();
});

describe("LearningTab（S8 objective 口径）", () => {
	it("空列表渲染 empty 提示", () => {
		render(<LearningTab runs={[]} />);
		expect(screen.getByTestId("learning-empty")).toBeTruthy();
	});

	it("按课程分组渲染；行展示 next_action reason 与进度", () => {
		render(<LearningTab runs={[RUN_DONE, RUN_PARTIAL, RUN_STALE]} />);

		const groups = screen.getAllByTestId("learning-group");
		expect(groups.length).toBe(2);

		const rows = screen.getAllByTestId("learning-run-row");
		expect(rows.length).toBe(3);
		// next_action reason 呈现在行内
		expect(screen.getByText(/继续攻克「能讲懂代码」/)).toBeTruthy();
		// 完成行显示结业
		expect(screen.getByText(/已结业/)).toBeTruthy();
		// stale 徽章
		expect(screen.getByText(/有新版/)).toBeTruthy();
		// 进度文本
		expect(screen.getByText(/必修已掌握 1\/2/)).toBeTruthy();
	});

	it("抽屉渲染四态地图/锁定先修/选修 chip/尝试次数/next_action/CTA", async () => {
		render(<LearningTab runs={[RUN_PARTIAL]} />);
		fireEvent.click(screen.getAllByTestId("learning-run-row")[0]);

		await waitFor(() => {
			expect(screen.getByTestId("objective-drawer")).toBeTruthy();
		});

		// 四态图标
		expect(screen.getAllByTestId("mastery-mastered").length).toBeGreaterThan(0);
		expect(screen.getAllByTestId("mastery-developing").length).toBeGreaterThan(0);
		expect(screen.getAllByTestId("mastery-unassessed").length).toBeGreaterThan(0);
		// 选修 chip
		expect(screen.getByText(/选修/)).toBeTruthy();
		// 锁定 + 缺失先修标题
		const locked = screen.getByTestId("objective-locked-obj-locked");
		expect(locked.textContent).toContain("能讲懂代码");
		// 尝试次数
		expect(screen.getByText(/尝试 2 次/)).toBeTruthy();
		// next_action 当前任务卡
		expect(screen.getByTestId("drawer-next-action").textContent).toContain(
			"继续攻克",
		);
		// CTA（解锁 objective 有；锁定的没有）
		expect(screen.getByTestId("cta-learn-obj-explain")).toBeTruthy();
		expect(() => screen.getByTestId("cta-learn-obj-locked")).toThrow();
	});

	it("CTA 复制 objective 口径指令（含 objective_id 与 submit_learning_attempt）", async () => {
		const writeText = vi.fn().mockResolvedValue(undefined);
		Object.defineProperty(navigator, "clipboard", {
			value: { writeText },
			configurable: true,
		});

		render(<LearningTab runs={[RUN_PARTIAL]} />);
		fireEvent.click(screen.getAllByTestId("learning-run-row")[0]);

		await waitFor(() => {
			expect(screen.getByTestId("cta-learn-obj-explain")).toBeTruthy();
		});
		fireEvent.click(screen.getByTestId("cta-learn-obj-explain"));

		await waitFor(() => {
			expect(writeText).toHaveBeenCalled();
		});
		const text = writeText.mock.calls[0][0] as string;
		expect(text).toContain("objective_id: obj-explain");
		expect(text).toContain("submit_learning_attempt");
	});

	it("learningSessionPrompt 纯函数：title + objective + 七步循环话术", () => {
		const text = learningSessionPrompt(DETAIL, DETAIL.objectives[1]);
		expect(text).toContain("Python 入门");
		expect(text).toContain("能讲懂代码");
		expect(text).toContain("objective_id: obj-explain");
		expect(text).toContain("七步学习循环");
	});
});

describe("ParticipationsTabs", () => {
	it("三个 tab 导航", () => {
		render(<ParticipationsTabs tab="learning" />);
		expect(screen.getByTestId("tab-learning")).toBeTruthy();
		expect(screen.getByTestId("tab-enrollments")).toBeTruthy();
		expect(screen.getByTestId("tab-sponsorships")).toBeTruthy();
	});
});
