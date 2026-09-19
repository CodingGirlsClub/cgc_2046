/**
 * 我的卡(U2/R2 抽组件):当年正面(3D 翻转+句子雾化开关)+ 今天背面(编辑)
 * + 金句授权三档。corridor 页内 Tab 与 flashback 独立页共用同一实现——
 * 判据与文案全部下沉 domain/flashback.ts(页面无渲染测试)。
 *
 * 数据由父级传入 capsule(父级负责加载),写操作(雾化/今天/授权)组件内
 * 直调 api 后经 onWrite 通知父级 reload(单数据流:父级是唯一数据源)。
 */
import { useState } from 'react'
import Taro from '@tarojs/taro'
import { Button, Text, Textarea, View } from '@tarojs/components'
import type { FlashbackCapsule, FlashbackMeAnswer } from '@/domain/models'
import { api } from '@/api'
import { myCardView, sentencesWithFog, toggleSentenceFog, QUOTE_LEVEL_OPTIONS, parseQuoteLevel, type QuoteLevel } from '@/domain/flashback'
import styles from '@/pages/flashback/index.module.css'

export default function MyCard({ capsule, onWrite }: { capsule: FlashbackCapsule; onWrite: () => void }) {
  const [flipped, setFlipped] = useState(false)
  const [answers, setAnswers] = useState<FlashbackMeAnswer[]>(capsule.me.answers)
  const [editing, setEditing] = useState(false)
  const [draftNow, setDraftNow] = useState(capsule.me.today?.nowStatus ?? '')
  const [draftWant, setDraftWant] = useState(capsule.me.today?.want ?? '')
  const [draftSay, setDraftSay] = useState(capsule.me.today?.say ?? '')
  const [quoteLevel, setQuoteLevel] = useState<QuoteLevel>(parseQuoteLevel(capsule.me.quoteLevel))
  const view = myCardView(capsule)

  // 句子雾/解雾:本地即时切换 + 整份 spans 提交(后端校验,失败父级 reload 纠正)
  const toggleFog = async (answer: FlashbackMeAnswer, sentenceIndex: number) => {
    const sentences = sentencesWithFog(answer)
    const sentence = sentences[sentenceIndex]
    if (!sentence) return
    const nextSpans = toggleSentenceFog(answer, sentence)
    const nextAnswer = { ...answer, fogSpans: nextSpans }
    setAnswers((prev) => prev.map((item) => (item.id === answer.id ? nextAnswer : item)))
    try {
      await api.flashbackAdjustFog(answer.id, nextSpans)
    } catch (error) {
      Taro.showToast({ title: error instanceof Error ? error.message : '设置失败', icon: 'none' })
    }
    onWrite()
  }

  const submitToday = async () => {
    try {
      await api.flashbackSubmitToday({ nowStatus: draftNow, want: draftWant, say: draftSay })
      setEditing(false)
      Taro.showToast({ title: '已保存', icon: 'success' })
    } catch (error) {
      Taro.showToast({ title: error instanceof Error ? error.message : '保存失败', icon: 'none' })
    }
    onWrite()
  }

  const setLicense = async (level: QuoteLevel) => {
    setQuoteLevel(level)
    try {
      await api.flashbackSetQuoteLicense(level, level === 'off' ? null : capsule.me.quoteQuestionKey, capsule.me.quoteSpan)
      Taro.showToast({ title: '授权已更新', icon: 'none' })
    } catch (error) {
      Taro.showToast({ title: error instanceof Error ? error.message : '设置失败', icon: 'none' })
    }
    onWrite()
  }

  return (
    <View className={styles.board}>
      <View className={styles.header}>
        <Text className={styles.eyebrow}>IN A FLASH · 闪念间</Text>
        <Text className={styles.headline}>{view.headline}</Text>
        <Text className={styles.subline}>{view.subline}</Text>
      </View>

      {/* 第 3b 件:点击卡面 3D 翻转(两段式),再按合上 */}
      <View className={styles.cardStage} onClick={() => setFlipped(!flipped)}>
        <View className={`${styles.flipCard} ${flipped ? styles.flipCardFlipped : ''}`}>
          {/* 正面:当年答案 + 逐句雾化开关(KTD4 本人视图原文永远完整) */}
          <View className={styles.flipFace}>
            {answers.map((answer) => (
              <View key={answer.id} className={styles.answerBlock}>
                <Text className={styles.answerText}>{answer.rawText}</Text>
                <View className={styles.fogControls}>
                  {sentencesWithFog(answer).map((sentence, index) => (
                    <Text
                      key={index}
                      className={`${styles.fogToggle} ${sentence.fogged ? styles.fogToggleOn : ''}`}
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
          {/* 背面:今天 + 编辑 */}
          <View className={styles.flipFaceBack}>
            {editing ? (
              <View className={styles.editor} onClick={(e) => e.stopPropagation()}>
                <Textarea className={styles.textarea} value={draftNow} onInput={(e) => setDraftNow(e.detail.value)} maxlength={200} placeholder="现在在做…" />
                <Textarea className={styles.textarea} value={draftWant} onInput={(e) => setDraftWant(e.detail.value)} maxlength={200} placeholder="想做…" />
                <Textarea className={styles.textarea} value={draftSay} onInput={(e) => setDraftSay(e.detail.value)} maxlength={200} placeholder="想说…(可留空)" />
                <Button size="mini" onClick={() => void submitToday()}>
                  保存
                </Button>
              </View>
            ) : (
              <View onClick={(e) => { e.stopPropagation(); setEditing(true) }}>
                <Text className={styles.todayNow}>{capsule.me.today?.nowStatus || '点这里写下现在'}</Text>
                <Text className={styles.todayWant}>{capsule.me.today?.want || '想做…'}</Text>
                {capsule.me.today?.say ? <Text className={styles.todaySay}>{capsule.me.today.say}</Text> : null}
                <Text className={styles.editorToggle}>编辑今天的你</Text>
              </View>
            )}
          </View>
        </View>
      </View>

      {/* 金句授权三档(R31):文案与 web 端 quoteLegend/quote_* 对齐,跨端一致 */}
      <Text className={styles.sectionTitle}>金句授权</Text>
      <View className={styles.quoteLevelRow}>
        {QUOTE_LEVEL_OPTIONS.map((option) => (
          <Text
            key={option.value}
            className={`${styles.quoteLevelBtn} ${quoteLevel === option.value ? styles.quoteLevelActive : ''}`}
            onClick={() => void setLicense(option.value)}
          >
            {option.label}
          </Text>
        ))}
      </View>
      {/* 当前档说明(与 web 端 quote_* 同文案):授权是白名单行为,desc 讲清去向 */}
      <Text className={styles.licenseDesc}>
        {QUOTE_LEVEL_OPTIONS.find((option) => option.value === quoteLevel)?.desc}
      </Text>
      {/* 勇气语(与 web quoteCourage/原独立页 licenseInspire 同源):档位后、选句前 */}
      <Text className={styles.licenseInspire}>你的答案，会成为别人的勇气。</Text>
      {capsule.me.quote && <Text className={styles.quotePreview}>「{capsule.me.quote}」</Text>}
    </View>
  )
}
