import { useCallback, useState } from 'react'
import { Button, Input, ScrollView, Text, Textarea, View } from '@tarojs/components'
import Taro, { useDidShow, useShareAppMessage, useShareTimeline } from '@tarojs/taro'
import { api } from '@/api'
import { PageState } from '@/components/PageState'
import { myCardView, shareMessage } from '@/domain/flashback'
import { corridorFrames, statsFrames, todayFrameLabel } from '@/domain/flashback-journey'
import { futureEventCards } from '@/domain/flashback'
import type { FlashbackWish } from '@/domain/models'
import MyCard from '@/components/MyCard'
import ShareSheet from '@/components/MyCard/ShareSheet'
import { STORAGE_KEYS } from '@/state/storage'
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
  // R14 分享（用户定稿 ③）：sheet 三入口 + 保存中态
  const [shareSheet, setShareSheet] = useState(false)
  // U6「看看未来」滚底:scrollIntoView 定位未来段;消费一次即清(回页不再滚)
  const [scrollAnchor, setScrollAnchor] = useState('')

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

  // useDidShow：登录回跳（returnUrl）后自动重载——路人态升级为参与态的落点。
  // U6「看看未来」:?future=1 → 数据就绪后滚到未来段(计划原文 scrollIntoView)
  useDidShow(() => {
    void load(city)
    const params = Taro.getCurrentInstance().router?.params
    if (params?.future === '1') {
      setScrollAnchor('')
      setTimeout(() => setScrollAnchor('futureAnchor'), 400)
    }
  })

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

  // U2/R1:页内 Tab(时间廊|我的卡)——参与态两键互达(修断裂 4);路人/找回只显示时间廊
  const [tab, setTab] = useState<'corridor' | 'mine'>('corridor')
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

  return (
    <View className={styles.page}>
      <ScrollView scrollY scrollIntoView={scrollAnchor} className={styles.wall} style={{ height: '100vh' }}>
        <View className={styles.header}>
          <Text className={styles.title}>闪念间 · 时间长廊</Text>
          <Text className={styles.hint}>↓ 下滑 = 时间前进：顶上是当年，底部是等你的未来 · 点任一格进入那一场</Text>
        </View>

        {/* U6/R9 路人态 1024 活动横幅(修断裂 2):可点进 initiative 详情报名 */}
        {mode.kind === 'viewer' && (
          <View
            className={styles.banner1024}
            onClick={() => void Taro.navigateTo({ url: '/pages/initiative-detail/index?slug=hackerstart1024' })}
          >
            <Text className={styles.banner1024Title}>1024 程序员节 · Hacker Start</Text>
            <Text className={styles.banner1024Sub}>新一年活动开放报名 →</Text>
          </View>
        )}

        {mode.kind === 'member' && (
          <View className={styles.mpTabBar}>
            <Text className={`${styles.mpTab} ${tab === 'corridor' ? styles.mpTabActive : ''}`} onClick={() => setTab('corridor')}>
              时间廊
            </Text>
            <Text className={`${styles.mpTab} ${tab === 'mine' ? styles.mpTabActive : ''}`} onClick={() => setTab('mine')}>
              我的卡
            </Text>
          </View>
        )}

        <View style={{ display: mode.kind === 'member' && tab === 'mine' ? 'none' : 'block' }}>
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

        {/* U3 未来·场次段(修断裂 1):三行简卡,亮金可报名/灰卡状态标签,CTA 端内闭环 */}
        {mode.kind === 'member' &&
          mode.capsule.futureEvents.length > 0 &&
          (() => {
            const cards = futureEventCards(mode.capsule.futureEvents)
            if (cards.length === 0) return null
            return (
              <View id="futureAnchor" className={styles.futureSection}>
                <Text className={styles.futureTitle}>未来 · 一起做点什么</Text>
                {cards.map((card) => (
                  <View
                    key={card.id}
                    className={`${styles.eventCard} ${card.status === 'open' ? styles.eventCardLit : styles.eventCardMuted}`}
                    onClick={() => {
                      if (card.status !== 'open') return
                      void Taro.navigateTo({ url: `/pages/event-detail/index?id=${card.id}&kind=event` })
                    }}
                  >
                    <Text className={styles.eventTitle}>{card.title}</Text>
                    <Text className={styles.eventMeta}>{card.meta}</Text>
                    <Text className={card.status === 'open' ? styles.eventCta : styles.eventBadge}>
                      {card.status === 'open' ? '报名 →' : card.status === 'full' ? '名额已满' : '报名已截止'}
                    </Text>
                  </View>
                ))}
              </View>
            )
          })()}
        </View>

        {/* U4 愿望段(R6):公开愿望纸白卡——愿望/遮罩姓/附议数,点卡开模态 */}
        {mode.kind === 'member' && (
          <View className={styles.futureSection}>
            <View className={styles.wishSectionHead}>
              <Text className={styles.futureTitle}>未来 · 大家许的愿</Text>
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
            <View className={styles.privateFold} onClick={() => setPrivateOpen(!privateOpen)}>
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
        {mode.kind === 'member' && tab === 'mine' && (
          <MyCard
            capsule={mode.capsule}
            onWrite={() => void reloadMember()}
            onOpenShare={() => setShareSheet(true)}
          />
        )}

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

      {/* 分享 sheet(R14 用户定稿 ③,三入口+R37 opt-in)——组件与裁剪端薄壳单源 */}
      {mode.kind === 'member' && myView && (
        <ShareSheet
          open={shareSheet}
          title={shareTitle}
          me={mode.capsule.me}
          onClose={() => setShareSheet(false)}
          onWrite={() => void reloadMember()}
        />
      )}

      {/* U4 公开愿望模态(R6):全文+留言流+附议/已附议+本人删除两步确认 */}
      {wishModal && (
        <View className={styles.wishModalMask} onClick={() => setWishModal(null)}>
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
      {/* U5 许愿半屏弹层(KD3/R8):文本+可见性+提交,提交后落位反馈 */}
      {wishSheet && (
        <View className={styles.wishSheetMask} onClick={() => setWishSheet(false)}>
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
