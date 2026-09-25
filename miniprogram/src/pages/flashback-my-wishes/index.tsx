import { useRef, useState } from 'react'
import { Button, Text, View } from '@tarojs/components'
import Taro, { useDidShow, useRouter } from '@tarojs/taro'
import { api } from '@/api'
import { getAuthToken } from '@/api/client'
import { getMyWishes } from '@/api/wishes'
import { wishStatusCopy, wishWriteReturnUrl, type MyWishes, type OwnedWish } from '@/domain/wish-writing'
import { setFlashbackEntry } from '@/state/flashbackEntry'
import { getActiveAccountId } from '@/state/accountState'
import styles from './index.module.css'

export default function MyWishesPage() {
  const router = useRouter()
  const [data, setData] = useState<MyWishes | null>(null)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState('')
  const [guest, setGuest] = useState(true)
  const [deleting, setDeleting] = useState<string | null>(null)
  const generation = useRef(0)
  const deletePending = useRef(false)
  const load = async () => {
    const seq = ++generation.current
    const owner = getActiveAccountId()
    setData(null)
    setError('')
    setGuest(!getAuthToken())
    if (!getAuthToken()) { setLoading(false); return }
    setLoading(true)
    try {
      const result = await getMyWishes()
      if (seq === generation.current && owner === getActiveAccountId()) setData(result)
    } catch (reason) {
      if (seq === generation.current) setError(reason instanceof Error ? reason.message : '读取失败，请重试。')
    } finally { if (seq === generation.current) setLoading(false) }
  }
  useDidShow(() => { void load() })
  const remove = async (wish: OwnedWish) => {
    if (deletePending.current) return
    deletePending.current = true
    const owner = getActiveAccountId()
    try {
      const choice = await Taro.showModal({ title: '删除这个愿望？', content: '删除后不再展示，且不退还今年的许愿额度。此操作无法撤销。', confirmText: '删除', confirmColor: '#963e31' })
      if (!choice.confirm || owner !== getActiveAccountId()) return
      setDeleting(wish.id)
      await api.flashbackDeleteWish(wish.id, null)
      await load()
    } catch (reason) { setError(reason instanceof Error ? reason.message : '删除失败，请重试。') }
    finally { deletePending.current = false; setDeleting(null) }
  }
  return <View className={styles.page}>
    <Text className={styles.eyebrow}>闪念间 · 写给未来</Text>
    <Text className={styles.title}>我的愿望</Text>
    {guest ? <View className={styles.state}>
      <Text>登录后查看自己许下的愿望，无需历史档案。</Text>
      <Button className={styles.primary} onClick={() => Taro.navigateTo({ url: `/pages/login/index?returnUrl=${encodeURIComponent('/pages/flashback-my-wishes/index')}` })}>登录查看</Button>
    </View> : <>
      {loading && <Text className={styles.state}>正在找回你的愿望…</Text>}
      {error && <View className={styles.state}><Text className={styles.error}>{error}</Text><Button className={styles.retry} onClick={() => void load()}>重新加载</Button></View>}
      {data && <>
        <Text className={styles.quota}>今年还可以许 {data.quotaRemaining} 个愿望 · 删除不退还额度</Text>
        {!data.wishes.length && <Text className={styles.state}>你还没有愿望。写下想和大家一起实现的事吧。</Text>}
        {data.wishes.map(wish => <View className={`${styles.wishCard} ${router.params.created === wish.id ? styles.created : ''}`} key={wish.id}>
          <Text className={styles.status}>{router.params.created === wish.id ? '已保存 · ' : ''}{wishStatusCopy(wish.status)}</Text>
          <Text className={styles.content}>{wish.content}</Text>
          <View className={styles.meta}><Text>{wish.signature || '匿名'}{wish.city ? ` · ${wish.city}` : ''}</Text><Button className={styles.deleteWish} disabled={!!deleting} loading={deleting === wish.id} onClick={() => void remove(wish)}>删除</Button></View>
        </View>)}
      </>}
    </>}
    <Button className={styles.primary} onClick={() => Taro.navigateTo({ url: wishWriteReturnUrl() })}>写下我的愿望</Button>
    <Button className={styles.backLink} onClick={() => { setFlashbackEntry('future'); void Taro.switchTab({ url: '/pages/flashback-corridor/index' }) }}>回闪念间，看看大家的愿望 →</Button>
  </View>
}
