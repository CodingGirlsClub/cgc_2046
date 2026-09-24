import { useCallback, useEffect, useMemo, useState } from 'react'
import { Button, ScrollView, Text, View } from '@tarojs/components'
import Taro, { useDidShow } from '@tarojs/taro'
import { api, SessionExpiredError } from '@/api'
import { AppTabBar } from '@/components/AppTabBar'
import { CheckInQr } from '@/components/CheckInQr'
import { PageState } from '@/components/PageState'
import { buildCheckInPayload } from '@/domain/checkin'
import { groupEnrollmentsByTarget } from '@/domain/enrollment-group'
import { checkInCodeText, enrollmentHistoryTimeText, enrollmentScheduleText, enrollmentStatusText, enrollmentVenueText, formatDateTime, remainingLabel } from '@/domain/format'
import type { EnrollmentSummary, OrderSummary, SubscriptionScenario } from '@/domain/models'
import {
  enrollmentCardTouchpoint,
  refundCardTouchpoint,
  requestAndGrant,
  type SubscriptionFeedback
} from '@/domain/subscription'
import { requestPlatformSubscriptions } from '@/platform'
import { cancelConfirmCopy, cancelRefundRuleText, enrollmentPaymentText, paidEnrollmentIds } from '@/domain/payment'
import styles from './index.module.css'

// 本页两个订阅触点（M2/M3 卡 + M7 付费卡）共用的注入式 deps——
// 反馈通道 = toast（accepted → success，其余 none），语义见 domain/subscription.ts。
const subscriptionDeps = {
  request: requestPlatformSubscriptions,
  grant: (scenario: SubscriptionScenario) => api.grantConsent(scenario),
  notify: ({ kind, title }: SubscriptionFeedback) =>
    Taro.showToast({ title, icon: kind === 'accepted' ? 'success' : 'none' })
}

export default function MyEnrollmentsPage() {
  const [items, setItems] = useState<EnrollmentSummary[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  // #355 P0-2：登录失效空态（区别于「还没有报名记录」假空态）
  const [expired, setExpired] = useState(false)
  const [now, setNow] = useState(Date.now)
  const [cancellingId, setCancellingId] = useState<string | null>(null)
  // #411 折叠历史区的展开态（本地态，按组键=latest.id；刷新/重载后收起）
  const [expandedGroups, setExpandedGroups] = useState<Record<string, boolean>>({})
  // 缴费链订单（R16）：卡面缴费文案由 domain 纯函数从报名 × 订单推导
  const [orders, setOrders] = useState<OrderSummary[]>([])
  // 卡面缴费文案：按 orders/items 变化派生一次（纯函数仍是唯一口径）
  const paymentTexts = useMemo(
    () => new Map(items.map((item) => [item.id, enrollmentPaymentText(item, orders)])),
    [items, orders],
  )
  // M7 付费卡触点门（#683）：缴费事实报名 id 集，同款派生
  const paidIds = useMemo(() => paidEnrollmentIds(orders), [orders])

  const load = useCallback(async () => {
    setLoading(true)
    setError('')
    setExpired(false)
    try {
      const [enrollments, orderList] = await Promise.all([api.getEnrollments(), api.getMyOrders()])
      setOrders(orderList)
      setItems(enrollments)
    } catch (reason) {
      // 掉线 ≠ 没有报名：SessionExpiredError → 重登空态，其余照常报错
      if (reason instanceof SessionExpiredError) setExpired(true)
      else setError(reason instanceof Error ? reason.message : '报名记录加载失败')
    } finally {
      setLoading(false)
    }
  }, [])

  useDidShow(() => { void load() })

  // 登录后 navigateBack 回本页，useDidShow 重载列表
  const goLogin = () => Taro.navigateTo({ url: '/pages/login/index' })
  useEffect(() => {
    const hasCountdown = items.some((item) => item.status === 'pending' && item.approvalDeadline)
    if (!hasCountdown) return undefined
    const timer = setInterval(() => setNow(Date.now()), 60_000)
    return () => clearInterval(timer)
  }, [items])

  // M2/M3：按条目类型分派——活动卡订阅「开始 + 改期」，课程卡订阅「学习停滞」。
  // （既有实现不分类型一律请求 event_reminder，而课程报名收不到该模板，属错配；
  // 判据与文案见 domain/subscription.ts，由 tests/subscription-domain.test.ts 钉住。）
  const subscribeReminder = (item: EnrollmentSummary) =>
    requestAndGrant(enrollmentCardTouchpoint(item.kind), subscriptionDeps)
  // M7 付费卡（#683）：资金类三键（退款×2 + 过期）的付款人腿，恰满单次上限 3。
  const subscribeRefund = () => requestAndGrant(refundCardTouchpoint(), subscriptionDeps)

  const cancelEnrollment = async (item: EnrollmentSummary) => {
    const modal = await Taro.showModal({
      title: '取消报名',
      // 弹窗正文单源 = domain 纯函数（与后端 cancel 行为逐句对齐：押金场截止前
      // 自助取消由后端同事务自动退款，规则见卡片常驻行；仅非押金场已付单提示联系组织者）
      content: cancelConfirmCopy({
        status: item.status,
        paymentMode: item.paymentMode,
        hasPaidOrder: orders.some((order) => order.enrollmentId === item.id && order.status === 'paid')
      })
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
  // #411：同 (kind, targetId) 多条折叠——最新条主卡片（全部操作只属于它），
  // 其余进「历史记录」只读区
  const groups = groupEnrollmentsByTarget(items)

  return (
    <View className={styles.page}>
      <View className={styles.header}>
        <Text className={styles.eyebrow}>MY ENROLLMENTS</Text>
        <Text className={styles.title}>我的报名</Text>
        <Text className={styles.subtitle}>状态变化会同步到这里。</Text>
      </View>

      <ScrollView scrollY className={`${styles.list} ${process.env.TARO_ENV === 'weapp' ? styles.listPlain : ''}`}>
        {loading ? (
          <PageState kind='loading' />
        ) : error ? (
          <PageState kind='error' message={error} onRetry={load} />
        ) : expired ? (
          <PageState
            kind='empty'
            title='登录已过期'
            message='重新登录后即可查看你的报名记录'
            action={{ label: '去登录', onClick: goLogin }}
            testId='session-expired'
          />
        ) : items.length === 0 ? (
          <PageState kind='empty' message='还没有报名记录，去发现页看看吧' />
        ) : groups.map((group) => {
          const item = group.latest
          const expanded = expandedGroups[item.id] === true
          const paymentText = paymentTexts.get(item.id) ?? null
          const checkInCode = checkInCodeText(item.status, item.checkInCode)
          const canCancel = item.status === 'pending' || item.status === 'confirmed'
          const scheduleLine = enrollmentScheduleText(item.kind, item.startsAt)
          const venueLine = enrollmentVenueText(item.venue)
          const depositRule = cancelRefundRuleText(item.paymentMode)
          return (
          <View key={item.id} className={styles.card} data-testid={`enrollment-${item.id}`}>
            <View className={styles.cardHeader}>
              <Text className={styles.kind}>{item.kind === 'event' ? '活动' : '课程'}</Text>
              <Text className={`${styles.status} ${styles[item.status]}`}>{enrollmentStatusText[item.status]}</Text>
            </View>
            <Text className={styles.cardTitle}>{item.title}</Text>
            {/* #617：改期/开课提醒的权威落点——时间行无条件（任意状态下都可能被
                通知点进来），地点行仅 venue 可解析时出现；两行置于标题正下方，
                与底部「截止前可自助取消」分层（上=什么时候，下=能不能退） */}
            {scheduleLine && (
              <Text className={styles.schedule} data-testid={`schedule-${item.id}`}>
                {scheduleLine}
              </Text>
            )}
            {venueLine && (
              <Text className={styles.schedule} data-testid={`venue-${item.id}`}>
                {venueLine}
              </Text>
            )}
            {checkInCode && item.kind === 'event' && item.checkInCode && (
              <View className={styles.checkInQr}>
                {/* #508-A：QR 供主理人小程序扫码（payload 自定义格式，非 URL）；
                    渲染失败组件自隐，下方 6 位码手输兜底 */}
                <CheckInQr payload={buildCheckInPayload(item.targetId, item.checkInCode)} />
              </View>
            )}
            {checkInCode && (
              <Text className={styles.checkInCode} data-testid={`check-in-code-${item.id}`}>
                {checkInCode}
              </Text>
            )}
            {item.status === 'confirmed' && paymentText && (
              <Text className={styles.paymentStatus} data-testid={`payment-status-${item.id}`}>
                {paymentText}
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
                  {paymentText}
                </Text>
                {/* U3-R1:JSAPI 调起是 weapp 专属能力——裁剪端(tt/xhs)隐藏去支付
                    按钮,引导网页端完成(零导流文案合规,渠道事实说明)。 */}
                {process.env.TARO_ENV === 'weapp' ? (
                  <Button
                    className={styles.payButton}
                    size='mini'
                    data-testid={`pay-entry-${item.id}`}
                    onClick={() => Taro.navigateTo({ url: `/pages/order-pay/index?enrollmentId=${item.id}` })}
                  >
                    去支付
                  </Button>
                ) : (
                  <Text className={styles.paymentHint}>
                    请在网页端完成支付（本端暂不支持支付调起）。
                  </Text>
                )}
              </>
            )}
            {/* 取消规则常驻行（对齐 web participations）：截止时点 + 押金退改规则，
                在点开弹窗前就立住预期——弹窗正文不再重复退款承诺 */}
            {canCancel && item.registrationDeadline && (
              <Text className={styles.cancelRule} data-testid={`cancel-deadline-${item.id}`}>
                截止前可自助取消：{formatDateTime(item.registrationDeadline)}
              </Text>
            )}
            {canCancel && depositRule && (
              <Text className={styles.paymentHint} data-testid={`deposit-refund-rule-${item.id}`}>
                {depositRule}
              </Text>
            )}
            {canCancel && (
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
                <Button className={styles.textButton} size='mini' onClick={() => void subscribeReminder(item)}>
                  {enrollmentCardTouchpoint(item.kind).label}
                </Button>
              </>
            )}
            {paidIds.has(item.id) && (
              <Button className={styles.textButton} size='mini' onClick={() => void subscribeRefund()}>
                {refundCardTouchpoint().label}
              </Button>
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
            {group.history.length > 0 && (
              <View className={styles.historyBlock}>
                <Text
                  className={styles.historyToggle}
                  data-testid={`history-toggle-${item.id}`}
                  onClick={() => setExpandedGroups((prev) => ({ ...prev, [item.id]: !prev[item.id] }))}
                >
                  历史记录({group.history.length}){expanded ? ' · 收起' : ''}
                </Text>
                {expanded && group.history.map((record) => (
                  <View key={record.id} className={styles.historyRow} data-testid={`history-${record.id}`}>
                    <View className={styles.historyHeader}>
                      <Text className={`${styles.status} ${styles[record.status]}`}>{enrollmentStatusText[record.status]}</Text>
                      <Text className={styles.historyTime}>{enrollmentHistoryTimeText(record.insertedAt)}</Text>
                    </View>
                    {record.rejectionReason && <Text className={styles.historyReason}>原因：{record.rejectionReason}</Text>}
                  </View>
                ))}
              </View>
            )}
          </View>
          )
        })}
      </ScrollView>
      {/* 裁剪端（tt/xhs）仍是 tabBar 页，保留底部 TabBar；微信端已降为
          「我的」页内入口（见 profile），普通页不挂 TabBar */}
      {process.env.TARO_ENV !== 'weapp' && (
        <>
          <Text className={styles.platformTip}>审批结果将通过本端订阅消息通知你</Text>
          <AppTabBar selected='enrollments' />
        </>
      )}
    </View>
  )
}
