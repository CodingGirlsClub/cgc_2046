import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, screen } from "@testing-library/react";
import { render } from "@/test-utils";
import RecruitmentPanelPage from "./page";
import {
	advanceVolunteerApplication,
	assignVolunteerApplication,
	cancelVolunteerApplication,
	closeRecruitmentCohort,
	fetchRecruitmentCohorts,
	fetchVolunteerApplicationDetail,
	fetchVolunteerApplications,
	openRecruitmentCohort,
	rejectVolunteerApplication,
	type AdminVolunteerApplication,
	type RecruitmentCohort,
} from "@/lib/graphql/recruitment";
import { fetchWorkspaceOfferings } from "@/lib/events";
import { useWorkspaceBySlug } from "@/lib/use-workspace-by-slug";

/**
 * 招募审核面板测试（U8：R13；Covers AE3/AE8/AE9 的前端侧与 AE4 的面板侧）。
 *
 * 服务端边界（policy 拒绝、唯一 open 约束、R15 副作用）由后端测试钉住；这里锁
 * 面板契约：三态渲染、行内操作调用参数、拒绝原因必填的前端拦截、分配选择器
 * 与简历下载链接。
 */

vi.mock("next/navigation", () => ({
	usePathname: () => "/w/2046/recruitment",
	useRouter: () => ({ push: vi.fn(), replace: vi.fn(), prefetch: vi.fn(), back: vi.fn() }),
	useParams: () => ({ slug: "2046" }),
	redirect: vi.fn(),
	permanentRedirect: vi.fn(),
}));

vi.mock("@/components/workspace-shell", () => ({
	default: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
}));

vi.mock("@/lib/use-workspace-by-slug", () => ({
	useWorkspaceBySlug: vi.fn(),
}));

vi.mock("@/lib/graphql/recruitment", async (importOriginal) => {
	const actual = await importOriginal<typeof import("@/lib/graphql/recruitment")>();
	return {
		...actual,
		fetchRecruitmentCohorts: vi.fn(),
		fetchVolunteerApplications: vi.fn(),
		fetchVolunteerApplicationDetail: vi.fn(),
		advanceVolunteerApplication: vi.fn(),
		assignVolunteerApplication: vi.fn(),
		rejectVolunteerApplication: vi.fn(),
		cancelVolunteerApplication: vi.fn(),
		createRecruitmentCohort: vi.fn(),
		openRecruitmentCohort: vi.fn(),
		closeRecruitmentCohort: vi.fn(),
	};
});

vi.mock("@/lib/events", async (importOriginal) => {
	const actual = await importOriginal<typeof import("@/lib/events")>();
	return { ...actual, fetchWorkspaceOfferings: vi.fn() };
});

const cohort: RecruitmentCohort = {
	id: "cohort-1",
	name: "第 1 批",
	applyDeadlineAt: "2026-10-10T23:59:00Z",
	startsAt: null,
	endsAt: null,
	status: "open",
};

const draftCohort: RecruitmentCohort = {
	...cohort,
	id: "cohort-2",
	name: "第 2 批",
	status: "draft",
};

const application: AdminVolunteerApplication = {
	id: "app-1",
	userId: "user-1",
	cohortId: "cohort-1",
	position: "event_moderator",
	city: "上海",
	heardAboutUs: "公众号",
	hasInternalReferrer: false,
	message: null,
	status: "submitted",
	rejectionReason: null,
	assignedAt: null,
	assignmentNote: null,
};

beforeEach(() => {
	vi.mocked(useWorkspaceBySlug).mockReturnValue({
		ws: { id: "ws-2046", name: "2046 社区" },
		loading: false,
		readOnlyVisitor: false,
	} as unknown as ReturnType<typeof useWorkspaceBySlug>);
	vi.mocked(fetchRecruitmentCohorts).mockResolvedValue([cohort, draftCohort]);
	vi.mocked(fetchVolunteerApplications).mockResolvedValue([application]);
	vi.mocked(fetchWorkspaceOfferings).mockResolvedValue([]);
	vi.mocked(fetchVolunteerApplicationDetail).mockResolvedValue({
		application,
		resumeProfile: {
			id: "resume-1",
			fullName: "小程",
			contactEmail: "xiao@example.com",
			weeklyHours: 4,
			skills: ["写作"],
			fileName: "resume.pdf",
			fileContentType: "application/pdf",
			fileSize: 1024,
			uploadedAt: "2026-09-18T00:00:00Z",
		},
	});
	vi.mocked(advanceVolunteerApplication).mockResolvedValue({ result: application, errors: [] });
	vi.mocked(assignVolunteerApplication).mockResolvedValue({ result: application, errors: [] });
	vi.mocked(rejectVolunteerApplication).mockResolvedValue({ result: application, errors: [] });
	vi.mocked(cancelVolunteerApplication).mockResolvedValue({ result: application, errors: [] });
	vi.mocked(openRecruitmentCohort).mockResolvedValue({ result: draftCohort, errors: [] });
	vi.mocked(closeRecruitmentCohort).mockResolvedValue({ result: cohort, errors: [] });
});

afterEach(() => {
	cleanup();
	vi.clearAllMocks();
});

describe("U8 招募审核面板", () => {
	it("渲染批次与申请列表（职位/城市/段位徽章）", async () => {
		render(<RecruitmentPanelPage />);

		// 批次名在「批次列表」与「过滤器 option」两处出现 → findAllByText
		expect((await screen.findAllByText("第 1 批")).length).toBeGreaterThan(1);
		expect(screen.getAllByText("第 2 批").length).toBeGreaterThan(0);
		expect(screen.getByText("场次主理人")).toBeInTheDocument();
		expect(screen.getByText("上海")).toBeInTheDocument();
		expect(screen.getAllByText("已提交").length).toBeGreaterThan(0);
	});

	it("推进：submitted → interview（调用带 workspaceId/id/stage）", async () => {
		render(<RecruitmentPanelPage />);

		fireEvent.click(await screen.findByRole("button", { name: "推进到面试" }));

		await vi.waitFor(() => {
			expect(advanceVolunteerApplication).toHaveBeenCalledWith("ws-2046", "app-1", "interview");
		});
	});

	it("拒绝：空原因时确认按钮禁用（前端拦截）；填原因后可提交（AE3 前端侧）", async () => {
		render(<RecruitmentPanelPage />);

		fireEvent.click(await screen.findByRole("button", { name: "拒绝" }));
		const confirm = screen.getByRole("button", { name: "确认拒绝" });
		expect(confirm).toBeDisabled();

		fireEvent.change(screen.getByLabelText("拒绝原因"), {
			target: { value: "本批名额已满" },
		});
		expect(confirm).not.toBeDisabled();

		fireEvent.click(confirm);
		await vi.waitFor(() => {
			expect(rejectVolunteerApplication).toHaveBeenCalledWith("ws-2046", "app-1", "本批名额已满");
		});
	});

	it("取消：备注选填，空备注也可提交（AE8 前端侧）", async () => {
		render(<RecruitmentPanelPage />);

		fireEvent.click(await screen.findByRole("button", { name: "取消" }));
		fireEvent.click(screen.getByRole("button", { name: "确认取消" }));

		await vi.waitFor(() => {
			expect(cancelVolunteerApplication).toHaveBeenCalledWith("ws-2046", "app-1", null);
		});
	});

	it("分配（training）：从该台场次中选一场（AE4 面板侧）", async () => {
		vi.mocked(fetchVolunteerApplications).mockResolvedValue([
			{ ...application, status: "training" },
		]);
		vi.mocked(fetchWorkspaceOfferings).mockResolvedValue([
			{ id: "event-1", title: "上海首场", status: "draft" },
		] as unknown as Awaited<ReturnType<typeof fetchWorkspaceOfferings>>);

		render(<RecruitmentPanelPage />);

		fireEvent.click(await screen.findByRole("button", { name: "项目分配" }));
		fireEvent.change(screen.getByLabelText("分配场次"), { target: { value: "event-1" } });
		fireEvent.change(screen.getByLabelText("分配备注"), { target: { value: "首场主理人" } });
		fireEvent.click(screen.getByRole("button", { name: "确认分配" }));

		await vi.waitFor(() => {
			expect(assignVolunteerApplication).toHaveBeenCalledWith("ws-2046", "app-1", {
				assignedEventId: "event-1",
				assignmentNote: "首场主理人",
			});
		});
	});

	it("批次开放冲突：显示稳定 code 文案（AE9 前端侧）", async () => {
		vi.mocked(openRecruitmentCohort).mockResolvedValue({
			result: null,
			errors: [{ message: "conflict", code: "recruitment_cohort_open_conflict" }],
		});

		render(<RecruitmentPanelPage />);

		fireEvent.click(await screen.findByRole("button", { name: "开放" }));

		expect(
			await screen.findByText("已有一个招募中的批次，请先关闭后再开放。"),
		).toBeInTheDocument();
	});

	it("详情展开：显示档案元数据与受保护下载链接", async () => {
		render(<RecruitmentPanelPage />);

		fireEvent.click(await screen.findByRole("button", { name: "详情" }));

		const link = await screen.findByRole("link", { name: /下载简历/ });
		expect(link).toHaveAttribute("href", "/api/recruitment/resumes/resume-1");
		expect(screen.getByText(/小程/)).toBeInTheDocument();
	});

	it("加载失败：显示错误态与重试（三态）", async () => {
		vi.mocked(fetchRecruitmentCohorts).mockRejectedValue(new Error("boom"));
		vi.mocked(fetchVolunteerApplications).mockRejectedValue(new Error("boom"));

		render(<RecruitmentPanelPage />);

		expect(await screen.findByRole("alert")).toBeInTheDocument();
		expect(screen.getByRole("button", { name: /重试|再次尝试/ })).toBeInTheDocument();
	});

	it("非终结段位才出行内操作（assigned 后无推进/拒绝/取消）", async () => {
		vi.mocked(fetchVolunteerApplications).mockResolvedValue([
			{ ...application, status: "assigned" },
		]);

		render(<RecruitmentPanelPage />);

		expect(await screen.findByText("已分配")).toBeInTheDocument();
		expect(screen.queryByRole("button", { name: "拒绝" })).not.toBeInTheDocument();
		expect(screen.queryByRole("button", { name: "取消" })).not.toBeInTheDocument();
		expect(screen.queryByRole("button", { name: "项目分配" })).not.toBeInTheDocument();
	});
});
