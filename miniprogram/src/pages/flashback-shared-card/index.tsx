/**
 * 公开卡页（#771）：朋友点开分享链接看到的全文卡。
 *
 * 三条硬约束：
 * 1. **只读**。访客面没有编辑、没有雾面开关、没有隐私设置——那些是本人的面。
 *    本页提供「找回我的闪念间」、公开金句墙与重试入口。
 * 2. **只走匿名读**。`getFlashbackSharedCard(shareId)` 不带任何 token：shareId
 *    是公开标识，转发链里不该夹本人面参数，页面也不该拿它去换写权限。
 * 3. **两种空态分开**。`null` = 这张卡已经收回（终局，不给重试——重试一个已被
 *    关闭的链接只会重复失败）；抛错 = 网络/服务端故障（可重试）。混成一个
 *    「加载失败」会让「作者关了分享」看起来像网络抖动。
 *
 * 加载时机 = `useDidShow`（首载 + 每次重新可见）。**每次加载都先清空**再发请求：
 * 留着旧卡等于给「作者刚关掉分享」留一个继续展示的窗口，任何失败都落错误态，
 * 不退回上一次成功的内容。换卡（shareId 变化）同理——先清空才不会出现一帧
 * 「B 的标题配 A 的正文」。
 */
import { useCallback, useEffect, useRef, useState } from 'react'
import { Button, Text, View } from '@tarojs/components'
import Taro, { useDidShow, useRouter, useShareAppMessage, useShareTimeline } from '@tarojs/taro'
import { api } from '@/api'
import { PageState } from '@/components/PageState'
import SharedFlashbackCard from '@/components/SharedFlashbackCard'
import { buildFlashbackCardSharePath, buildFlashbackJourneyPath } from '@/domain/share-route'
import type { FlashbackSharedCard as SharedCard } from '@/domain/models'
// 转发卡片图 = 品牌火苗（构建期保证资产存在），绝不截本人卡面
import shareCardImage from '@/assets/brand/cgc-flame.png'
import styles from './index.module.css'

type Mode =
  | { kind: 'loading' }
  /** 分享被关掉 / 卡不存在 / 档案已删 —— 终局，不给重试（重试没有意义） */
  | { kind: 'unavailable' }
  /** 网络或服务端故障 —— 可重试 */
  | { kind: 'error'; message: string }
  | { kind: 'ready'; card: SharedCard }

export default function FlashbackSharedCardPage() {
  const router = useRouter()
  const shareId = typeof router.params.shareId === 'string' ? router.params.shareId : ''
  const [mode, setMode] = useState<Mode>({ kind: 'loading' })
  // 请求序号：换卡/重试时旧响应不得覆盖新内容（同 discover 页 requestSeq 先例）
  const requestSeq = useRef(0)

  const load = useCallback(async () => {
    if (!shareId) {
      setMode({ kind: 'unavailable' })
      return
    }
    const seq = ++requestSeq.current
    // **先清空再加载**：留着旧卡等于给「作者刚关掉分享」留一个继续展示的窗口。
    // 任何失败都落在错误态上，不会退回上一次成功的内容。
    setMode({ kind: 'loading' })
    try {
      const card = await api.getFlashbackSharedCard(shareId)
      if (seq !== requestSeq.current) return
      setMode(card ? { kind: 'ready', card } : { kind: 'unavailable' })
    } catch (error) {
      if (seq !== requestSeq.current) return
      setMode({ kind: 'error', message: error instanceof Error ? error.message : '这张卡暂时打不开' })
    }
  }, [shareId])

  useEffect(() => {
    void Taro.setNavigationBarTitle({ title: '闪念间 · 一张卡' }).catch(() => {})
    // 卸载时作废在途响应：晚到的 setMode 不写进已销毁的页面
    return () => {
      requestSeq.current++
    }
  }, [])

  useDidShow(() => {
    void load()
  })

  const shareReady = mode.kind === 'ready'
  useEffect(() => {
    // 收回态/故障态不留转发入口：转发一个已经失效的链接，等于把朋友送到
    // 「这张卡已经收回」。失败静默——菜单可见性只是体验，真正的门在下面
    // onShareAppMessage 的返回值上。
    if (shareReady) {
      void Taro.showShareMenu({ withShareTicket: false, showShareItems: ['shareAppMessage'] }).catch(() => {})
    } else {
      void Taro.hideShareMenu().catch(() => {})
    }
  }, [shareReady])

  useShareAppMessage(() => {
    // 标题刻意中性：转发文案里不带卡主身份（转发链会被继续转下去）。
    // 回调内零副作用：转发面板每次打开都会调用它。
    const title = '闪念间 · 一张卡'
    if (!shareReady || !shareId) return { title, path: buildFlashbackJourneyPath(), imageUrl: shareCardImage }
    return { title, path: buildFlashbackCardSharePath(shareId), imageUrl: shareCardImage }
  })

  useShareTimeline(() => ({
    title: '闪念间 · 一张卡',
    // 朋友圈的 path 恒为当前页，故 shareId 只能走 query
    query: `shareId=${encodeURIComponent(shareId)}`,
    imageUrl: shareCardImage
  }))

  const voicesLink = <Button className={styles.voicesLink} onClick={() => void Taro.navigateTo({ url: '/pages/flashback-voices/index' })}>看更多声音 · 去金句墙 →</Button>

  const goJourney = () => {
    void Taro.navigateTo({ url: buildFlashbackJourneyPath() })
  }

  if (mode.kind === 'loading') {
    return <PageState kind='loading' title='正在显影…' />
  }

  if (mode.kind === 'unavailable') {
    return (
      <View className={styles.page}>
        <View className={styles.terminalBlock}>
          {voicesLink}
          <Text className={styles.terminalEyebrow}>IN A FLASH · 闪念间</Text>
          <Text className={styles.terminalTitle}>这张卡已经收回</Text>
          <Text className={styles.terminalBody}>
            她关掉了这张卡的公开分享。已经打开过的人不受影响，链接不再生效。
          </Text>
          <Button className={styles.terminalAction} hoverClass={styles.pressed} onClick={goJourney}>
            找回我的闪念间 →
          </Button>
        </View>
      </View>
    )
  }

  if (mode.kind === 'error') {
    return (
      <View className={styles.page}>
        <PageState kind='error' message={mode.message} onRetry={() => void load()} />
        <View className={styles.retryFoot}>
          <Button className={styles.quietAction} hoverClass={styles.pressed} onClick={goJourney}>
            找回我的闪念间 →
          </Button>
        </View>
      </View>
    )
  }

  return (
    <View className={styles.page}>
      <View className={styles.cardWrap}>
        <SharedFlashbackCard card={mode.card} />
      </View>

      {voicesLink}
      {/* 访客出口：她也有一张。不提供任何本人面动作（编辑/雾面/隐私设置） */}
      <Button className={styles.journeyAction} data-testid='fb-shared-journey' hoverClass={styles.pressed} onClick={goJourney}>
        找回我的闪念间 →
      </Button>
      <Text className={styles.footNote}>这是她在闪念间写下的一张卡 · 雾住的句子只有她自己能看到</Text>
    </View>
  )
}
