import { useCallback, useState } from 'react'
import { Button, Canvas, ScrollView, Text, View } from '@tarojs/components'
import Taro, { useDidShow, useShareAppMessage, useShareTimeline } from '@tarojs/taro'
import { api } from '@/api'
import { PageState } from '@/components/PageState'
import { cardStatusText, myCardView, shareMessage, splitActionCards, endorseAction } from '@/domain/flashback'
import { corridorFrames, statsFrames, todayFrameLabel } from '@/domain/flashback-journey'
import { STORAGE_KEYS } from '@/state/storage'
import type {
  FlashbackCapsule,
  FlashbackClaimResult,
  FlashbackMyActionCard,
  FlashbackPublicStats
} from '@/domain/models'
import { FlashbackNotBoundError, FlashbackTokenInvalidError } from '@/domain/models'
import { SUMMARY_CARD_CANVAS_ID, saveFlashbackSummaryCard } from '@/platform/summary-card'
import styles from './index.module.css'

type Mode =
  | { kind: 'loading' }
  | { kind: 'error'; message: string }
  | { kind: 'member'; capsule: FlashbackCapsule; token: string | null }
  /** 路人围观态（R32）：长廊 + 统计，无任何未授权内容；guide = 回头找到自己档案的出口 */
  | { kind: 'viewer'; stats: FlashbackPublicStats | null; guide: 'login' | 'recover' | null }

const NO_CARDS = { endorsed: [] as FlashbackMyActionCard[], open: [] as FlashbackMyActionCard[] }


/**
 * 长廊（mp 版原型 F corridor；R12/R32/R34）：垂直时间墙「↓ 下滑 = 时间前进」+
 * 城市堆（确定性转角 + 错峰显影）+ ⚡今天格 + 未来行动卡，点格进场次页。
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
  // R14 分享（用户定稿 ③）：sheet 三入口 + 保存中态
  const [shareSheet, setShareSheet] = useState(false)
  const [saving, setSaving] = useState(false)

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

  // useDidShow：登录回跳（returnUrl）后自动重载——路人态升级为参与态的落点
  useDidShow(() => {
    void load(city)
  })

  const pickCity = (next: string | null) => {
    setCity(next)
    void load(next)
  }

  // R14 分享：卡片落旅程入口（朋友从闪念间入口进入）；不带本人 token（R32 边界）
  const shareTitle = mode.kind === 'member' ? shareMessage(mode.capsule.me).title : '闪念间 · 找回当年的自己'
  useShareAppMessage(() => ({ title: shareTitle, path: '/pages/flashback-journey/index' }))
  useShareTimeline(() => ({ title: shareTitle }))

  const saveCard = async () => {
    if (mode.kind !== 'member' || saving) return
    setSaving(true)
    try {
      await saveFlashbackSummaryCard(mode.capsule.me)
      setShareSheet(false)
    } finally {
      setSaving(false)
    }
  }

  const openEvent = (key: string) => {
    void Taro.navigateTo({ url: `/pages/flashback-event/index?key=${encodeURIComponent(key)}` })
  }

  /** 未来行动卡的下一步（R13 每张卡有下一步）：scheduled 直链报名，其余去我的页附议 */
  const openCard = (card: FlashbackMyActionCard) => {
    const action = endorseAction(card)
    if (action.kind === 'goEvent' && card.eventId) {
      void Taro.navigateTo({ url: `/pages/event-detail/index?id=${card.eventId}&kind=event` })
      return
    }
    void Taro.navigateTo({ url: '/pages/flashback/index' })
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
  const cards = mode.kind === 'member' ? splitActionCards(mode.capsule.actionCards) : NO_CARDS
  const orderedCards = [...cards.endorsed, ...cards.open]
  const me = mode.kind === 'member' ? mode.capsule.me : null
  const myView = me && mode.kind === 'member' ? myCardView(mode.capsule) : null

  return (
    <View className={styles.page}>
      <ScrollView scrollY className={styles.wall} style={{ height: '100vh' }}>
        <View className={styles.header}>
          <Text className={styles.title}>闪念间 · 时间长廊</Text>
          <Text className={styles.hint}>↓ 下滑 = 时间前进：顶上是当年，底部是等你的未来 · 点任一格进入那一场</Text>
        </View>

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
          <View key={frame.key} className={styles.frame} onClick={() => openEvent(frame.key)}>
            <View className={styles.frameHead}>
              <Text className={styles.frameWhen}>
                {frame.when}
                {frame.label ? <Text className={styles.frameLabel}> {frame.label}</Text> : null}
              </Text>
            </View>
            <View className={styles.piles}>
              {frame.piles.map((pile, index) => (
                <View key={pile.city} className={styles.pile} hoverClass={styles.pilePressed} hoverStayTime={120}>
                  {/* 转角五档按堆序取模（确定性，无 Math.random；CSS 见 .tilt0-.tilt4）。
                      点堆进场次：帧级 onClick 已覆盖（整帧可点），按压反馈给「堆」入口。 */}
                  <View className={`${styles.pileCard} ${styles[`tilt${(index * 2) % 5}`]}`}>
                    <Text className={styles.pileCity}>{pile.city}</Text>
                  </View>
                  <Text className={styles.pileCount}>
                    {pile.city} · {pile.count} 位
                  </Text>
                </View>
              ))}
            </View>
            {frame.returned > 0 && <Text className={styles.frameReturned}>{frame.returned} 位已回来</Text>}
          </View>
        ))}

        {/* ⚡今天格：参与态=我的卡（未寄出为虚线位）；路人态=回到此刻 */}
        <View className={`${styles.frame} ${styles.todayFrame}`}>
          <Text className={`${styles.frameWhen} ${styles.frameWhenNow}`}>{todayFrameLabel()}</Text>
          {me && myView ? (
            <View className={styles.todayCard}>
              <Text className={styles.todayName}>{me.fullName}</Text>
              <Text className={styles.todaySub}>
                {me.today?.sentToWallAt ? '你刚寄出的照片' : '你的照片还没贴上墙——在旅程里寄出它'}
              </Text>
            </View>
          ) : (
            <View className={styles.todayEmpty}>
              <Text className={styles.todayEmptyText}>这一刻，还没有你的照片</Text>
            </View>
          )}
        </View>

        {/* 未来行动卡（参与态）：proposed/forming/scheduled/done */}
        {mode.kind === 'member' && (
          <View className={`${styles.frame} ${styles.futureFrame}`}>
            <Text className={styles.frameWhen}>未来 · 一起做点什么<Text className={styles.frameLabel}> 未显影 · 等你们共创</Text></Text>
            {orderedCards.length === 0 && (
              <Text className={styles.futureEmpty}>还没有提议的卡——回信里许下的愿望经运营确认后会成卡上墙。</Text>
            )}
            {orderedCards.map((card) => {
              const action = endorseAction(card)
              return (
                <View key={card.id} className={`${styles.futureCard} ${styles[card.status]}`} onClick={() => openCard(card)}>
                  <View className={styles.futureHead}>
                    <Text className={styles.futureTitle}>{card.title}</Text>
                    <Text className={`${styles.futureStatus} ${styles[card.status]}`}>{cardStatusText(card.status)}</Text>
                  </View>
                  <Text className={styles.futureMeta}>
                    {card.city ?? '城市待定'} · {action.hint}
                  </Text>
                  {action.kind !== 'done' && <Text className={styles.futureAction}>{action.label} →</Text>}
                </View>
              )
            })}
          </View>
        )}

        {/* 序列终点：分享（参与态）/ 找回引导（路人态） */}
        <View className={styles.footer}>
          {mode.kind === 'member' && (
            <Button className={styles.cta} onClick={() => setShareSheet(true)}>
              把这一刻做成卡片 →
            </Button>
          )}
          {mode.kind === 'viewer' && mode.guide === 'login' && (
            <View className={styles.guideBlock}>
              <Text className={styles.guideText}>你也在这些照片里吗？登录后我们帮你找。</Text>
              <Button className={styles.cta} onClick={goLogin}>
                微信一键登录，找回你的那一张 →
              </Button>
            </View>
          )}
          {mode.kind === 'viewer' && mode.guide === 'recover' && (
            <View className={styles.guideBlock}>
              <Text className={styles.guideText}>
                我们还没找到你的档案——收到过我们的链接就从链接打开完成首程，或用网页端「闪念间」凭手机号找回。
              </Text>
            </View>
          )}
          {mode.kind === 'viewer' && mode.guide === null && (
            <Text className={styles.viewerHint}>名册只对同场的人可见——这里是每一年发生过的事。</Text>
          )}
        </View>
      </ScrollView>

      <Canvas id={SUMMARY_CARD_CANVAS_ID} canvasId={SUMMARY_CARD_CANVAS_ID} type="2d" className={styles.shareCanvas} />

      {/* 分享 sheet（用户定稿 ③，与我的页同款三入口） */}
      {shareSheet && mode.kind === 'member' && myView && (
        <View className={styles.shareMask} onClick={() => setShareSheet(false)}>
          <View className={styles.shareSheet} onClick={(event) => event.stopPropagation()}>
            <Text className={styles.shareSheetTitle}>{shareTitle}</Text>
            <View className={styles.shareEntries}>
              <Button className={styles.shareEntry} openType="share">
                <Text className={styles.shareEntryIcon}>💬</Text>
                <Text className={styles.shareEntryLabel}>转发给好友</Text>
              </Button>
              <View
                className={styles.shareEntry}
                onClick={() => Taro.showToast({ title: '朋友圈分享请点右上角「···」选择', icon: 'none' })}
              >
                <Text className={styles.shareEntryIcon}>📷</Text>
                <Text className={styles.shareEntryLabel}>朋友圈</Text>
              </View>
              <View className={styles.shareEntry} onClick={() => void saveCard()}>
                <Text className={styles.shareEntryIcon}>⬇️</Text>
                <Text className={styles.shareEntryLabel}>{saving ? '保存中…' : '保存卡片'}</Text>
              </View>
            </View>
            <Button className={styles.shareCancel} onClick={() => setShareSheet(false)}>
              取消
            </Button>
          </View>
        </View>
      )}
    </View>
  )
}
