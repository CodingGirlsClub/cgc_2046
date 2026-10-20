import { describe, expect, it } from "vitest";
import { orderActions } from "./order-actions";

describe("orderActions（管理面操作资格，镜像后端 precondition）", () => {
	const cases: Array<{
		name: string;
		order: { status: string; enrollmentStatus?: string | null };
		expected: { refund: boolean; waive: boolean; retry: boolean };
	}> = [
		{
			name: "paid + confirmed → 仅退款",
			order: { status: "paid", enrollmentStatus: "confirmed" },
			expected: { refund: true, waive: false, retry: false },
		},
		{
			name: "pending + payment_pending → 免缴",
			order: { status: "pending", enrollmentStatus: "payment_pending" },
			expected: { refund: false, waive: true, retry: false },
		},
		{
			// 后端 waive_payment 的 CAS 前提是报名 payment_pending；
			// 订单 pending 但报名已确认时前端不得给免缴入口
			name: "pending + confirmed → 无免缴（订单状态不充分）",
			order: { status: "pending", enrollmentStatus: "confirmed" },
			expected: { refund: false, waive: false, retry: false },
		},
		{
			name: "payment_pending 但订单已过期 → 免缴仍可见（报名态优先）",
			order: { status: "expired", enrollmentStatus: "payment_pending" },
			expected: { refund: false, waive: true, retry: false },
		},
		{
			name: "refund_failed → 重试退款",
			order: { status: "refund_failed", enrollmentStatus: "confirmed" },
			expected: { refund: false, waive: false, retry: true },
		},
		{
			name: "refunded / cancelled / forfeited → 无操作",
			order: { status: "refunded", enrollmentStatus: "cancelled" },
			expected: { refund: false, waive: false, retry: false },
		},
		{
			name: "报名状态缺失（历史数据）→ 不免缴",
			order: { status: "pending", enrollmentStatus: null },
			expected: { refund: false, waive: false, retry: false },
		},
	];

	for (const { name, order, expected } of cases) {
		it(name, () => {
			expect(orderActions(order)).toEqual(expected);
		});
	}
});
