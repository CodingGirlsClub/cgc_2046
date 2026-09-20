import { useCallback, useEffect, useRef, useState } from 'react'
import { Button, Input, ScrollView, Text, Textarea, View } from '@tarojs/components'
import Taro, { useDidShow, useShareAppMessage, useShareTimeline } from '@tarojs/taro'
import { api } from '@/api'
import { AppTabBar } from '@/components/AppTabBar'
import { PageState } from '@/components/PageState'
import MyCard from '@/components/MyCard'
import { myCardView, quoteLikeBadge, shareMessage, futureEventCards, quoteCandidatesOf, isCandidatePicked, parseQuoteLevel, QUOTE_LEVEL_OPTIONS, TODAY_FIELDS, questionLabel, type QuoteLevel } from '@/domain/flashback'
import { corridorFrames, statsFrames, todayFrameLabel } from '@/domain/flashback-journey'
import { useQuoteLicense, type QuoteSpanPick } from '@/components/MyCard/useQuoteLicense'
import type { FlashbackWish } from '@/domain/models'
import { STORAGE_KEYS } from '@/state/storage'
import { consumeFlashbackEntry, type FlashbackEntryIntent } from '@/state/flashbackEntry'
import type {
  FlashbackCapsule,
  FlashbackClaimResult,
  FlashbackPublicStats
} from '@/domain/models'
import { FlashbackNotBoundError, FlashbackTokenInvalidError } from '@/domain/models'
import styles from './index.module.css'

type Mode =
  | { kind: 'loading' }
  | { kind: 'error'; message: string }
  | { kind: 'member'; capsule: FlashbackCapsule; token: string | null }
  /** 路人围观态（R32）：长廊 + 统计，无任何未授权内容；guide = 回头找到自己档案的出口 */
  | { kind: 'viewer'; stats: FlashbackPublicStats | null; guide: 'login' | 'recover' | null }



/**
 * 长廊（mp 版原型 F corridor；R12/R32/R34）：垂直时间墙「↓ 下滑 = 时间前进」+
 * 城市堆（确定性转角 + 错峰显影）+ ⚡今天格 + 未来段（场次/愿望/私愿，U3-U5），点格进场次页。
 *
 * 三级视角（R32）：
 * ① token/登录档案可读 → 参与态（完整长廊）；
 * ② 登录但库里没有档案 → 先自动匹配认领（flashbackClaim），bound=false →
 *    「找回你的那一张」会话引导；
 * ③ 未登录 → 路人态（公开统计长廊 + 登录引导）。
 */
export default function FlashbackCorridorPage() {
  const [mode, setMode] = useState<Mode>({ kind: 'loading' })
  const [city, setCity] = useState<string | null>(null)
  // U6「看看未来」滚底:scrollIntoView 定位未来段;消费一次即清(回页不再滚)
  const [scrollAnchor, setScrollAnchor] = useState('')
  // U4 开卡层/U7 授权层:分层入口(view=看档案停在合着面;write=错峰翻面+定位今天块)
  const [cardLayer, setCardLayer] = useState<null | 'view' | 'write'>(null)
  // write 模式翻面落定后抽屉内滚动锚点
  const [cardScrollTo, setCardScrollTo] = useState('')
  // U8 快门仪式层:回访进门(原型 G intro)——呼吸快门+「多年前,你写过一些答案」
  const [shutter, setShutter] = useState(false)
  const cardOpenedAt = useRef(0)
  const openCardLayer = (mode: 'view' | 'write') => {
    setCardLayer(mode)
    setCardScrollTo('')
    cardOpenedAt.current = Date.now()
    if (mode === 'write') {
      // 翻面错峰(抽屉升起 0.28s + 翻转 0.9s)完成后滚到今天块
      setTimeout(() => setCardScrollTo('fbTodayBlock'), 1250)
    }
  }
  const [licenseOpen, setLicenseOpen] = useState(false)
  // U7 授权弹层:三档+多选圈选+预览(数据 me;写走 useQuoteLicense 单源)
  const [licensePicks, setLicensePicks] = useState<QuoteSpanPick[]>([])
  const [licenseLevel, setLicenseLevel] = useState<QuoteLevel>('off')
  const [licenseInited, setLicenseInited] = useState(false)
  const { submitLicense } = useQuoteLicense(() => void reloadMember())
  // U7 报名 sheet:点场次卡→详情(押金);报名→event-detail 端内闭环
  const [eventSheet, setEventSheet] = useState<{ id: string; title: string; meta: string } | null>(null)
  const [enrolled, setEnrolled] = useState<string[]>([])
  const [sendingCard, setSendingCard] = useState(false)
  // 金句授权引导(一次性):首程落地或寄出落定且未授权未推过 → 轻推
  const [licenseNudge, setLicenseNudge] = useState(false)
  const maybeNudgeLicense = (level: string) => {
    if (level !== 'off') return
    if (Taro.getStorageSync<boolean>(STORAGE_KEYS.flashbackLicenseNudge)) return
    setLicenseNudge(true)
  }

  // 寄出落定后今天格一次性强调(脉冲 1.5s;静态卡无可点信号,用户不会想到去点)
  const [todayLanded, setTodayLanded] = useState(false)

  /** 寄出落定(U5 三拍收尾):关抽屉 → 滚到 ⚡今天格,让用户看到自己上墙 */
  const sentLanding = () => {
    setCardLayer(null)
    setScrollAnchor('')
    setTimeout(() => setScrollAnchor('todayAnchor'), 350)
    setTodayLanded(true)
    setTimeout(() => setTodayLanded(false), 2000)
    if (mode.kind === 'member') maybeNudgeLicense(parseQuoteLevel(mode.capsule.me.quoteLevel))
  }

  /** 寄出(U5 完整三拍);骨架期:发送 → toast + 交 U5 落定 */
  const sendTodayCard = async () => {
    if (mode.kind !== 'member' || sendingCard) return
    setSendingCard(true)
    try {
      await api.flashbackSendToWall(mode.token ?? "")
      Taro.showToast({ title: '已贴上墙', icon: 'none' })
      await reloadMember()
      sentLanding()
    } catch (error) {
      Taro.showToast({ title: error instanceof Error ? error.message : '寄出失败', icon: 'none' })
    } finally {
      setSendingCard(false)
    }
  }

  const loadStats = useCallback(async (): Promise<FlashbackPublicStats | null> => {
    try {
      return await api.getFlashbackPublicStats()
    } catch {
      return null
    }
  }, [])

  const load = useCallback(
    async (cityFilter?: string | null) => {
      const token = Taro.getStorageSync<string>(STORAGE_KEYS.flashbackToken) || null
      try {
        const capsule = await api.getFlashbackCapsule(cityFilter ?? null, token)
        setMode({ kind: 'member', capsule, token })
      } catch (error) {
        if (error instanceof FlashbackTokenInvalidError) {
          // 链接已失效/被接管：清掉后按无 token 重载（已登录走会话腿，否则路人态）
          Taro.removeStorageSync(STORAGE_KEYS.flashbackToken)
          void load(cityFilter)
          return
        }
        if (error instanceof FlashbackNotBoundError) {
          // 三级视角②：登录自动匹配 → 直接认领（R27 claim 无 token 面）
          let claimed: FlashbackClaimResult | null = null
          try {
            claimed = await api.flashbackClaim(null)
          } catch {
            claimed = null
          }
          if (claimed?.bound) {
            Taro.showToast({ title: `已为你收好 ${claimed.boundCount} 张卡`, icon: 'none' })
            // 认领成功即重拉；若服务端仍报未绑定（数据不一致）落找回引导，
            // 绝不再递归认领（防死循环）
            const capsule = await api.getFlashbackCapsule(cityFilter ?? null, null).catch(() => null)
            if (capsule) {
              setMode({ kind: 'member', capsule, token: null })
              return
            }
            setMode({ kind: 'viewer', stats: await loadStats(), guide: 'recover' })
            return
          }
          setMode({ kind: 'viewer', stats: await loadStats(), guide: 'recover' })
          return
        }
        if ((error as { name?: string }).name === 'SessionExpiredError') {
          setMode({ kind: 'viewer', stats: await loadStats(), guide: 'login' })
          return
        }
        setMode({ kind: 'error', message: error instanceof Error ? error.message : '加载失败' })
      }
    },
    [loadStats]
  )

  // U8:member 就绪(非 welcome 首程)→ 快门仪式层
  useEffect(() => {
    if (mode.kind !== 'member') return
    const params = Taro.getCurrentInstance().router?.params
    if (params?.welcome === '1') return
    if (true) return // TEMP-UAT
    setShutter(true)
    // eslint-disable-next-line react-hooks/exhaustive-deps -- 进页一次性仪式
  }, [mode.kind])

  // 闪念间入口 intent（长廊成为 tabBar 页面后 switchTab 不带 query）：useDidShow
  // 一次性消费，供 future（滚未来段）与 welcome（推金句引导）两处共用——两处
  // 各自消费的话，先跑的那处会把 intent 清掉，后一处永远读不到。
  const entryIntent = useRef<FlashbackEntryIntent | null>(null)

  // useDidShow：登录回跳（returnUrl）后自动重载——路人态升级为参与态的落点；
  // 切 Tab 回本页同样触发（数据刷新）。intent 已消费时本段无副作用。
  useDidShow(() => {
    entryIntent.current = consumeFlashbackEntry()
    void load(city)
    if (entryIntent.current === 'future') {
      setScrollAnchor('')
      setTimeout(() => setScrollAnchor('futureAnchor'), 400)
    }
  })

  // 首程落地（welcome intent）：member 就绪后一次性推金句授权引导
  const welcomeNudged = useRef(false)
  useEffect(() => {
    if (mode.kind !== 'member' || welcomeNudged.current) return
    if (entryIntent.current !== 'welcome') return
    welcomeNudged.current = true
    maybeNudgeLicense(parseQuoteLevel(mode.capsule.me.quoteLevel))
    // eslint-disable-next-line react-hooks/exhaustive-deps -- 落地一次性
  }, [mode.kind])

  // 首次进入（member 数据就绪）→ 定位到「今天」格：长廊按时间序排列，真实
  // 数据的历史场次（2012-2018 六城）会把今天格推到数屏之外，用户点进来第一
  // 眼看不到任何属于自己的东西。只滚一次——切 Tab 回来保持用户自己的位置
  // （手动翻到历史后不该被强拉回来）。
  //
  // 用 scrollTop 精确居中而非 scrollIntoView：后者只能顶部对齐（微信
  // scroll-view 无对齐参数），今天格会贴住黑框上沿；靠插入空白留白来下推
  // 又会在框顶露出空白——测量后把今天格中心对准黑框中心，上方自然是历史
  // 帧的内容。
  const initialCentered = useRef(false)
  const [scrollTop, setScrollTop] = useState<number | undefined>(undefined)

  const centerToday = () => {
    const query = Taro.createSelectorQuery()
    query.select('#fbCapsule').boundingClientRect()
    query.select('#todayAnchor').boundingClientRect()
    query.select('#fbCapsule').scrollOffset()
    query.exec((res) => {
      const [viewport, today, offset] = res as [
        { top: number; height: number } | null,
        { top: number; height: number } | null,
        { scrollTop: number } | null
      ]
      if (!viewport || !today || !offset) {
        // 测量失败（节点未就绪等）→ 退化为顶部对齐，至少让今天格可见
        setScrollAnchor('')
        setTimeout(() => setScrollAnchor('todayAnchor'), 50)
        return
      }
      const next = offset.scrollTop + (today.top - viewport.top) - (viewport.height - today.height) / 2
      setScrollTop(Math.max(0, Math.round(next)))
    })
  }

  useEffect(() => {
    if (mode.kind !== 'member' || initialCentered.current) return
    initialCentered.current = true
    // future intent（用户明确要看未来段）优先于默认定位——useDidShow 已设锚点
    if (entryIntent.current === 'future') return
    setTimeout(centerToday, 300)
    // eslint-disable-next-line react-hooks/exhaustive-deps -- 首次就绪一次性
  }, [mode.kind])

  const pickCity = (next: string | null) => {
    setCity(next)
    void load(next)
  }

  // R14 分享：卡片落旅程入口（朋友从闪念间入口进入）；不带本人 token（R32 边界）
  const shareTitle = mode.kind === 'member' ? shareMessage(mode.capsule.me).title : '闪念间 · 找回当年的自己'
  useShareAppMessage(() => ({ title: shareTitle, path: '/pages/flashback-journey/index' }))
  useShareTimeline(() => ({ title: shareTitle }))


  const openEvent = (key: string) => {
    void Taro.navigateTo({ url: `/pages/flashback-event/index?key=${encodeURIComponent(key)}` })
  }

  // U4 愿望段:私愿折叠(KD2 防瞥屏)/公开愿模态(R6)
  const [privateOpen, setPrivateOpen] = useState(false)
  const [wishModal, setWishModal] = useState<FlashbackWish | null>(null)
  // U5 许愿半屏弹层(KD3):文本+可见性+提交,落位反馈
  const [wishSheet, setWishSheet] = useState(false)
  const [wishDraft, setWishDraft] = useState('')
  const [wishVisibility, setWishVisibility] = useState<'private' | 'public'>('private')
  const [wishComment, setWishComment] = useState('')
  const [wishBusy, setWishBusy] = useState(false)
  const reloadMember = async () => {
    if (mode.kind !== 'member') return
    const capsule = await api.getFlashbackCapsule(city, mode.token).catch(() => null)
    if (capsule) setMode({ ...mode, capsule })
  }

  const submitWish = async () => {
    if (mode.kind !== 'member' || wishBusy || !wishDraft.trim()) return
    setWishBusy(true)
    try {
      await api.flashbackCreateWish(wishDraft.trim(), wishVisibility, mode.token)
      setWishSheet(false)
      setWishDraft('')
      setWishVisibility('private')
      await reloadMember()
      Taro.showToast({ title: wishVisibility === 'public' ? '愿望已上墙' : '已收进你的私人许愿', icon: 'none' })
    } catch (error) {
      Taro.showToast({ title: error instanceof Error ? error.message : '许愿失败', icon: 'none' })
    } finally {
      setWishBusy(false)
    }
  }

  const endorse = async (wish: FlashbackWish) => {
    if (mode.kind !== 'member' || wishBusy) return
    setWishBusy(true)
    try {
      const count = await api.flashbackEndorseWish(wish.id, mode.token)
      Taro.showToast({ title: wish.endorsedByMe ? '已取消附议' : `已附议 · ${count} 人`, icon: 'none' })
      await reloadMember()
      const fresh = (mode.capsule.publicWishes.find((w) => w.id === wish.id) ?? null) as FlashbackWish | null
      if (fresh && wishModal) setWishModal({ ...fresh })
    } catch (error) {
      Taro.showToast({ title: error instanceof Error ? error.message : '操作失败', icon: 'none' })
    } finally {
      setWishBusy(false)
    }
  }

  const addComment = async (wish: FlashbackWish) => {
    if (mode.kind !== 'member' || wishBusy || !wishComment.trim()) return
    setWishBusy(true)
    try {
      await api.flashbackAddWishComment(wish.id, wishComment.trim(), mode.token)
      setWishComment('')
      await reloadMember()
      const fresh = (mode.capsule.publicWishes.find((w) => w.id === wish.id) ?? null) as FlashbackWish | null
      if (fresh) setWishModal(fresh)
      Taro.showToast({ title: '留言已上墙', icon: 'none' })
    } catch (error) {
      Taro.showToast({ title: error instanceof Error ? error.message : '操作失败', icon: 'none' })
    } finally {
      setWishBusy(false)
    }
  }

  const deleteWish = async (wish: FlashbackWish) => {
    if (mode.kind !== 'member' || !wish.mine || wishBusy) return
    const { confirm } = await Taro.showModal({ title: '删除这条愿望?', content: wish.content, confirmText: '删除' })
    if (!confirm) return
    setWishBusy(true)
    try {
      await api.flashbackDeleteWish(wish.id, mode.token)
      setWishModal(null)
      await reloadMember()
      Taro.showToast({ title: '已删除', icon: 'none' })
    } catch (error) {
      Taro.showToast({ title: error instanceof Error ? error.message : '删除失败', icon: 'none' })
    } finally {
      setWishBusy(false)
    }
  }

  const goLogin = () => {
    void Taro.navigateTo({
      url: `/pages/login/index?returnUrl=${encodeURIComponent('/pages/flashback-corridor/index')}`
    })
  }

  if (mode.kind === 'loading') {
    return <PageState kind="loading" title="正在显影…" />
  }

  if (mode.kind === 'error') {
    return <PageState kind="error" message={mode.message} onRetry={() => void load(city)} />
  }

  const frames = mode.kind === 'member' ? corridorFrames(mode.capsule.archives) : statsFrames(mode.stats?.archives ?? [])
  const cities = mode.kind === 'member' ? mode.capsule.cities : []
  const me = mode.kind === 'member' ? mode.capsule.me : null
  const myView = me && mode.kind === 'member' ? myCardView(mode.capsule) : null

  // 「今天写过没」：三处 dock 状态共用判定。遍历 TODAY_FIELDS 单表——原实现
  // 手写 nowStatus/want/say 三项，**漏了 need**（只填「需要什么帮助」的用户
  // 被判成没写）；单表遍历随字段增减自动跟随。
  const todayWritten = !!me?.today && TODAY_FIELDS.some((row) => !!me.today?.[row.field])

  return (
    <View className={styles.page}>
      {/* member 卡区（U4 覆盖层入口）；路人态直接是长廊（原 1024 横幅已撤——
          活动推广归「发现」，双 Tab 重复推送同一活动） */}
      {mode.kind === 'member' && me && myView && (
        <View className={styles.cardDock}>
          <View
          className={styles.miniCard}
          onClick={() => openCardLayer('view')}
        >
            <Text className={styles.miniCardName}>{me.fullName}</Text>
            <Text className={styles.miniCardFacts}>
              {(me.appliedAt ? me.appliedAt.slice(0, 4) : '') + (me.city ? ` · ${me.city}` : '')}
            </Text>
            <Text className={styles.miniCardHint}>点卡片翻开</Text>
          </View>
          <View className={styles.dockActions}>
            <Text
              className={styles.dockWritePrimary}
              onClick={() => openCardLayer('write')}
            >
              ✎ 写今天的你{todayWritten ? ' ✓' : ''}
            </Text>
            <Text
              className={`${styles.dockSend} ${sendingCard ? styles.dockSendBusy : me?.today?.sentToWallAt ? styles.dockSendDone : todayWritten ? '' : styles.dockSendDim}`}
              onClick={() => void sendTodayCard()}
            >
              {sendingCard ? '正在贴上墙…' : me?.today?.sentToWallAt ? '已寄出 ✓' : '写完寄出 →'}
            </Text>
            <Text
              className={`${styles.dockLicense} ${me && parseQuoteLevel(me.quoteLevel) !== 'off' ? styles.dockLicenseOn : ''}`}
              onClick={() => {
                const meLv = me ? parseQuoteLevel(me.quoteLevel) : 'off'
                setLicenseLevel(meLv)
                setLicensePicks(
                  me && me.quoteSpans
                    ? me.quoteSpans.map((sp) => ({ questionKey: sp.questionKey, start: sp.start, len: sp.len }))
                    : [],
                )
                setLicenseInited(true)
                setLicenseOpen(true)
              }}
            >
              ← 金句授权{me && parseQuoteLevel(me.quoteLevel) !== 'off' ? ` · ${parseQuoteLevel(me.quoteLevel) === 'anonymous' ? '匿名' : '实名'} ✓` : ''}
            </Text>
          </View>
        </View>
      )}

      <View className={styles.capsuleShell}>
      <ScrollView
        id='fbCapsule'
        scrollY
        scrollIntoView={scrollAnchor}
        scrollTop={scrollTop}
        scrollWithAnimation
        className={styles.capsule}
      >
        <View className={styles.capsuleInner}>
        {mode.kind === 'member' && cities.length > 1 && (
          <View className={styles.cityPins}>
            <Text className={`${styles.cityPinAll} ${city === null ? styles.cityPinActive : ''}`} onClick={() => pickCity(null)}>
              全部
            </Text>
            {cities.map((name) => (
              <Text key={name} className={`${styles.cityPin} ${city === name ? styles.cityPinActive : ''}`} onClick={() => pickCity(name)}>
                {name}
              </Text>
            ))}
          </View>
        )}

        {/* 过去场次：城市堆（确定性转角 + CSS 错峰显影）+ 进入这一场 */}
        {frames.map((frame) => (
          <View key={frame.key} className={styles.capFrame} onClick={() => openEvent(frame.key)}>
            <View className={styles.capFrameHead}>
              <Text className={styles.capWhen}>{frame.when}</Text>
              {frame.label ? <Text className={styles.capLabel}> {frame.label}</Text> : null}
            </View>
            <View className={styles.piles}>
              {frame.piles.map((pile, index) => (
                <View key={pile.city} className={styles.pileItem}>
                  <View
                    className={`${styles.pinPolaroid} ${index % 4 === 0 ? styles.tiltA : index % 4 === 1 ? styles.tiltB : index % 4 === 2 ? styles.tiltC : styles.tiltD}`}
                    style={{ animationDelay: `${index * 0.15}s` }}
                  >
                    <View className={styles.pinPhoto}>
                      <Text className={styles.pinCity}>{pile.city}</Text>
                      <Text className={styles.pinCount}>{pile.count} 位</Text>
                    </View>
                  </View>
                  {pile.returned > 0 ? (
                    <Text className={styles.capReturned}>{pile.returned} 位已回来</Text>
                  ) : null}
                </View>
              ))}
            </View>
          </View>
        ))}

        {/* ⚡今天格:G 状态机——member 未寄=虚线「你的位置」(点开卡);已寄=发光拍立得;路人=空位 */}
        <View className={`${styles.capFrame} ${styles.capFrameNow}`} id="todayAnchor">
          <Text className={styles.todayTitle}>{todayFrameLabel()}</Text>
          <View className={styles.todaySlot}>
            {me && me.today?.sentToWallAt ? (
              <View
                className={`${styles.todayLit} ${todayLanded ? styles.todayLitLanded : ''}`}
                onClick={() => void Taro.navigateTo({ url: '/pages/flashback-today/index' })}
              >
                <View className={styles.todayLitPhoto}>
                  <Text className={styles.todayLitName}>{me.fullName}</Text>
                </View>
                <Text className={styles.todayLitCap}>点开看你的卡 · 可保存分享</Text>
              </View>
            ) : me ? (
              <View className={styles.todayVacant} onClick={() => openCardLayer('write')}>
                <Text className={styles.todayVacantText}>你的位置</Text>
              </View>
            ) : (
              <View className={styles.todayVacant} onClick={() => Taro.showToast({ title: '登录后，找回你的那一张', icon: 'none' })}>
                <Text className={styles.todayVacantText}>这一刻，还没有你的照片</Text>
              </View>
            )}
          </View>
        </View>

        {/* U3 未来·场次段(修断裂 1):三行简卡,亮金可报名/灰卡状态标签,CTA 端内闭环 */}
        {mode.kind === 'member' &&
          mode.capsule.futureEvents.length > 0 &&
          (() => {
            const cards = futureEventCards(mode.capsule.futureEvents)
            if (cards.length === 0) return null
            return (
              <View id="futureAnchor" className={styles.futureSection}>
                {mode.capsule.futureEvents.map((frame) => {
                  const when = frame.initiativeStartsAt
                    ? new Date(frame.initiativeStartsAt).toLocaleDateString('zh-CN', { month: 'numeric', day: 'numeric' }).replace('/', '.')
                    : ''
                  return (
                    <View key={frame.initiativeSlug} className={styles.capFrame} style={{ borderBottom: 'none', paddingBottom: 0 }}>
                      <View className={styles.capFrameHead}>
                        <Text className={styles.capFuture}>{when || '即将'} · {frame.initiativeName}</Text>
                        <Text className={styles.capFutureDim}>未显影</Text>
                      </View>
                    </View>
                  )
                })}
                <Text className={styles.futureTitleDark}>未来 · 一起做什么</Text>
                {cards.map((card) => (
                  <View
                    key={card.id}
                    className={`${styles.eventCard} ${card.status === 'open' ? styles.eventCardLit : styles.eventCardMuted}`}
                    onClick={() => {
                      if (card.status !== 'open') return
                      setEventSheet({ id: card.id, title: card.title, meta: card.meta })
                    }}
                  >
                    <Text className={styles.eventTitle}>{card.title}</Text>
                    <Text className={styles.eventMeta}>{card.meta}</Text>
                    <Text className={card.status === 'open' ? styles.eventCta : styles.eventBadge}>
                      {card.status !== 'open'
                        ? card.status === 'full'
                          ? '名额已满'
                          : '报名已截止'
                        : enrolled.includes(card.title)
                          ? '已报名 ✓'
                          : '报名 →'}
                    </Text>
                  </View>
                ))}
              </View>
            )
          })()}

        {/* U4 愿望段(R6):公开愿望纸白卡——愿望/遮罩姓/附议数,点卡开模态 */}
        {mode.kind === 'member' && (
          <View className={styles.futureSection}>
            <View className={styles.wishSectionHead}>
              <Text className={styles.futureTitleDark}>未来 · 大家许的愿</Text>
              <Text className={styles.wishAddBtn} onClick={() => setWishSheet(true)}>
                + 许个愿
              </Text>
            </View>
            {mode.capsule.publicWishes.map((wish) => (
              <View key={wish.id} className={styles.wishCard} onClick={() => setWishModal(wish)}>
                <Text className={styles.wishContent}>{wish.content}</Text>
                <View className={styles.wishFoot}>
                  <Text className={styles.wishWho}>
                    {wish.wisherMasked ?? '匿名'}
                    {wish.city ? ` · ${wish.city}` : ''}
                  </Text>
                  <Text className={wish.endorsedByMe ? styles.wishEndorsed : styles.wishEndorse}>
                    👍 {wish.endorsementCount}
                    {wish.endorsedByMe ? ' · 已附议' : ''}
                  </Text>
                </View>
              </View>
            ))}
          </View>
        )}

        {/* U4 私愿折叠段(KD2/R7):一行「🔒 私人许愿(N)」点击展开,防瞥屏;仅本人 */}
        {mode.kind === 'member' && mode.capsule.myPrivateWishes.length > 0 && (
          <View className={styles.futureSection}>
            <View className={`${styles.privateFold} ${styles.privateFoldDark}`} onClick={() => setPrivateOpen(!privateOpen)}>
              <Text className={styles.privateFoldLabel}>🔒 私人许愿({mode.capsule.myPrivateWishes.length} 条)</Text>
              <Text className={styles.privateFoldArrow}>{privateOpen ? '收起 ▲' : '展开 ▼'}</Text>
            </View>
            {privateOpen &&
              mode.capsule.myPrivateWishes.map((wish) => (
                <View key={wish.id} className={`${styles.wishCard} ${styles.wishCardPrivate}`}>
                  <Text className={styles.wishContent}>{wish.content}</Text>
                  <View className={styles.wishFoot}>
                    <Text className={styles.wishWho}>仅自己可见</Text>
                    <Text className={styles.wishDelete} onClick={() => void deleteWish(wish)}>
                      删除
                    </Text>
                  </View>
                </View>
              ))}
          </View>
        )}

        {/* 序列终点：分享（参与态）/ 找回引导（路人态） */}
          {mode.kind === 'viewer' && mode.guide === null && (
            <Text className={styles.viewerHint}>名册只对同场的人可见——这里是每一年发生过的事。</Text>
          )}
        </View>
      </ScrollView>
      </View>

      <AppTabBar selected='flashback' />

      {/* 金句授权引导(一次性):勇气语+去授权/先不 */}
      {licenseNudge && (
        <View className={styles.nudgeMask} catchMove onClick={() => setLicenseNudge(false)}>
          <View className={styles.nudgeCard} onClick={(e) => e.stopPropagation()}>
            <Text className={styles.nudgeLead}>你说的话，会成为别人的勇气。</Text>
            <Text className={styles.nudgeSub}>从当年的答案里选一句，匿名或实名地传下去。</Text>
            <Button
              className={styles.nudgePrimary}
              onClick={() => {
                Taro.setStorageSync(STORAGE_KEYS.flashbackLicenseNudge, true)
                setLicenseNudge(false)
                setLicenseLevel('anonymous')
                setLicensePicks(
                  me?.quoteSpans
                    ? me.quoteSpans.map((sp) => ({ questionKey: sp.questionKey, start: sp.start, len: sp.len }))
                    : [],
                )
                setLicenseInited(true)
                setLicenseOpen(true)
              }}
            >
              选一句试试 →
            </Button>
            <Button
              className={styles.nudgeSkip}
              onClick={() => {
                Taro.setStorageSync(STORAGE_KEYS.flashbackLicenseNudge, true)
                setLicenseNudge(false)
              }}
            >
              先不
            </Button>
          </View>
        </View>
      )}

      {/* U8 快门仪式层:回访进门——呼吸快门,点按即入(原型 G intro) */}
      {shutter && mode.kind === 'member' && (
        <View className={styles.shutterMask} onClick={() => setShutter(false)}>
          <View className={styles.shutterCenter}>
            <Text className={styles.shutterEyebrow}>IN A FLASH · 闪念间</Text>
            <Text className={styles.shutterLead}>多年前，{'\n'}你写过一些答案。</Text>
            <View className={styles.shutterBtn} onClick={(e) => { e.stopPropagation(); setShutter(false) }} />
            <Text className={styles.shutterHint}>按下快门，回到那天</Text>
          </View>
        </View>
      )}

      {/* U4 开卡层:暗场+MyCard;view=停在合着面(点按翻开),write=错峰翻面+定位今天块;
          遮罩 catchTouchMove 防滚动穿透;闸 1100ms≥翻转时长 */}
      {mode.kind === 'member' && !!cardLayer && (
        <View
          className={styles.layerMask}
          catchMove
          onClick={() => {
            if (Date.now() - cardOpenedAt.current < 1100) return
            setCardLayer(null)
          }}
        >
          {/* chrome 全部悬浮于遮罩:状态小字在卡上方,分享胶囊在卡下方,卡是唯一主角 */}
          <View className={styles.maskBadge}>
            <View className={styles.maskBadgeLeft}>
              {(() => {
                const today = mode.capsule.me.today
                const hasToday = todayWritten
                const text = today?.sentToWallAt && hasToday
                  ? '已寄出到校友墙'
                  : hasToday
                    ? '写好了 · 寄出贴上墙'
                    : '点击照片翻面写字 · 再点寄出'
                return <Text className={today?.sentToWallAt && hasToday ? styles.wallOn : styles.wallOff}>{text}</Text>
              })()}
              {quoteLikeBadge(mode.capsule.me) && (
                <Text className={styles.maskLike}>❤ {mode.capsule.me.quoteStats?.likeCount ?? 0}</Text>
              )}
            </View>
            <Text className={styles.layerClose} onClick={() => setCardLayer(null)}>✕</Text>
          </View>
          <ScrollView
            scrollY
            scrollIntoView={cardScrollTo}
            className={styles.layerCard}
            onClick={(e) => e.stopPropagation()}
          >
            <MyCard
              capsule={mode.capsule}
              token={mode.token}
              onWrite={() => void reloadMember()}
              onSent={sentLanding}
              autoOpen={cardLayer === 'write'}
              chrome={false}
            />
          </ScrollView>
        </View>
      )}
      {/* U7 金句授权弹层:badge 勇气语+三档+多选圈选+两档预览(所见即所得) */}
      {licenseOpen && mode.kind === 'member' && (
        <View className={styles.wishSheetMask} catchMove onClick={() => setLicenseOpen(false)}>
          <View className={styles.licenseSheet} onClick={(e) => e.stopPropagation()}>
            <View className={styles.wishSheetBar} />
            <Text className={styles.wishSheetTitle}>金句授权</Text>
            <View className={styles.courageBadge}>
              <Text className={styles.courageBadgeText}>你说的话会成为别人的勇气！</Text>
            </View>
            {QUOTE_LEVEL_OPTIONS.map(({ value: lv, label, desc }) => (
              <View
                key={lv}
                className={`${styles.licenseRow} ${licenseLevel === lv ? styles.licenseRowActive : ''}`}
                onClick={() => {
                  setLicenseLevel(lv)
                  // 切档位不动圈选：关档只关档——圈选是用户的挑句劳动，保留它
                  // 才能在切回来时立刻复原（减句走下面的逐句取消）。
                  void submitLicense(lv, licensePicks)
                }}
              >
                <View className={styles.licenseDot} />
                <View>
                  <Text className={styles.licenseLabel}>{label}</Text>
                  <Text className={styles.licenseDesc}>{desc}</Text>
                </View>
              </View>
            ))}
            {licenseLevel !== 'off' && (
              <View className={styles.quotePickerSheet}>
                <Text className={styles.quotePickHint}>
                  选出可以展示的句子（可多选，平台从中挑选）：已选 {licensePicks.length} 句
                </Text>
                {quoteCandidatesOf(mode.capsule.me.answers, mode.capsule.me.today).map((candidate) => {
                  const picked = isCandidatePicked(candidate, licensePicks)
                  const order = licensePicks.findIndex(
                    (p) => p.questionKey === candidate.questionKey && p.start === candidate.start,
                  )
                  return (
                    <Text
                      key={`${candidate.questionKey}:${candidate.start}`}
                      className={`${styles.quoteCandidate} ${picked ? styles.quoteCandidateActive : ''} ${candidate.fogged ? styles.quoteCandidateFogged : ''}`}
                      onClick={() => {
                        if (candidate.fogged) {
                          Taro.showToast({ title: '这句已雾住,先解雾才能选', icon: 'none' })
                          return
                        }
                        const pick = { questionKey: candidate.questionKey, start: candidate.start, len: candidate.len }
                        const next = picked
                          ? licensePicks.filter(
                              (p) => !(p.questionKey === pick.questionKey && p.start === pick.start),
                            )
                          : [...licensePicks, pick]
                        setLicensePicks(next)
                        void submitLicense(licenseLevel, next)
                      }}
                    >
                      {picked ? `✓${order + 1} ` : ''}
                      {candidate.sentence}
                      <Text className={styles.quoteCandidateQ}>{questionLabel(candidate.questionKey)}</Text>
                    </Text>
                  )
                })}
                {licensePicks.length > 0 && licenseInited && (
                  <View className={styles.quotePreview}>
                    <Text className={styles.quotePreviewHint}>这句话将这样出现：</Text>
                    {licenseLevel === 'credited' ? (
                      <View className={styles.quotePreviewCard}>
                        <Text className={styles.quotePreviewQ}>
                          「{mode.capsule.me.quote ?? ''}」
                        </Text>
                        <View className={styles.quotePreviewBy}>
                          <Text className={styles.quotePreviewName}>{mode.capsule.me.fullName}</Text>
                          <Text className={styles.quotePreviewLink}>点开看实名档案 ›</Text>
                        </View>
                      </View>
                    ) : (
                      <View className={styles.quotePreviewCard}>
                        <Text className={styles.quotePreviewQ}>
                          「{mode.capsule.me.quote ?? ''}」
                        </Text>
                        <View className={styles.quotePreviewBy}>
                          <Text className={styles.quotePreviewName}>
                            {mode.capsule.me.surname}** · {mode.capsule.me.appliedAt?.slice(0, 4)} · {mode.capsule.me.city ?? ''}
                          </Text>
                          <Text className={styles.quotePreviewDim}>匿名 · 不可点</Text>
                        </View>
                      </View>
                    )}
                  </View>
                )}
              </View>
            )}
            <Text className={styles.licenseFoot}>你的授权随时可调，默认全部关闭</Text>
          </View>
        </View>
      )}

      {/* 底部固定 CTA 条(胶囊外,白底):member=进卡片页;viewer=登录找回。
          member 侧进卡片页而非直接开分享面板——先看到"要保存的卡"再决定
          存哪张/分享，与今天格入口同一落点（所见即所得）。 */}
      <View className={styles.footerBar}>
        {mode.kind === 'member' ? (
          <Button className={styles.cta} onClick={() => void Taro.navigateTo({ url: '/pages/flashback-today/index' })}>
            把这一刻做成卡片 →
          </Button>
        ) : (
          <Button className={styles.cta} onClick={goLogin}>
            你也在这些照片里吗？登录找回 →
          </Button>
        )}
      </View>

      {/* U4 公开愿望模态(R6):全文+留言流+附议/已附议+本人删除两步确认 */}
      {wishModal && (
        <View className={styles.wishModalMask} catchMove onClick={() => setWishModal(null)}>
          <View className={styles.wishModal} onClick={(e) => e.stopPropagation()}>
            <Text className={styles.wishModalContent}>{wishModal.content}</Text>
            <View className={styles.wishFoot}>
              <Text className={styles.wishWho}>
                {wishModal.wisherMasked ?? '匿名'}
                {wishModal.city ? ` · ${wishModal.city}` : ''}
              </Text>
              <Text
                className={wishModal.endorsedByMe ? styles.wishEndorsed : styles.wishEndorse}
                onClick={() => void endorse(wishModal)}
              >
                {wishModal.endorsedByMe ? '✓ 已附议' : '👍 附议'} · {wishModal.endorsementCount}
              </Text>
              {wishModal.mine && (
                <Text className={styles.wishDelete} onClick={() => void deleteWish(wishModal)}>
                  删除
                </Text>
              )}
            </View>
            <View className={styles.wishComments}>
              <Text className={styles.wishCommentsTitle}>留言({wishModal.comments.length})</Text>
              {wishModal.comments.map((comment) => (
                <View key={comment.id} className={styles.wishCommentRow}>
                  <Text className={styles.wishCommentWho}>{comment.commenterMasked ?? '匿名'}:</Text>
                  <Text className={styles.wishCommentText}>{comment.content}</Text>
                </View>
              ))}
            </View>
            <View className={styles.wishCommentInput}>
              <Input
                className={styles.wishInput}
                value={wishComment}
                onInput={(e) => setWishComment(e.detail.value)}
                maxlength={200}
                placeholder="留一句支持…"
                confirmHold
              />
              <Button size="mini" disabled={wishBusy || !wishComment.trim()} onClick={() => void addComment(wishModal)}>
                发送
              </Button>
            </View>
          </View>
        </View>
      )}
      {/* U7 报名 sheet:详情+押金;报名→event-detail 端内闭环(押金支付在那里) */}
      {eventSheet && (
        <View className={styles.wishSheetMask} catchMove onClick={() => setEventSheet(null)}>
          <View className={styles.wishSheet} onClick={(e) => e.stopPropagation()}>
            <View className={styles.wishSheetBar} />
            <Text className={styles.wishSheetTitle}>{eventSheet.title}</Text>
            <Text className={styles.eventMeta}>{eventSheet.meta}</Text>
            <Text className={styles.enrollDeposit}>押金 ¥69 · 到场退 · 限 18+</Text>
            <Button
              className={styles.wishSheetSubmit}
              onClick={() => {
                setEnrolled((prev) => (prev.includes(eventSheet.title) ? prev : [...prev, eventSheet.title]))
                setEventSheet(null)
                Taro.showToast({ title: '已报名 · 详情将发你微信', icon: 'none' })
                void Taro.navigateTo({ url: `/pages/event-detail/index?id=${eventSheet.id}&kind=event` })
              }}
            >
              报名 · 押金 ¥69
            </Button>
          </View>
        </View>
      )}

      {/* U5 许愿半屏弹层(KD3/R8):文本+可见性+提交,提交后落位反馈 */}
      {wishSheet && (
        <View className={styles.wishSheetMask} catchMove onClick={() => setWishSheet(false)}>
          <View className={styles.wishSheet} onClick={(e) => e.stopPropagation()}>
            <View className={styles.wishSheetBar} />
            <Text className={styles.wishSheetTitle}>许个愿</Text>
            <Textarea
              className={styles.wishSheetInput}
              value={wishDraft}
              onInput={(e) => setWishDraft(e.detail.value)}
              maxlength={500}
              placeholder="写下你想和 CGC 一起实现的…(500 字内)"
              autoHeight
            />
            <View className={styles.wishSheetVisibility}>
              <Text
                className={`${styles.visibilityBtn} ${wishVisibility === 'public' ? styles.visibilityActive : ''}`}
                onClick={() => setWishVisibility('public')}
              >
                公开 · 上墙让大家附议
              </Text>
              <Text
                className={`${styles.visibilityBtn} ${wishVisibility === 'private' ? styles.visibilityActive : ''}`}
                onClick={() => setWishVisibility('private')}
              >
                🔒 私人 · 仅自己可见
              </Text>
            </View>
            <Button
              className={styles.wishSheetSubmit}
              disabled={wishBusy || !wishDraft.trim()}
              onClick={() => void submitWish()}
            >
              {wishBusy ? '许愿中…' : '许下这个愿'}
            </Button>
          </View>
        </View>
      )}
    </View>
  )
}
