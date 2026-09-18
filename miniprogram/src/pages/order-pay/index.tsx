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
  preCreateDepositGate,
  createOrderSelfHealsToConsent,
  type DepositPayNotice,
  type OrderPollStatus,
  type RequestPaymentArgs,
} from '@/domain/payment'
import type { OrderSummary } from '@/domain/models'
import { paymentResultTouchpoint, requestAndGrant } from '@/domain/subscription'
import { requestPlatformSubscriptions } from '@/platform'
import styles from './index.module.css'

/**
 * 缴费闭环 U12/R13/R14：小程序订单支付页。
 *
 * 链路（#727 重排后）：预检报名快照（paymentMode/depositAmountCents）→ 押金场
 * 先「勾选同意」→ createOrder（带 depositConsent）→ credential(pay_params) →
 * Taro.requestPayment(JSAPI 五键) → 轮询 orderStatus(2s×30s，与 web 同契约) →
 * paid 成功态 / 超窗手动刷新态；倒计时 expire_at。
 *
 * 押金同意门两道（U1 小程序落点 + #727 后端下沉）：
 * - 创单前门：押金场的判据取**报名快照**（paymentMode 识别 + depositAmountCents
 *   表态，与 web /orders/new 同源）——勾选后才创单，创单请求携带 depositConsent:
 *   true；后端按 order_kind 复核（缺失即拒 order_deposit_consent_required，本页
 *   落可重试错误态）。
 * - 支付前门：判据是**订单自己的口径快照** `order.orderKind` + `order.amountCents`
 *   （后端 order_kind/报名时物化的押金快照），不是活动的实时缴费配置——活动随时
 *   可改配置，这一笔不会；金额创单前用报名快照、创单后一律切到订单快照。判据为
 *   纯函数 preCreateDepositGate / canRequestPayment，本页只渲染。
 *
 * e2e 边界(#172 已定)：真实支付调起不可自动化，端到端止于订单生成 + 凭据
 * 返回；requestPayment 之后的行为由单测(纯逻辑)与真实小额验收覆盖。
 */
type Phase = 'preflight' | 'consent' | 'creating' | 'await' | 'paid'

/** 页头标题按阶段（paid/expired 另有口径，在渲染处前置） */
const PHASE_TITLE: Record<Phase, string> = {
  preflight: '等待支付',
  consent: '押金确认',
  creating: '等待支付',
  await: '等待支付',
  paid: '支付成功'
}

export default function OrderPayPage() {
  const router = useRouter()
  const enrollmentId = router.params.enrollmentId ?? ''

  const [order, setOrder] = useState<OrderSummary | null>(null)
  const [paymentArgs, setPaymentArgs] = useState<RequestPaymentArgs | null>(null)
  const [credentialError, setCredentialError] = useState('')
  const [paying, setPaying] = useState(false)
  const [phase, setPhase] = useState<Phase>('preflight')
  const [pollElapsed, setPollElapsed] = useState(0)
  const [manualMode, setManualMode] = useState(false)
  const [now, setNow] = useState(Date.now)
  const [error, setError] = useState('')
  const [ack, setAck] = useState(false)
  // 创单前押金门（预检结果）：required 时先出披露 + 勾选
  // 创单前押金门：非 null = 押金场（先披露 + 勾选），null = 直接创单
  const [gate, setGate] = useState<DepositPayNotice | null>(null)
  const startedRef = useRef(false)

  // 下单：凭据即取，失败可重试。同意标记 = 预检判定押金且本页已勾选
  // （后端 fail-closed 复核，非押金单忽略该字段）。
  // 同帧连点锁（#751-①）：setState 异步生效，快速双击两次 click 都带旧 state，
  // disabled 拦不住——ref 在第一次进入时即置位，第二次直接返回（防双创单）
  const creatingRef = useRef(false)
  const createOrderFlow = useCallback(async () => {
    if (!enrollmentId || creatingRef.current) return
    creatingRef.current = true
    setPhase('creating')
    setError('')
    try {
      const created = await api.createOrder(enrollmentId, gate !== null && ack)
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
      // 自愈（#751-②）：后端判押金而本端预检未识别（预检失败/旧缓存）→
      // 拒单转「披露 + 勾选」流程，勾选后重试带 depositConsent，不再同构死循环
      if (createOrderSelfHealsToConsent(reason)) {
        setGate(depositPayNotice(null))
        setError('')
        setPhase('consent')
        return
      }
      setError(reason instanceof Error ? reason.message : '下单失败，请重试')
    } finally {
      creatingRef.current = false
    }
  }, [enrollmentId, gate, ack])

  // 预检 + 创单（进页一次；错误卡的「重新下单」重跑本函数，ack 保留）：
  // 押金场先停 consent（勾选 → 创单），非押金场直接创单。预检抛错（网络/会话）
  // → 不创单：押金事实未知时创单可能撞后端同意门，落可重试错误态更诚实；
  // 查无（null，他人报名/未登录）照旧交给 createOrder 的业务错误兜底。
  const startFlow = useCallback(async () => {
    if (!enrollmentId) return
    setPhase('preflight')
    setError('')
    let next: DepositPayNotice | null
    try {
      next = preCreateDepositGate(await api.getEnrollment(enrollmentId))
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : '读取报名信息失败，请重试')
      return
    }
    setGate(next)
    if (next) {
      setPhase('consent')
      return
    }
    await createOrderFlow()
  }, [enrollmentId, createOrderFlow])

  useEffect(() => {
    if (startedRef.current || !enrollmentId) return
    startedRef.current = true
    void startFlow()
  }, [enrollmentId, startFlow])

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
  const subscribePayment = () =>
    requestAndGrant(touchpoint, {
      request: requestPlatformSubscriptions,
      grant: (scenario) => api.grantConsent(scenario),
      notify: ({ kind, title }) => Taro.showToast({ title, icon: kind === 'accepted' ? 'success' : 'none' })
    })

  // 押金披露 + 勾选行（两道门共用同一段标记：判据不同源——创单前=报名快照、
  // 支付前=订单快照——但披露口径与 e2e 锚点必须同形；类名留在本页 wxss）
  const depositAckBlock = (notice: DepositPayNotice) => (
    <View className={styles.depositNotice} data-testid='deposit-pay-notice'>
      <Text className={styles.depositAmount}>{notice.amountText}</Text>
      <Text className={styles.depositForfeit}>{notice.forfeitText}</Text>
      {/* 显式同意：整行可点（小程序无表单控件先例，与报名选档同款行选择） */}
      <View
        className={styles.ackRow}
        data-testid='deposit-ack-option'
        onClick={() => setAck((value) => !value)}
      >
        <View className={`${styles.ackBox} ${ack ? styles.ackBoxChecked : ''}`}>
          {ack && <Text className={styles.ackTick}>✓</Text>}
        </View>
        <Text className={styles.ackLabel}>{notice.ackLabel}</Text>
      </View>
    </View>
  )

  if (!enrollmentId) return <PageState kind='empty' message='缺少报名信息' />
  if ((phase === 'preflight' || phase === 'creating') && !error)
    return <PageState kind='loading' />

  return (
    <View className={styles.page}>
      <ScrollView scrollY className={styles.scroll}>
        <View className={styles.header}>
          <Text className={styles.eyebrow}>ORDER</Text>
          <Text className={styles.title}>
            {phase === 'paid' ? '支付成功' : expired ? '订单已过期' : PHASE_TITLE[phase]}
          </Text>
          {order && <Text className={styles.amount}>¥{formatAmount(order.amountCents)}</Text>}
          {phase !== 'paid' && !expired && order && (
            <Text className={styles.countdown} data-testid='order-countdown'>
              剩余支付时间 {remain}
            </Text>
          )}
        </View>

        {phase === 'consent' && gate ? (
          // 创单前门（#727）：勾选 → 创单（带 consent）→ 支付。披露金额 = 报名
          // 快照（与后端下单实付同源）；未勾选不创单，零订单零凭据。
          <View className={styles.card}>
            <Text className={styles.cardTitle}>押金支付</Text>
            <Text className={styles.cardHint}>请先阅读并同意押金条款，同意后创建订单。</Text>
            {depositAckBlock(gate)}
            <Button
              className={styles.primaryButton}
              data-testid='create-order-with-consent'
              disabled={!ack}
              onClick={() => void createOrderFlow()}
            >
              {ack ? '同意并支付' : '请先勾选确认'}
            </Button>
          </View>
        ) : phase === 'paid' ? (
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
                {/* 重试重跑「预检 →（押金则）同意 → 创单」：首单若因押金事实识别
                    失败被后端拒，只重发创单会死循环；ack 保留不重置（#727） */}
                <Button className={styles.primaryButton} data-testid='retry-create' onClick={() => void startFlow()}>
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
                    {depositNotice && depositAckBlock(depositNotice)}
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
