import { useState } from 'react'
import { Button, Input, Text, View } from '@tarojs/components'
import Taro, { useRouter } from '@tarojs/taro'
import { api } from '@/api'
import { PageState } from '@/components/PageState'
import { parseCheckInScan } from '@/domain/checkin'
import type { CheckInMethod, CheckInOutcome } from '@/domain/models'
import styles from './index.module.css'

/** 扫码结果与页面当前活动不一致时的本地拦截（不消耗后端失败节流计数） */
type LocalError = { kind: 'not_check_in_code' } | { kind: 'other_event' }
type Feedback = CheckInOutcome | LocalError | { kind: 'network'; message: string }

/**
 * 主理人现场核销页（#508 选项 A）：扫码主路径 + 手输 6 位码兜底。
 *
 * - 入口按场挂载（event-detail 对 owner/admin 显示）；eventId 来自路由参数，
 *   扫码 payload 里的 eventId 只做交叉校验（异场码本地拦截）；
 * - 授权与「码无效/已核销/押金已结算」判定全在后端 mutation（KTD4 fail-closed），
 *   本页只做结果呈现；「已核销」是幂等提示态而非错误（重复扫码是现场常态）；
 * - 连续核销是高频正常路径：一次提交后页面保持可立即扫下一位。
 */
export default function CheckInPage() {
  const router = useRouter()
  const eventId = router.params.eventId ?? ''
  const title = router.params.title ? decodeURIComponent(router.params.title) : ''
  const [manualCode, setManualCode] = useState('')
  const [submitting, setSubmitting] = useState(false)
  const [feedback, setFeedback] = useState<Feedback | null>(null)

  if (!eventId) return <PageState kind='error' message='缺少活动参数，请从活动详情页进入' />

  const submit = async (code: string, method: CheckInMethod) => {
    if (submitting) return
    setSubmitting(true)
    setFeedback(null)
    try {
      const outcome = await api.checkInEnrollment(eventId, code, method)
      setFeedback(outcome)
      if (outcome.kind === 'success') setManualCode('')
    } catch (reason) {
      // 网络/服务故障与业务失败不同桶：可原样重试（web 核销页同款二分类）
      setFeedback({
        kind: 'network',
        message: reason instanceof Error ? reason.message : '网络异常，请稍后重试'
      })
    } finally {
      setSubmitting(false)
    }
  }

  const dispatchScan = (raw: string, method: CheckInMethod) => {
    const parsed = parseCheckInScan(raw)
    if (!parsed) {
      setFeedback({ kind: 'not_check_in_code' })
      return
    }
    if (parsed.eventId && parsed.eventId !== eventId) {
      setFeedback({ kind: 'other_event' })
      return
    }
    void submit(parsed.code, method)
  }

  const scan = async () => {
    try {
      const result = await Taro.scanCode({ scanType: ['qrCode'] })
      dispatchScan(result.result, 'scan')
    } catch {
      // 用户取消扫码：静默（profile 扫码邀请同款口径）
    }
  }

  const submitManual = () => dispatchScan(manualCode, 'manual')

  return (
    <View className={styles.page}>
      <View className={styles.header}>
        <Text className={styles.eyebrow}>CHECK-IN</Text>
        <Text className={styles.title} data-testid='check-in-title'>{title || '现场核销'}</Text>
        <Text className={styles.subtitle}>扫参与者的核销二维码，或手输 6 位核销码。</Text>
      </View>

      <View className={styles.actions}>
        <Button
          className={styles.scanButton}
          loading={submitting}
          data-testid='check-in-scan'
          onClick={() => void scan()}
        >
          扫码核销
        </Button>
        <View className={styles.manualRow}>
          <Input
            className={styles.codeInput}
            placeholder='手输 6 位核销码'
            maxlength={12}
            value={manualCode}
            data-testid='check-in-code-input'
            onInput={(event) => setManualCode(event.detail.value)}
          />
          <Button
            className={styles.manualButton}
            size='mini'
            loading={submitting}
            data-testid='check-in-manual-submit'
            onClick={submitManual}
          >
            核销
          </Button>
        </View>
      </View>

      {feedback && (
        <View className={styles.feedback} data-testid='check-in-feedback'>
          <FeedbackView feedback={feedback} />
        </View>
      )}
    </View>
  )
}

function FeedbackView({ feedback }: { feedback: Feedback }) {
  switch (feedback.kind) {
    case 'success':
      return (
        <>
          <Text className={`${styles.feedbackTitle} ${styles.success}`} data-testid='check-in-success'>
            核销成功
          </Text>
          {feedback.depositRefund === 'refunding' && (
            <Text className={styles.feedbackNote} data-testid='check-in-deposit-refund'>
              押金退款已发起，全额原路退回。
            </Text>
          )}
          {feedback.depositRefund === 'refunded' && (
            <Text className={styles.feedbackNote} data-testid='check-in-deposit-refund'>
              押金已全额退回。
            </Text>
          )}
        </>
      )
    case 'already':
      return (
        <Text className={`${styles.feedbackTitle} ${styles.info}`} data-testid='check-in-already'>
          该报名已核销，无需重复核销。
        </Text>
      )
    case 'invalid':
      return (
        <Text className={`${styles.feedbackTitle} ${styles.failure}`} data-testid='check-in-invalid'>
          核销码无效或与本场活动不匹配，请让参与者重新出示。
        </Text>
      )
    case 'forfeited':
      return (
        <Text className={`${styles.feedbackTitle} ${styles.failure}`} data-testid='check-in-forfeited'>
          该报名的押金已按未到场结算（不退），无法再核销。
        </Text>
      )
    case 'forbidden':
      return (
        <Text className={`${styles.feedbackTitle} ${styles.failure}`} data-testid='check-in-forbidden'>
          你没有本场活动的核销权限。
        </Text>
      )
    case 'rate_limited':
      return (
        <Text className={`${styles.feedbackTitle} ${styles.failure}`} data-testid='check-in-rate-limited'>
          核销尝试过于频繁，请稍后再试。
        </Text>
      )
    case 'not_check_in_code':
      return (
        <Text className={`${styles.feedbackTitle} ${styles.failure}`} data-testid='check-in-not-code'>
          扫到的不是核销码，请确认参与者出示的是报名二维码。
        </Text>
      )
    case 'other_event':
      return (
        <Text className={`${styles.feedbackTitle} ${styles.failure}`} data-testid='check-in-other-event'>
          这是其他活动的核销码，请核对当前核销场次。
        </Text>
      )
    case 'network':
      return (
        <Text className={`${styles.feedbackTitle} ${styles.failure}`} data-testid='check-in-network-error'>
          {feedback.message}
        </Text>
      )
  }
}
