import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, screen, fireEvent, waitFor } from "@testing-library/react";
import { render } from "@/test-utils";
import OfferingPaymentsPanel from "./offering-payments-panel";

const { client } = vi.hoisted(() => ({ client: { query: vi.fn(), mutate: vi.fn() } }));

vi.mock("@/lib/payment-errors", async () => {
	const messages = (await import("../messages/zh-CN.json")).default;
	const errors = messages.errors as Record<string, string>;
	const translate = (code: string | null | undefined, fallback: string): string =>
		!code ? fallback : (errors[code] ?? fallback);
	return {
		usePaymentErrorTranslator: () => translate,
	};
});
vi.mock("@/lib/apollo-client", () => ({ client }));

const baseOrder = {
	id: "o1",
	enrollmentId: "e1",
	provider: "wechat_native",
	outTradeNo: "oto-1",
	transactionId: null,
	amountCents: 19900,
	status: "paid",
	expireAt: "2026-08-16T12:00:00Z",
	refundedAt: null,
	cancelReason: null,
	tierName: "标准档",
	enrollmentStatus: "confirmed",
	learnerEmail: "learner@example.com",
};

function ordersPayload(results: unknown[]) {
	return { data: { workspaceOrders: { results, count: results.length } } };
}

function statsPayload(collected: number, pending: number, refunded: number, refundFailed = 0) {
	return {
		data: {
			workspacePaymentStats: JSON.stringify({
				collected_cents: collected,
				pending_cents: pending,
				refunded_cents: refunded,
				refund_failed_cents: refundFailed,
			}),
		},
	};
}

/** 第 index 次 client.mutate 调用的 mutation 文档名（区分两段：RetryRefund vs ConfirmOperation） */
function mutationName(index: number): string | undefined {
	const args = client.mutate.mock.calls[index][0] as {
		mutation: { definitions: Array<{ name?: { value: string } }> };
	};
	return args.mutation.definitions[0]?.name?.value;
}

beforeEach(() => {
	vi.clearAllMocks();
});

afterEach(cleanup);

describe("OfferingPaymentsPanel 活动经营面（U7，R5-R7，AE6）", () => {
	it("AE6：manage 用户见面板；非 manage 不渲染", () => {
		const { rerender } = render(
			<OfferingPaymentsPanel
				workspaceId="ws-1"
				offeringId="ev-1"
				kind="event"
				manage={false}
				pricingEnabled
			/>,
		);

		expect(screen.queryByTestId("offering-payments-panel")).not.toBeInTheDocument();
		expect(client.query).not.toHaveBeenCalled();

		rerender(
			<OfferingPaymentsPanel
				workspaceId="ws-1"
				offeringId="ev-1"
				kind="event"
				manage
				pricingEnabled
			/>,
		);

		expect(screen.getByTestId("offering-payments-panel")).toBeInTheDocument();
	});

	it("取数带 offering 筛选：订单查询带 eventId，stats 带 eventId", async () => {
		client.query
			.mockReturnValueOnce(ordersPayload([{ ...baseOrder }]))
			.mockReturnValueOnce(statsPayload(19900, 0, 0));

		render(
			<OfferingPaymentsPanel
				workspaceId="ws-1"
				offeringId="ev-1"
				kind="event"
				manage
				pricingEnabled
			/>,
		);

		// 初拉顺序：load(orders) → loadStats（面板 useEffect 内固定顺序）；
		// 默认视图 = 非终态 + 已退款（R6，终态经状态筛选可见）
		expect(client.query.mock.calls[0][0].variables).toEqual({
			workspaceId: "ws-1",
			filter: {
				eventId: { eq: "ev-1" },
				status: {
					in: ["pending", "paid", "refunding", "refund_failed", "refunded"],
				},
			},
			first: 20,
		});

		expect(client.query.mock.calls[1][0].variables).toEqual({
			workspaceId: "ws-1",
			eventId: "ev-1",
		});
	});

	it("U7 keyset 分页：满页显示加载更多，点击带 after 追加；短页隐藏", async () => {
		const page1 = Array.from({ length: 20 }, (_, i) => ({
			...baseOrder,
			id: `p1-${i}`,
		}));
		const page2 = [{ ...baseOrder, id: "p2-0" }];

		client.query
			.mockImplementationOnce(() => ({
				data: {
					workspaceOrders: {
						results: page1,
						count: 21,
						startKeyset: "ks-0",
						endKeyset: "ks-19",
					},
				},
			}))
			.mockImplementationOnce(() => statsPayload(0, 0, 0))
			.mockImplementationOnce(() => ({
				data: {
					workspaceOrders: {
						results: page2,
						count: 21,
						startKeyset: "ks-19",
						endKeyset: "ks-20",
					},
				},
			}));

		render(
			<OfferingPaymentsPanel
				workspaceId="ws-1"
				offeringId="ev-1"
				kind="event"
				manage
				pricingEnabled
			/>,
		);

		expect(await screen.findByTestId("order-row-p1-19")).toBeInTheDocument();
		const loadMore = screen.getByTestId("offering-load-more");
		expect(loadMore).toBeInTheDocument();

		fireEvent.click(loadMore);

		await screen.findByTestId("order-row-p2-0");
		expect(client.query.mock.calls[2][0].variables).toMatchObject({
			after: "ks-19",
			first: 20,
		});
		// 短页（1 < 20）：加载更多隐藏
		expect(screen.queryByTestId("offering-load-more")).not.toBeInTheDocument();
	});

	it("R7：refund_failed 行重试两段确认——首调建 pending 透传摘要，确认后 confirmOperation 并刷新", async () => {
		const failed = { ...baseOrder, id: "o-failed", status: "refund_failed" };
		client.query
			.mockReturnValueOnce(ordersPayload([failed]))
			.mockReturnValueOnce(statsPayload(0, 0, 0, 19900))
			.mockReturnValueOnce(ordersPayload([{ ...failed, status: "refunding" }]))
			.mockReturnValueOnce(statsPayload(0, 0, 0, 0));
		client.mutate
			.mockResolvedValueOnce({
				data: {
					retryRefund: {
						pendingId: "p-r1",
						summary: "重试退款 ¥199.00（渠道 wechat_native）：refund_failed → refunding，重新入队渠道退款",
						errors: [],
					},
				},
			})
			.mockResolvedValueOnce({
				data: { confirmOperation: { pendingId: "p-r1", status: "confirmed", errors: [] } },
			});

		render(
			<OfferingPaymentsPanel
				workspaceId="ws-1"
				offeringId="co-1"
				kind="course"
				manage
				pricingEnabled
			/>,
		);

		// 第一段：点重试即建 pending，弹层透传后端摘要
		fireEvent.click(await screen.findByTestId("offering-retry-o-failed"));

		expect(await screen.findByTestId("offering-op-summary")).toHaveTextContent("重试退款");
		expect(client.mutate).toHaveBeenCalledTimes(1);
		expect(client.mutate.mock.calls[0][0].variables).toEqual({ id: "o-failed" });
		expect(mutationName(0)).toBe("RetryRefund");

		// 第二段：确认 → confirmOperation(pendingId)
		fireEvent.click(screen.getByTestId("offering-op-confirm"));

		await waitFor(() => expect(client.mutate).toHaveBeenCalledTimes(2));
		expect(client.mutate.mock.calls[1][0].variables).toEqual({ pendingId: "p-r1" });
		expect(mutationName(1)).toBe("ConfirmOperation");

		// 刷新：orders 再次查询
		await waitFor(() => expect(client.query.mock.calls.length).toBe(4));
	});

	it("R7：paid 行退款同款两段——offering-refund 建 pending，op-confirm 执行并刷新", async () => {
		client.query
			.mockReturnValueOnce(ordersPayload([{ ...baseOrder }]))
			.mockReturnValueOnce(statsPayload(19900, 0, 0))
			.mockReturnValueOnce(ordersPayload([{ ...baseOrder, status: "refunding" }]))
			.mockReturnValueOnce(statsPayload(0, 0, 19900));
		client.mutate
			.mockResolvedValueOnce({
				data: {
					refundOrder: {
						pendingId: "p-f1",
						summary: "退款 ¥199.00（渠道 wechat_native）：…此操作不可恢复",
						errors: [],
					},
				},
			})
			.mockResolvedValueOnce({
				data: { confirmOperation: { pendingId: "p-f1", status: "confirmed", errors: [] } },
			});

		render(
			<OfferingPaymentsPanel
				workspaceId="ws-1"
				offeringId="ev-1"
				kind="event"
				manage
				pricingEnabled
			/>,
		);

		fireEvent.click(await screen.findByTestId("offering-refund-o1"));

		expect(await screen.findByTestId("offering-op-summary")).toHaveTextContent("退款 ¥199.00");
		expect(client.mutate.mock.calls[0][0].variables).toEqual({ id: "o1" });
		expect(mutationName(0)).toBe("RefundOrder");

		fireEvent.click(screen.getByTestId("offering-op-confirm"));

		await waitFor(() => expect(client.mutate).toHaveBeenCalledTimes(2));
		expect(client.mutate.mock.calls[1][0].variables).toEqual({ pendingId: "p-f1" });
		await waitFor(() => expect(client.query.mock.calls.length).toBe(4));
	});

	it("AE4/F13：免费活动无订单 → 一行免费状态；有已付历史 → 完整面板可退款", async () => {
		// 无订单：收敛一行免费态
		client.query
			.mockResolvedValueOnce(ordersPayload([]))
			.mockResolvedValueOnce(statsPayload(0, 0, 0));

		render(
			<OfferingPaymentsPanel
				workspaceId="ws-1"
				offeringId="ev-1"
				kind="event"
				manage
				pricingEnabled={false}
			/>,
		);

		expect(await screen.findByTestId("offering-free-status")).toBeInTheDocument();

		// F13：免费态但有已付订单（关闭收费故意保留）→ 完整面板（退款可操作）
		cleanup();
		client.query
			.mockReset()
			.mockResolvedValueOnce(ordersPayload([{ ...baseOrder }]))
			.mockResolvedValueOnce(statsPayload(19900, 0, 0));

		render(
			<OfferingPaymentsPanel
				workspaceId="ws-1"
				offeringId="ev-2"
				kind="event"
				manage
				pricingEnabled={false}
			/>,
		);

		expect(await screen.findByTestId(`offering-refund-${baseOrder.id}`)).toBeInTheDocument();
		expect(screen.queryByTestId("offering-free-status")).not.toBeInTheDocument();
	});
});
