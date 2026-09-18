import { useCallback, useState } from 'react'
import { Button, Radio, RadioGroup, ScrollView, Text, Textarea, View } from '@tarojs/components'
import Taro, { useDidShow } from '@tarojs/taro'
import { api, FlashbackNotBoundError, SessionExpiredError } from '@/api'
import { PageState } from '@/components/PageState'
import {
  actionCardTarget,
  cardStatusText,
  ENDORSE_ROLES,
  endorseAction,
  myCardView,
  parseQuoteLevel,
  QUOTE_LEVEL_OPTIONS,
  sentencesWithFog,
  splitActionCards,
  toggleSentenceFog,
  type QuoteLevel
} from '@/domain/flashback'
import { flashbackEndorseTouchpoint, submitAfterConsent } from '@/domain/subscription'
import type { FlashbackCapsule, FlashbackMeAnswer, FlashbackMyActionCard } from '@/domain/models'
import { requestPlatformSubscriptions } from '@/platform'
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
  const [endorsing, setEndorsing] = useState(false)

  const load = useCallback(async () => {
    setState({ kind: 'loading' })
    try {
      const capsule = await api.getFlashbackCapsule()
      setAnswers(capsule.me.answers)
      // 授权档从 capsule 恢复（R31；非法值 fail-closed 落 off）——不再恒定重置 off（P3）
      setQuoteLevel(parseQuoteLevel(capsule.me.quoteLevel))
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

  useDidShow(() => { void load() })

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

  const changeQuoteLevel = async (level: QuoteLevel) => {
    setQuoteLevel(level)
    try {
      await api.flashbackSetQuoteLicense(level)
      Taro.showToast({ title: '授权已更新', icon: 'none' })
    } catch (error) {
      Taro.showToast({ title: error instanceof Error ? error.message : '设置失败', icon: 'none' })
      void load()
    }
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
        </View>

        <View className={styles.section}>
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

          <View className={styles.licenseCard}>
            <Text className={styles.sectionTitle}>金句授权</Text>
            <Text className={styles.sectionDesc}>你的授权随时可调，默认全部关闭</Text>
            <RadioGroup onChange={(event) => void changeQuoteLevel((event.detail.value as QuoteLevel) ?? 'off')}>
              {QUOTE_LEVEL_OPTIONS.map((option) => (
                <View
                  key={option.value}
                  className={`${styles.licenseOption} ${quoteLevel === option.value ? styles.licenseOptionActive : ''}`}
                >
                  <Radio className={styles.licenseRadio} value={option.value} checked={quoteLevel === option.value} color="#e8b04b" />
                  <View>
                    <Text className={styles.licenseLabel}>{option.label}</Text>
                    <Text className={styles.licenseDesc}>{option.desc}</Text>
                  </View>
                </View>
              ))}
            </RadioGroup>
          </View>

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
    </View>
  )
}
