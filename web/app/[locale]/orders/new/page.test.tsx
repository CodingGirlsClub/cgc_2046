import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, screen, waitFor } from "@testing-library/react";
import { render } from "@/test-utils";
import NewOrderPage from "./page";

const { client } = vi.hoisted(() => ({ client: { query: vi.fn(), mutate: vi.fn() } }));
const { useAuthed } = vi.hoisted(() => ({ useAuthed: vi.fn() }));
const { routerMocks } = vi.hoisted(() => ({ routerMocks: { replace: vi.fn(), push: vi.fn() } }));

// i18n Phase 3：payment-errors 表迁 messages errors namespace；测试环境无
// NextIntlClientProvider，mock 同语义的 zh-CN translator（真实迁移语义在
// lib/payment-errors.test.tsx 以 provider 覆盖）
vi.mock("@/lib/payment-errors", async () => {
	const messages = (await import("../../../../messages/zh-CN.json")).default;
	const errors = messages.errors as Record<string, string>;
	const translate = (code: string | null | undefined, fallback: string): string =>
		!code ? fallback : (errors[code] ?? fallback);
	return {
		// 稳定引用：组件 useCallback 依赖它，逐渲染新建会破坏轮询/守卫时序
		usePaymentErrorTranslator: () => translate,
	};
});
vi.mock("@/lib/apollo-client", () => ({ client }));
vi.mock("@/lib/use-authed", () => ({ useAuthed }));
vi.mock("next/navigation", () => ({
	redirect: vi.fn(),
	permanentRedirect: vi.fn(),
	useSearchParams: () => new URLSearchParams("enrollmentId=enr-1"),
	useRouter: () => routerMocks,
	usePathname: () => "/orders/new",
}));

beforeEach(() => {
	vi.clearAllMocks();
	useAuthed.mockReturnValue({ authed: true, confirmed: true, userId: "u1" });
});

afterEach(cleanup);

describe("/orders/new 进页守卫（支付接续）", () => {
	it("报名非 payment_pending → 引导卡，不渲染渠道表单", async () => {
		client.query.mockResolvedValueOnce({
			data: { myEnrollments: { results: [{ id: "enr-1", status: "confirmed" }] } },
		});

		render(<NewOrderPage />);

		expect(await screen.findByTestId("order-guard-blocked")).toBeInTheDocument();
		expect(screen.getByText(/报名已取消或已支付/)).toBeInTheDocument();
		expect(screen.getByTestId("order-guard-to-participations")).toHaveAttribute(
			"href",
			"/participations",
		);
		expect(screen.queryByTestId("order-new")).not.toBeInTheDocument();
		expect(client.mutate).not.toHaveBeenCalled();
	});

	it("报名不存在 → 引导卡（同 blocked 分支）", async () => {
		client.query.mockResolvedValueOnce({ data: { myEnrollments: { results: [] } } });

		render(<NewOrderPage />);

		expect(await screen.findByTestId("order-guard-blocked")).toBeInTheDocument();
		expect(screen.queryByTestId("order-new")).not.toBeInTheDocument();
	});

	it("payment_pending 且已有 pending 订单 → 直接跳已有订单页，不渲染表单", async () => {
		client.query.mockResolvedValueOnce({
			data: { myEnrollments: { results: [{ id: "enr-1", status: "payment_pending" }] } },
		});
		client.query.mockResolvedValueOnce({
			data: { myOrders: { results: [{ id: "order-9" }] } },
		});

		render(<NewOrderPage />);

		await waitFor(() =>
			expect(routerMocks.replace).toHaveBeenCalledWith("/orders/order-9"),
		);
		expect(screen.queryByTestId("order-new")).not.toBeInTheDocument();
	});

	it("payment_pending 且无进行中订单 → 渲染渠道表单", async () => {
		client.query.mockResolvedValueOnce({
			data: { myEnrollments: { results: [{ id: "enr-1", status: "payment_pending" }] } },
		});
		client.query.mockResolvedValueOnce({
			data: { myOrders: { results: [] } },
		});

		render(<NewOrderPage />);

		expect(await screen.findByTestId("order-new")).toBeInTheDocument();
		expect(routerMocks.replace).not.toHaveBeenCalled();
	});

	it("未签约渠道灰置：alipay_page/alipay_wap radio disabled + 未开通角标", async () => {
		client.query.mockResolvedValueOnce({
			data: { myEnrollments: { results: [{ id: "enr-1", status: "payment_pending" }] } },
		});
		client.query.mockResolvedValueOnce({
			data: { myOrders: { results: [] } },
		});

		render(<NewOrderPage />);

		await screen.findByTestId("order-new");
		expect(screen.getByTestId("provider-alipay_page")).toHaveTextContent("未开通");
		expect(screen.getByTestId("provider-alipay_wap")).toHaveTextContent("未开通");
		expect(screen.getByTestId("provider-alipay_page").querySelector("input")).toBeDisabled();
		expect(screen.getByTestId("provider-alipay_wap").querySelector("input")).toBeDisabled();
		expect(screen.getByTestId("provider-wechat_native").querySelector("input")).toBeEnabled();
		expect(screen.getByTestId("provider-alipay_qr").querySelector("input")).toBeEnabled();
	});
});
