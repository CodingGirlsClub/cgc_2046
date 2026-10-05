import { useCallback, useEffect, useRef, useState } from 'react'
import { Button, Text, View } from '@tarojs/components'
import Taro from '@tarojs/taro'
import { api } from '@/api'
import { PageState } from '@/components/PageState'
import type { NotificationItem, NotificationPage } from '@/domain/models'
import { mergeNotifications, notificationRoute } from '@/domain/notifications'
import { accountScopeCurrent, captureAccountScope } from '@/state/accountState'
import { currentPlatform } from '@/platform'
import styles from './index.module.css'

export function NotificationInbox({ userId }: { userId: string }) {
  const [page, setPage] = useState<NotificationPage | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [moreError, setMoreError] = useState('')
  const [pending, setPending] = useState('')
  const generation = useRef(0)

  const load = useCallback(async (after?: string) => {
    const scope = captureAccountScope()
    if (!scope || scope.userId !== userId) return
    const request = ++generation.current
    if (after) { setPending('more'); setMoreError('') }
    else { setLoading(true); setError('') }
    try {
      const result = await api.getNotifications(after)
      if (!accountScopeCurrent(scope) || request !== generation.current) return
      setPage(previous => after && previous ? { ...result, items: mergeNotifications(previous.items, result.items) } : result)
    } catch (reason) {
      if (request !== generation.current) return
      if (!accountScopeCurrent(scope)) { setPage(null); setError('登录状态已变化，请重新登录'); return }
      const message = reason instanceof Error ? reason.message : '通知加载失败'
      if (after) setMoreError(message)
      else setError(message)
    } finally {
      if (request === generation.current) { setLoading(false); setPending('') }
    }
  }, [userId])

  useEffect(() => {
    setPage(null)
    void load()
    return () => { generation.current += 1 }
  }, [load])

  const mark = async (item: NotificationItem) => {
    const scope = captureAccountScope()
    if (!scope || scope.userId !== userId) return
    const request = generation.current
    setPending(item.id)
    try {
      const acknowledged = await api.markNotificationRead(item.id)
      if (!accountScopeCurrent(scope) || request !== generation.current) return
      setPage(previous => previous ? { ...previous, items: mergeNotifications(previous.items, [acknowledged]) } : previous)
    } catch (reason) {
      if (!accountScopeCurrent(scope) || request !== generation.current) return
      void Taro.showToast({ title: reason instanceof Error ? reason.message : '标记失败，请重试', icon: 'none' })
    } finally {
      if (accountScopeCurrent(scope) && request === generation.current) setPending('')
    }
  }

  const open = async (item: NotificationItem) => {
    const route = notificationRoute(item.deepLink, currentPlatform())
    if (!route) return
    try { await Taro[route.method]({ url: route.url }) }
    catch { void Taro.showToast({ title: '无法打开，请稍后重试', icon: 'none' }) }
  }

  const scope = captureAccountScope()
  const visible = scope?.userId === userId
  return (
    <View className={styles.inbox}>
      <View className={styles.heading}>
        <Text className={styles.sectionTitle}>通知收件箱</Text>
        <Button className={styles.refresh} disabled={loading || !!pending} onClick={() => void load()} aria-label='刷新通知收件箱'>刷新</Button>
      </View>
      <Text className={styles.description}>最近 30 天系统生成的通知，不代表渠道已送达。</Text>
      <View className={styles.panel}>
        {!visible ? <PageState kind='error' message='登录状态已变化，请重新登录' /> : loading ? <PageState kind='loading' /> : error ?
          <PageState kind='error' message={error} onRetry={() => void load()} /> : (
          <>
            {page?.source === 'cache' && <View className={styles.cacheNotice}><Text>缓存记录，可能不是最新状态。</Text><Button className={styles.retry} onClick={() => void load()}>重新加载</Button></View>}
            {!page?.items.length ? <PageState kind='empty' message='最近 30 天暂无通知' /> : page.items.map(item => (
              <View key={item.id} className={styles.notification}>
                <View className={styles.rowHeading}><Text className={styles.notificationTitle}>{item.title}</Text><Text className={item.readAt ? styles.read : styles.unread}>{item.readAt ? '已读' : '未读'}</Text></View>
                <Text className={styles.notificationBody}>{item.body}</Text>
                <Text className={styles.time}>{new Date(item.createdAt).toLocaleString('zh-CN')}</Text>
                <View className={styles.actions}>
                  {notificationRoute(item.deepLink, currentPlatform()) && <Button className={styles.viewButton} onClick={() => void open(item)} aria-label={`查看${item.title}`}>查看</Button>}
                  {!item.readAt && <Button className={styles.markButton} loading={pending === item.id} disabled={!!pending} onClick={() => void mark(item)} aria-label={`将${item.title}标为已读`}>标为已读</Button>}
                </View>
              </View>
            ))}
            {moreError && <Text className={styles.error}>{moreError}</Text>}
            {page?.hasMore && <Button className={styles.more} loading={pending === 'more'} disabled={!!pending} onClick={() => void load(page.nextCursor ?? undefined)}>{moreError ? '重试加载更多' : '加载更多'}</Button>}
          </>
        )}
      </View>
    </View>
  )
}
