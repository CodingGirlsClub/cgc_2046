import { describe, expect, it } from 'vitest'
import { enrollmentPaymentText } from '@/domain/payment'
import type { OrderSummary } from '@/domain/models'

/**
 * U11/R16：my-enrollments 缴费态卡面（纯数据层断言——页面组件渲染依赖 Taro 运行时，
 * 卡面文案由 domain/payment.enrollmentPaymentText 单源产出，页面只做映射）。
 *
 * 覆盖：payment_pending 待支付 + 名额保留提示；confirmed 报名按订单状态出
 * 已支付/退款中/已退款；押金链终态 forfeited（押金未退未到场）与 refund_failed
 * （退款失败，平台处理中）；无订单（免费/免缴）与作废单不出缴费行。
 */

const order = (
  enrollmentId: string,
  status: OrderSummary['status']
): Pick<OrderSummary, 'enrollmentId' | 'status'> => ({ enrollmentId, status })

describe('my-enrollments 缴费态卡面（U11/R16）', () => {
  it('payment_pending 报名：待支付 + 名额保留提示', () => {
    expect(enrollmentPaymentText({ id: 'e1', status: 'payment_pending' })).toBe(
      '缴费状态：待支付 · 名额已保留，请尽快完成支付'
    )
  })

  it('confirmed 报名：按订单状态展示已支付/退款中/已退款', () => {
    expect(enrollmentPaymentText({ id: 'e2', status: 'confirmed' }, [order('e2', 'paid')])).toBe(
      '缴费状态：已支付'
    )
    expect(enrollmentPaymentText({ id: 'e3', status: 'confirmed' }, [order('e3', 'refunding')])).toBe(
      '缴费状态：退款中'
    )
    expect(enrollmentPaymentText({ id: 'e4', status: 'confirmed' }, [order('e4', 'refunded')])).toBe(
      '缴费状态：已退款'
    )
  })

  it('押金链终态上卡：押金未退（未到场）与渠道退款失败', () => {
    expect(enrollmentPaymentText({ id: 'e5', status: 'confirmed' }, [order('e5', 'forfeited')])).toBe(
      '缴费状态：押金未退（未到场）'
    )
    expect(enrollmentPaymentText({ id: 'e6', status: 'confirmed' }, [order('e6', 'refund_failed')])).toBe(
      '缴费状态：退款失败，平台处理中'
    )
  })

  it('无订单（免费/免缴）与作废单不出缴费态', () => {
    expect(enrollmentPaymentText({ id: 'e7', status: 'confirmed' })).toBeNull()
    // 未支付/作废订单不产生缴费行（待支付由报名状态自身表达）
    expect(enrollmentPaymentText({ id: 'e8', status: 'confirmed' }, [order('e8', 'pending')])).toBeNull()
    expect(enrollmentPaymentText({ id: 'e9', status: 'confirmed' }, [order('e9', 'expired')])).toBeNull()
    expect(enrollmentPaymentText({ id: 'e10', status: 'confirmed' }, [order('e10', 'cancelled')])).toBeNull()
    // 非 confirmed 报名（pending/rejected/cancelled）不出订单缴费态
    expect(enrollmentPaymentText({ id: 'e11', status: 'rejected' }, [order('e11', 'paid')])).toBeNull()
    expect(enrollmentPaymentText({ id: 'e12', status: 'cancelled' })).toBeNull()
    expect(enrollmentPaymentText({ id: 'e13', status: 'pending' }, [order('e13', 'paid')])).toBeNull()
  })

  it('重入作废单不遮蔽有效缴费态（同报名多单）', () => {
    expect(
      enrollmentPaymentText({ id: 'e14', status: 'confirmed' }, [
        order('e14', 'expired'),
        order('e14', 'refunded')
      ])
    ).toBe('缴费状态：已退款')
  })
})
