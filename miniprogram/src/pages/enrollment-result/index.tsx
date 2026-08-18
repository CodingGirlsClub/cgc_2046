import { useState } from 'react'
import { Button, Text, View } from '@tarojs/components'
import Taro from '@tarojs/taro'
import { api } from '@/api'
import { PageState } from '@/components/PageState'
import type { EnrollmentSummary, SubscriptionScenario } from '@/domain/models'
import { enrollmentResultCopy } from '@/domain/payment'
import { requestPlatformSubscription } from '@/platform'
import { STORAGE_KEYS } from '@/state/storage'
import styles from './index.module.css'

export default function EnrollmentResultPage() {
  const [enrollment] = useState(() => Taro.getStorageSync<EnrollmentSummary>(STORAGE_KEYS.lastEnrollment))
  const [submitting, setSubmitting] = useState(false)
  const [subscriptionState, setSubscriptionState] = useState('')

  if (!enrollment) return <PageState kind='empty' message='没有找到刚刚提交的报名' />

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
