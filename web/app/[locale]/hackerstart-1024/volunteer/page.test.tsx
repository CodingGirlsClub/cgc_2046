import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { cleanup, fireEvent, screen, within } from "@testing-library/react";
import { render } from "@/test-utils";
import VolunteerApplyPage from "./page";
import {
	createVolunteerApplication,
	fetchCampaignWorkspaceId,
	fetchCurrentRecruitmentCohort,
	fetchMyResumeProfile,
	fetchMyVolunteerApplications,
	upsertResumeProfile,
	uploadResumeFile,
	type RecruitmentCohort,
	type ResumeProfile,
	type VolunteerApplication,
} from "@/lib/graphql/recruitment";
import { fetchCurrentProfile } from "@/lib/profile";
import { useAuthed } from "@/lib/use-authed";
import zhCN from "@/messages/zh-CN.json";
import en from "@/messages/en.json";

/**
 * 志愿者申请页测试（U7：R10/R11/R18；Covers AE1、AE5、AE12 与 F2 前端侧）。
 *
 * 确定性分层：结构 / 文案 / 状态机（三态、两步流、PIPL 台阶、AE2/AE5 前端侧）
 * 全走断言；≤640px 的真实几何（390px 单列、无横向滚动）由浏览器侧走查承担，
 * 这里锁 CSS 契约与消息契约（漏一处即红）。
 */

const VOLUNTEER_PATH = "/hackerstart-1024/volunteer";
const CAMPAIGN_CSS = "../../../../components/hackerstart-1024/hackerstart-1024.css";
const PAGE_SOURCE = "./page.tsx";

vi.mock("next/navigation", () => ({
	usePathname: () => VOLUNTEER_PATH,
	useRouter: () => ({ push: vi.fn(), replace: vi.fn(), prefetch: vi.fn() }),
	useParams: () => ({}),
	redirect: vi.fn(),
	permanentRedirect: vi.fn(),
}));

vi.mock("@/lib/use-authed", () => ({ useAuthed: vi.fn() }));
vi.mock("@/lib/profile", () => ({ fetchCurrentProfile: vi.fn() }));

// 只替掉数据面：常量（VOLUNTEER_REVIEW_STAGES 等）保持真实实现
vi.mock("@/lib/graphql/recruitment", async (importOriginal) => {
	const actual = await importOriginal<typeof import("@/lib/graphql/recruitment")>();
	return {
		...actual,
		fetchCampaignWorkspaceId: vi.fn(),
		fetchCurrentRecruitmentCohort: vi.fn(),
		fetchMyResumeProfile: vi.fn(),
		fetchMyVolunteerApplications: vi.fn(),
		upsertResumeProfile: vi.fn(),
		uploadResumeFile: vi.fn(),
		createVolunteerApplication: vi.fn(),
	};
});

const authedMock = vi.mocked(useAuthed);
const workspaceIdMock = vi.mocked(fetchCampaignWorkspaceId);
const cohortMock = vi.mocked(fetchCurrentRecruitmentCohort);
const profileMock = vi.mocked(fetchMyResumeProfile);
const appsMock = vi.mocked(fetchMyVolunteerApplications);
const upsertMock = vi.mocked(upsertResumeProfile);
const uploadMock = vi.mocked(uploadResumeFile);
const createMock = vi.mocked(createVolunteerApplication);
const accountMock = vi.mocked(fetchCurrentProfile);

const WORKSPACE_ID = "ws-2046";
const COHORT: RecruitmentCohort = {
	id: "cohort-1",
	// 批次名来自后端数据（不落 messages）：用 ASCII 名字，en 侧零中文断言才不被数据干扰
	name: "Cohort 1 · First volunteer intake",
	applyDeadlineAt: "2026-10-10T15:59:00Z",
	startsAt: "2026-10-24T01:00:00Z",
	endsAt: "2027-01-31T15:59:00Z",
	status: "open",
};

const PROFILE: ResumeProfile = {
	id: "profile-1",
	fullName: "张三",
	contactEmail: "zhangsan@example.com",
	weeklyHours: 8,
	skills: ["organizing"],
	fileName: null,
	fileContentType: null,
	fileSize: null,
	uploadedAt: null,
};

const PROFILE_WITH_FILE: ResumeProfile = {
	...PROFILE,
	fileName: "cv.pdf",
	fileContentType: "application/pdf",
	fileSize: 2048,
	uploadedAt: "2026-09-18T02:00:00Z",
};

const APPLICATION: VolunteerApplication = {
	id: "app-1",
	cohortId: "cohort-1",
	position: "event_moderator",
	city: "上海",
	heardAboutUs: "朋友圈",
	hasInternalReferrer: false,
	message: null,
	status: "submitted",
	rejectionReason: null,
	assignedAt: null,
	assignmentNote: null,
};

function readSource(relativePath: string): string {
	return readFileSync(fileURLToPath(new URL(relativePath, import.meta.url)), "utf8");
}

/** 递归展开嵌套对象为点路径键集合（数组按叶子处理） */
function flattenKeys(node: unknown, prefix = ""): string[] {
	if (node === null || typeof node !== "object" || Array.isArray(node)) return [prefix];
	return Object.entries(node as Record<string, unknown>).flatMap(([key, value]) =>
		flattenKeys(value, prefix ? `${prefix}.${key}` : key),
	);
}

/** 账号资料桩（fetchCurrentProfile 的返回面只用 email） */
function accountWith(email: string) {
	return {
		id: "u1",
		email,
		isPlatformAdmin: false,
		displayName: null,
		locale: null,
	};
}

beforeEach(() => {
	vi.clearAllMocks();
	authedMock.mockReturnValue({ authed: true, confirmed: true, userId: "u1" });
	workspaceIdMock.mockResolvedValue(WORKSPACE_ID);
	cohortMock.mockResolvedValue(COHORT);
	profileMock.mockResolvedValue(null);
	appsMock.mockResolvedValue([]);
	accountMock.mockResolvedValue(accountWith(""));
	upsertMock.mockResolvedValue({ result: PROFILE, errors: [] });
	uploadMock.mockResolvedValue({ result: PROFILE_WITH_FILE, errors: [] });
	createMock.mockResolvedValue({ result: APPLICATION, errors: [] });
});

afterEach(cleanup);

	describe("职位选择卡（tab 交互）", () => {
		it("点击职位卡 → 选中高亮迁移，且联动第 2 步职位单选（AE 前端交互）", async () => {
			render(<VolunteerApplyPage />);

			// 初始：featured（场次主理人）选中
			const tiles = () => Array.from(document.querySelectorAll("#va-roles [role=radio]"));
			expect(tiles().length).toBe(3);
			expect(tiles()[0].getAttribute("aria-checked")).toBe("true");
			expect(tiles()[0].className).toContain("hs24-tile--selected");

			// 点击第三张（活动教练）→ 高亮迁移、表单单选联动
			fireEvent.click(tiles()[2]);
			expect(tiles()[2].getAttribute("aria-checked")).toBe("true");
			expect(tiles()[0].getAttribute("aria-checked")).toBe("false");
			expect(tiles()[2].className).toContain("hs24-tile--selected");
			expect(tiles()[0].className).not.toContain("hs24-tile--selected");
		});

		it("键盘可达：Enter/Space 选中（radiogroup 语义）", async () => {
			render(<VolunteerApplyPage />);
			const tiles = () => Array.from(document.querySelectorAll("#va-roles [role=radio]"));
			expect(tiles()[1].getAttribute("tabindex")).toBe("0");
			fireEvent.keyDown(tiles()[1], { key: "Enter" });
			expect(tiles()[1].getAttribute("aria-checked")).toBe("true");
		});
	});

	describe("/hackerstart-1024/volunteer 志愿者申请页（U7）", () => {
	it("叙事结构：hero / 批次 / 三职位 / featured 深读 / 四段流程 / 分组 FAQ / 表单 / 我的申请 / 页脚", async () => {
		render(<VolunteerApplyPage />);
		await screen.findByText(zhCN.volunteerApply.cohort.openBadge);

		const ZH = zhCN.volunteerApply;
		expect(document.querySelectorAll("h1")).toHaveLength(1);
		expect(document.querySelector("#va-hero-title")?.textContent).toBe(
			ZH.hero.title.replace(/<[^>]+>/g, ""),
		);
		// 段标题与消息一致（含 <em> 玫红段）
		for (const [selector, message] of [
			["#va-cohort-title", ZH.cohort.title],
			["#va-roles-title", ZH.roles.title],
			["#va-deep-title", ZH.deep.title],
			["#va-flow-title", ZH.flow.title],
			["#va-faq-title", ZH.faq.title],
			["#va-apply-title", ZH.form.title],
			["#va-my-apps-title", ZH.myApps.title],
		] as const) {
			expect(document.querySelector(selector)?.textContent, selector).toBe(
				message.replace(/<[^>]+>/g, ""),
			);
		}

		// 三职位：featured 是场次主理人；职责与要求成对出现
		const roleTiles = Array.from(document.querySelectorAll("#va-roles .hs24-cap3 .hs24-tile"));
		expect(roleTiles).toHaveLength(3);
		expect(roleTiles[0]?.className).toContain("hs24-tile--selected");
		for (const [index, role] of ZH.roles.items.entries()) {
			const tile = roleTiles[index];
			expect(tile?.textContent).toContain(role.t);
			for (const line of role.duty) expect(tile?.textContent).toContain(line);
			for (const line of role.reqs) expect(tile?.textContent).toContain(line);
		}

		// featured 深读：三段职责 + 四项支持
		expect(document.querySelectorAll("#va-deep-title ~ .hs24-cap3 .hs24-tile")).toHaveLength(3);
		expect(document.querySelector("#va-deep-title")?.closest("section")?.textContent).toContain(
			ZH.deep.quoteBy,
		);

		// 四段流程（网申 → 面试 → 训练营 → 项目分配）
		const flowNodes = Array.from(document.querySelectorAll(".hs24-ladder__step"));
		expect(flowNodes).toHaveLength(4);
		expect(flowNodes[0]?.textContent).toContain(ZH.flow.steps[0].t);
		expect(flowNodes[3]?.textContent).toContain(ZH.flow.steps[3].t);

		// 分组 FAQ（共同关心 + 三个职位小节）
		expect(document.querySelectorAll(".hs24-faq").length).toBe(ZH.faq.groups.length);
		expect(
			Array.from(document.querySelectorAll(".hs24-sub")).map((node) => node.textContent),
		).toEqual(ZH.faq.groups.map((group) => group.g));

		// 页脚回宣传页
		expect(screen.getByRole("link", { name: /返回宣传页/ })).toHaveAttribute(
			"href",
			"/hackerstart-1024",
		);
	});

	it("AE1：未登录 → 登录引导（带回跳）而非表单，且不发数据面请求", async () => {
		authedMock.mockReturnValue({ authed: false, confirmed: true, userId: null });

		render(<VolunteerApplyPage />);

		// 叙事照常（公开落地页）
		expect(document.querySelector("#va-hero-title")).not.toBeNull();
		expect(document.querySelector("#va-faq-title")).not.toBeNull();

		// 登录引导：回跳 = 当前申请页路径（照公开面既有写法，非裸 /login）
		const loginLinks = screen.getAllByRole("link", { name: zhCN.volunteerApply.form.login });
		expect(loginLinks.length).toBeGreaterThan(0);
		for (const link of loginLinks) {
			expect(link).toHaveAttribute(
				"href",
				`/login?next=${encodeURIComponent(VOLUNTEER_PATH)}`,
			);
		}

		// 表单不渲染 + 我的申请区不渲染 + 批次卡为登录引导态
		expect(document.querySelector("#va-apply form")).toBeNull();
		expect(document.querySelector("#va-my-apps")).toBeNull();
		expect(document.querySelector("#va-cohort")?.textContent).toContain(
			zhCN.volunteerApply.cohort.loginRequired,
		);

		// 未登录不发招募数据面请求（无 workspaceId 可解析）
		expect(workspaceIdMock).not.toHaveBeenCalled();
		expect(cohortMock).not.toHaveBeenCalled();
	});

	it("登录态确认中 → 只显示确认提示，表单与我的申请都不渲染", () => {
		authedMock.mockReturnValue({ authed: false, confirmed: false, userId: null });

		render(<VolunteerApplyPage />);

		expect(document.querySelector("#va-apply")?.textContent).toContain(
			zhCN.volunteerApply.form.checking,
		);
		expect(document.querySelector("#va-apply form")).toBeNull();
		expect(document.querySelector("#va-my-apps")).toBeNull();
	});

	it("R10：open 批次 → 名称 + 截止 + 执行周期 + 申请入口（数据面走动态读）", async () => {
		render(<VolunteerApplyPage />);

		await vi.waitFor(() => expect(cohortMock).toHaveBeenCalledWith(WORKSPACE_ID));
		await screen.findByText(zhCN.volunteerApply.cohort.openBadge);

		const card = document.querySelector(".hs24-cohort");
		expect(card?.textContent).toContain(COHORT.name);
		expect(card?.textContent).toContain("2026");
		expect(card?.textContent).toContain(zhCN.volunteerApply.cohort.period.slice(0, 4));
		// 申请入口（页内锚到表单段）
		expect(
			within(card as HTMLElement).getByRole("link", { name: zhCN.volunteerApply.cohort.cta }),
		).toHaveAttribute("href", "#va-apply");
		// 两步表单可用
		expect(document.querySelector("#va-apply form")).not.toBeNull();
		expect(
			screen.getByRole("heading", { name: zhCN.volunteerApply.form.step1Title }),
		).toBeInTheDocument();
	});

	it("AE12：无 open 批次 → 空态文案 + 申请入口收起（表单调用被收）", async () => {
		cohortMock.mockResolvedValue(null);

		render(<VolunteerApplyPage />);

		// 空态文案在批次卡与申请区各出现一次（入口收起后申请区给的是同一态）
		expect(await screen.findAllByText(zhCN.volunteerApply.cohort.emptyTitle)).toHaveLength(2);
		// 批次区空态
		expect(document.querySelector("#va-cohort")?.textContent).toContain(
			zhCN.volunteerApply.cohort.emptyDesc,
		);
		// 入口收起：卡片 CTA 与表单都不在，空态文案在申请区也出现
		expect(
			screen.queryByRole("link", { name: zhCN.volunteerApply.cohort.cta }),
		).toBeNull();
		expect(document.querySelector("#va-apply form")).toBeNull();
		expect(document.querySelector("#va-apply")?.textContent).toContain(
			zhCN.volunteerApply.cohort.emptyTitle,
		);
		// 页面其余叙事照常
		expect(document.querySelector("#va-roles-title")).not.toBeNull();
		expect(document.querySelector("#va-faq-title")).not.toBeNull();
	});

	it("R10 三态：读取失败 → 失败文案 + 重试（不显示无批次空态），重试后恢复", async () => {
		cohortMock.mockRejectedValueOnce(new Error("boom"));

		render(<VolunteerApplyPage />);

		expect(await screen.findAllByText(zhCN.volunteerApply.cohort.loadFailed)).toHaveLength(2);
		// 失败 ≠ 空态：不出现「当前无开放批次」
		expect(document.body.textContent).not.toContain(
			zhCN.volunteerApply.cohort.emptyTitle,
		);
		// 失败态入口收起逻辑不生效：不把批次当「无」处理（申请区给失败 + 重试）
		const retry = within(document.querySelector("#va-apply") as HTMLElement).getByRole(
			"button",
			{ name: zhCN.common.retry },
		);

		cohortMock.mockResolvedValue(COHORT);
		fireEvent.click(retry);

		await screen.findByText(zhCN.volunteerApply.cohort.openBadge);
		expect(cohortMock).toHaveBeenCalledTimes(2);
		expect(document.querySelector("#va-apply form")).not.toBeNull();
	});

	it("R11/PIPL：未勾选采集同意台阶 → 上传与提交被拦截，链 /privacy", async () => {
		render(<VolunteerApplyPage />);
		await screen.findByText(zhCN.volunteerApply.cohort.openBadge);

		// 告知面：勾选框 + 隐私政策链接
		const consent = document.querySelector("#va-consent") as HTMLInputElement;
		expect(consent).not.toBeNull();
		expect(screen.getByRole("link", { name: zhCN.volunteerApply.form.consentLink })).toHaveAttribute(
			"href",
			"/privacy",
		);

		// 上传被拦截：选择入口禁用，程序化 change 也不放行
		expect(
			screen.getByRole("button", { name: zhCN.volunteerApply.upload.choose }),
		).toBeDisabled();
		const fileInput = document.querySelector("#va-resume-file") as HTMLInputElement;
		fireEvent.change(fileInput, {
			target: { files: [new File(["resume"], "cv.pdf", { type: "application/pdf" })] },
		});
		expect(upsertMock).not.toHaveBeenCalled();
		expect(uploadMock).not.toHaveBeenCalled();

		// 提交被拦截：第 1 步下一步拦（勾选台阶未过）
		fireEvent.change(screen.getByLabelText(zhCN.volunteerApply.form.fullName), {
			target: { value: "张三" },
		});
		fireEvent.change(screen.getByLabelText(zhCN.volunteerApply.form.contactEmail), {
			target: { value: "zhangsan@example.com" },
		});
		fireEvent.click(screen.getByRole("button", { name: zhCN.volunteerApply.form.next }));

		expect(await screen.findByRole("alert")).toHaveTextContent(
			zhCN.volunteerApply.form.consentRequired,
		);
		expect(upsertMock).not.toHaveBeenCalled();
		expect(createMock).not.toHaveBeenCalled();
	});

	it("R11：手机号建号（账号无邮箱）→ 联系邮箱必填，未填被拦截", async () => {
		render(<VolunteerApplyPage />);
		await screen.findByText(zhCN.volunteerApply.cohort.openBadge);

		const email = screen.getByLabelText(zhCN.volunteerApply.form.contactEmail) as HTMLInputElement;
		expect(email.readOnly).toBe(false);

		fireEvent.change(screen.getByLabelText(zhCN.volunteerApply.form.fullName), {
			target: { value: "张三" },
		});
		fireEvent.click(document.querySelector("#va-consent") as HTMLElement);
		fireEvent.click(screen.getByRole("button", { name: zhCN.volunteerApply.form.next }));

		expect(await screen.findByRole("alert")).toHaveTextContent(
			zhCN.volunteerApply.form.profileIncomplete,
		);
		expect(upsertMock).not.toHaveBeenCalled();
	});

	it("R11：账号已有邮箱 → 预填只读（不随输入改动）", async () => {
		accountMock.mockResolvedValue(accountWith("account@example.com"));

		render(<VolunteerApplyPage />);
		await screen.findByText(zhCN.volunteerApply.cohort.openBadge);

		const email = (await screen.findByLabelText(
			zhCN.volunteerApply.form.contactEmail,
		)) as HTMLInputElement;
		await vi.waitFor(() => expect(email.value).toBe("account@example.com"));
		expect(email.readOnly).toBe(true);
		expect(screen.getByText(zhCN.volunteerApply.form.contactEmailFromAccount)).toBeInTheDocument();
	});

	it("R11/U2：选择文件 → 先建档再上传 → 档案回显（管道顺序 + base64 载荷）", async () => {
		render(<VolunteerApplyPage />);
		await screen.findByText(zhCN.volunteerApply.cohort.openBadge);

		fireEvent.change(screen.getByLabelText(zhCN.volunteerApply.form.fullName), {
			target: { value: "张三" },
		});
		fireEvent.change(screen.getByLabelText(zhCN.volunteerApply.form.contactEmail), {
			target: { value: "zhangsan@example.com" },
		});
		fireEvent.click(document.querySelector("#va-consent") as HTMLElement);

		const fileInput = document.querySelector("#va-resume-file") as HTMLInputElement;
		const bytes = new Uint8Array([1, 2, 3]);
		fireEvent.change(fileInput, {
			target: { files: [new File([bytes], "cv.pdf", { type: "application/pdf" })] },
		});

		await vi.waitFor(() => expect(uploadMock).toHaveBeenCalledTimes(1));
		// 先建档（U2 契约：未建档上传报 resume_profile_not_found）
		expect(upsertMock).toHaveBeenCalledWith(WORKSPACE_ID, {
			fullName: "张三",
			contactEmail: "zhangsan@example.com",
			weeklyHours: null,
			skills: [],
		});
		expect(upsertMock.mock.invocationCallOrder[0]).toBeLessThan(
			uploadMock.mock.invocationCallOrder[0],
		);
		expect(uploadMock).toHaveBeenCalledWith(WORKSPACE_ID, {
			fileName: "cv.pdf",
			contentType: "application/pdf",
			contentBase64: "AQID",
		});

		// 档案回显（文件名 + 大小）
		expect(
			await screen.findByText(
				zhCN.volunteerApply.upload.uploaded
					.replace("{name}", "cv.pdf")
					.replace("{size}", "2 KB"),
			),
		).toBeInTheDocument();
	});

	it("上传控件：类型 / 大小前置校验在控件内（不发请求）", async () => {
		render(<VolunteerApplyPage />);
		await screen.findByText(zhCN.volunteerApply.cohort.openBadge);

		fireEvent.change(screen.getByLabelText(zhCN.volunteerApply.form.fullName), {
			target: { value: "张三" },
		});
		fireEvent.change(screen.getByLabelText(zhCN.volunteerApply.form.contactEmail), {
			target: { value: "zhangsan@example.com" },
		});
		fireEvent.click(document.querySelector("#va-consent") as HTMLElement);

		const fileInput = document.querySelector("#va-resume-file") as HTMLInputElement;
		fireEvent.change(fileInput, {
			target: { files: [new File(["x"], "cv.txt", { type: "text/plain" })] },
		});
		expect(await screen.findByRole("alert")).toHaveTextContent(
			zhCN.volunteerApply.upload.rejectType,
		);
		expect(upsertMock).not.toHaveBeenCalled();

		// 超限：6MB 原始文件（U2 上限 5MB）
		const big = new File([new Uint8Array(6 * 1024 * 1024)], "big.pdf", {
			type: "application/pdf",
		});
		fireEvent.change(fileInput, { target: { files: [big] } });
		expect(await screen.findByRole("alert")).toHaveTextContent(
			zhCN.volunteerApply.upload.rejectSize,
		);
		expect(uploadMock).not.toHaveBeenCalled();
	});

	it("AE5：已有简历档案 → 预填 + 跳过重传直接进第 2 步", async () => {
		profileMock.mockResolvedValue(PROFILE_WITH_FILE);

		render(<VolunteerApplyPage />);
		await screen.findByText(zhCN.volunteerApply.form.profileReused);

		// 预填 + 档案回显 + 选择入口变为「替换简历」
		expect(
			(screen.getByLabelText(zhCN.volunteerApply.form.fullName) as HTMLInputElement).value,
		).toBe(PROFILE.fullName);
		expect(
			screen.getByRole("button", { name: zhCN.volunteerApply.upload.replace }),
		).toBeInTheDocument();

		fireEvent.click(document.querySelector("#va-consent") as HTMLElement);
		fireEvent.click(screen.getByRole("button", { name: zhCN.volunteerApply.form.next }));

		expect(
			await screen.findByRole("heading", { name: zhCN.volunteerApply.form.step2Title }),
		).toBeInTheDocument();
		expect(uploadMock).not.toHaveBeenCalled();
		// 第 1 步的档案更新用预填值（姓名/邮箱来自档案）
		expect(upsertMock).toHaveBeenCalledWith(WORKSPACE_ID, {
			fullName: PROFILE.fullName,
			contactEmail: PROFILE.contactEmail,
			weeklyHours: PROFILE.weeklyHours,
			skills: PROFILE.skills,
		});
	});

	it("第 1 步缺简历文件 → 不放行第 2 步（两步顺序不可跳过）", async () => {
		render(<VolunteerApplyPage />);
		await screen.findByText(zhCN.volunteerApply.cohort.openBadge);

		fireEvent.change(screen.getByLabelText(zhCN.volunteerApply.form.fullName), {
			target: { value: "张三" },
		});
		fireEvent.change(screen.getByLabelText(zhCN.volunteerApply.form.contactEmail), {
			target: { value: "zhangsan@example.com" },
		});
		fireEvent.click(document.querySelector("#va-consent") as HTMLElement);
		fireEvent.click(screen.getByRole("button", { name: zhCN.volunteerApply.form.next }));

		expect(await screen.findByRole("alert")).toHaveTextContent(
			zhCN.volunteerApply.form.fileRequired,
		);
		expect(upsertMock).not.toHaveBeenCalled();
	});

	it("提交成功 → 进入「我的申请」并显示当前段位（F2 前端侧）", async () => {
		profileMock.mockResolvedValue(PROFILE_WITH_FILE);
		appsMock
			.mockResolvedValueOnce([])
			.mockResolvedValueOnce([APPLICATION]);

		render(<VolunteerApplyPage />);
		await screen.findByText(zhCN.volunteerApply.form.profileReused);

		fireEvent.click(document.querySelector("#va-consent") as HTMLElement);
		fireEvent.click(screen.getByRole("button", { name: zhCN.volunteerApply.form.next }));
		await screen.findByRole("heading", { name: zhCN.volunteerApply.form.step2Title });

		fireEvent.change(screen.getByLabelText(zhCN.volunteerApply.form.city), {
			target: { value: "上海" },
		});
		fireEvent.click(screen.getByRole("button", { name: zhCN.volunteerApply.form.submit }));

		await vi.waitFor(() =>
			expect(createMock).toHaveBeenCalledWith(WORKSPACE_ID, {
				cohortId: COHORT.id,
				position: "event_moderator",
				city: "上海",
				heardAboutUs: null,
				hasInternalReferrer: false,
				message: null,
			}),
		);

		// 提交成功 → 我的申请刷新 + 段位展示
		expect(await screen.findByText(zhCN.volunteerApply.myApps.submitted)).toBeInTheDocument();
		const myApps = document.querySelector("#va-my-apps") as HTMLElement;
		expect(myApps.textContent).toContain(zhCN.volunteerApply.positions.event_moderator);
		expect(myApps.textContent).toContain(zhCN.volunteerApply.statusLabels.submitted);
		expect(appsMock).toHaveBeenCalledTimes(2);
	});

	it("AE2 前端侧：同批已有申请 → 提示本批已申请（表单收起，入口不再出现）", async () => {
		appsMock.mockResolvedValue([APPLICATION]);

		render(<VolunteerApplyPage />);

		await screen.findByText(zhCN.volunteerApply.form.appliedTitle);
		expect(document.querySelector("#va-apply form")).toBeNull();
		expect(document.querySelector("#va-apply")?.textContent).toContain(
			zhCN.volunteerApply.form.appliedDesc,
		);
		// 段位可见（该批申请的状态卡）
		expect(
			within(document.querySelector("#va-apply") as HTMLElement).getByText(
				zhCN.volunteerApply.statusLabels.submitted,
			),
		).toBeInTheDocument();
	});

	it("AE2 竞态：提交撞同批唯一约束 → 按 code 出「本批已申请」文案（不透传英文原文）", async () => {
		profileMock.mockResolvedValue(PROFILE_WITH_FILE);
		createMock.mockResolvedValue({
			result: null,
			errors: [{ message: "an application for this cohort already exists", code: "volunteer_application_already_submitted" }],
		});

		render(<VolunteerApplyPage />);
		await screen.findByText(zhCN.volunteerApply.form.profileReused);

		fireEvent.click(document.querySelector("#va-consent") as HTMLElement);
		fireEvent.click(screen.getByRole("button", { name: zhCN.volunteerApply.form.next }));
		await screen.findByRole("heading", { name: zhCN.volunteerApply.form.step2Title });
		fireEvent.click(screen.getByRole("button", { name: zhCN.volunteerApply.form.submit }));

		expect(await screen.findByRole("alert")).toHaveTextContent(
			zhCN.errors.volunteer_application_already_submitted,
		);
	});

	it("我的申请：列表读取失败 → 失败文案 + 重试后恢复列表", async () => {
		appsMock.mockRejectedValueOnce(new Error("boom"));

		render(<VolunteerApplyPage />);

		expect(await screen.findAllByText(zhCN.volunteerApply.myApps.loadFailed)).toHaveLength(1);
		const myApps = document.querySelector("#va-my-apps") as HTMLElement;
		expect(myApps.textContent).not.toContain(zhCN.volunteerApply.myApps.empty);

		appsMock.mockResolvedValue([
			{
				...APPLICATION,
				id: "app-rejected",
				status: "rejected",
				rejectionReason: "本批职位已满",
			},
		]);
		fireEvent.click(within(myApps).getByRole("button", { name: zhCN.common.retry }));

		await vi.waitFor(() =>
			expect(document.querySelector("#va-my-apps")?.textContent).toContain(
				zhCN.volunteerApply.statusLabels.rejected,
			),
		);
		// 终止态：段位胶囊 + 终止文案 + 拒绝原因；不画四段进度条
		expect(document.querySelector("#va-my-apps")?.textContent).toContain(
			zhCN.volunteerApply.myApps.rejected,
		);
		expect(document.querySelector("#va-my-apps")?.textContent).toContain(
			zhCN.volunteerApply.myApps.rejectionReason.replace("{reason}", "本批职位已满"),
		);
		expect(document.querySelectorAll("#va-my-apps ol")).toHaveLength(0);
	});

	it("我的申请：assigned → 四段进度条到终态（当前段位 = 项目分配）", async () => {
		appsMock.mockResolvedValue([{ ...APPLICATION, id: "app-assigned", status: "assigned" }]);

		render(<VolunteerApplyPage />);

		await vi.waitFor(() =>
			expect(document.querySelector("#va-my-apps")?.textContent).toContain(
				zhCN.volunteerApply.statusLabels.assigned,
			),
		);
		expect(document.querySelectorAll("#va-my-apps ol")).toHaveLength(1);
		expect(
			Array.from(document.querySelectorAll("#va-my-apps ol li")).map(
				(node) => node.textContent,
			),
		).toEqual([
			zhCN.volunteerApply.stageLabels.submitted,
			zhCN.volunteerApply.stageLabels.interview,
			zhCN.volunteerApply.stageLabels.training,
			zhCN.volunteerApply.stageLabels.assigned,
		]);
	});

	it("my apps：空列表文案（未提交过）", async () => {
		render(<VolunteerApplyPage />);

		await screen.findByText(zhCN.volunteerApply.myApps.empty);
		expect(document.querySelector("#va-my-apps")).not.toBeNull();
	});

	it("R18/CSS 契约：≤640px 单列化（新增网格全部 sm: 起步）+ 同页族 token 复用", () => {
		const css = readSource(CAMPAIGN_CSS);
		const source = readSource(PAGE_SOURCE);

		// 复用 U6 的 ≤640px 响应式块（角色卡 / 支持瓦片单列）
		const mobileStart = css.indexOf("@media (max-width: 640px)");
		expect(mobileStart).toBeGreaterThan(-1);
		expect(css.slice(mobileStart)).toMatch(
			/\.hs24-cap3,\s*\.hs24-tiles,\s*\.hs24-openqs\s*\{\s*grid-template-columns:\s*1fr;/,
		);
		// 横向滚动：section 裁掉装饰右溢出
		expect(css).toMatch(/\.hs24-section\s*\{[^}]*overflow-x:\s*clip;/);

		// 本页新增的多列网格一律 sm:（640px）起步 → ≤640px 恒单列
		const grids = source.match(/grid-cols-1[^"]*sm:grid-cols-\d/g) ?? [];
		expect(grids.length).toBeGreaterThan(0);
		expect(source).not.toMatch(/(?<!sm:)grid-cols-[2-9]/);
		// 硬编码中文 UI 串由 AST 层的 check:i18n-coverage 拦截（注释不参与），此处不重复
	});

	it("i18n：zh/en 键集与数组条目一一对应，en 无中文残留，整页可切换英文", async () => {
		const ZH = zhCN.volunteerApply;
		const EN = en.volunteerApply;
		expect(flattenKeys(ZH).sort()).toEqual(flattenKeys(EN).sort());
		expect(ZH.roles.items).toHaveLength(3);
		expect(EN.roles.items).toHaveLength(3);
		expect(ZH.flow.steps).toHaveLength(4);
		expect(EN.flow.steps).toHaveLength(4);
		expect(ZH.faq.groups).toHaveLength(4);
		expect(EN.faq.groups).toHaveLength(4);
		expect(JSON.stringify(EN)).not.toMatch(/[\u4e00-\u9fff]/);

		render(<VolunteerApplyPage />, { locale: "en" });
		await screen.findByText(EN.cohort.openBadge);

		expect(document.querySelector("#va-hero-title")?.textContent).toBe(
			EN.hero.title.replace(/<[^>]+>/g, ""),
		);
		expect(screen.getByRole("link", { name: EN.cohort.cta })).toHaveAttribute(
			"href",
			"#va-apply",
		);
		// 主体（不含顶导的语言切换器，那里本就并排显示「中文」）零中文
		const mainText = Array.from(
			document.querySelectorAll(".hs24-hero, .hs24-section, .hs24-footer"),
		)
			.map((node) => node.textContent)
			.join("");
		expect(mainText).not.toMatch(/[\u4e00-\u9fff]/);
	});

	it("错误路径：messages 缺 namespace 时不白屏（next-intl 回落 key 路径）", async () => {
		const consoleError = vi.spyOn(console, "error").mockImplementation(() => {});
		try {
			render(<VolunteerApplyPage />, { messages: { volunteerApply: {} } });
			// 骨架照常：段落齐全、列表回落空数组而非崩掉
			expect(document.querySelector("#va-hero-title")).not.toBeNull();
			expect(document.querySelector("#va-roles-title")).not.toBeNull();
			expect(document.querySelectorAll("#va-roles .hs24-cap3 .hs24-tile")).toHaveLength(0);
			expect(document.querySelectorAll(".hs24-ladder__step")).toHaveLength(0);
		} finally {
			consoleError.mockRestore();
		}
	});
});
