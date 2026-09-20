import { useCallback, useEffect, useState } from 'react'
import { Button, Text, View } from '@tarojs/components'
import Taro, { useRouter } from '@tarojs/taro'
import { api } from '@/api'
import { PageState } from '@/components/PageState'
import type { EnrollmentSummary } from '@/domain/models'
import { enrollmentResultCopy } from '@/domain/payment'
import { enrollmentResultTouchpoint } from '@/domain/subscription'
import { requestPlatformSubscriptions } from '@/platform'
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
  // M1：刚提交完报名，用户最想知道「我进了吗 / 开得成吗 / 会不会取消」——
  // 三问恰好用满微信单次 tmplIds 上限 3（判据与文案见 domain/subscription.ts）。
  const touchpoint = enrollmentResultTouchpoint(enrollment.status)

  const subscribe = async () => {
    if (!touchpoint) return
    setSubmitting(true)
    // 先清空上一次提示：二次点按（含改点其他场景）时不留旧文案
    setSubscriptionState('')
    try {
      const accepted = await requestPlatformSubscriptions(touchpoint.scenarios)
      if (accepted.length === 0) {
        setSubscriptionState(touchpoint.deniedCopy)
        return
      }
      // 一次授权 = 后端 +1 配额，逐场景上报（部分接受只报被接受的）
      for (const scenario of accepted) await api.grantConsent(scenario)
      setSubscriptionState(touchpoint.acceptedCopy)
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
        {touchpoint && (
          <Text className={styles.cardMeta}>{touchpoint.label}需要你主动授权一次</Text>
        )}
      </View>

      {touchpoint && (
        <Button className={styles.subscribeButton} data-testid='subscribe-result' loading={submitting} onClick={subscribe}>
          {touchpoint.label}
        </Button>
      )}
      {subscriptionState && <Text className={styles.subscriptionState} data-testid='subscription-state'>{subscriptionState}</Text>}

      <Button className={styles.secondaryButton} onClick={() => Taro.navigateTo({ url: '/pages/my-enrollments/index' })}>
        查看我的报名
      </Button>
    </View>
  )
}
