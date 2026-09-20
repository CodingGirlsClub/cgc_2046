/**
 * 我的卡(F 式两面拍立得,用户定稿):点开即「当年答案相纸」——题干+雾化句
 * 直接印在相纸上(点句切换雾面),再点卡面翻到「今天写入面」——三行手写线
 * 直接可输入(placeholder 引导,失焦自动保存),「写完寄出 →」= 保存+上墙
 * 一步到位;无「编辑」按钮,无需进入编辑态。
 * 数据由父级传入 capsule/token;雾化/今天/寄出直调 api 后经 onWrite 通知
 * 父级 reload;分享 sheet 由页面级 onOpenShare 唤起(canvas 在页面)。
 */
import { useEffect, useState } from 'react'
import { Button, Input, Text, View } from '@tarojs/components'
import Taro from '@tarojs/taro'
import type { FlashbackCapsule, FlashbackMeAnswer } from '@/domain/models'
import { api } from '@/api'
import {
  isCandidatePicked,
  quoteLikeBadge,
  sentencesWithFog,
  toggleSentenceFog,
  todaySentencesWithFog,
  toggleTodaySentenceFog,
  TODAY_FIELDS
} from '@/domain/flashback'
import { questionLabel } from '@/domain/flashback-journey'
import styles from './index.module.css'

type TodayKey = (typeof TODAY_FIELDS)[number]['field']

export default function MyCard({
  capsule,
  token,
  onWrite,
  onSent,
  autoOpen = false,
  chrome = true,
  onOpenShare
}: {
  capsule: FlashbackCapsule
  /** 会话腿寄出需要(capsule token 或登录态二选一,与 corridor 加载同源) */
  token?: string | null
  onWrite: () => void
  /** 寄出成功(保存+上墙)后通知页面:关抽屉+滚到今天格 */
  onSent?: () => void
  /** write 入口:抽屉升起直接落在「今天写入面」;view 入口落在「当年答案面」 */
  autoOpen?: boolean
  /** chrome:状态行+分享按钮(独立页需要;corridor 居中模态里外移到遮罩,传 false) */
  chrome?: boolean
  /** 唤起页面级分享 sheet(canvas 与「···」原生分享 hook 都在页面) */
  onOpenShare?: () => void
}) {
  const [answers, setAnswers] = useState<FlashbackMeAnswer[]>(capsule.me.answers)
  const [flipped, setFlipped] = useState(autoOpen)
  const [draft, setDraft] = useState<Record<TodayKey, string>>({
    nowStatus: capsule.me.today?.nowStatus ?? '',
    want: capsule.me.today?.want ?? '',
    need: capsule.me.today?.need ?? '',
    say: capsule.me.today?.say ?? ''
  })
  const [saving, setSaving] = useState(false)

  // capsule 更新(reload/写后)同步本地雾化态
  useEffect(() => {
    setAnswers(capsule.me.answers)
  }, [capsule])

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

  const persistToday = async (next: Record<TodayKey, string>) => {
    await api.flashbackSubmitToday({
      nowStatus: next.nowStatus || null,
      want: next.want || null,
      need: next.need || null,
      say: next.say || null
    })
    onWrite()
  }

  const saveOnBlur = () => {
    void persistToday(draft).catch((error: unknown) =>
      Taro.showToast({ title: error instanceof Error ? error.message : '保存失败', icon: 'none' })
    )
  }

  const sendToday = async () => {
    if (saving) return
    setSaving(true)
    try {
      await persistToday(draft)
      await api.flashbackSendToWall(token ?? '')
      Taro.showToast({ title: '已贴上墙', icon: 'none' })
      onWrite()
      onSent?.()
    } catch (error) {
      Taro.showToast({ title: error instanceof Error ? error.message : '寄出失败', icon: 'none' })
    } finally {
      setSaving(false)
    }
  }

  return (
    <View className={styles.section}>
      {chrome && (
        <View className={styles.statusRow}>
          <Text
            className={`${styles.wallBadge} ${capsule.me.today?.sentToWallAt ? styles.onWall : styles.offWall}`}
          >
            {capsule.me.today?.sentToWallAt ? '已寄出到校友墙' : '还没寄出 · 写完贴上面'}
          </Text>
          {quoteLikeBadge(capsule.me) && (
            <Text className={styles.likeBadge} data-testid='fb-like-badge'>
              ❤ {capsule.me.quoteStats?.likeCount ?? 0}
            </Text>
          )}
        </View>
      )}
      {/* F 式两面拍立得:当年答案相纸 ⇄ 今天写入相纸(一次连贯 180°,两面常挂) */}
      <View className={styles.cardFlipScene}>
        <View className={`${styles.cardFlip} ${flipped ? styles.cardFlipFlipped : ''}`}>
          {/* 正面:当年答案相纸(题干+雾化句+署名行);点击翻到今天写入面 */}
          <View
            className={`${styles.cardFlipFace} ${styles.paperFace}`}
            onClick={() => setFlipped(true)}
          >
            <View className={styles.paperPhotoA}>
              {answers.map((answer) => (
                <View key={answer.id} className={styles.paperQA}>
                  <Text className={styles.paperQ}>{questionLabel(answer.questionKey)}</Text>
                  <View className={styles.paperA}>
                    {sentencesWithFog(answer).map((sentence, index) => (
                      <Text
                        key={`${answer.id}-${index}`}
                        className={`${styles.sentence} ${sentence.fogged ? styles.sentenceFogged : ''}`}
                        onClick={(e) => {
                          e.stopPropagation()
                          void toggleFog(answer, index)
                        }}
                      >
                        {sentence.text}
                      </Text>
                    ))}
                  </View>
                </View>
              ))}
            </View>
            <Text className={styles.fogHint}>点句子可切换雾面 · 雾面句对外不可见</Text>
            <View className={styles.signRow}>
              <Text className={styles.signName}>{capsule.me.fullName}</Text>
              <Text className={styles.signTime}>
                {capsule.me.appliedAt ? capsule.me.appliedAt.slice(0, 10).replace(/-/g, '.') : ''}
              </Text>
            </View>
          </View>

          {/* 背面:今天写入相纸(三行手写线直接输入,失焦自动保存) */}
          <View
            className={`${styles.cardFlipFace} ${styles.cardFlipFaceBack} ${styles.paperFace}`}
            onClick={(e) => e.stopPropagation()}
          >
            <View className={styles.paperPhotoB}>
              <Text className={styles.paperTodayTitle}>
                今天的你 · {new Date().toLocaleDateString('zh-CN', { year: 'numeric', month: 'numeric', day: 'numeric' }).replace(/\//g, '.')}
              </Text>
              {TODAY_FIELDS.map((field) => (
                <View key={field.field} className={styles.writeRow}>
                  <Text className={styles.writeLabel}>{field.label}</Text>
                  <Input
                    className={styles.writeInput}
                    value={draft[field.field]}
                    placeholder={field.placeholder}
                    placeholderClass={styles.writePlaceholder}
                    maxlength={100}
                    onInput={(e) => setDraft((prev) => ({ ...prev, [field.field]: e.detail.value }))}
                    onBlur={() => saveOnBlur()}
                  />
                </View>
              ))}
            </View>
            <Button
              className={`${styles.sendBtn} ${saving ? styles.sendBtnBusy : ''}`}
              disabled={saving}
              onClick={() => void sendToday()}
            >
              {saving ? '正在贴上墙…' : '写完寄出 →'}
            </Button>
            <Text className={styles.sendNote}>寄出即公开 · 包括当年的答案</Text>
            <Text className={styles.backLink} onClick={() => setFlipped(false)}>
              ← 回到当年答案
            </Text>
          </View>
        </View>
      </View>

      {chrome && onOpenShare && (
        <Button className={styles.shareButton} onClick={onOpenShare}>
          分享 · 把这一刻做成卡片
        </Button>
      )}
    </View>
  )
}

/**
 * 今天回看卡(今天格 lit 点击):单面相纸=「这张卡在别人眼里的样子」——
 * 今天的你按句渲染(U10 起句级雾:点句切换,雾句=雾块示意对外隐藏)、
 * 当年答案按句渲染(雾句=雾块,已授权金句浅金高亮)+署名行。分享钩子由页面挂在卡下。
 * onToggleTodayFog:页面实现调 flashbackAdjustTodayFog(传 null = 只读,如他人视角)。
 */
export function TodayReview({
  me,
  level,
  onToggleTodayFog
}: {
  me: FlashbackCapsule['me']
  level: 'off' | 'anonymous' | 'credited'
  onToggleTodayFog?: ((field: 'now' | 'want' | 'need' | 'say', spans: Array<{ start: number; len: number }>) => void) | null
}) {
  const spans = me.quoteSpans ?? []
  const todayFog = me.today?.fogSpans ?? {}
  return (
    <View className={styles.paperFace}>
      <View className={styles.paperPhotoB}>
        <Text className={styles.paperTodayTitle}>
          今天的你 · {new Date().toLocaleDateString('zh-CN', { year: 'numeric', month: 'numeric', day: 'numeric' }).replace(/\//g, '.')}
        </Text>
        {TODAY_FIELDS.map((row) => {
          const raw = me.today?.[row.field]
          if (!raw) return null
          return (
            <View key={row.field} className={styles.writeRow}>
              <Text className={styles.writeLabel}>{row.label}</Text>
              <View className={styles.paperA}>
                {todaySentencesWithFog(raw, todayFog[row.fog]).map((sentence, index) => (
                  <Text
                    key={`${row.fog}-${index}`}
                    className={`${styles.rvSentence} ${sentence.fogged ? styles.rvFog : ''}`}
                    onClick={() => {
                      if (!onToggleTodayFog) return
                      onToggleTodayFog(row.fog, toggleTodaySentenceFog(todayFog[row.fog], sentence))
                    }}
                  >
                    {sentence.text}
                  </Text>
                ))}
              </View>
            </View>
          )
        })}
      </View>
      <View className={styles.paperPhotoA}>
        <Text className={styles.paperTodayTitle}>当年的你 · {me.appliedAt ? me.appliedAt.slice(0, 4) : ''}</Text>
        {me.answers.map((answer) => (
          <View key={answer.id} className={styles.paperQA}>
            <Text className={styles.paperQ}>{questionLabel(answer.questionKey)}</Text>
            <View className={styles.paperA}>
              {sentencesWithFog(answer).map((sentence, index) => {
                const span = { questionKey: answer.questionKey, start: sentence.start, len: sentence.len }
                const isQuote = level !== 'off' && isCandidatePicked({ ...span, sentence: sentence.text }, spans)
                return (
                  <Text
                    key={`${answer.id}-${index}`}
                    className={`${styles.rvSentence} ${sentence.fogged ? styles.rvFog : ''} ${isQuote ? styles.rvQuote : ''}`}
                  >
                    {sentence.text}
                  </Text>
                )
              })}
            </View>
          </View>
        ))}
      </View>
      <View className={styles.signRow}>
        <Text className={styles.signName}>{me.fullName}</Text>
        <Text className={styles.signTime}>{me.appliedAt ? me.appliedAt.slice(0, 10).replace(/-/g, '.') : ''}</Text>
      </View>
    </View>
  )
}
