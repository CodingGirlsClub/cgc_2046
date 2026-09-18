import { useCallback, useEffect, useRef, useState } from 'react'
import { Button, ScrollView, Text, View } from '@tarojs/components'
import Taro, { useDidHide, useDidShow, useRouter, useShareAppMessage, useUnload } from '@tarojs/taro'
import { api } from '@/api'
import { getPublicInitiatives } from '@/api/initiatives'
import { PageState } from '@/components/PageState'
import type { CatalogItem, ContentKind, PublicInitiativeCard } from '@/domain/models'
import { enrollmentBlockedNotice, enrollmentMetricText, enrollmentStatusText, formatDateTime, scheduleText, venueText } from '@/domain/format'
import { paymentBlockCopy, tierAmountText } from '@/domain/payment'
import { detailQualificationBadgeText } from '@/domain/initiative'
import { buildInitiativeSharePath } from '@/domain/share-route'
import { moderatorTouchpoint } from '@/domain/subscription'
import { requestPlatformSubscriptions } from '@/platform'
import styles from './index.module.css'

const policyText: Record<CatalogItem['enrollmentPolicy'], string> = {
  open: '提交后立即确认',
  request: '提交后等待审批',
  invite_only: '需要有效批次码'
}

export function EventRegistrationActions({ item, onRegister }: { item: CatalogItem; onRegister: () => void }) {
  // 报名门双门（status 优先，badge 兜底）单源在 domain/format：非 open 恒有提示
  const blockedNotice = enrollmentBlockedNotice(item)
  const enrolled = item.myEnrollment ? <>
    <Text className={styles.enrolledNotice} data-testid='enrolled-notice'>已报名 · {enrollmentStatusText[item.myEnrollment.status]}</Text>
    <Button className={styles.primaryButton} data-testid='view-my-enrollment' onClick={() => Taro.switchTab({ url: '/pages/my-enrollments/index' })}>查看我的报名</Button>
  </> : null
  // 活跃报名最优先：非成班活动「报名截止即 closed」（closed ≠ 活动结束），
  // 截止后、活动开始前已报名用户仍保留「查看我的报名」入口（承载核销码）
  const myStatus = item.myEnrollment?.status
  if (myStatus === 'pending' || myStatus === 'payment_pending' || myStatus === 'confirmed') return enrolled
  if (item.status !== 'open') {
    // 归档场（cancelled/closed）：文案由双门单源给（closed 按 endsAt 分已结束/已截止）
    return <Text className={styles.closedNotice} data-testid='archived-event-notice'>{blockedNotice}</Text>
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

  // 挂载 Initiative 的回链（对齐 web public-offering-detail）：initiativeId →
  // 公开卡片查 name/slug；initiative 非公开或查询失败均不渲染回链。
  const [initiative, setInitiative] = useState<PublicInitiativeCard | null>(null)
  const initiativeId = item?.kind === 'event' ? item.initiativeId : null
  useEffect(() => {
    if (!initiativeId) {
      setInitiative(null)
      return
    }
    let cancelled = false
    getPublicInitiatives()
      .then((cards) => {
        if (!cancelled) setInitiative(cards.find((card) => card.id === initiativeId) ?? null)
      })
      .catch(() => {
        if (!cancelled) setInitiative(null)
      })
    return () => { cancelled = true }
  }, [initiativeId])

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

  // M5 主理人订阅（仅 canCheckIn 时渲染入口，见下方 footer）
  const subscribeModerator = async () => {
    const touchpoint = moderatorTouchpoint()
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
  const badgeText = detailQualificationBadgeText(item)

  return (
    <View className={styles.page}>
      <ScrollView scrollY className={styles.scroll}>
        <View className={styles.header}>
          <Text className={styles.kind}>{item.kind === 'event' ? 'EVENT' : 'COURSE'}</Text>
          <Text className={styles.title} data-testid='detail-title'>{item.title}</Text>
          {/* open 与报名标签语义重复，详情页不展示（对齐 web QualificationBadgeTag） */}
          {badgeText && <Text className={styles.qualificationBadge} data-testid='qualification-badge'>{badgeText}</Text>}
          {initiative && (
            <Text
              className={styles.initiativeLink}
              onClick={() => Taro.navigateTo({ url: buildInitiativeSharePath(initiative.slug) })}
            >
              所属倡导活动：{initiative.name} →
            </Text>
          )}
        </View>

        <View className={styles.metrics}>
          <View className={styles.metric}>
            {/* 公开面以派生标签替代原始计数（KTD1/D2：confirmedCount 对非成员不可读）；
                归档场（非 open）显示条目状态词，避免「报名中 + 已取消」并列（#574） */}
            <Text className={styles.metricValue} data-testid='enrollment-badge'>{enrollmentMetricText(item)}</Text>
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
              {/* #687：脏金额不表态——「金额待定」，绝不 ¥0/¥0.00 */}
              <Text className={styles.value}>{tierAmountText(tier, '金额待定')}</Text>
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
          <>
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
            {/* M5：唯一能证明「我是主理人」的页面（canModerateEvent 门），也是
                event_moderator_assigned 自身的深链落页。鸡生蛋取舍：用户正是通过
                该通知才首次得知被指派，故**第一次指派必然送不到**；此处覆盖的是
                「已是某活动主理人者订阅后续指派」。 */}
            <Button
              className={styles.checkInEntry}
              data-testid='subscribe-moderator'
              onClick={subscribeModerator}
            >
              {moderatorTouchpoint().label}
            </Button>
          </>
        )}
        <EventRegistrationActions item={item} onRegister={register} />
      </View>
    </View>
  )
}
