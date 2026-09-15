import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, screen, waitFor } from "@testing-library/react";
import { render } from "@/test-utils";
import CheckInPage from "./page";
import { CHECK_IN_ENROLLMENT } from "@/lib/graphql/attendance";

const { useParams } = vi.hoisted(() => ({ useParams: vi.fn() }));
// IO 边界（apollo client / workspace 解析 hook）用 mock；lib/check-in 的归一与
// 读取走真实实现（页面本地校验行为就是本单测的守卫对象）
const { mutate, query, useWorkspaceBySlug } = vi.hoisted(() => ({
	mutate: vi.fn(),
	query: vi.fn(),
	useWorkspaceBySlug: vi.fn(),
}));

vi.mock("next/navigation", () => ({
	redirect: vi.fn(),
	permanentRedirect: vi.fn(),
	useParams,
	// ThemeProvider 依赖 usePathname 解析 workspace slug（ADR-0004）
	usePathname: vi.fn(() => "/w/cgc-academy/events/evt-1/check-in"),
}));
vi.mock("@/lib/apollo-client", () => ({ client: { mutate, query } }));
vi.mock("@/lib/use-workspace-by-slug", () => ({ useWorkspaceBySlug }));
// 壳的成员强制/未认证重定向由 WorkspaceShell 自身测试承担；本文件守卫面板行为
vi.mock("@/components/workspace-shell", () => ({
	default: ({ children }: { children: React.ReactNode }) => <>{children}</>,
}));

const EVENT = {
	id: "evt-1",
	title: "押金制黑客松",
	depositEnabled: true,
};

const MEMBER_WS = {
	id: "ws-1",
	slug: "cgc-academy",
	name: "CGC 线上学院",
	myRoleNames: ["owner"],
	myAbilities: ["view_workspace", "manage_events"],
};

// 后端手写 payload 是扁平形状（enrollmentId/checkedInAt/method/errors），
// 不是 AshGraphql 生成 mutation 的 {result, errors} 信封。
const SUCCESS = {
	data: {
		checkInEnrollment: {
			enrollmentId: "enr-1",
			checkedInAt: "2026-09-14T02:00:00Z",
			method: "manual",
			depositRefund: "refunding",
			errors: [],
		},
	},
};

function renderPage() {
	useParams.mockReturnValue({ slug: "cgc-academy", id: "evt-1" });
	useWorkspaceBySlug.mockReturnValue({
		ws: MEMBER_WS,
		loading: false,
		readOnlyVisitor: false,
	});
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

async function submitCode(value: string) {
	fireEvent.change(await screen.findByTestId("check-in-code-input"), {
		target: { value },
	});
	fireEvent.click(screen.getByTestId("check-in-submit"));
}

describe("工作台壳内核验页（#559）", () => {
	beforeEach(() => {
		vi.clearAllMocks();
		query.mockResolvedValue({ data: { getEvent: EVENT } });
		mutate.mockResolvedValue(SUCCESS);
	});

	afterEach(() => cleanup());

	it("成员读面成功：显示标题；手输 6 位码提交成功（manual）并显示押金退款说明", async () => {
		renderPage();

		// 标题在面包屑与 h1 各出现一次——断言 h1 那一处
		expect(
			await screen.findByRole("heading", { name: "押金制黑客松" }),
		).toBeInTheDocument();
		await submitCode("042 317");

		await waitFor(() =>
			expect(screen.getByTestId("check-in-success")).toBeInTheDocument(),
		);
		// 归一剥空白后提交；web 页恒为 manual（扫码主路径在小程序）
		expect(mutate).toHaveBeenCalledWith(
			expect.objectContaining({
				mutation: CHECK_IN_ENROLLMENT,
				variables: { eventId: "evt-1", code: "042317", method: "manual" },
			}),
		);
		expect(screen.getByTestId("check-in-success")).toHaveTextContent(
			/押金退款已发起/,
		);
	});

	it("closed 活动成员可读：读面返回 closed 场次 → 进页可提交（#552 正面回归）", async () => {
		query.mockResolvedValue({
			data: { getEvent: { ...EVENT, status: "closed" } },
		});
		renderPage();

		expect(
			await screen.findByRole("heading", { name: "押金制黑客松" }),
		).toBeInTheDocument();
		await submitCode("042317");

		await waitFor(() =>
			expect(screen.getByTestId("check-in-success")).toBeInTheDocument(),
		);
	});

	it("读面失败（网络/权限）：标题兜底 + 表单可用，提交照发（授权在 mutation）", async () => {
		query.mockRejectedValue(new Error("network down"));
		renderPage();

		// 通用标题兜底，表单不等读面
		expect(
			await screen.findByTestId("check-in-code-input"),
		).toBeInTheDocument();
		await submitCode("042317");

		await waitFor(() =>
			expect(screen.getByTestId("check-in-success")).toBeInTheDocument(),
		);
	});

	it("同码再提交：后端回已核销 → 显示「已核销」（码留输入框）", async () => {
		mutate.mockResolvedValueOnce(SUCCESS);
		renderPage();
		await submitCode("042317");
		await waitFor(() =>
			expect(screen.getByTestId("check-in-success")).toBeInTheDocument(),
		);

		mutate.mockResolvedValueOnce(errorPayload("attendance_already_checked_in"));
		fireEvent.click(screen.getByTestId("check-in-submit"));

		expect(await screen.findByTestId("check-in-error")).toHaveTextContent(
			/已核销/,
		);
		expect(screen.getByTestId("check-in-code-input")).toHaveValue("042317");
	});

	it("该报名无押金单（免费/定价/存量报名）：成功卡不出现押金退款文案", async () => {
		mutate.mockResolvedValue({
			data: {
				checkInEnrollment: { ...SUCCESS.data.checkInEnrollment, depositRefund: null },
			},
		});
		renderPage();
		await submitCode("042317");

		await waitFor(() =>
			expect(screen.getByTestId("check-in-success")).toBeInTheDocument(),
		);
		expect(screen.queryByText(/押金退款已发起/)).not.toBeInTheDocument();
	});

	it("押金场（depositEnabled: true）：现场提示含押金退还承诺", async () => {
		renderPage();
		expect(
			await screen.findByText(/押金将立即全额退还/),
		).toBeInTheDocument();
	});

	it.each([false, null])(
		"非押金场 / 旗标未知（depositEnabled: %s）：只显示通用不可撤销提示，不承诺押金退还",
		async (depositEnabled) => {
			query.mockResolvedValue({
				data: { getEvent: { ...EVENT, depositEnabled } },
			});
			renderPage();
			// 等场次读面落地（标题出现）后再断言押金文案始终缺席
			expect(
				await screen.findByRole("heading", { name: "押金制黑客松" }),
			).toBeInTheDocument();
			expect(screen.getByText(/核销后不可撤销/)).toBeInTheDocument();
			expect(
				screen.queryByText(/押金将立即全额退还/),
			).not.toBeInTheDocument();
		},
	);

	it("业务错误码 → 文案（已核销 / 押金已结算 / 无效码 / 无权限 / 会话过期 / 网络异常）", async () => {
		const cases: Array<{ code?: string; reject?: Error; expected: RegExp }> = [
			{ code: "attendance_already_checked_in", expected: /已核销/ },
			{ code: "deposit_already_forfeited", expected: /未到场结算/ },
			{ code: "attendance_invalid_code", expected: /核销码无效/ },
			{ code: "forbidden", expected: /没有执行该操作的权限/ },
			{ reject: new Error("unauthorized"), expected: /登录状态已失效/ },
			{ reject: new Error("fetch failed"), expected: /网络/ },
		];
		for (const item of cases) {
			cleanup();
			vi.clearAllMocks();
			query.mockResolvedValue({ data: { getEvent: EVENT } });
			if (item.reject) mutate.mockRejectedValue(item.reject);
			else mutate.mockResolvedValue(errorPayload(item.code!));

			renderPage();
			await submitCode("042317");

			expect(await screen.findByTestId("check-in-error")).toHaveTextContent(
				item.expected,
			);
		}
	});

	it("网络类失败可重试：第二次提交成功", async () => {
		mutate.mockRejectedValueOnce(new Error("fetch failed"));
		renderPage();
		await submitCode("042317");
		expect(await screen.findByTestId("check-in-error")).toHaveTextContent(/网络/);

		fireEvent.click(screen.getByTestId("check-in-submit"));
		await waitFor(() =>
			expect(screen.getByTestId("check-in-success")).toBeInTheDocument(),
		);
	});

	it("提交中：按钮禁用且重渲染不重复提交（防连点）", async () => {
		let resolveMutate: (value: unknown) => void = () => {};
		mutate.mockImplementation(
			() => new Promise((resolve) => (resolveMutate = resolve)),
		);
		renderPage();
		await submitCode("042317");

		const button = screen.getByTestId("check-in-submit");
		expect(button).toBeDisabled();
		fireEvent.click(button);
		expect(mutate).toHaveBeenCalledTimes(1);

		resolveMutate(SUCCESS);
		await waitFor(() =>
			expect(screen.getByTestId("check-in-success")).toBeInTheDocument(),
		);
	});

	it("空码 / 非 6 位数字 → 本地提示，不发 mutation", async () => {
		renderPage();

		fireEvent.click(await screen.findByTestId("check-in-submit"));
		expect(await screen.findByTestId("check-in-hint")).toBeInTheDocument();
		expect(mutate).not.toHaveBeenCalled();

		await submitCode("12 34");
		expect(screen.getByTestId("check-in-hint")).toBeInTheDocument();
		expect(mutate).not.toHaveBeenCalled();
	});
});
