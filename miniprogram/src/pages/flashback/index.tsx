import { useCallback, useEffect, useRef, useState } from 'react'
import { Button, Canvas, Radio, RadioGroup, ScrollView, Text, Textarea, View } from '@tarojs/components'
import Taro, { useDidShow, useShareAppMessage, useShareTimeline } from '@tarojs/taro'
import { api, FlashbackNotBoundError, SessionExpiredError } from '@/api'
import { PageState } from '@/components/PageState'
import {
  actionCardTarget,
  cardStatusText,
  ENDORSE_ROLES,
  endorseAction,
  isCandidatePicked,
  myCardView,
  parseQuoteLevel,
  QUOTE_LEVEL_OPTIONS,
  quoteCandidatesOf,
  quoteLikeBadge,
  shareOptInState,
  shareMessage,
  sentencesWithFog,
  splitActionCards,
  toggleSentenceFog,
  type QuoteCandidate,
  type QuoteLevel
} from '@/domain/flashback'
import { buildFlashbackJourneyPath } from '@/domain/share-route'

// 裁剪端（抖音/小红书）未注册闪念间旅程页——分享卡片回落回访页自身
const isCut = process.env.TARO_ENV === 'tt' || process.env.TARO_ENV === 'xhs'
import { flashbackEndorseTouchpoint, submitAfterConsent } from '@/domain/subscription'
import type { FlashbackCapsule, FlashbackMeAnswer, FlashbackMyActionCard, FlashbackMyCard } from '@/domain/models'
import { requestPlatformSubscriptions } from '@/platform'
import { SUMMARY_CARD_CANVAS_ID, saveFlashbackSummaryCard } from '@/platform/summary-card'
import styles from './index.module.css'

type LoadState =
  | { kind: 'loading' }
  | { kind: 'ready'; capsule: FlashbackCapsule }
  | { kind: 'not_bound' }
  | { kind: 'need_login' }
  | { kind: 'error'; message: string }

/**
 * U9/R28「我的闪念间」：回访正门（登录账号绑定档案）。
 * - 我的卡：当年正面（句子级雾化开关，KTD4 本人视图原文永远完整）+ 今天背面（编辑）；
 * - 金句授权三档（R31 端内入口）；
 * - 行动板：附议前先订阅授权（`submitAfterConsent` 顺序契约，成场通知优先订阅消息）。
 * 判据与文案全部下沉 domain/flashback.ts（页面无渲染测试，纯函数 node --test 钉住）。
 */
export default function FlashbackPage() {
  const [state, setState] = useState<LoadState>({ kind: 'loading' })
  const [answers, setAnswers] = useState<FlashbackMeAnswer[]>([])
  const [editing, setEditing] = useState(false)
  const [draftNow, setDraftNow] = useState('')
  const [draftWant, setDraftWant] = useState('')
  const [draftSay, setDraftSay] = useState('')
  const [quoteLevel, setQuoteLevel] = useState<QuoteLevel>('off')
  // R35 圈选：已选句（questionKey + 区间）——load 时从 capsule 回显
  const [pickedQuote, setPickedQuote] = useState<{ questionKey: string | null; start: number; len: number } | null>(null)
  // R37 分享 opt-in（默认不勾；已授权则勾选态 + 禁用）
  const [shareOptIn, setShareOptIn] = useState(false)
  const [quoteBusy, setQuoteBusy] = useState(false)
  const [endorsing, setEndorsing] = useState(false)
  // R34 城市钉：null = 全部；点钉带 city 重拉（服务端过滤行动板）
  const [city, setCity] = useState<string | null>(null)
  // 用户定稿 ① / 第 3b 件：我的卡两态——合着卡面（默认）→ 点击卡面 3D 翻转看正反两面 → 再按合上
  const [flipped, setFlipped] = useState(false)
  // 两段式翻面：前半程转到侧棱（cardFlipOut）→ 侧棱处换面 → 后半程转回（cardFlipIn）
  const [flipPhase, setFlipPhase] = useState<'idle' | 'out' | 'in'>('idle')
  const flipTimers = useRef<ReturnType<typeof setTimeout>[]>([])
  useEffect(() => () => { flipTimers.current.forEach(clearTimeout) }, [])
  const flipCard = (next: boolean) => {
    if (flipPhase !== 'idle' || next === flipped) return
    setFlipPhase('out')
    flipTimers.current.push(setTimeout(() => {
      setFlipped(next)
      setFlipPhase('in')
      flipTimers.current.push(setTimeout(() => setFlipPhase('idle'), 340))
    }, 320))
  }
  // 用户定稿 ③：分享浮层（好友/朋友圈/保存卡片）+ 保存中态
  const [shareSheet, setShareSheet] = useState(false)
  const [saving, setSaving] = useState(false)

  const load = useCallback(async (cityFilter?: string | null) => {
    setState({ kind: 'loading' })
    try {
      const capsule = await api.getFlashbackCapsule(cityFilter ?? null)
      setAnswers(capsule.me.answers)
      // 授权档从 capsule 恢复（R31；非法值 fail-closed 落 off）——不再恒定重置 off（P3）
      setQuoteLevel(parseQuoteLevel(capsule.me.quoteLevel))
      // R35/R37：圈选区间与分享 opt-in 初值都来自 capsule（授权永不预选：
      // 只有已授权才置勾，否则保持 false）
      setPickedQuote(
        capsule.me.quoteQuestionKey && capsule.me.quoteSpan
          ? { questionKey: capsule.me.quoteQuestionKey, start: capsule.me.quoteSpan.start, len: capsule.me.quoteSpan.len }
          : null
      )
      setShareOptIn(shareOptInState(capsule.me) === 'already')
      setDraftNow(capsule.me.today?.nowStatus ?? '')
      setDraftWant(capsule.me.today?.want ?? '')
      setDraftSay(capsule.me.today?.say ?? '')
      setState({ kind: 'ready', capsule })
    } catch (error) {
      if (error instanceof FlashbackNotBoundError) {
        setState({ kind: 'not_bound' })
      } else if (error instanceof SessionExpiredError) {
        setState({ kind: 'need_login' })
      } else {
        setState({ kind: 'error', message: error instanceof Error ? error.message : '加载失败' })
      }
    }
  }, [])

  useDidShow(() => { void load(city) })

  // R14 分享（用户定稿 ③）：··· 胶囊菜单转发好友 / 朋友圈（iOS 朋友圈仅
  // 文字+首图，平台限制，可用即达）；标题动态相对年数。卡片落旅程入口
  // （批次二：朋友从闪念间首程进入；不带本人 token，R32 边界）
  useShareAppMessage(() => {
    const me = state.kind === 'ready' ? state.capsule.me : null
    return {
      title: me ? shareMessage(me).title : '闪念间 · 找回当年的自己',
      path: isCut ? '/pages/flashback/index' : buildFlashbackJourneyPath()
    }
  })
  useShareTimeline(() => {
    const me = state.kind === 'ready' ? state.capsule.me : null
    return { title: me ? shareMessage(me).title : '闪念间 · 找回当年的自己' }
  })

  const pickCity = (next: string | null) => {
    setCity(next)
    void load(next)
  }

  // 句子雾/解雾：本地即时切换 + 整份 spans 提交（后端校验重叠/越界，失败重载）
  const toggleFog = async (answer: FlashbackMeAnswer, sentenceIndex: number) => {
    const sentences = sentencesWithFog(answer)
    const sentence = sentences[sentenceIndex]
    if (!sentence) return
    const nextSpans = toggleSentenceFog(answer, sentence)
    const nextAnswer = { ...answer, fogSpans: nextSpans }
    setAnswers((prev) => prev.map((item) => (item.id === answer.id ? nextAnswer : item)))
    try {
      await api.flashbackAdjustFog(answer.id, nextSpans)
    } catch {
      void load()
    }
  }

  const saveToday = async () => {
    try {
      await api.flashbackSubmitToday({
        nowStatus: draftNow || null,
        want: draftWant || null,
        say: draftSay || null
      })
      setEditing(false)
      void load()
    } catch (error) {
      Taro.showToast({ title: error instanceof Error ? error.message : '保存失败', icon: 'none' })
    }
  }

  /** 授权提交（R31/R35）：档位 + 圈选区间一起发——只发档位会把已选区间覆盖成空 */
  const submitLicense = async (
    level: QuoteLevel,
    candidate: { questionKey: string | null; start: number; len: number } | null
  ): Promise<boolean> => {
    if (quoteBusy) return false
    setQuoteBusy(true)
    try {
      await api.flashbackSetQuoteLicense(
        level,
        level === 'off' ? null : (candidate?.questionKey ?? null),
        level === 'off' ? null : (candidate ? { start: candidate.start, len: candidate.len } : null)
      )
      Taro.showToast({ title: '授权已更新', icon: 'none' })
      void load()
      return true
    } catch (error) {
      Taro.showToast({ title: error instanceof Error ? error.message : '设置失败', icon: 'none' })
      void load()
      return false
    } finally {
      setQuoteBusy(false)
    }
  }

  /** 切档：off 直接生效；anonymous/credited 需要圈选——已有圈选则直接换档，
   * 否则只展开候选列表（未圈选 = 不上墙，提交发生在点句时）。 */
  const changeQuoteLevel = async (level: QuoteLevel) => {
    setQuoteLevel(level)
    if (level === 'off') {
      setPickedQuote(null)
      await submitLicense('off', null)
      return
    }
    if (pickedQuote) await submitLicense(level, pickedQuote)
  }

  /** 圈选一句（R35）：本地即时高亮 + 落库（span 与展示同源） */
  const pickQuoteCandidate = async (candidate: QuoteCandidate) => {
    const next = { questionKey: candidate.questionKey, start: candidate.start, len: candidate.len }
    setPickedQuote(next)
    await submitLicense(quoteLevel === 'off' ? 'anonymous' : quoteLevel, next)
    if (quoteLevel === 'off') setQuoteLevel('anonymous')
  }

  /** R37 分享 opt-in：勾选即开匿名档（span = 卡片金句）；取消勾选不动既有档位 */
  const toggleShareOptIn = async (next: boolean, me: FlashbackMyCard) => {
    if (next === shareOptIn) return
    setShareOptIn(next)
    if (!next) return
    const ok = await submitLicense(
      'anonymous',
      me.quoteSpan ? { questionKey: me.quoteQuestionKey, start: me.quoteSpan.start, len: me.quoteSpan.len } : null
    )
    if (!ok) setShareOptIn(false)
  }

  // 附议提交前先订阅授权（KTD5/R13a：一次授权恰好覆盖「成场那一条」；
  // 授权被拒/缺配不阻断附议，成场通知退回邮件/短信）
  const endorse = async (card: FlashbackMyActionCard, role: string | null) => {
    if (endorsing) return
    setEndorsing(true)
    try {
      await submitAfterConsent(
        flashbackEndorseTouchpoint(),
        {
          request: requestPlatformSubscriptions,
          grant: (scenario) => api.grantConsent(scenario)
        },
        () => api.flashbackEndorse(card.id, role)
      )
      Taro.showToast({ title: '已附议', icon: 'success' })
      void load()
    } catch (error) {
      Taro.showToast({ title: error instanceof Error ? error.message : '附议失败', icon: 'none' })
    } finally {
      setEndorsing(false)
    }
  }

  const pickRoleAndEndorse = (card: FlashbackMyActionCard) => {
    const items = [...ENDORSE_ROLES.map(({ label }) => label), '只附议，不认领角色']
    Taro.showActionSheet({
      itemList: items,
      success: ({ tapIndex }) => {
        const role = tapIndex < ENDORSE_ROLES.length ? ENDORSE_ROLES[tapIndex].value : null
        void endorse(card, role)
      }
    })
  }

  const openCard = (card: FlashbackMyActionCard) => {
    const target = actionCardTarget(card)
    if (target) {
      void Taro.navigateTo({ url: target })
    }
  }

  const goLogin = () => Taro.navigateTo({ url: '/pages/login/index' })

  // R14 保存摘要卡（用户定稿 ③）：绘制/导出/保存已下沉 platform/summary-card
  // （旅程终点长廊共用同一实现）；这里只管 saving 态与关闭 sheet
  const saveSummaryCard = async () => {
    if (state.kind !== 'ready' || saving) return
    setSaving(true)
    try {
      await saveFlashbackSummaryCard(state.capsule.me)
      setShareSheet(false)
    } finally {
      setSaving(false)
    }
  }

  if (state.kind === 'loading') {
    return <PageState kind="loading" title="正在显影…" />
  }

  if (state.kind === 'need_login') {
    return (
      <View className={styles.page}>
        <View className={styles.stateBlock}>
          <Text className={styles.stateText}>登录后可以看到你的闪念间档案</Text>
          <Button className={styles.stateAction} onClick={goLogin}>去登录</Button>
        </View>
      </View>
    )
  }

  if (state.kind === 'not_bound') {
    return (
      <View className={styles.page}>
        <View className={styles.stateBlock}>
          <Text className={styles.stateText}>
            你的账号还没有绑定闪念间档案。{'\n'}打开我们发给你的专属链接完成首程，或在网页端「闪念间」凭手机号找回。
          </Text>
        </View>
      </View>
    )
  }

  if (state.kind === 'error') {
    return <PageState kind="error" message={state.message} onRetry={() => void load()} />
  }

  const { capsule } = state
  const view = myCardView(capsule)
  const quoteCandidates = quoteCandidatesOf(answers)
  const shareOptInMode = shareOptInState(capsule.me)
  const { endorsed, open } = splitActionCards(capsule.actionCards)
  const orderedCards = [...endorsed, ...open]

  return (
    <View className={styles.page}>
      <ScrollView scrollY className={styles.board} style={{ height: '100vh' }}>
        <View className={styles.header}>
          <Text className={styles.eyebrow}>IN A FLASH · 闪念间</Text>
          <Text className={styles.headline}>{view.headline}</Text>
          <Text className={styles.subline}>{view.subline}</Text>
          <Text className={`${styles.wallBadge} ${view.wallState === 'on_wall' ? styles.onWall : styles.offWall}`}>
            {view.wallState === 'on_wall' ? '已寄出到校友墙' : '还未寄出（可在网页端寄出）'}
          </Text>
          {/* R36：作者侧点赞回显——上墙且有点赞才出现（domain 判据 quoteLikeBadge） */}
          {quoteLikeBadge(capsule.me) && (
            <Text className={styles.likeBadge} data-testid="fb-like-badge">
              {quoteLikeBadge(capsule.me)}
            </Text>
          )}
        </View>

        <View className={styles.section}>
          {/* 第 3b 件：点击卡面 3D 翻转（两段式：0.32s 转出 → 侧棱换面 → 0.32s 转入，原型 E ia-flip 语言） */}
          <View className={styles.cardFlipScene}>
            <View
              className={`${styles.cardFlip} ${flipPhase === 'out' ? styles.cardFlipOut : ''} ${flipPhase === 'in' ? styles.cardFlipIn : ''}`}
            >
            {/* 合着卡面（默认态）：全名 + 年份·城市 + 已寄出微标；点击翻开（用户定稿 ①） */}
            {!flipped && (
              <View className={styles.polaroidCover} onClick={() => flipCard(true)}>
                <View className={styles.coverDot} />
                <Text className={styles.coverName}>{capsule.me.fullName}</Text>
                <Text className={styles.coverFacts}>
                  {[
                    capsule.me.appliedAt ? capsule.me.appliedAt.slice(0, 4) : '',
                    capsule.me.city
                  ].filter(Boolean).join(' · ')}
                </Text>
                <Text className={styles.coverHint}>点按翻开你的拍立得</Text>
              </View>
            )}
            {flipped && (
            <View className={styles.polaroidFlipOpen}>
            <View className={styles.polaroid}>
              <Text className={styles.polaroidLabel}>POLAROID · {capsule.me.appliedAt ? capsule.me.appliedAt.slice(0, 10) : '当年'}</Text>
              {answers.map((answer) => (
                <View key={answer.id}>
                  <Text className={styles.cardFaceTitle}>当年正面 · 你的答案</Text>
                  <Text className={styles.answerMeta}>点按句子切换雾面：雾面句对外隐藏，你这里永远完整</Text>
                  <View className={styles.sentences}>
                    {sentencesWithFog(answer).map((sentence, index) => (
                      <Text
                        key={`${answer.id}-${index}`}
                        className={`${styles.sentence} ${sentence.fogged ? styles.sentenceFogged : ''}`}
                        onClick={() => void toggleFog(answer, index)}
                      >
                        {sentence.text}
                      </Text>
                    ))}
                  </View>
                </View>
              ))}

              <View className={styles.todayBlock}>
                <Text className={styles.cardFaceTitle}>今天背面 · 今天的你</Text>
                {editing ? (
                  <View>
                    <View className={styles.todayRow}>
                      <Text className={styles.todayLabel}>现在在做什么</Text>
                      <Textarea className={styles.textarea} value={draftNow} onInput={(event) => setDraftNow(event.detail.value)} maxlength={200} />
                    </View>
                    <View className={styles.todayRow}>
                      <Text className={styles.todayLabel}>想做的事 / 想学的东西</Text>
                      <Textarea className={styles.textarea} value={draftWant} onInput={(event) => setDraftWant(event.detail.value)} maxlength={200} />
                    </View>
                    <View className={styles.todayRow}>
                      <Text className={styles.todayLabel}>想对 CGC 说的话</Text>
                      <Textarea className={styles.textarea} value={draftSay} onInput={(event) => setDraftSay(event.detail.value)} maxlength={200} />
                    </View>
                    <Button className={styles.saveButton} onClick={() => void saveToday()}>保存</Button>
                  </View>
                ) : (
                  <View>
                    <View className={styles.todayRow}>
                      <Text className={styles.todayLabel}>现在在做什么</Text>
                      <Text className={capsule.me.today?.nowStatus ? styles.todayText : styles.todayEmpty}>
                        {capsule.me.today?.nowStatus || '还没写下'}
                      </Text>
                    </View>
                    <View className={styles.todayRow}>
                      <Text className={styles.todayLabel}>想做的事 / 想学的东西</Text>
                      <Text className={capsule.me.today?.want ? styles.todayText : styles.todayEmpty}>
                        {capsule.me.today?.want || '还没写下'}
                      </Text>
                    </View>
                    <View className={styles.todayRow}>
                      <Text className={styles.todayLabel}>想对 CGC 说的话</Text>
                      <Text className={capsule.me.today?.say ? styles.todayText : styles.todayEmpty}>
                        {capsule.me.today?.say || '还没写下'}
                      </Text>
                    </View>
                    <Button className={styles.editorToggle} onClick={() => setEditing(true)}>编辑今天的你</Button>
                  </View>
                )}
              </View>
            </View>
            <Button className={styles.foldBackButton} onClick={() => flipCard(false)}>合上（回到卡面）</Button>
            </View>
            )}
            </View>
          </View>
          {/* R14 分享入口（用户定稿 ③）：显式按钮唤起分享 sheet（··· 胶囊菜单原生分享由 hooks 常驻注册） */}
          <Button className={styles.shareButton} onClick={() => setShareSheet(true)}>分享 · 把这一刻做成卡片</Button>
          <Canvas id={SUMMARY_CARD_CANVAS_ID} canvasId={SUMMARY_CARD_CANVAS_ID} type="2d" className={styles.shareCanvas} />

          <View className={styles.licenseCard}>
            <Text className={styles.sectionTitle}>金句授权</Text>
            <Text className={styles.sectionDesc}>你的授权随时可调，默认全部关闭</Text>
            {/* R35 选句器：匿名/实名档下展开候选句（按句切分、排除雾面段）；
                未圈选 = 不上墙；点句即提交（span 与这里展示的同源） */}
            {quoteLevel !== 'off' && (
              <View className={styles.quotePicker}>
                <Text className={styles.quotePickHint}>选一句放上首页金句墙（未选 = 不上墙）</Text>
                {quoteCandidates.map((candidate) => (
                  <Text
                    key={`${candidate.questionKey}:${candidate.start}`}
                    className={`${styles.quoteCandidate} ${
                      isCandidatePicked(candidate, pickedQuote) ? styles.quoteCandidateActive : ''
                    }`}
                    onClick={() => void pickQuoteCandidate(candidate)}
                  >
                    {candidate.sentence}
                  </Text>
                ))}
                {quoteCandidates.length === 0 && (
                  <Text className={styles.quotePickHint}>当年的句子里都带着雾面——解开后才能选金句</Text>
                )}
              </View>
            )}
            <RadioGroup onChange={(event) => void changeQuoteLevel((event.detail.value as QuoteLevel) ?? 'off')}>
              {QUOTE_LEVEL_OPTIONS.map((option) => (
                <View
                  key={option.value}
                  className={`${styles.licenseOption} ${quoteLevel === option.value ? styles.licenseOptionActive : ''}`}
                >
                  <Radio className={styles.licenseRadio} value={option.value} checked={quoteLevel === option.value} color="#ea5504" />
                  <View>
                    <Text className={styles.licenseLabel}>{option.label}</Text>
                    <Text className={styles.licenseDesc}>{option.desc}</Text>
                  </View>
                </View>
              ))}
            </RadioGroup>
          </View>

          {capsule.cities.length > 1 && (
            <View className={styles.cityPins}>
              {/* 全部钉独立类（cityPinAll）：e2e 类名定位——城市钉取 .cityPin 第一匹配 */}
              <Text
                className={`${styles.cityPinAll} ${city === null ? styles.cityPinActive : ''}`}
                onClick={() => pickCity(null)}
              >
                全部
              </Text>
              {capsule.cities.map((name) => (
                <Text
                  key={name}
                  className={`${styles.cityPin} ${city === name ? styles.cityPinActive : ''}`}
                  onClick={() => pickCity(name)}
                >
                  {name}
                </Text>
              ))}
            </View>
          )}
          <Text className={styles.sectionTitle}>行动板</Text>
          <Text className={styles.boardHint}>已附议的卡排前面；附议后成场时会收到通知</Text>
          {orderedCards.length === 0 && (
            <Text className={styles.boardHint}>行动板还没有卡——回信里许下的愿望经运营确认后会成卡上墙。</Text>
          )}
          {orderedCards.map((card) => {
            const action = endorseAction(card)
            return (
              <View key={card.id} className={`${styles.actionCard} ${styles[card.status]}`}>
                <View className={styles.actionHeader}>
                  <Text className={styles.actionTitle}>{card.title}</Text>
                  <Text className={`${styles.actionStatus} ${styles[card.status]}`}>{cardStatusText(card.status)}</Text>
                </View>
                <Text className={styles.actionMeta}>
                  {card.city ?? '城市待定'} · {action.hint}
                </Text>
                {card.rolesClaimed.length > 0 && (
                  <Text className={styles.rolesRow}>
                    已认领：{card.rolesClaimed.map((role) => ENDORSE_ROLES.find(({ value }) => value === role)?.label ?? role).join('、')}
                  </Text>
                )}
                {action.kind === 'endorse' && (
                  <Button
                    className={`${styles.endorseButton} ${card.endorsedByMe ? styles.endorseButtonPlain : ''}`}
                    disabled={endorsing}
                    onClick={() => pickRoleAndEndorse(card)}
                  >
                    {action.label}
                  </Button>
                )}
                {action.kind === 'goEvent' && (
                  <Button className={styles.endorseButton} onClick={() => openCard(card)}>{action.label}</Button>
                )}
                {action.kind === 'done' && <Text className={styles.rolesRow}>{action.label}</Text>}
              </View>
            )
          })}
        </View>
      </ScrollView>

      {/* 分享 sheet（原型 F：遮罩 + 底部圆角面板 + 三入口 + 取消） */}
      {shareSheet && (
        <View className={styles.shareMask} onClick={() => setShareSheet(false)}>
          <View className={styles.shareSheet} onClick={(event) => event.stopPropagation()}>
            <Text className={styles.shareSheetTitle}>把这一刻做成卡片</Text>
            {shareOptInMode !== 'hidden' && (
              <View
                className={`${styles.shareOptIn} ${shareOptInMode === 'already' ? styles.shareOptInLocked : ''}`}
                data-testid="fb-share-optin"
                onClick={() => {
                  if (shareOptInMode === 'already' || quoteBusy) return
                  void toggleShareOptIn(!shareOptIn, capsule.me)
                }}
              >
                <Text className={styles.shareOptInBox}>{shareOptIn ? '☑' : '☐'}</Text>
                <Text className={styles.shareOptInLabel}>
                  {shareOptInMode === 'already'
                    ? '已允许闪念间把这句话展示在首页（档位可在上方调整）'
                    : '同时允许闪念间把这句话展示在首页'}
                </Text>
              </View>
            )}
            <View className={styles.shareEntries}>
              <Button className={styles.shareEntry} openType="share">
                <Text className={styles.shareEntryIcon}>💬</Text>
                <Text className={styles.shareEntryLabel}>转发给好友</Text>
              </Button>
              <View className={styles.shareEntry} onClick={() => Taro.showToast({ title: '朋友圈分享请点右上角「···」选择', icon: 'none' })}>
                <Text className={styles.shareEntryIcon}>📷</Text>
                <Text className={styles.shareEntryLabel}>朋友圈</Text>
              </View>
              <View className={styles.shareEntry} onClick={() => void saveSummaryCard()}>
                <Text className={styles.shareEntryIcon}>⬇️</Text>
                <Text className={styles.shareEntryLabel}>{saving ? '保存中…' : '保存卡片'}</Text>
              </View>
            </View>
            <Button className={styles.shareCancel} onClick={() => setShareSheet(false)}>取消</Button>
          </View>
        </View>
      )}
    </View>
  )
}
