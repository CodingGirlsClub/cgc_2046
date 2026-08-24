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

		// 初拉顺序：load(orders) → loadStats（面板 useEffect 内固定顺序）
		expect(client.query.mock.calls[0][0].variables).toEqual({
			workspaceId: "ws-1",
			filter: { eventId: { eq: "ev-1" } },
		});

		expect(client.query.mock.calls[1][0].variables).toEqual({
			workspaceId: "ws-1",
			eventId: "ev-1",
		});
	});

	it("R7：refund_failed 行出现重试按钮，点击后 retryRefund 并刷新（此前无入口的回归对照）", async () => {
		const failed = { ...baseOrder, id: "o-failed", status: "refund_failed" };
		client.query
			.mockReturnValueOnce(ordersPayload([failed]))
			.mockReturnValueOnce(statsPayload(0, 0, 0, 19900))
			.mockReturnValueOnce(ordersPayload([{ ...failed, status: "refunding" }]))
			.mockReturnValueOnce(statsPayload(0, 0, 0, 0));
		client.mutate.mockResolvedValueOnce({
			data: { retryRefund: { result: { id: "o-failed", status: "refunding" }, errors: [] } },
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

		const retryButton = await screen.findByTestId("offering-retry-o-failed");
		expect(retryButton).toBeInTheDocument();

		fireEvent.click(retryButton);

		await waitFor(() => expect(client.mutate).toHaveBeenCalled());
		const mutateArgs = client.mutate.mock.calls[0][0] as {
			mutation: { definitions: Array<{ name?: { value: string } }> };
		};
		expect(mutateArgs.mutation.definitions[0]?.name?.value).toBe("RetryRefund");

		// 刷新：orders 再次查询（refunding 行可见）
		await waitFor(() => expect(client.query.mock.calls.length).toBe(4));
	});

	it("AE4：免费活动 → 一行免费状态，不拉订单查询", () => {
		render(
			<OfferingPaymentsPanel
				workspaceId="ws-1"
				offeringId="ev-1"
				kind="event"
				manage
				pricingEnabled={false}
			/>,
		);

		expect(screen.getByTestId("offering-free-status")).toBeInTheDocument();
		expect(client.query).not.toHaveBeenCalled();
	});
});
