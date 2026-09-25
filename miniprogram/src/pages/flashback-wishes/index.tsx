import { useEffect, useState } from 'react'
import { Button, Text, View } from '@tarojs/components'
import Taro, { useRouter, useShareAppMessage, useShareTimeline } from '@tarojs/taro'
import { api } from '@/api'
import { getAuthToken } from '@/api/client'
import { PageState } from '@/components/PageState'
import { VoicesMap } from '@/components/Voices/Map'
import { VoiceCityFilter } from '@/components/Voices/CityFilter'
import { useWishTree } from '@/components/Wishes/useWishTree'
import { EndorseWishSheet } from '@/components/Wishes/EndorseSheet'
import WishEchoCard from '@/components/WishEchoCard'
import { parseCityParam, wishTreeShare } from '@/domain/wish-tree'
import type { ViewerWish } from '@/domain/flashback'
import shareImage from '@/assets/flashback/voices-map.png'
import styles from './index.module.css'

export default function WishesPage() {
  const router = useRouter()
  const feed = useWishTree(router.params.wishId?.trim() || null, parseCityParam(router.params.city))
  const { tree, current, city } = feed
  const [endorse, setEndorse] = useState<ViewerWish | null>(null)
  const [canceling, setCanceling] = useState(false)
  useShareAppMessage(event => ({ ...wishTreeShare(event.from === 'button' && (event.target as { dataset?: { scope?: string } } | undefined)?.dataset?.scope === 'wish' ? current : null), imageUrl: shareImage }))
  useEffect(() => { void Taro.showShareMenu({ showShareItems: ['shareAppMessage', 'shareTimeline'] }) }, [])
  useShareTimeline(() => ({ ...wishTreeShare(current), imageUrl: shareImage }))
  const contribute = async () => {
    if (!current || canceling) return
    if (!getAuthToken()) {
      await Taro.navigateTo({ url: `/pages/login/index?returnUrl=${encodeURIComponent(wishTreeShare(current).path)}` })
      return
    }
    if (!current.endorsedByViewer) { setEndorse(current); return }
    const choice = await Taro.showModal({ title: '取消出力？', content: '取消后将不再以附议者身份接收这条愿望的回响提醒。', confirmText: '确认取消' })
    if (!choice.confirm) return
    setCanceling(true)
    try { await api.flashbackCancelEndorseWish(current.id); feed.reload() }
    catch (reason) { void Taro.showToast({ title: reason instanceof Error ? reason.message : '取消失败，请重试。', icon: 'none' }) }
    finally { setCanceling(false) }
  }
  return <View className={styles.page}>
    <View className={styles.header}>
      <View className={styles.tabs}>
        <Button className={styles.voicesTab} onClick={() => Taro.redirectTo({ url: '/pages/flashback-voices/index' + (city ? `?city=${encodeURIComponent(city)}` : '') })}><Text>金句墙</Text><Text className={styles.english}>VOICES</Text></Button>
        <View className={styles.selectedTab}><Text>许愿树</Text><Text className={styles.english}>WISHES</Text></View>
      </View>
    </View>
    <View className={styles.mapWrap}>
    <VoicesMap cities={feed.cities} selected={current?.city ?? city} caption={current?.content} />
      <Button className={styles.shareTree} openType='share' data-scope='tree'>↗ 分享整树</Button>
    </View>
    <Text className={styles.legend}>青绿 · 山河来处　　金线 · 句长成树</Text>
    <VoiceCityFilter contentKind='愿望' cities={feed.cities} selected={city} loading={feed.citiesLoading} error={feed.citiesError} retry={feed.retryCities} onChange={feed.chooseCity} />
    <View className={styles.reader}>
      <View className={styles.filters}>
        <Button className={`${styles.allFilter} ${!feed.echoesOnly ? styles.activeFilter : ''}`} onClick={() => feed.chooseEchoes(false)}>全部</Button>
        <Button className={`${styles.echoFilter} ${feed.echoesOnly ? styles.activeFilter : ''}`} onClick={() => feed.chooseEchoes(true)}>已有回响</Button>
      </View>
      {tree.status === 'loading' && <PageState kind='loading' title='正在看看大家的愿望…' />}
      {tree.status === 'error' && <PageState kind='error' message={tree.error} onRetry={feed.retry} />}
      {tree.status === 'gone' && <View className={styles.state}><Text className={styles.stateTitle}>这个愿望，目前无法查看。</Text><Text className={styles.stateCopy}>它可能已被收回。来看看其他人的愿望吧。</Text><Button className={styles.allTree} onClick={feed.all}>看看整棵许愿树 →</Button></View>}
      {tree.status === 'ready' && !current && <View className={styles.state}><Text className={styles.stateTitle}>{feed.echoesOnly ? '这里还没有公开的回响。' : '这里，等着新的愿望。'}</Text><Text className={styles.stateCopy}>{city ? `${city}的这片枝头暂时空着。` : '每个愿望，都可能成为下一次相聚。'}</Text><Button className={styles.allTree} onClick={feed.all}>看看全部愿望 →</Button></View>}
      {current && <>
        <Text className={styles.content}>{current.content}</Text>
        <View className={styles.meta}><Text className={styles.author}>{current.signature || '匿名'} · {current.city || '城市不限'}</Text><Button className={styles.shareWish} openType='share' data-scope='wish'>分享愿望 ↗</Button></View>
        <Text className={styles.count}><Text className={styles.countNumber}>{current.expectationCount}</Text> 人也在期待</Text>
        <View className={styles.actions}>
          <Button className={`${styles.expect} ${current.expectedByViewer ? styles.expected : ''}`} disabled={feed.expecting} loading={feed.expecting} onClick={() => void feed.toggleExpect()}>{current.expectedByViewer ? '已期待 · 取消' : '我也期待'}</Button>
          <Button className={styles.contribute} disabled={canceling} onClick={() => void contribute()}>{current.endorsedByViewer ? '已出力 · 取消' : '我能出力'}</Button>
        </View>
        <Text className={styles.notice}>出力时，可选择接收新回响的提醒。</Text>
        <WishEchoCard key={current.id} echoes={current.echoes} />
        <View className={styles.pager}>
          <Button className={styles.previous} disabled={tree.appending || tree.rows.length < 2} onClick={() => feed.step(-1)}>← 上一个</Button>
          <Text>{String(tree.rows.findIndex(row => row.id === tree.id) + 1).padStart(2, '0')} / {tree.rows.length}{tree.more ? '+' : ''}</Text>
          <Button className={styles.next} disabled={tree.appending || (tree.rows.length < 2 && !tree.more)} onClick={() => feed.step(1)}>{tree.appending ? '加载中…' : '下一个 →'}</Button>
        </View>
        {tree.error && <View className={styles.appendError}><Text>{tree.error}</Text><Button onClick={feed.retry}>重试</Button></View>}
        <Button className={styles.shuffle} onClick={feed.shuffle}>换一批愿望 ↻</Button>
      </>}
      <View className={styles.footer}>
        <Button className={styles.writeWish} onClick={() => Taro.navigateTo({ url: '/pages/flashback-wish-write/index' })}>写下我的愿望</Button>
        <Button className={styles.myWishes} onClick={() => Taro.navigateTo({ url: '/pages/flashback-my-wishes/index' })}>我的愿望 →</Button>
      </View>
    </View>
    {endorse && <EndorseWishSheet key={endorse.id} wish={endorse} paper onClose={() => setEndorse(null)} onSaved={() => { setEndorse(null); feed.reload() }} />}
  </View>
}
