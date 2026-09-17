import { useCallback, useEffect, useRef, useState } from 'react'
import { Button, ScrollView, Text, View } from '@tarojs/components'
import Taro, { useRouter } from '@tarojs/taro'
import { api } from '@/api'
import { PageState } from '@/components/PageState'
import {
  POLL_TOTAL_MS,
  canRequestPayment,
  countdownText,
  depositPayNotice,
  formatAmount,
  mapPaymentCredential,
  nextPollTick,
  type OrderPollStatus,
  type RequestPaymentArgs
} from '@/domain/payment'
import type { OrderSummary } from '@/domain/models'
import { paymentResultTouchpoint } from '@/domain/subscription'
import { requestPlatformSubscriptions } from '@/platform'
import styles from './index.module.css'

/**
 * 缴费闭环 U12/R13/R14：小程序订单支付页。
 *
 * 链路：createOrder(wechat_jsapi) → credential(pay_params) →
 * Taro.requestPayment(JSAPI 五键) → 轮询 orderStatus(2s×30s，与 web 同
 * 契约) → paid 成功态 / 超窗手动刷新态；倒计时 expire_at。
 *
 * 押金同意门（U1 小程序落点）：押金单在「立即支付」前明示「押金 ¥xx（到场退）·
 * 未到场不退」并须勾选同意，未勾选不放行。判据是**订单自己的口径快照**
 * `order.orderKind`（后端 order_kind），不是活动的实时缴费配置——活动随时可改
 * 配置，这一笔不会；金额同理取 `order.amountCents`（报名时物化的押金快照）。
 * 用户同意的就是这一笔。判据为纯函数 canRequestPayment，本页只渲染。
 *
 * e2e 边界(#172 已定)：真实支付调起不可自动化，端到端止于订单生成 + 凭据
 * 返回；requestPayment 之后的行为由单测(纯逻辑)与真实小额验收覆盖。
 */
export default function OrderPayPage() {
  const router = useRouter()
  const enrollmentId = router.params.enrollmentId ?? ''

  const [order, setOrder] = useState<OrderSummary | null>(null)
  const [paymentArgs, setPaymentArgs] = useState<RequestPaymentArgs | null>(null)
  const [credentialError, setCredentialError] = useState('')
  const [paying, setPaying] = useState(false)
  const [phase, setPhase] = useState<'creating' | 'await' | 'paid'>('creating')
  const [pollElapsed, setPollElapsed] = useState(0)
  const [manualMode, setManualMode] = useState(false)
  const [now, setNow] = useState(Date.now)
  const [error, setError] = useState('')
  const [ack, setAck] = useState(false)
  const createdRef = useRef(false)

  // 下单(一次性)：凭据即取,失败可重试
  const createOrderFlow = useCallback(async () => {
    if (!enrollmentId) return
    setPhase('creating')
    setError('')
    try {
      const created = await api.createOrder(enrollmentId)
      setOrder(created.order)
      const dispatch = mapPaymentCredential(created.credential)
      if (dispatch.mode === 'jsapi') {
        setPaymentArgs(dispatch.args)
        setCredentialError('')
      } else {
        setPaymentArgs(null)
        setCredentialError(dispatch.reason)
      }
      setPhase('await')
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : '下单失败，请重试')
    }
  }, [enrollmentId])

  useEffect(() => {
    if (createdRef.current || !enrollmentId) return
    createdRef.current = true
    void createOrderFlow()
  }, [enrollmentId, createOrderFlow])

  const status = (order?.status ?? 'pending') as OrderPollStatus

  // 资金动作门（U1）：押金单先勾选——口径与金额都取订单自己的快照
  const depositNotice =
    order?.orderKind === 'deposit' ? depositPayNotice(order.amountCents) : null
  const ackRequired = depositNotice !== null && !ack
  const canPay = canRequestPayment({
    order,
    ack,
    hasCredential: paymentArgs !== null,
    paying
  })

  // 支付调起(R13)：requestPayment 完成(用户支付/取消)后轮询确认
  const requestPayment = async () => {
    if (!canPay || !paymentArgs) return
    setPaying(true)
    try {
      // signType 收敛为 Taro 联合字面量(RSA/MD5/HMAC-SHA256,后端 v3 固定 RSA)
      await Taro.requestPayment({ ...paymentArgs, signType: paymentArgs.signType as 'RSA' })
      Taro.showToast({ title: '支付完成，确认中…', icon: 'none' })
    } catch (reason) {
      // 用户取消/失败：留在本页，可再次调起
      Taro.showToast({
        title: reason instanceof Error && /cancel/i.test(reason.message) ? '已取消支付' : '调起支付失败，请重试',
        icon: 'none'
      })
    } finally {
      setPaying(false)
    }
  }

  const pollStatus = useCallback(async () => {
    if (!order) return
    try {
      setOrder(await api.getOrderStatus(order.id))
    } catch {
      // 单次轮询失败不终止轮询(网络抖动)
    }
  }, [order])

  // 轮询(R14)：paid 停；超窗手动态(刷新按钮重置)
  const windowExpired = pollElapsed >= POLL_TOTAL_MS
  const manual = manualMode || windowExpired

  useEffect(() => {
    if (phase !== 'await' || !order || manual) return
    const tick = nextPollTick(pollElapsed, status)
    if (!tick.continue) return
    const timer = setTimeout(() => {
      void pollStatus().finally(() => setPollElapsed((elapsed) => elapsed + (tick.delayMs ?? 0)))
    }, tick.delayMs ?? 0)
    return () => clearTimeout(timer)
  }, [phase, order, manual, pollElapsed, status, pollStatus])

  // paid 收敛
  useEffect(() => {
    if (status === 'paid') setPhase('paid')
  }, [status])

  // 倒计时(R6)
  useEffect(() => {
    const timer = setInterval(() => setNow(Date.now()), 500)
    return () => clearInterval(timer)
  }, [])

  const remain = countdownText(now, order?.expireAt)
  const expired = remain === '已过期'
  // 双态触点单变量：pending/paid 按钮与 handler 共用，label 随 phase 正确分派
  const touchpoint = paymentResultTouchpoint(phase === 'paid')

  const refreshManually = () => {
    setPollElapsed(0)
    setManualMode(false)
    void pollStatus()
  }

  // M6 双态触点（#683 收紧 2）：pending 态先授权 → 首单即送达；paid 态兜底补
  // 授权（本单或已 discard，配额结转下一单）。判据/文案/时机下沉 domain。
  const subscribePayment = async () => {
    try {
      const accepted = await requestPlatformSubscriptions(touchpoint.scenarios)
      if (accepted.length === 0) {
        Taro.showToast({ title: touchpoint.deniedCopy, icon: 'none' })
        return
      }
      for (const scenario of accepted) await api.grantConsent(scenario)
      Taro.showToast({ title: touchpoint.acceptedCopy, icon: 'success' })
    } catch (reason) {
      Taro.showToast({ title: reason instanceof Error ? reason.message : '订阅失败', icon: 'none' })
    }
  }

  if (!enrollmentId) return <PageState kind='empty' message='缺少报名信息' />
  if (phase === 'creating' && !error) return <PageState kind='loading' />

  return (
    <View className={styles.page}>
      <ScrollView scrollY className={styles.scroll}>
        <View className={styles.header}>
          <Text className={styles.eyebrow}>ORDER</Text>
          <Text className={styles.title}>
            {phase === 'paid' ? '支付成功' : expired ? '订单已过期' : '等待支付'}
          </Text>
          {order && <Text className={styles.amount}>¥{formatAmount(order.amountCents)}</Text>}
          {phase !== 'paid' && !expired && order && (
            <Text className={styles.countdown} data-testid='order-countdown'>
              剩余支付时间 {remain}
            </Text>
          )}
        </View>

        {phase === 'paid' ? (
          <View className={styles.card}>
            <Text className={styles.cardTitle}>✓ 支付完成，报名已确认</Text>
            <Button
              className={styles.primaryButton}
              data-testid='go-enrollments'
              onClick={() => Taro.reLaunch({ url: '/pages/my-enrollments/index' })}
            >
              查看我的报名
            </Button>
            <Button
              className={styles.textButton}
              data-testid='subscribe-reminder'
              onClick={() => void subscribePayment()}
            >
              {touchpoint.label}
            </Button>
          </View>
        ) : expired ? (
          <View className={styles.card}>
            <Text className={styles.cardTitle}>订单超时未支付，名额已释放</Text>
            <Text className={styles.cardHint}>可重新报名后再下单。</Text>
            <Button
              className={styles.textButton}
              onClick={() => Taro.navigateBack()}
            >
              返回
            </Button>
          </View>
        ) : (
          <>
            {error ? (
              <View className={styles.card}>
                <Text className={styles.cardTitle}>{error}</Text>
                <Button className={styles.primaryButton} data-testid='retry-create' onClick={() => void createOrderFlow()}>
                  重新下单
                </Button>
              </View>
            ) : (
              <View className={styles.card}>
                {credentialError ? (
                  <>
                    <Text className={styles.cardTitle}>{credentialError}</Text>
                    <Text className={styles.cardHint}>可刷新重试或联系组织者。</Text>
                    <Button className={styles.textButton} onClick={() => void createOrderFlow()}>刷新凭据</Button>
                  </>
                ) : (
                  <>
                    <Text className={styles.cardTitle}>微信支付</Text>
                    <Text className={styles.cardHint}>点击下方按钮调起微信支付，完成后本页自动确认。</Text>
                    {depositNotice && (
                      <View className={styles.depositNotice} data-testid='deposit-pay-notice'>
                        <Text className={styles.depositAmount}>{depositNotice.amountText}</Text>
                        <Text className={styles.depositForfeit}>{depositNotice.forfeitText}</Text>
                        {/* 显式同意：整行可点（小程序无表单控件先例，与报名选档同款行选择） */}
                        <View
                          className={styles.ackRow}
                          data-testid='deposit-ack-option'
                          onClick={() => setAck((value) => !value)}
                        >
                          <View className={`${styles.ackBox} ${ack ? styles.ackBoxChecked : ''}`}>
                            {ack && <Text className={styles.ackTick}>✓</Text>}
                          </View>
                          <Text className={styles.ackLabel}>{depositNotice.ackLabel}</Text>
                        </View>
                      </View>
                    )}
                    <Button
                      className={styles.primaryButton}
                      data-testid='request-payment'
                      loading={paying}
                      disabled={!canPay}
                      onClick={() => void requestPayment()}
                    >
                      {paying ? '调起支付…' : ackRequired ? '请先勾选确认' : '立即支付'}
                    </Button>
                    <Button
                      className={styles.textButton}
                      data-testid='subscribe-payment-result'
                      onClick={() => void subscribePayment()}
                    >
                      {touchpoint.label}
                    </Button>
                  </>
                )}
              </View>
            )}

            {manual && !error ? (
              <View className={styles.card}>
                <Text className={styles.cardTitle}>自动确认已暂停（30 秒）</Text>
                <Button className={styles.textButton} data-testid='manual-refresh' onClick={refreshManually}>
                  刷新支付状态
                </Button>
              </View>
            ) : (
              !error && <Text className={styles.pollingHint} data-testid='polling-hint'>正在确认支付状态…（每 2 秒自动刷新）</Text>
            )}
          </>
        )}
      </ScrollView>
    </View>
  )
}
