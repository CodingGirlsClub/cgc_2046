import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, screen, waitFor } from "@testing-library/react";
import { render } from "@/test-utils";
import CheckInPage from "./page";
import { CHECK_IN_ENROLLMENT } from "@/lib/graphql/attendance";

const { useParams, useSearchParams, usePathname } = vi.hoisted(() => ({
	useParams: vi.fn(),
	useSearchParams: vi.fn(),
	usePathname: vi.fn(),
}));
const { useAuthed } = vi.hoisted(() => ({ useAuthed: vi.fn() }));
// IO 边界（apollo client / 公开读面）用 mock；lib/check-in 的归一、URL 构造与
// 解析分支走真实实现（页面本地校验行为就是本单测的守卫对象）
const { mutate, fetchPublicOffering } = vi.hoisted(() => ({
	mutate: vi.fn(),
	fetchPublicOffering: vi.fn(),
}));

vi.mock("next/navigation", () => ({
	redirect: vi.fn(),
	permanentRedirect: vi.fn(),
	useParams,
	useSearchParams,
	// ThemeProvider 依赖 usePathname 解析 workspace slug（ADR-0004）
	usePathname,
}));
vi.mock("@/lib/auth-provider", () => ({ useAuthed }));
vi.mock("@/lib/apollo-client", () => ({
	client: { mutate, query: vi.fn() },
}));
vi.mock("@/lib/public-offerings", () => ({ fetchPublicOffering }));
// 套 SitePage 顶导后引入语言切换器（依赖 app router 的 next-intl useRouter）：行为无关
vi.mock("@/components/language-switcher", () => ({
	default: () => null,
}));

const EVENT = { id: "evt-1", slug: "deposit-hackathon", title: "押金制黑客松" };

// 后端手写 payload 是扁平形状（enrollmentId/checkedInAt/method/errors），
// 不是 AshGraphql 生成 mutation 的 {result, errors} 信封。
const SUCCESS = {
	data: {
		checkInEnrollment: {
			enrollmentId: "enr-1",
			checkedInAt: "2026-09-14T02:00:00Z",
			method: "scan",
			errors: [],
		},
	},
};

/** 渲染核销页（默认：已登录、路段为公开 slug、URL 带合法码） */
function renderPage({ code }: { code?: string } = {}) {
	useParams.mockReturnValue({ slug: "deposit-hackathon" });
	useSearchParams.mockReturnValue(new URLSearchParams(code ? `code=${code}` : ""));
	render(<CheckInPage />);
}

function errorPayload(code: string) {
	return {
		data: {
			checkInEnrollment: {
				enrollmentId: null,
				checkedInAt: null,
				method: null,
				errors: [{ code }],
			},
		},
	};
}

async function submitForm() {
	fireEvent.click(await screen.findByTestId("check-in-submit"));
}

beforeEach(() => {
	vi.clearAllMocks();
	useAuthed.mockReturnValue({ authed: true, confirmed: true, userId: "u-mod" });
	usePathname.mockReturnValue("/events/deposit-hackathon/check-in");
	fetchPublicOffering.mockResolvedValue(EVENT);
	mutate.mockResolvedValue(SUCCESS);
});

afterEach(cleanup);

describe("/events/[slug]/check-in 现场核销（R6、R11）", () => {
	it("URL 带码：预填 → 提交成功（scan）→ 显示核销成功与押金退款说明", async () => {
		renderPage({ code: "123456" });

		expect(await screen.findByTestId("check-in-code-input")).toHaveValue("123456");
		expect(screen.getByText("押金制黑客松")).toBeInTheDocument();
		expect(screen.getByText(/确认出示核销码的人本人就在现场/)).toBeInTheDocument();

		await submitForm();

		await waitFor(() =>
			expect(mutate).toHaveBeenCalledWith({
				mutation: CHECK_IN_ENROLLMENT,
				variables: { eventId: "evt-1", code: "123456", method: "scan" },
			}),
		);
		const success = await screen.findByTestId("check-in-success");
		expect(success).toHaveTextContent("✓ 核销成功，已记录到场");
		expect(success).toHaveTextContent(/押金退款已发起/);
		expect(success).toHaveTextContent(/方式：扫码/);
	});

	it("同码再提交：后端回已核销 → 显示「已核销」（面板显示最近一次提交结果）", async () => {
		renderPage({ code: "123456" });
		await submitForm();
		await screen.findByTestId("check-in-success");

		mutate.mockResolvedValueOnce(errorPayload("attendance_already_checked_in"));
		await submitForm();

		expect(await screen.findByTestId("check-in-error")).toHaveTextContent(
			"该报名已核销，无需重复核销。",
		);
		expect(screen.queryByTestId("check-in-success")).not.toBeInTheDocument();
	});

	it("手输码：提交以 manual 记录", async () => {
		renderPage();
		const input = await screen.findByTestId("check-in-code-input");
		fireEvent.change(input, { target: { value: "000 042" } });
		await submitForm();

		await waitFor(() =>
			expect(mutate).toHaveBeenCalledWith({
				mutation: CHECK_IN_ENROLLMENT,
				variables: { eventId: "evt-1", code: "000042", method: "manual" },
			}),
		);
	});

	it("URL 预填后手改码：提交以 manual 记录（方式随输入来源）", async () => {
		renderPage({ code: "123456" });
		fireEvent.change(await screen.findByTestId("check-in-code-input"), {
			target: { value: "999999" },
		});
		await submitForm();

		await waitFor(() =>
			expect(mutate).toHaveBeenCalledWith({
				mutation: CHECK_IN_ENROLLMENT,
				variables: { eventId: "evt-1", code: "999999", method: "manual" },
			}),
		);
	});

	it("业务错误码 → 文案（已核销 / 押金已结算 / 无效码 / 无权限 / 会话过期 / 网络异常）", async () => {
		// 六态：四种 payload code、顶层 unauthorized（会话过期）、网络类 throw
		const cases: { label: string; expected: string; mock: () => void }[] = [
			{
				label: "attendance_already_checked_in",
				expected: "该报名已核销，无需重复核销。",
				mock: () =>
					mutate.mockResolvedValueOnce(
						errorPayload("attendance_already_checked_in"),
					),
			},
			{
				label: "deposit_already_forfeited",
				expected: "该报名的押金已按未到场结算（不退），无法再核销。",
				mock: () =>
					mutate.mockResolvedValueOnce(
						errorPayload("deposit_already_forfeited"),
					),
			},
			{
				label: "attendance_invalid_code",
				expected: "核销码无效或与本场活动不匹配，请让参与者重新出示。",
				mock: () =>
					mutate.mockResolvedValueOnce(errorPayload("attendance_invalid_code")),
			},
			{
				label: "forbidden",
				expected: "你没有执行该操作的权限。",
				mock: () => mutate.mockResolvedValueOnce(errorPayload("forbidden")),
			},
			{
				label: "unauthorized（顶层错误）",
				expected: "登录状态已失效，请重新登录后再核销。",
				mock: () => mutate.mockRejectedValueOnce(new Error("unauthorized")),
			},
			{
				label: "网络异常",
				expected: "网络异常，未收到核销结果，请重试。",
				mock: () => mutate.mockRejectedValueOnce(new Error("socket hang up")),
			},
		];

		for (const testCase of cases) {
			cleanup();
			vi.clearAllMocks();
			useAuthed.mockReturnValue({
				authed: true,
				confirmed: true,
				userId: "u-mod",
			});
			usePathname.mockReturnValue("/events/deposit-hackathon/check-in");
			fetchPublicOffering.mockResolvedValue(EVENT);
			testCase.mock();

			renderPage({ code: "123456" });
			await submitForm();

			const alert = await screen.findByTestId("check-in-error");
			expect(alert.textContent, testCase.label).toBe(testCase.expected);
			// 失败后按钮回到可点（可重试），不残留禁止态
			expect(screen.getByTestId("check-in-submit")).toBeEnabled();
		}
	});

	it("网络类失败可重试：第二次提交成功", async () => {
		mutate.mockRejectedValueOnce(new Error("network down"));
		renderPage({ code: "123456" });
		await submitForm();

		expect(await screen.findByTestId("check-in-error")).toHaveTextContent(
			"网络异常，未收到核销结果，请重试。",
		);

		await submitForm();

		expect(await screen.findByTestId("check-in-success")).toBeInTheDocument();
		expect(mutate).toHaveBeenCalledTimes(2);
	});

	it("提交中：按钮禁用且重渲染不重复提交（防连点）", async () => {
		const gate = Promise.withResolvers<unknown>();
		mutate.mockReturnValueOnce(gate.promise);
		renderPage({ code: "123456" });
		await submitForm();

		const button = screen.getByTestId("check-in-submit");
		await waitFor(() => expect(button).toBeDisabled());
		expect(button).toHaveTextContent("核销中…");
		fireEvent.click(button);
		expect(mutate).toHaveBeenCalledTimes(1);

		gate.resolve(SUCCESS);
		expect(await screen.findByTestId("check-in-success")).toBeInTheDocument();
	});

	it("URL 码为空 → 本地提示，不发 mutation", async () => {
		renderPage();
		await screen.findByTestId("check-in-code-input");
		await submitForm();

		expect(await screen.findByTestId("check-in-hint")).toHaveTextContent(
			"请输入 6 位核销码。",
		);
		expect(mutate).not.toHaveBeenCalled();
	});

	it("手输非 6 位数字 → 本地提示，不发 mutation", async () => {
		renderPage();
		const input = await screen.findByTestId("check-in-code-input");
		fireEvent.change(input, { target: { value: "12ab" } });
		await submitForm();

		expect(await screen.findByTestId("check-in-hint")).toHaveTextContent(
			"核销码为 6 位数字，请核对后重试。",
		);
		expect(mutate).not.toHaveBeenCalled();
	});

	it("URL 码格式非法 → 提示改手输，不预填垃圾值、不提交", async () => {
		renderPage({ code: "abc" });

		expect(await screen.findByTestId("check-in-hint")).toHaveTextContent(
			"链接里的核销码格式不对，请手动输入 6 位核销码。",
		);
		expect(screen.getByTestId("check-in-code-input")).toHaveValue("");
		await submitForm();
		expect(mutate).not.toHaveBeenCalled();
	});

	it("未登录：先登录（next 回带本页与码），不渲染提交按钮", async () => {
		useAuthed.mockReturnValue({ authed: false, confirmed: true, userId: null });
		renderPage({ code: "123456" });

		const login = await screen.findByRole("link", { name: "登录后核销" });
		expect(login.getAttribute("href")).toBe(
			"/login?next=%2Fevents%2Fdeposit-hackathon%2Fcheck-in%3Fcode%3D123456",
		);
		expect(screen.queryByTestId("check-in-submit")).not.toBeInTheDocument();
	});

	it("路段解析不到 → 场次不可访问提示（不渲染表单）", async () => {
		fetchPublicOffering.mockResolvedValueOnce(null);
		renderPage({ code: "123456" });

		expect(await screen.findByRole("alert")).toHaveTextContent(
			"场次不存在或不可访问",
		);
		expect(screen.queryByTestId("check-in-submit")).not.toBeInTheDocument();
	});

	it("场次解析网络失败 → 可重试，重试后渲染表单", async () => {
		fetchPublicOffering.mockRejectedValueOnce(new Error("boom"));
		renderPage({ code: "123456" });

		expect(await screen.findByRole("alert")).toHaveTextContent(
			"场次信息加载失败。",
		);
		fetchPublicOffering.mockResolvedValueOnce(EVENT);
		fireEvent.click(screen.getByRole("button", { name: "重试" }));

		expect(await screen.findByTestId("check-in-submit")).toBeInTheDocument();
	});
});
