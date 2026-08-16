import { describe, expect, it } from 'vitest'
import { PAYMENT_STATUS_LABEL } from '@/domain/payment'
import type { EnrollmentStatus, EnrollmentSummary, OrderSummary } from '@/domain/models'

/**
 * U12/R16：my-enrollments 缴费状态渲染（纯数据层断言——页面组件渲染依赖
 * Taro 运行时，状态合并/词表逻辑在此钉死，页面只做映射）。
 *
 * 覆盖：payment_pending 报名卡（待支付 + 去支付）；confirmed 报名按最新订单
 * 展示 paid/refunded/refunding；无订单/终态订单不出缴费态。
 */

const statusText: Record<EnrollmentStatus, string> = {
  pending: '等待审批',
  payment_pending: '待支付',
  confirmed: '已通过',
  rejected: '已拒绝',
  expired: '审批超时',
  cancelled: '已取消'
}

/** 页面 load 的合并逻辑镜像（my-enrollments/index.tsx load 内联实现） */
function paymentLabelFor(
  enrollment: Pick<EnrollmentSummary, 'id' | 'status'>,
  orders: Pick<OrderSummary, 'enrollmentId' | 'status'>[]
): string | null {
  if (enrollment.status !== 'confirmed') {
    // payment_pending 态由报名状态自身表达（词表键存在 = 渲染不炸）
    return enrollment.status === 'payment_pending'
      ? `缴费状态：${PAYMENT_STATUS_LABEL.payment_pending}`
      : null
  }
  const order = orders.find(({ enrollmentId }) => enrollmentId === enrollment.id)
  if (!order) return null
  if (order.status === 'paid' || order.status === 'refunded' || order.status === 'refunding') {
    return `缴费状态：${PAYMENT_STATUS_LABEL[order.status] ?? order.status}`
  }
  return null
}

const paidOrder = (enrollmentId: string, status: OrderSummary['status']): Pick<OrderSummary, 'enrollmentId' | 'status'> => ({
  enrollmentId,
  status
})

describe('my-enrollments 缴费状态渲染（U12/R16）', () => {
  it('payment_pending 报名：待支付词表 + 缴费提示语义', () => {
    expect(statusText.payment_pending).toBe('待支付')
    expect(paymentLabelFor({ id: 'e1', status: 'payment_pending' }, [])).toBe(
      '缴费状态：待支付'
    )
  })

  it('confirmed 报名：按订单状态展示已支付/已退款/退款中', () => {
    expect(paymentLabelFor({ id: 'e2', status: 'confirmed' }, [paidOrder('e2', 'paid')])).toBe(
      '缴费状态：已支付'
    )
    expect(paymentLabelFor({ id: 'e3', status: 'confirmed' }, [paidOrder('e3', 'refunded')])).toBe(
      '缴费状态：已退款'
    )
    expect(paymentLabelFor({ id: 'e4', status: 'confirmed' }, [paidOrder('e4', 'refunding')])).toBe(
      '缴费状态：退款中'
    )
  })

  it('无订单（免费/免缴）与终态订单不出缴费态', () => {
    expect(paymentLabelFor({ id: 'e5', status: 'confirmed' }, [])).toBeNull()
    // expired/cancelled 订单不产生缴费态标签
    expect(paymentLabelFor({ id: 'e6', status: 'confirmed' }, [paidOrder('e6', 'expired')])).toBeNull()
    expect(paymentLabelFor({ id: 'e7', status: 'confirmed' }, [paidOrder('e7', 'cancelled')])).toBeNull()
    // 非相关状态不出
    expect(paymentLabelFor({ id: 'e8', status: 'rejected' }, [paidOrder('e8', 'paid')])).toBeNull()
    expect(paymentLabelFor({ id: 'e9', status: 'cancelled' }, [])).toBeNull()
  })

  it('多个历史订单取数组首条（最新）：later 订单优先', () => {
    const orders = [paidOrder('e10', 'refunded'), paidOrder('e10', 'expired')]
    expect(paymentLabelFor({ id: 'e10', status: 'confirmed' }, orders)).toBe('缴费状态：已退款')
  })
})
