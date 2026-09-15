import { useCallback, useRef, useState } from 'react'
import { Button, ScrollView, Text, View } from '@tarojs/components'
import Taro, { useDidHide, useDidShow, useRouter, useShareAppMessage, useUnload } from '@tarojs/taro'
import { api } from '@/api'
import { PageState } from '@/components/PageState'
import type { CatalogItem, ContentKind } from '@/domain/models'
import { enrollmentBadgeText, enrollmentBlockedNotice, enrollmentStatusText, formatDateTime, scheduleText, venueText } from '@/domain/format'
import { formatAmount, paymentBlockCopy } from '@/domain/payment'
import { qualificationBadgeText } from '@/domain/initiative'
import styles from './index.module.css'

const policyText: Record<CatalogItem['enrollmentPolicy'], string> = {
  open: '提交后立即确认',
  request: '提交后等待审批',
  invite_only: '需要有效批次码'
}

export function EventRegistrationActions({ item, onRegister }: { item: CatalogItem; onRegister: () => void }) {
  const blockedNotice = enrollmentBlockedNotice(item.enrollmentBadge)
  const enrolled = item.myEnrollment ? <>
    <Text className={styles.enrolledNotice} data-testid='enrolled-notice'>已报名 · {enrollmentStatusText[item.myEnrollment.status]}</Text>
    <Button className={styles.primaryButton} data-testid='view-my-enrollment' onClick={() => Taro.switchTab({ url: '/pages/my-enrollments/index' })}>查看我的报名</Button>
  </> : null
  // 活跃报名最优先：非成班活动「报名截止即 closed」（closed ≠ 活动结束），
  // 截止后、活动开始前已报名用户仍保留「查看我的报名」入口（承载核销码）
  const myStatus = item.myEnrollment?.status
  if (myStatus === 'pending' || myStatus === 'payment_pending' || myStatus === 'confirmed') return enrolled
  if (item.status !== 'open') {
    // closed 按 endsAt 区分：已过 → 活动已结束；未过/未定 → 报名已截止
    const notice = item.status === 'cancelled'
      ? '活动已取消，仅供查看。'
      : item.endsAt && Date.parse(item.endsAt) <= Date.now()
        ? '活动已结束，仅供查看。'
        : '报名已截止，仅供查看。'
    return <Text className={styles.closedNotice} data-testid='archived-event-notice'>{notice}</Text>
  }
  if (item.myEnrollment) return enrolled
  if (blockedNotice) return <Text className={styles.closedNotice} data-testid='registration-closed-notice'>{blockedNotice}</Text>
  return <Button className={styles.primaryButton} data-testid='register-action' onClick={onRegister}>立即报名</Button>
}

export default function EventDetailPage() {
  const router = useRouter()
  const id = router.params.id ?? ''
  const kind = (router.params.kind === 'course' ? 'course' : 'event') as ContentKind
  const [item, setItem] = useState<CatalogItem | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  // #508-A：核销入口门（owner/admin 才显示；探测失败/非成员一律 false）
  const [canCheckIn, setCanCheckIn] = useState(false)
  const requestSeq = useRef(0)

  const load = useCallback(async () => {
    const seq = ++requestSeq.current
    setLoading(true)
    setError('')
    try {
      const result = await api.getContent(kind, id)
      if (seq === requestSeq.current) setItem(result)
      if (seq === requestSeq.current && result.kind === 'event') {
        // 入口探测不阻塞详情主流程：失败即隐藏（真授权在后端 mutation）
        void api.canModerateEvent(result.id).then((allowed) => {
          if (seq === requestSeq.current) setCanCheckIn(allowed)
        })
      }
    } catch (reason) {
      if (seq === requestSeq.current) setError(reason instanceof Error ? reason.message : '详情加载失败')
    } finally {
      if (seq === requestSeq.current) setLoading(false)
    }
  }, [id, kind])

  // 报名/登录后 navigateBack 回本页不 remount：useDidShow 重载详情
  //（my-enrollments/discover/workspace/profile 同款）
  useDidShow(() => { void load() })
  useDidHide(() => { requestSeq.current++ })
  useUnload(() => { requestSeq.current++ })

  const register = async () => {
    if (!item || item.status !== 'open') return
    // 已有活跃报名（pending/payment_pending/confirmed）不再进报名漏斗——
    // 后端唯一索引会拒绝，此处提前收口到「我的报名」（#355 P1-3）
    if (item.myEnrollment) {
      await Taro.switchTab({ url: '/pages/my-enrollments/index' })
      return
    }
    const target = `/pages/register-form/index?id=${item.id}&kind=${item.kind}`
    try {
      const session = await api.getSession()
      if (!session.user) {
        await Taro.navigateTo({ url: `/pages/login/index?returnUrl=${encodeURIComponent(target)}` })
        return
      }
      await Taro.navigateTo({ url: target })
    } catch (reason) {
      Taro.showToast({ title: reason instanceof Error ? reason.message : '暂时无法报名', icon: 'none' })
    }
  }

  useShareAppMessage(() => ({
    title: item?.title ?? '程序媛汇 · 精选活动',
    path: `/pages/event-detail/index?id=${id}&kind=${kind}`
  }))

  if (loading) return <PageState kind='loading' />
  if (error) return <PageState kind='error' message={error} onRetry={load} />
  if (!item) return <PageState kind='empty' message='内容不存在' />

  const payment = paymentBlockCopy(item)

  return (
    <View className={styles.page}>
      <ScrollView scrollY className={styles.scroll}>
        <View className={styles.header}>
          <Text className={styles.kind}>{item.kind === 'event' ? 'EVENT' : 'COURSE'}</Text>
          <Text className={styles.title} data-testid='detail-title'>{item.title}</Text>
          {item.qualificationBadge && <Text data-testid='qualification-badge'>{qualificationBadgeText({ qualificationBadge: item.qualificationBadge, shortBy: item.shortBy })}</Text>}
        </View>

        <View className={styles.metrics}>
          <View className={styles.metric}>
            {/* 公开面以派生标签替代原始计数（KTD1/D2：confirmedCount 对非成员不可读） */}
            <Text className={styles.metricValue} data-testid='enrollment-badge'>{enrollmentBadgeText[item.enrollmentBadge]}</Text>
            <Text className={styles.metricLabel}>报名状态</Text>
          </View>
          <View className={styles.metric}>
            <Text className={styles.metricValue}>{item.registrationDeadline ? formatDateTime(item.registrationDeadline) : '无截止'}</Text>
            <Text className={styles.metricLabel}>报名截止</Text>
          </View>
          <View className={styles.metric}>
            <Text className={styles.metricValue}>{item.enrollmentPolicy === 'request' ? '审批' : '即时'}</Text>
            <Text className={styles.metricLabel}>报名方式</Text>
          </View>
        </View>

        <View className={styles.block}>
          <Text className={styles.blockTitle}>活动信息</Text>
          <View className={styles.row} data-testid='detail-schedule'>
            <Text className={styles.label}>时间</Text>
            <Text className={styles.value}>{scheduleText(item.startsAt, item.endsAt)}</Text>
          </View>
          {item.kind === 'event' && (
            <View className={styles.row} data-testid='detail-venue'>
              <Text className={styles.label}>地点</Text>
              <Text className={styles.value}>{venueText(item.venue) ?? '地点待定'}</Text>
            </View>
          )}
        </View>

        <View className={styles.block} data-testid='payment-block'>
          <Text className={styles.blockTitle}>{payment.title}</Text>
          <Text className={styles.amountLine} data-testid='payment-amount'>{payment.amountText}</Text>
          {payment.tiers.map((tier) => (
            <View key={tier.id} className={styles.row} data-testid={`price-tier-${tier.id}`}>
              <Text className={styles.label}>{tier.name}</Text>
              <Text className={styles.value}>¥{formatAmount(tier.amountCents)}</Text>
            </View>
          ))}
          {payment.notes.map((note) => (
            <Text key={note} className={styles.noteLine} data-testid='payment-note'>{note}</Text>
          ))}
        </View>

        <View className={styles.policyBlock}>
          <Text className={styles.policyTitle}>报名说明</Text>
          <Text className={styles.policyText}>{policyText[item.enrollmentPolicy]}</Text>
          {item.registrationDeadline && (
            <Text className={styles.deadline}>截止：{formatDateTime(item.registrationDeadline)}</Text>
          )}
        </View>
      </ScrollView>

      <View className={styles.footer}>
        {/* 核销页只在全量端注册（裁剪端无管理功能）——入口同口径隐藏 */}
        {canCheckIn && item.kind === 'event' && process.env.TARO_ENV !== 'tt' && process.env.TARO_ENV !== 'xhs' && (
          <Button
            className={styles.checkInEntry}
            data-testid='check-in-entry'
            onClick={() =>
              Taro.navigateTo({
                url: `/pages/check-in/index?eventId=${item.id}&title=${encodeURIComponent(item.title)}`
              })
            }
          >
            扫码核销（主理人）
          </Button>
        )}
        <EventRegistrationActions item={item} onRegister={register} />
      </View>
    </View>
  )
}
