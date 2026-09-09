import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, screen, fireEvent, waitFor } from "@testing-library/react";
import { render } from "@/test-utils";
import PaymentsManagement, { OrderStatusBadge, StatsCards } from "./payments-management";

const { client } = vi.hoisted(() => ({ client: { query: vi.fn(), mutate: vi.fn() } }));

// i18n Phase 3：payment-errors 表迁 messages errors namespace；测试环境无
// NextIntlClientProvider，mock 同语义的 zh-CN translator（真实迁移语义在
// lib/payment-errors.test.tsx 以 provider 覆盖）
vi.mock("@/lib/payment-errors", async () => {
	const messages = (await import("../messages/zh-CN.json")).default;
	const errors = messages.errors as Record<string, string>;
	const translate = (code: string | null | undefined, fallback: string): string =>
		!code ? fallback : (errors[code] ?? fallback);
	return {
		// 稳定引用：组件 useCallback 依赖它，逐渲染新建会破坏轮询/守卫时序
		usePaymentErrorTranslator: () => translate,
	};
});
vi.mock("@/lib/apollo-client", () => ({ client }));
vi.mock("@/lib/events", () => ({
	fetchWorkspaceOfferings: vi.fn().mockResolvedValue([]),
}));

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

/** 第 index 次 client.mutate 调用的 mutation 文档名（区分两段：RefundOrder vs ConfirmOperation） */
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

describe("OrderStatusBadge / StatsCards（U11 管理面）", () => {
	it("状态徽章词表与样式变体", () => {
		const { container, rerender } = render(<OrderStatusBadge status="paid" />);
		expect(screen.getByTestId("order-badge-paid")).toHaveTextContent("已支付");
		expect(container.firstElementChild?.className).toContain("emerald");

		rerender(<OrderStatusBadge status="refund_failed" />);
		expect(screen.getByTestId("order-badge-refund_failed")).toHaveTextContent("退款失败");
		expect(container.firstElementChild?.className).toContain("red");
	});

	it("统计卡四分量（含退款失败待处理）；null 时全 0，失败额非 0 红色强调", () => {
		const { rerender } = render(
			<StatsCards
				stats={{
					collectedCents: 59700,
					pendingCents: 19900,
					refundedCents: 19900,
					refundFailedCents: 9900,
				}}
				statsError={false}
				onRetryStats={() => undefined}
			/>,
		);
		expect(screen.getByTestId("stats-collected")).toHaveTextContent("¥597.00");
		expect(screen.getByTestId("stats-pending")).toHaveTextContent("¥199.00");
		expect(screen.getByTestId("stats-refunded")).toHaveTextContent("¥199.00");
		expect(screen.getByTestId("stats-refund-failed")).toHaveTextContent("¥99.00");
		// 失败额非 0：danger 强调类
		expect(screen.getByTestId("stats-refund-failed").querySelector("p:last-child")).toHaveClass("text-red-300");

		rerender(<StatsCards stats={null} statsError={false} onRetryStats={() => undefined} />);
		expect(screen.getByTestId("stats-collected")).toHaveTextContent("¥0.00");
		expect(screen.getByTestId("stats-refund-failed")).toHaveTextContent("¥0.00");
	});

	it("U2-R3：stats 加载失败 → 错误态 + 重试（不再伪装 ¥0.00）", () => {
		const retry = vi.fn();
		render(<StatsCards stats={null} statsError onRetryStats={retry} />);
		expect(screen.getByTestId("stats-error")).toHaveTextContent("统计加载失败");
		expect(screen.queryByTestId("stats-collected")).not.toBeInTheDocument();
		fireEvent.click(screen.getByTestId("stats-retry"));
		expect(retry).toHaveBeenCalledTimes(1);
	});
});

describe("PaymentsManagement（U11：列表/退款/免缴）", () => {
	it("列表渲染：报名人/档位/金额/渠道 + paid 徽章；退款与免缴按钮按条件显隐", async () => {
		client.query.mockImplementation((opts: { variables: { workspaceId: string } }) =>
			opts.variables.workspaceId === "ws1"
				? ordersPayload([
						baseOrder,
						{ ...baseOrder, id: "o2", status: "pending", enrollmentStatus: "payment_pending" },
						{ ...baseOrder, id: "o3", status: "expired", enrollmentStatus: "expired" },
					])
				: statsPayload(59700, 19900, 19900),
		);

		render(<PaymentsManagement workspaceId="ws1" manage />);

		expect(await screen.findByTestId("order-row-o1")).toBeInTheDocument();
		expect(screen.getAllByText("learner@example.com").length).toBe(3);
		expect(screen.getAllByText("标准档").length).toBe(3);
		expect(screen.getAllByText("¥199.00").length).toBeGreaterThan(0);

		// paid → 退款入口；pending + payment_pending 报名 → 免缴入口；expired 无操作
		expect(screen.getByTestId("refund-o1")).toBeInTheDocument();
		expect(screen.queryByTestId("refund-o2")).not.toBeInTheDocument();
		expect(screen.getByTestId("waive-o2")).toBeInTheDocument();
		expect(screen.queryByTestId("waive-o1")).not.toBeInTheDocument();
		expect(screen.queryByTestId("refund-o3")).not.toBeInTheDocument();
	});

	it("非管理（manage=false）：退款/免缴按钮全隐藏", async () => {
		client.query.mockImplementation((opts: { variables: { workspaceId: string } }) =>
			opts.variables.workspaceId === "ws1"
				? ordersPayload([{ ...baseOrder, enrollmentStatus: "payment_pending" }])
				: statsPayload(0, 0, 0),
		);

		render(<PaymentsManagement workspaceId="ws1" manage={false} />);

		await screen.findByTestId("order-row-o1");
		expect(screen.queryByTestId("refund-o1")).not.toBeInTheDocument();
		expect(screen.queryByTestId("waive-o1")).not.toBeInTheDocument();
	});

	it("退款后端两段确认：首调建 pending 透传摘要 → op-confirm 发 confirmOperation → 刷新", async () => {
		const paidOrder = ordersPayload([baseOrder]);
		const refunding = ordersPayload([{ ...baseOrder, status: "refunding" }]);

		client.query.mockImplementation((opts: { variables: { workspaceId: string } }) =>
			opts.variables.workspaceId === "ws1" ? paidOrder : statsPayload(59700, 0, 0),
		);

		render(<PaymentsManagement workspaceId="ws1" manage />);
		await screen.findByTestId("refund-o1");

		// 第一段：点退款即建 pending（不落业务库），弹层透传后端生成的摘要
		client.mutate.mockResolvedValueOnce({
			data: {
				refundOrder: {
					pendingId: "p1",
					summary: "退款 ¥199.00（渠道 wechat_native）：paid → refunding 并入队渠道退款，原路全额退回；退款即取消报名并释放名额，此操作不可恢复",
					errors: [],
				},
			},
		});
		fireEvent.click(screen.getByTestId("refund-o1"));

		expect(await screen.findByRole("group", { name: "请确认操作" })).toBeInTheDocument();
		expect(screen.getByTestId("op-summary").textContent).toContain("¥199.00");
		expect(screen.getByTestId("op-summary").textContent).toContain("不可恢复");
		expect(client.mutate).toHaveBeenCalledTimes(1);
		expect(client.mutate.mock.calls[0][0].variables).toEqual({ id: "o1" });
		expect(mutationName(0)).toBe("RefundOrder");

		// 第二段：确认 → confirmOperation(pendingId)
		client.mutate.mockResolvedValueOnce({
			data: { confirmOperation: { pendingId: "p1", status: "confirmed", errors: [] } },
		});
		// 动作后的重拉 mock 必须在 click 前替换（confirm 的 microtask 链
		// 会立刻消费刷新查询，晚替换拿到的还是旧 paid 负载）
		client.query.mockImplementation((opts: { variables: { workspaceId: string } }) =>
			opts.variables.workspaceId === "ws1" ? refunding : statsPayload(0, 0, 19900),
		);

		fireEvent.click(screen.getByTestId("op-confirm"));

		await waitFor(() => expect(client.mutate).toHaveBeenCalledTimes(2));
		expect(client.mutate.mock.calls[1][0].variables).toEqual({ pendingId: "p1" });
		expect(mutationName(1)).toBe("ConfirmOperation");

		// 动作后列表/统计重拉（refunding 徽章出现）
		await waitFor(
			() => expect(screen.getByTestId("order-badge-refunding")).toBeInTheDocument(),
			{ timeout: 3000 },
		);
	});

	it("退款弹层取消发 cancelOperation（不执行）；免缴同款两段且作用于 enrollmentId", async () => {
		client.query.mockImplementation((opts: { variables: { workspaceId: string } }) =>
			opts.variables.workspaceId === "ws1"
				? ordersPayload([
						baseOrder,
						{ ...baseOrder, id: "o2", enrollmentId: "e2", status: "pending", enrollmentStatus: "payment_pending" },
					])
				: statsPayload(59700, 19900, 0),
		);

		render(<PaymentsManagement workspaceId="ws1" manage />);
		await screen.findByTestId("refund-o1");

		// 退款第一段 → 弹层 → 取消 → cancelOperation（业务永不执行）
		client.mutate.mockResolvedValueOnce({
			data: { refundOrder: { pendingId: "p1", summary: "退款 ¥199.00…", errors: [] } },
		});
		fireEvent.click(screen.getByTestId("refund-o1"));
		await screen.findByTestId("op-cancel");

		client.mutate.mockResolvedValueOnce({
			data: { cancelOperation: { pendingId: "p1", status: "cancelled", errors: [] } },
		});
		fireEvent.click(screen.getByTestId("op-cancel"));

		await waitFor(() => expect(client.mutate).toHaveBeenCalledTimes(2));
		expect(client.mutate.mock.calls[1][0].variables).toEqual({ pendingId: "p1" });
		expect(mutationName(1)).toBe("CancelOperation");
		// 弹层关闭
		await waitFor(() => expect(screen.queryByTestId("op-confirm")).not.toBeInTheDocument());

		// 免缴：第一段目标 = 报名 id（waivePayment 作用于 enrollment）
		client.mutate.mockResolvedValueOnce({
			data: { waivePayment: { pendingId: "p2", summary: "免缴该报名：…", errors: [] } },
		});
		fireEvent.click(screen.getByTestId("waive-o2"));
		await screen.findByTestId("op-confirm");
		expect(client.mutate.mock.calls[2][0].variables).toEqual({ id: "e2" });
		expect(mutationName(2)).toBe("WaivePayment");

		client.mutate.mockResolvedValueOnce({
			data: { confirmOperation: { pendingId: "p2", status: "confirmed", errors: [] } },
		});
		fireEvent.click(screen.getByTestId("op-confirm"));
		await waitFor(() => expect(client.mutate).toHaveBeenCalledTimes(4));
		expect(client.mutate.mock.calls[3][0].variables).toEqual({ pendingId: "p2" });
	});

	it("取消遇终态（pending 已过期/已确认）：弹层照关 + 面板级提示，不卡死", async () => {
		client.query.mockImplementation((opts: { variables: { workspaceId: string } }) =>
			opts.variables.workspaceId === "ws1"
				? ordersPayload([baseOrder])
				: statsPayload(19900, 0, 0),
		);

		render(<PaymentsManagement workspaceId="ws1" manage />);
		await screen.findByTestId("refund-o1");

		client.mutate.mockResolvedValueOnce({
			data: { refundOrder: { pendingId: "p-exp", summary: "退款 ¥199.00…", errors: [] } },
		});
		fireEvent.click(screen.getByTestId("refund-o1"));
		await screen.findByTestId("op-cancel");

		// 服务端 pending 已过期：cancelOperation 返回业务错误而非 cancelled
		client.mutate.mockResolvedValueOnce({
			data: {
				cancelOperation: {
					pendingId: null,
					status: null,
					errors: [{ message: "pending operation has expired", code: "operation_cancel_failed" }],
				},
			},
		});
		fireEvent.click(screen.getByTestId("op-cancel"));

		// 弹层关闭（不卡死）+ 面板级错误提示（errors 命名空间文案）
		await waitFor(() => expect(screen.queryByTestId("op-confirm")).not.toBeInTheDocument());
		expect(await screen.findByRole("alert")).toHaveTextContent(
			"取消失败：该操作可能已被确认或取消，请刷新后核对。",
		);
	});

	it("状态筛选：切到 paid 时 filter 变量下推", async () => {
		client.query.mockImplementation((opts: { variables: { workspaceId: string } }) =>
			opts.variables.workspaceId === "ws1" ? ordersPayload([]) : statsPayload(0, 0, 0),
		);

		render(<PaymentsManagement workspaceId="ws1" manage />);
		await screen.findByTestId("orders-empty");

		fireEvent.change(screen.getByTestId("status-filter"), { target: { value: "paid" } });

		await waitFor(() => {
			expect(client.query).toHaveBeenCalledWith(
				expect.objectContaining({
					variables: { workspaceId: "ws1", filter: { status: { eq: "paid" } } },
				}),
			);
		});
	});

	it("U9/R8：活动筛选——选中后订单查询带 eventId；清除恢复全量", async () => {
		const { fetchWorkspaceOfferings } = await import("@/lib/events");
		(fetchWorkspaceOfferings as ReturnType<typeof vi.fn>).mockReset();
		(fetchWorkspaceOfferings as ReturnType<typeof vi.fn>)
			.mockResolvedValueOnce([{ id: "ev-1", title: "测试活动" }])
			.mockResolvedValueOnce([]);

		client.query.mockImplementation((opts: { variables: { workspaceId: string } }) =>
			opts.variables.workspaceId === "ws1" ? ordersPayload([]) : statsPayload(0, 0, 0),
		);

		render(<PaymentsManagement workspaceId="ws1" manage />);
		await screen.findByTestId("orders-empty");

		const select = await screen.findByTestId("offering-filter");
		fireEvent.change(select, { target: { value: "ev-1" } });

		await waitFor(() => {
			expect(client.query).toHaveBeenCalledWith(
				expect.objectContaining({
					variables: { workspaceId: "ws1", filter: { eventId: { eq: "ev-1" } } },
				}),
			);
		});

		fireEvent.change(select, { target: { value: "" } });

		await waitFor(() => {
			expect(client.query).toHaveBeenCalledWith(
				expect.objectContaining({
					variables: { workspaceId: "ws1", filter: {} },
				}),
			);
		});
	});
});
