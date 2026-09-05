import { useCallback, useEffect, useState } from 'react'
import { Button, Text, View } from '@tarojs/components'
import Taro, { useRouter } from '@tarojs/taro'
import { api } from '@/api'
import { PageState } from '@/components/PageState'
import type { EnrollmentSummary, SubscriptionScenario } from '@/domain/models'
import { enrollmentResultCopy } from '@/domain/payment'
import { requestPlatformSubscription } from '@/platform'
import { STORAGE_KEYS } from '@/state/storage'
import styles from './index.module.css'

// #355 P1-4：结果页承担结果查询职责，不再只是提交瞬时回执。数据源优先级：
// 路由 ?id=（register-form 提交后必带）→ 服务端回查（换设备/清缓存仍可得）；
// 失败/未登录降级本机 storage lastEnrollment；两者皆空 → 真空态（引导去我的报名）。
export default function EnrollmentResultPage() {
  const router = useRouter()
  const enrollmentId = router.params.id ?? ''
  const [enrollment, setEnrollment] = useState<EnrollmentSummary | null>(null)
  const [loading, setLoading] = useState(Boolean(enrollmentId))
  const [submitting, setSubmitting] = useState(false)
  const [subscriptionState, setSubscriptionState] = useState('')

  const load = useCallback(async () => {
    if (!enrollmentId) {
      setEnrollment(Taro.getStorageSync<EnrollmentSummary>(STORAGE_KEYS.lastEnrollment) || null)
      return
    }
    setLoading(true)
    try {
      // 服务端回查失败（未登录/网络）不致命：本机回执兜底
      const fetched = await api.getEnrollment(enrollmentId).catch(() => null)
      setEnrollment(
        fetched ?? (Taro.getStorageSync<EnrollmentSummary>(STORAGE_KEYS.lastEnrollment) || null)
      )
    } finally {
      setLoading(false)
    }
  }, [enrollmentId])

  useEffect(() => { void load() }, [load])

  if (loading) return <PageState kind='loading' />
  if (!enrollment) {
    return <PageState kind='empty' message='没有找到这条报名记录，可在「我的报名」中查看' />
  }

  const pending = enrollment.status === 'pending'
  const paymentPending = enrollment.status === 'payment_pending'
  const copy = enrollmentResultCopy(enrollment.status, process.env.TARO_ENV === 'weapp')
  const scenario: SubscriptionScenario = pending ? 'approval_result' : 'event_reminder'

  const subscribe = async () => {
    setSubmitting(true)
    try {
      const accepted = await requestPlatformSubscription(scenario)
      if (!accepted) {
        setSubscriptionState('你暂未授权，可稍后在报名页再次订阅')
        return
      }
      await api.grantConsent(scenario)
      setSubscriptionState(pending ? '已订阅审批结果通知' : '已订阅活动提醒')
    } catch (reason) {
      setSubscriptionState(reason instanceof Error ? reason.message : '订阅失败，请稍后重试')
    } finally {
      setSubmitting(false)
    }
  }

  return (
    <View className={styles.page}>
      <View className={`${styles.statusMark} ${pending || paymentPending ? styles.pending : styles.confirmed}`}>
        {pending ? '…' : paymentPending ? '¥' : '✓'}
      </View>
      <Text className={styles.title} data-testid='enrollment-result'>
        {copy.title}
      </Text>
      <Text className={styles.subtitle}>{copy.subtitle}</Text>

      <View className={styles.card}>
        <Text className={styles.cardLabel}>报名项目</Text>
        <Text className={styles.cardTitle}>{enrollment.title}</Text>
        {!paymentPending && (
          <Text className={styles.cardMeta}>{pending ? '审批结果通知' : '活动开始提醒'}需要你主动授权一次</Text>
        )}
      </View>

      {!paymentPending && (
        <Button className={styles.subscribeButton} data-testid='subscribe-result' loading={submitting} onClick={subscribe}>
          {pending ? '订阅审批结果通知' : '订阅活动提醒'}
        </Button>
      )}
      {subscriptionState && <Text className={styles.subscriptionState} data-testid='subscription-state'>{subscriptionState}</Text>}

      <Button className={styles.secondaryButton} onClick={() => Taro.switchTab({ url: '/pages/my-enrollments/index' })}>
        查看我的报名
      </Button>
    </View>
  )
}
