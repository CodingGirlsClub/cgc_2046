/**
 * 我的卡(U2/R2 完整版,从原独立页整体搬迁):合着拍立得卡面 → 点击两段式 3D 翻转
 * (0.32s 转出 → 侧棱换面 → 0.32s 转入,原型 E ia-flip 语言)→ 当年正面(句子级
 * 雾化开关,KTD4 本人视图原文永远完整)+ 今天背面(编辑);金句授权三档(R31)+
 * R35 圈选器(点句即提交);R36 作者侧点赞回显;分享按钮唤起页面级 sheet。
 *
 * 数据由父级传入 capsule(父级负责加载),写操作(雾化/今天/授权)组件内直调 api
 * 后经 onWrite 通知父级 reload;分享 sheet/canvas 属页面级资源,经 onOpenShare
 * 唤起——corridor(微信端)与裁剪端薄壳共用本组件,视觉与交互单源。
 */
import { useEffect, useRef, useState } from 'react'
import { Button, Radio, RadioGroup, Text, Textarea, View } from '@tarojs/components'
import Taro from '@tarojs/taro'
import type { FlashbackCapsule, FlashbackMeAnswer } from '@/domain/models'
import { api } from '@/api'
import {
  isCandidatePicked,
  myCardView,
  parseQuoteLevel,
  QUOTE_LEVEL_OPTIONS,
  quoteCandidatesOf,
  quoteLikeBadge,
  sentencesWithFog,
  toggleSentenceFog,
  type QuoteCandidate,
  type QuoteLevel
} from '@/domain/flashback'
import styles from './index.module.css'
import { useQuoteLicense, type QuoteSpanPick } from './useQuoteLicense'

export default function MyCard({
  capsule,
  onWrite,
  onOpenShare
}: {
  capsule: FlashbackCapsule
  onWrite: () => void
  /** 唤起页面级分享 sheet(canvas 与「···」原生分享 hook 都在页面) */
  onOpenShare: () => void
}) {
  const [answers, setAnswers] = useState<FlashbackMeAnswer[]>(capsule.me.answers)
  const [editing, setEditing] = useState(false)
  const [draftNow, setDraftNow] = useState(capsule.me.today?.nowStatus ?? '')
  const [draftWant, setDraftWant] = useState(capsule.me.today?.want ?? '')
  const [draftSay, setDraftSay] = useState(capsule.me.today?.say ?? '')
  const [quoteLevel, setQuoteLevel] = useState<QuoteLevel>(parseQuoteLevel(capsule.me.quoteLevel))
  // R35 圈选:已选句(questionKey + 区间)——capsule 更新时从 me 回显
  const [pickedQuote, setPickedQuote] = useState<QuoteSpanPick | null>(
    capsule.me.quoteSpan && capsule.me.quoteQuestionKey
      ? { questionKey: capsule.me.quoteQuestionKey, start: capsule.me.quoteSpan.start, len: capsule.me.quoteSpan.len }
      : null
  )
  // 第 3b 件:两段式翻面状态机
  const [flipped, setFlipped] = useState(false)
  const [flipPhase, setFlipPhase] = useState<'idle' | 'out' | 'in'>('idle')
  const flipTimers = useRef<ReturnType<typeof setTimeout>[]>([])
  useEffect(() => () => { flipTimers.current.forEach(clearTimeout) }, [])

  // capsule 更新(reload/写后)同步本地受控态
  useEffect(() => {
    setAnswers(capsule.me.answers)
    setDraftNow(capsule.me.today?.nowStatus ?? '')
    setDraftWant(capsule.me.today?.want ?? '')
    setDraftSay(capsule.me.today?.say ?? '')
    setQuoteLevel(parseQuoteLevel(capsule.me.quoteLevel))
    setPickedQuote(
      capsule.me.quoteSpan && capsule.me.quoteQuestionKey
        ? { questionKey: capsule.me.quoteQuestionKey, start: capsule.me.quoteSpan.start, len: capsule.me.quoteSpan.len }
        : null
    )
  }, [capsule])

  const { submitLicense } = useQuoteLicense(onWrite)

  const flipCard = (next: boolean) => {
    if (flipPhase !== 'idle' || next === flipped) return
    setFlipPhase('out')
    flipTimers.current.push(setTimeout(() => {
      setFlipped(next)
      setFlipPhase('in')
      flipTimers.current.push(setTimeout(() => setFlipPhase('idle'), 340))
    }, 320))
  }

  // 句子雾/解雾:本地即时切换 + 整份 spans 提交(后端校验重叠/越界,失败 reload 纠正)
  const toggleFog = async (answer: FlashbackMeAnswer, sentenceIndex: number) => {
    const sentences = sentencesWithFog(answer)
    const sentence = sentences[sentenceIndex]
    if (!sentence) return
    const nextSpans = toggleSentenceFog(answer, sentence)
    setAnswers((prev) => prev.map((item) => (item.id === answer.id ? { ...answer, fogSpans: nextSpans } : item)))
    try {
      await api.flashbackAdjustFog(answer.id, nextSpans)
    } catch {
      onWrite()
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
      onWrite()
    } catch (error) {
      Taro.showToast({ title: error instanceof Error ? error.message : '保存失败', icon: 'none' })
    }
  }

  /** 切档:off 直接生效;anonymous/credited 已有圈选则直接换档,
   * 否则只展开候选列表(未圈选 = 不上墙,提交发生在点句时)。 */
  const changeQuoteLevel = async (level: QuoteLevel) => {
    setQuoteLevel(level)
    if (level === 'off') {
      setPickedQuote(null)
      await submitLicense('off', null)
      return
    }
    if (pickedQuote) await submitLicense(level, pickedQuote)
  }

  /** 圈选一句(R35):本地即时高亮 + 落库(span 与展示同源) */
  const pickQuoteCandidate = async (candidate: QuoteCandidate) => {
    const next = { questionKey: candidate.questionKey, start: candidate.start, len: candidate.len }
    setPickedQuote(next)
    await submitLicense(quoteLevel === 'off' ? 'anonymous' : quoteLevel, next)
    if (quoteLevel === 'off') setQuoteLevel('anonymous')
  }

  const view = myCardView(capsule)
  const quoteCandidates = quoteCandidatesOf(answers)

  return (
    <View className={styles.section}>
      <View className={styles.header}>
        <Text className={styles.eyebrow}>IN A FLASH · 闪念间</Text>
        <Text className={styles.headline}>{view.headline}</Text>
        <Text className={styles.subline}>{view.subline}</Text>
        <Text className={`${styles.wallBadge} ${view.wallState === 'on_wall' ? styles.onWall : styles.offWall}`}>
          {view.wallState === 'on_wall' ? '已寄出到校友墙' : '还未寄出（可在网页端寄出）'}
        </Text>
        {/* R36:作者侧点赞回显——上墙且有点赞才出现(domain 判据 quoteLikeBadge) */}
        {quoteLikeBadge(capsule.me) && (
          <Text className={styles.likeBadge} data-testid="fb-like-badge">
            {quoteLikeBadge(capsule.me)}
          </Text>
        )}
      </View>

      {/* 第 3b 件:点击卡面 3D 翻转(两段式:0.32s 转出 → 侧棱换面 → 0.32s 转入) */}
      <View className={styles.cardFlipScene}>
        <View
          className={`${styles.cardFlip} ${flipPhase === 'out' ? styles.cardFlipOut : ''} ${flipPhase === 'in' ? styles.cardFlipIn : ''}`}
        >
          {/* 合着卡面(默认态):全名 + 年份·城市;点击翻开(用户定稿 ①) */}
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

      {/* R14 分享入口(用户定稿 ③):显式按钮唤起页面级 sheet(··· 胶囊菜单原生分享由页面 hook 常驻注册) */}
      <Button className={styles.shareButton} onClick={onOpenShare}>分享 · 把这一刻做成卡片</Button>

      <View className={styles.licenseCard}>
        <Text className={styles.sectionTitle}>金句授权</Text>
        <Text className={styles.sectionDesc}>你的授权随时可调，默认全部关闭</Text>
        {/* R35 选句器:匿名/实名档下展开候选句(按句切分、排除雾面段);
            未圈选 = 不上墙;点句即提交(span 与这里展示的同源) */}
        {quoteLevel !== 'off' && (
          <View className={styles.quotePicker}>
            <Text className={styles.quotePickHint}>从当年答案里选一句作为你的金句（未选 = 不展示）：</Text>
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
        {/* 激励文案(用户选 C):三档下方常显 */}
        <Text className={styles.licenseInspire}>你的答案，会成为别人的勇气。</Text>
      </View>
    </View>
  )
}

