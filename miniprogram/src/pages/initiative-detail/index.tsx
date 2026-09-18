import { Text, View } from '@tarojs/components'
import Taro, { useDidHide, useDidShow, useRouter, useShareAppMessage, useUnload } from '@tarojs/taro'
import { useCallback, useRef, useState } from 'react'
import { getPublicInitiative } from '@/api/initiatives'
import { PageState } from '@/components/PageState'
import type { PublicInitiative } from '@/domain/models'
import { formatDateTime, scheduleText, venueText } from '@/domain/format'
import { initiativeCancelledNotice, initiativeStatusText, participationConditionText, qualificationBadgeText } from '@/domain/initiative'
import { buildInitiativeSharePath } from '@/domain/share-route'
import styles from './index.module.css'

export function InitiativeContent({ data }: { data: PublicInitiative }) {
  const counters = [
    ['城市', data.cityCount], ['场次', data.eventCount],
    ['报名', data.confirmedCount], ['成班', data.qualifiedEventCount]
  ] as const

  return (
    <View className={styles.page}>
      <Text className={styles.status}>{initiativeStatusText(data.status)}</Text>
      {initiativeCancelledNotice(data.status) && <Text className={styles.cancelled}>{initiativeCancelledNotice(data.status)}</Text>}
      <Text className={styles.title} data-testid='initiative-title'>{data.name}</Text>
      {data.hashtag && <Text className={styles.hashtag}>{data.hashtag}</Text>}
      <Text className={styles.meta}>{scheduleText(data.windowStartsAt, data.windowEndsAt)}</Text>
      {data.description && <Text className={styles.description}>{data.description}</Text>}
      <View className={styles.counters}>
        {counters.map(([label, count]) => (
          <View key={label} className={styles.counter}>
            <Text className={styles.count}>{count}</Text><Text className={styles.label}>{label}</Text>
          </View>
        ))}
      </View>
      {data.cities.length === 0 ? <PageState kind='empty' message='暂时还没有公开场次' /> : data.cities.map((group) => (
        <View key={group.city} className={styles.group}>
          <Text className={styles.city}>{group.city}</Text>
          {group.events.map((event) => (
            <View key={event.id} className={styles.card} data-testid={`initiative-event-${event.id}`}
              onClick={() => Taro.navigateTo({ url: `/pages/event-detail/index?id=${encodeURIComponent(event.id)}&kind=event` })}>
              <Text className={styles.event}>{event.title}</Text>
              <Text className={styles.schedule}>{scheduleText(event.startsAt, event.endsAt)}</Text>
              <Text className={styles.cardMeta}>地点：{venueText(event.venue) ?? '地点待定'}</Text>
              <Text className={styles.cardMeta}>报名截止：{event.registrationDeadline ? formatDateTime(event.registrationDeadline) : '无截止'}</Text>
              {/* 参与条件（#627）：缴费槽单槽三态 + 年龄门槛存在性；成班进度仍只由徽章承载 */}
              <Text className={styles.condition} data-testid='initiative-event-condition'>{participationConditionText(event)}</Text>
              <Text className={styles.badge}>{qualificationBadgeText(event)}</Text>
              <Text className={styles.link}>{event.archived ? '查看活动留档' : '查看活动详情'} →</Text>
            </View>
          ))}
        </View>
      ))}
    </View>
  )
}

export default function InitiativeDetailPage() {
  const slug = useRouter().params.slug ?? ''
  const [data, setData] = useState<PublicInitiative | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const requestSeq = useRef(0)
  const load = useCallback(async () => {
    const seq = ++requestSeq.current
    setLoading(true)
    setError('')
    setData(null)
    try {
      const result = slug ? await getPublicInitiative(slug) : null
      if (seq === requestSeq.current) setData(result)
    } catch (reason) {
      if (seq === requestSeq.current) setError(reason instanceof Error ? reason.message : '活动加载失败')
    } finally {
      if (seq === requestSeq.current) setLoading(false)
    }
  }, [slug])

  useDidShow(() => { void load() })
  useDidHide(() => { requestSeq.current++ })
  useUnload(() => { requestSeq.current++ })
  useShareAppMessage(() => ({
    title: data?.name ?? '程序媛汇 · 倡导活动',
    path: buildInitiativeSharePath(slug)
  }))

  if (loading) return <PageState kind='loading' />
  if (error) return <PageState kind='error' message={error} onRetry={load} />
  if (!data) return <PageState kind='empty' title='活动不存在' message='活动可能尚未公开，请返回发现页查看其他活动。' />
  return <InitiativeContent data={data} />
}
