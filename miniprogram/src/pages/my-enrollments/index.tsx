import { useCallback, useEffect, useState } from 'react'
import { Button, ScrollView, Text, View } from '@tarojs/components'
import Taro, { useDidShow } from '@tarojs/taro'
import { api } from '@/api'
import { AppTabBar } from '@/components/AppTabBar'
import { PageState } from '@/components/PageState'
import { remainingLabel } from '@/domain/format'
import type { EnrollmentStatus, EnrollmentSummary } from '@/domain/models'
import { PAYMENT_STATUS_LABEL } from '@/domain/payment'
import { requestPlatformSubscription } from '@/platform'
import styles from './index.module.css'

const statusText: Record<EnrollmentStatus, string> = {
  pending: '等待审批',
  payment_pending: '待支付',
  confirmed: '已通过',
  rejected: '已拒绝',
  expired: '审批超时',
  cancelled: '已取消'
}

export default function MyEnrollmentsPage() {
  const [items, setItems] = useState<EnrollmentSummary[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [now, setNow] = useState(Date.now)
  const [cancellingId, setCancellingId] = useState<string | null>(null)

  const [paymentByEnrollment, setPaymentByEnrollment] = useState<Record<string, string>>({})

  const load = useCallback(async () => {
    setLoading(true)
    setError('')
    try {
      const [enrollments, orders] = await Promise.all([api.getEnrollments(), api.getMyOrders()])
      // 缴费态(R16)：confirmed 报名挂最新订单状态展示 paid/refunded;
      // payment_pending 由报名状态自身表达。
      const byEnrollment: Record<string, string> = {}
      for (const order of orders) {
        if (order.status === 'paid' || order.status === 'refunded' || order.status === 'refunding') {
          byEnrollment[order.enrollmentId] = order.status
        }
      }
      setPaymentByEnrollment(byEnrollment)
      setItems(enrollments)
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : '报名记录加载失败')
    } finally {
      setLoading(false)
    }
  }, [])

  useDidShow(() => { void load() })
  useEffect(() => {
    const hasCountdown = items.some((item) => item.status === 'pending' && item.approvalDeadline)
    if (!hasCountdown) return undefined
    const timer = setInterval(() => setNow(Date.now()), 60_000)
    return () => clearInterval(timer)
  }, [items])

  const subscribeReminder = async () => {
    try {
      if (await requestPlatformSubscription('event_reminder')) {
        await api.grantConsent('event_reminder')
        Taro.showToast({ title: '已订阅活动提醒', icon: 'success' })
      }
    } catch (reason) {
      Taro.showToast({ title: reason instanceof Error ? reason.message : '订阅失败', icon: 'none' })
    }
  }

  const cancelEnrollment = async (item: EnrollmentSummary) => {
    const modal = await Taro.showModal({
      title: '取消报名',
      content:
        item.status === 'payment_pending'
          ? '取消后将释放名额并作废待支付订单，此操作不可恢复。'
          : '取消后名额将即时释放，此操作不可恢复。'
    })
    if (!modal.confirm) return

    setCancellingId(item.id)
    try {
      await api.cancelEnrollment(item.id)
      await load()
      Taro.showToast({ title: '已取消报名', icon: 'success' })
    } catch (reason) {
      Taro.showToast({ title: reason instanceof Error ? reason.message : '取消报名失败', icon: 'none' })
    } finally {
      setCancellingId(null)
    }
  }

  return (
    <View className={styles.page}>
      <View className={styles.header}>
        <Text className={styles.eyebrow}>MY ENROLLMENTS</Text>
        <Text className={styles.title}>我的报名</Text>
        <Text className={styles.subtitle}>状态变化会同步到这里。</Text>
      </View>

      <ScrollView scrollY className={styles.list}>
        {loading ? (
          <PageState kind='loading' />
        ) : error ? (
          <PageState kind='error' message={error} onRetry={load} />
        ) : items.length === 0 ? (
          <PageState kind='empty' message='还没有报名记录，去发现页看看吧' />
        ) : items.map((item) => (
          <View key={item.id} className={styles.card} data-testid={`enrollment-${item.id}`}>
            <View className={styles.cardHeader}>
              <Text className={styles.kind}>{item.kind === 'event' ? '活动' : '课程'}</Text>
              <Text className={`${styles.status} ${styles[item.status]}`}>{statusText[item.status]}</Text>
            </View>
            <Text className={styles.cardTitle}>{item.title}</Text>
            {item.status === 'confirmed' && paymentByEnrollment[item.id] && (
              <Text className={styles.paymentStatus} data-testid={`payment-status-${item.id}`}>
                缴费状态：{PAYMENT_STATUS_LABEL[paymentByEnrollment[item.id]] ?? paymentByEnrollment[item.id]}
              </Text>
            )}
            {item.status === 'pending' && (
              <View className={styles.countdown}>
                <Text className={styles.countdownLabel}>审批剩余</Text>
                <Text className={styles.countdownValue}>{remainingLabel(item.approvalDeadline, now)}</Text>
              </View>
            )}
            {item.status === 'payment_pending' && (
              <>
                <Text className={styles.paymentHint} data-testid={`payment-hint-${item.id}`}>
                  缴费状态：{PAYMENT_STATUS_LABEL.payment_pending} · 名额已保留，请尽快完成支付
                </Text>
                <Button
                  className={styles.payButton}
                  size='mini'
                  data-testid={`pay-entry-${item.id}`}
                  onClick={() => Taro.navigateTo({ url: `/pages/order-pay/index?enrollmentId=${item.id}` })}
                >
                  去支付
                </Button>
              </>
            )}
            {(item.status === 'pending' || item.status === 'confirmed') && (
              <Button
                className={styles.textButton}
                size='mini'
                disabled={cancellingId === item.id}
                onClick={() => void cancelEnrollment(item)}
              >
                {cancellingId === item.id ? '取消中…' : '取消报名'}
              </Button>
            )}
            {item.status === 'confirmed' && (
              <>
                <Button className={styles.textButton} size='mini' onClick={subscribeReminder}>订阅活动提醒</Button>
              </>
            )}
            {(item.status === 'rejected' || item.status === 'expired') && (
              <Button
                className={styles.textButton}
                size='mini'
                onClick={() => Taro.navigateTo({ url: `/pages/register-form/index?id=${item.targetId}&kind=${item.kind}` })}
              >
                重新提交
              </Button>
            )}
            {item.rejectionReason && <Text className={styles.reason}>原因：{item.rejectionReason}</Text>}
          </View>
        ))}
      </ScrollView>
      {process.env.TARO_ENV !== 'weapp' && (
        <Text className={styles.platformTip}>审批结果将通过本端订阅消息通知你</Text>
      )}
      <AppTabBar selected='enrollments' />
    </View>
  )
}
