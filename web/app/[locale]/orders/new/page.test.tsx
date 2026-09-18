import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, fireEvent, screen, waitFor } from "@testing-library/react";
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

	describe("/orders/new 押金披露门（#696）", () => {
		// 守卫 + 可达性证据合一：修复前（无披露门）此用例的「零创单」断言必红
		// ——押金 payment_pending 报名点「前往支付」直接 CREATE_ORDER；修复后绿。
		const mockDepositEnrollment = (overrides: Record<string, unknown> = {}) => {
			client.query.mockResolvedValueOnce({
				data: {
					myEnrollments: {
						results: [
							{
								id: "enr-1",
								status: "payment_pending",
								paymentMode: "deposit",
								depositAmountCents: 6900,
								...overrides,
							},
						],
					},
				},
			});
			client.query.mockResolvedValueOnce({
				data: { myOrders: { results: [] } },
			});
		};

		it("押金报名：披露+勾选出现，未勾选「前往支付」禁用、点按零创单（T1）", async () => {
			mockDepositEnrollment();

			render(<NewOrderPage />);

			expect(await screen.findByTestId("deposit-note")).toBeInTheDocument();
			expect(screen.getByText("押金 ¥69（到场退）")).toBeInTheDocument();
			expect(screen.getByText("未到场不退。")).toBeInTheDocument();
			expect(screen.getByTestId("deposit-consent")).toBeInTheDocument();
			expect(screen.getByTestId("create-order")).toBeDisabled();

			fireEvent.click(screen.getByTestId("create-order"));
			expect(client.mutate).not.toHaveBeenCalled();
		});

		it("押金报名：勾选同意 → 放行创单并跳订单页（T2）", async () => {
			mockDepositEnrollment();
			client.mutate.mockResolvedValueOnce({
				data: {
					createOrder: { result: { id: "order-1" }, errors: [], metadata: null },
				},
			});

			render(<NewOrderPage />);

			await screen.findByTestId("deposit-note");
			fireEvent.click(screen.getByTestId("deposit-consent-checkbox"));
			expect(screen.getByTestId("create-order")).toBeEnabled();

			fireEvent.click(screen.getByTestId("create-order"));
			await waitFor(() => expect(client.mutate).toHaveBeenCalledTimes(1));
			// #727：押金单创单必须携带同意标记（后端权威闸）
			expect(client.mutate).toHaveBeenCalledWith(
				expect.objectContaining({
					variables: {
						input: {
							enrollmentId: "enr-1",
							provider: "wechat_native",
							depositConsent: true,
						},
					},
				}),
			);
			await waitFor(() =>
				expect(routerMocks.replace).toHaveBeenCalledWith("/orders/order-1"),
			);
		});

		it("非押金场：创单不带 depositConsent 键（现状零改动，T3/T4 载荷面）", async () => {
			client.query.mockResolvedValueOnce({
				data: {
					myEnrollments: {
						results: [
							{ id: "enr-1", status: "payment_pending", paymentMode: "pricing" },
						],
					},
				},
			});
			client.query.mockResolvedValueOnce({ data: { myOrders: { results: [] } } });
			client.mutate.mockResolvedValueOnce({
				data: {
					createOrder: { result: { id: "order-1" }, errors: [], metadata: null },
				},
			});

			render(<NewOrderPage />);

			await screen.findByTestId("order-new");
			fireEvent.click(screen.getByTestId("create-order"));
			await waitFor(() => expect(client.mutate).toHaveBeenCalledTimes(1));
			expect(client.mutate).toHaveBeenCalledWith(
				expect.objectContaining({
					variables: {
						input: { enrollmentId: "enr-1", provider: "wechat_native" },
					},
				}),
			);
		});

		it("守卫失败 → 后端拒单（order_deposit_consent_required）→ 自愈补门 + 重跑守卫（#727）", async () => {
			// 第一次守卫查询 reject（既有「不阻塞下单」兜底）→ 本页押金事实缺失
			client.query.mockRejectedValueOnce(new Error("guard down"));
			// 自愈重跑守卫：拿到押金快照
			mockDepositEnrollment();
			client.mutate
				.mockResolvedValueOnce({
					data: {
						createOrder: {
							result: null,
							errors: [
								{
									code: "order_deposit_consent_required",
									message:
										"deposit consent is required before creating a deposit order",
								},
							],
							metadata: null,
						},
					},
				})
				.mockResolvedValueOnce({
					data: {
						createOrder: { result: { id: "order-1" }, errors: [], metadata: null },
					},
				});

			render(<NewOrderPage />);

			await screen.findByTestId("order-new");
			expect(screen.queryByTestId("deposit-consent")).not.toBeInTheDocument();

			// 第一次创单：不带 consent（守卫失败 → 按非押金处理）
			fireEvent.click(screen.getByTestId("create-order"));
			await waitFor(() => expect(client.mutate).toHaveBeenCalledTimes(1));
			expect(client.mutate).toHaveBeenLastCalledWith(
				expect.objectContaining({
					variables: {
						input: { enrollmentId: "enr-1", provider: "wechat_native" },
					},
				}),
			);

			// 自愈：披露块 + 勾选出现（金额 = 重跑守卫拿到的快照），未勾选仍禁用
			// （金额断言用 findByText：重跑守卫是异步的，先出块再补快照金额）
			expect(await screen.findByTestId("deposit-note")).toBeInTheDocument();
			expect(await screen.findByText("押金 ¥69（到场退）")).toBeInTheDocument();
			expect(screen.getByTestId("create-order")).toBeDisabled();

			fireEvent.click(screen.getByTestId("deposit-consent-checkbox"));
			fireEvent.click(screen.getByTestId("create-order"));
			await waitFor(() => expect(client.mutate).toHaveBeenCalledTimes(2));
			expect(client.mutate).toHaveBeenLastCalledWith(
				expect.objectContaining({
					variables: {
						input: {
							enrollmentId: "enr-1",
							provider: "wechat_native",
							depositConsent: true,
						},
					},
				}),
			);
			await waitFor(() =>
				expect(routerMocks.replace).toHaveBeenCalledWith("/orders/order-1"),
			);
		});

		it.each([
			["pricing", "定价场"],
			["free", "免费场"],
		])(
			"%s 报名 → 不出现勾选态，直接可下单（T3/T4 回归：现状不坏）",
			async (mode) => {
				client.query.mockResolvedValueOnce({
					data: {
						myEnrollments: {
							results: [
								{ id: "enr-1", status: "payment_pending", paymentMode: mode },
							],
						},
					},
				});
				client.query.mockResolvedValueOnce({
					data: { myOrders: { results: [] } },
				});

				render(<NewOrderPage />);

				await screen.findByTestId("order-new");
				expect(screen.queryByTestId("deposit-note")).not.toBeInTheDocument();
				expect(screen.queryByTestId("deposit-consent")).not.toBeInTheDocument();
				expect(screen.getByTestId("create-order")).toBeEnabled();
			},
		);

		// #675/#686 口径：识别按 paymentMode 存在性，金额纯表态——脏快照（缺失/
		// 0/负/非整数分）门照常出现、文案「押金（金额待定）」，绝不显示 ¥0
		it.each([["null", null], ["0", 0], ["-1", -1], ["6900.5", 6900.5]])(
			"押金报名 + 脏快照（%s）→ 门照常、金额待定、refute ¥0（T5）",
			async (_label, dirty) => {
				mockDepositEnrollment({ depositAmountCents: dirty });

				render(<NewOrderPage />);

				expect(await screen.findByTestId("deposit-note")).toBeInTheDocument();
				expect(screen.getByText("押金（金额待定）")).toBeInTheDocument();
				expect(screen.queryByText(/¥0/)).not.toBeInTheDocument();
				expect(screen.getByTestId("create-order")).toBeDisabled();
			},
		);
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
