/**
 * 卡片页(今天格 lit 点击进入 / 长廊底部「把这一刻做成卡片」)：四态落版 +
 * 所见即所存。
 *
 * 四态 chip（顺序 = 用户价值序，`CARD_MODES` 单表）同时决定**预览**与**保存物**：
 *  - 合起来（默认：全貌，过去与现在并置，产品核心意象）
 *  - 当年的你 / 今天的你（两个拆解视图）
 *  - 摘要卡（金句版式，R14 分享默认物，固定 3:4）
 * 预览与 canvas 共用同一 model（domain 的 summaryCardModel / recordCardModel），
 * 换态即换存出来的东西。
 *
 * **两段都可点句切雾**（各自在被渲染时）——卡片页是寄出后全部内容唯一的
 * 雾化入口面（写入面不做雾化），不可回归。
 *
 * ── 站外分享（#771）──────────────────────────────────────────────────
 * 「分享给朋友」不再是 openType 转发按钮，而是打开**朋友将看到的全文卡**对话框：
 * 先让人看到对方会看到什么，再决定要不要把链接给出去。
 *
 * 三条边界：
 * 1. **预览数据只来自 `capsule.me.cardSharing.preview`**（白名单 DTO，段结构
 *    与公开读面同源）。`cardSharing` 缺失时不拿 `me.answers` 去补——那会把
 *    雾面与全名一起端出去。缺状态 = 预览拿不到，如实说，不给假卡。
 * 2. **转发只走 shareId**。`onShareAppMessage` 只在链接真的可分享时返回卡片
 *    path，图恒为品牌火苗——绝不默认截当前页（本页是本人原文面，截图等于绕过
 *    雾面与授权）。回调内不做任何写操作：转发面板每次打开都会调它。
 * 3. **开启/关闭是本人显式动作**（一次点按 = 一次 API），与金句授权档
 *    （QuoteOptIn / quoteLevel）互相独立——开卡不连带授权金句，反之亦然。
 *    关闭只清公开态，shareId 不变（重新开启复用同一个链接）。
 */
import { useCallback, useEffect, useRef, useState } from 'react'
import { Button, Canvas, ScrollView, Text, View } from '@tarojs/components'
import Taro, { useShareAppMessage } from '@tarojs/taro'
import { api } from '@/api'
import { PageState } from '@/components/PageState'
import { TodayReview } from '@/components/MyCard'
import QuoteOptIn from '@/components/MyCard/QuoteOptIn'
import SharedFlashbackCard from '@/components/SharedFlashbackCard'
import { CARD_MODES, parseQuoteLevel, shareMessage, summaryCardModel, type FlashbackCardMode } from '@/domain/flashback'
import { buildFlashbackCardSharePath, buildFlashbackJourneyPath } from '@/domain/share-route'
import { CARD_CANVAS_ID, saveFlashbackCard } from '@/platform/flashback-card'
import { STORAGE_KEYS } from '@/state/storage'
import { FlashbackTokenInvalidError } from '@/domain/models'
import type { FlashbackCapsule, FlashbackCardSharing } from '@/domain/models'
// 转发卡片图 = 品牌火苗。**import 而非路径字面量**：import 让打包器在构建期
// 保证资产存在并进入产物（pages/discover、pages/login 同款），字面量字符串
// 写错了要到线上才发现。绝不默认截当前页——本页是本人原文面。
import shareCardImage from '@/assets/brand/cgc-flame.png'
import styles from './index.module.css'

/** 摘要卡的 DOM 预览：与 canvas 同版式（居中、金句为主）。摘要卡口径不含
 *  雾句——`summaryCardModel` 已按此过滤，故预览与保存物一致。 */
function SummaryCardPreview({ me }: { me: FlashbackCapsule['me'] }) {
  const model = summaryCardModel(me)
  return (
    <View className={styles.summaryCard}>
      <Text className={styles.summaryKicker}>IN A FLASH · 闪念间</Text>
      <Text className={styles.summaryStamp}>{model.stamp || '当年'}</Text>
      <Text className={styles.summaryQuote}>“{model.quote}”</Text>
      {model.todayLine && <Text className={styles.summaryToday}>今天的我：{model.todayLine}</Text>}
      <Text className={styles.summaryFooter}>{model.footer}</Text>
    </View>
  )
}

export default function FlashbackTodayPage() {
  const [capsule, setCapsule] = useState<FlashbackCapsule | null>(null)
  const [error, setError] = useState('')
  const [mode, setMode] = useState<FlashbackCardMode>('both')
  const [saving, setSaving] = useState(false)
  const [shareOpen, setShareOpen] = useState(false)
  const [shareBusy, setShareBusy] = useState(false)
  /**
   * 开启/关闭的返回 DTO 直接落 UI——它就是服务端答复，不必等一次重拉才显示。
   * load() 成功时清空它，让 capsule 重新成为唯一真源（重拉失败也不会把
   * 「已开启」退回「去授权」的假象）。
   */
  const [sharingPatch, setSharingPatch] = useState<FlashbackCardSharing | null>(null)
  /** 写操作的连点保护（state 只管按钮文案/禁用，防重靠 ref：同一 tick 内
   *  两次点击都读不到刚 set 的 state）。 */
  const shareBusyRef = useRef(false)
  /** 卸载后不得再 setState（分享面板里的异步写与重拉都可能晚于离开页面） */
  const mountedRef = useRef(true)

  useEffect(() => {
    mountedRef.current = true
    return () => {
      mountedRef.current = false
    }
  }, [])

  useEffect(() => {
    void Taro.setNavigationBarTitle({ title: '卡片' }).catch(() => {})
    void load()
    // eslint-disable-next-line react-hooks/exhaustive-deps -- 进页一次性加载
  }, [])

  const load = useCallback(async () => {
    setError('')
    try {
      const token = Taro.getStorageSync<string>(STORAGE_KEYS.flashbackToken) || null
      const next = await api.getFlashbackCapsule(null, token)
      if (!mountedRef.current) return
      setCapsule(next)
      // 服务端真源归位：本地 patch 只在两次 load 之间顶着用
      setSharingPatch(null)
    } catch (e) {
      if (!mountedRef.current) return
      if (e instanceof FlashbackTokenInvalidError) {
        Taro.removeStorageSync(STORAGE_KEYS.flashbackToken)
      }
      setError(e instanceof Error ? e.message : '加载失败')
    }
  }, [])

  /**
   * 公开开关状态（fail-closed）：`enabled !== true` 一律按关。`undefined`
   * （旧 fixture / 后端未给）是「未知」，不是「开」——不猜、不放行。
   */
  const sharing = sharingPatch ?? capsule?.me.cardSharing ?? null
  const shareId = sharing?.shareId ?? null
  /** 可分享 = 已开启 **且** 拿到 shareId。开了却没有 id 是契约违约，
   *  按不可分享处理（宁可不给按钮，也不给一个转不出卡的按钮）。 */
  const shareReady = sharing?.enabled === true && !!shareId

  useEffect(() => {
    // 右上角菜单只在链接真的可分享时开放，且只开「转发给朋友」：朋友圈
    // （shareTimeline）的 path 恒为当前页，带 shareId 也只会落到本人卡片页的
    // 访客错误态——没有正确落地页就不提供入口。失败静默：菜单可见性只是体验，
    // 真正的门在 onShareAppMessage 的返回值上。
    if (shareReady) {
      void Taro.showShareMenu({ withShareTicket: false, showShareItems: ['shareAppMessage'] }).catch(() => {})
    } else {
      void Taro.hideShareMenu().catch(() => {})
    }
  }, [shareReady])

  useShareAppMessage(() => {
    // 回调内零副作用：转发面板每次打开都会调用它，写操作放这里会被重复触发。
    const title = capsule ? shareMessage(capsule.me).title : '闪念间 · 找回当年的自己'
    if (shareReady && shareId) {
      return { title, path: buildFlashbackCardSharePath(shareId), imageUrl: shareCardImage }
    }
    // 链接没开时不转发本人卡片页（那是原文面）：退回旅程入口，与旧行为一致。
    // 菜单此时已隐藏，这条只是 hideShareMenu 落地前的时间差兜底。
    return { title, path: buildFlashbackJourneyPath(), imageUrl: shareCardImage }
  })

  const saveCard = async () => {
    if (!capsule || saving) return
    setSaving(true)
    try {
      await saveFlashbackCard(capsule.me, mode)
    } catch (e) {
      Taro.showToast({ title: e instanceof Error ? e.message : '保存失败', icon: 'none' })
    } finally {
      if (mountedRef.current) setSaving(false)
    }
  }

  /** 开启/关闭公开链接（本人显式动作）。token = 会话腿身份（跳过注册的回访者）。 */
  const setCardSharing = async (enabled: boolean) => {
    if (shareBusyRef.current) return
    shareBusyRef.current = true
    setShareBusy(true)
    try {
      const token = Taro.getStorageSync<string>(STORAGE_KEYS.flashbackToken) || null
      const next = await api.flashbackSetCardSharing(enabled, token)
      if (!mountedRef.current) return
      setSharingPatch(next)
    } catch (e) {
      if (!mountedRef.current) return
      Taro.showToast({
        title: e instanceof Error ? e.message : enabled ? '开启失败，请重试' : '关闭失败，请重试',
        icon: 'none'
      })
    } finally {
      shareBusyRef.current = false
      if (mountedRef.current) setShareBusy(false)
    }
  }

  // 两段的点句切雾共用：读会话 token → 调对应 API → 重拉 capsule（雾态以服务端为准）
  const adjustFog = (call: (token: string | null) => Promise<void>) => {
    const token = Taro.getStorageSync<string>(STORAGE_KEYS.flashbackToken) || null
    void call(token)
      .then(() => load())
      .catch((error: unknown) =>
        Taro.showToast({
          title: error instanceof Error ? error.message : '雾面调整失败',
          icon: 'none'
        })
      )
  }

  // 首载失败可重试;token 失效清掉后按无 token 重拉(会话腿)
  if (error && !capsule) {
    return <PageState kind='error' message={error} onRetry={() => void load()} />
  }
  if (!capsule) {
    return <PageState kind='loading' title='正在显影…' />
  }

  return (
    <View className={styles.page}>
      <View className={styles.modeChips}>
        {CARD_MODES.map((item) => (
          <Text
            key={item.value}
            className={`${styles.modeChip} ${mode === item.value ? styles.modeChipActive : ''}`}
            data-testid={`card-mode-${item.value}`}
            onClick={() => setMode(item.value)}
          >
            {item.label}
          </Text>
        ))}
      </View>

      <View className={styles.cardWrap}>
        {mode === 'summary' ? (
          <SummaryCardPreview me={capsule.me} />
        ) : (
          <TodayReview
            me={capsule.me}
            level={parseQuoteLevel(capsule.me.quoteLevel)}
            mode={mode}
            onToggleTodayFog={(field, spans) => adjustFog((token) => api.flashbackAdjustTodayFog(field, spans, token))}
            onTogglePastFog={(answerId, spans) => adjustFog((token) => api.flashbackAdjustFog(answerId, spans, token))}
          />
        )}
      </View>

      <View className={styles.actions}>
        <Button
          className={styles.actionPrimary}
          data-testid='card-save'
          disabled={saving}
          onClick={() => void saveCard()}
        >
          {saving ? '保存中…' : '保存图片'}
        </Button>
        <Button
          className={styles.actionSecondary}
          data-testid='card-share'
          hoverClass={styles.pressed}
          onClick={() => setShareOpen(true)}
        >
          分享给朋友
        </Button>
      </View>

      {/* R37：授权引导只在「圈了金句但还没授权」时出现（判据在组件内）。
          放在按钮之后：勾是分享时的选项，紧贴分享按钮；tip 讲的是卡片本身，留在最底。
          plain 变体 = 去白底、字号更小——不让它读起来像分享的必填项。
          与公开链接开关**互相独立**：一处动作不改另一处状态。 */}
      <QuoteOptIn me={capsule.me} onWrite={() => void load()} variant='plain' />

      <Text className={styles.tip}>
        {mode === 'summary'
          ? '摘要卡只含未雾的句子 · 原文不会进卡片'
          : '点句子可切换雾面 · 雾面句对外不可见'}
      </Text>

      {/* 离屏画布（保存时节点需已在）——四态共用，尺寸由 domain 版式算出 */}
      <Canvas id={CARD_CANVAS_ID} canvasId={CARD_CANVAS_ID} type='2d' className={styles.cardCanvas} />

      {/* 朋友将看到的全文卡（#771）：先看后给。内容可滚，动作在底部固定。 */}
      {shareOpen && (
        <View className={styles.shareMask} catchMove onClick={() => setShareOpen(false)}>
          <View className={styles.sharePanel} onClick={(event) => event.stopPropagation()}>
            <Text className={styles.shareTitle} data-testid='fb-share-dialog-title'>
              朋友将看到的全文卡
            </Text>

            {!sharing ? (
              /* 缺状态 = 预览拿不到：不拿 me.answers 拼一张假卡出来（那会绕过雾面）。 */
              <View className={styles.shareMissing}>
                <Text className={styles.shareMissingText}>
                  拿不到公开预览，暂时无法确认朋友会看到什么。
                </Text>
                <Button className={styles.shareQuiet} hoverClass={styles.pressed} onClick={() => void load()}>
                  刷新看看
                </Button>
                <Button className={styles.shareCancel} hoverClass={styles.pressed} onClick={() => setShareOpen(false)}>
                  先不分享
                </Button>
              </View>
            ) : (
              <>
                <ScrollView scrollY className={styles.sharePreview}>
                  <SharedFlashbackCard card={sharing.preview} />
                </ScrollView>

                <View className={styles.shareNotice}>
                  <Text className={styles.shareNoticeLine}>
                    · 链接分享的是上面这张完整卡，不只是摘要卡
                  </Text>
                  <Text className={styles.shareNoticeLine}>· 链接可被转发，别人截图后无法撤回</Text>
                  <Text className={styles.shareNoticeLine}>· 你在这里调雾面，朋友看到的会跟着变</Text>
                  <Text className={styles.shareNoticeLine}>
                    · 卡上只有隐名与城市，没有联系人、社交账号与全名
                  </Text>
                </View>

                <View className={styles.shareActions}>
                  {sharing.enabled !== true && (
                    <>
                      <Text className={styles.shareConsent}>
                        开启后，任何拿到链接的人都能看到上面这张卡。随时可以关。
                      </Text>
                      <Button
                        className={styles.sharePrimary}
                        data-testid='fb-share-enable'
                        disabled={shareBusy}
                        hoverClass={styles.pressed}
                        onClick={() => void setCardSharing(true)}
                      >
                        {shareBusy ? '正在开启…' : '允许生成分享链接'}
                      </Button>
                    </>
                  )}

                  {sharing.enabled === true && !shareReady && (
                    /* 开了却没有 shareId = 契约违约：不给转发按钮（转不出去），如实说。 */
                    <>
                      <Text className={styles.shareConsent}>链接标识缺失，这张卡现在分享不出去。</Text>
                      <Button className={styles.shareQuiet} hoverClass={styles.pressed} onClick={() => void load()}>
                        刷新看看
                      </Button>
                    </>
                  )}

                  {shareReady && (
                    <>
                      <View className={styles.shareStatus}>
                        <Text className={styles.shareStatusOn}>链接已开启</Text>
                        <Text className={styles.shareStatusHint}>朋友点开就能看到上面这张卡</Text>
                      </View>
                      <Button className={styles.sharePrimary} data-testid='fb-share-send' openType='share' hoverClass={styles.pressed}>
                        发送给朋友
                      </Button>
                      {/* 关闭是独立动作，不与转发并列成两颗同权重按钮：
                          转发是主路径，关链接是收尾动作。 */}
                      <Button
                        className={styles.shareQuiet}
                        data-testid='fb-share-disable'
                        disabled={shareBusy}
                        hoverClass={styles.pressed}
                        onClick={() => void setCardSharing(false)}
                      >
                        {shareBusy ? '正在关闭…' : '关闭链接 · 已发出的转发会失效'}
                      </Button>
                    </>
                  )}

                  <Button className={styles.shareCancel} hoverClass={styles.pressed} onClick={() => setShareOpen(false)}>
                    先不分享
                  </Button>
                </View>
              </>
            )}
          </View>
        </View>
      )}
    </View>
  )
}
