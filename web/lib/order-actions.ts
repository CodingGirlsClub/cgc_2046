/**
 * 管理面订单操作资格（单一真源，两个缴费视图共用）。
 *
 * 规则镜像后端 precondition，前端不得各自重写：
 * - 退款：`Order.refund`（paid → refunding）
 * - 免缴：`Enrollment.waive_payment`（CAS 前提 payment_pending；
 *   注意不是订单 status —— 订单 pending 与报名 payment_pending 不等价）
 * - 重试退款：`Order.retry_refund`（refund_failed → refunding）
 *
 * 后端 policy + DB CAS 仍是最终裁决；本函数只决定入口是否展示。
 */

import type { Order } from "./graphql/orders";

export interface OrderActionEligibility {
	refund: boolean;
	waive: boolean;
	retry: boolean;
}

export function orderActions(
	order: Pick<Order, "status" | "enrollmentStatus">,
): OrderActionEligibility {
	return {
		refund: order.status === "paid",
		waive: order.enrollmentStatus === "payment_pending",
		retry: order.status === "refund_failed",
	};
}
