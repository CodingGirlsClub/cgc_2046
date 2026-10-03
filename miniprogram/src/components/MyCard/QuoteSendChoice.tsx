/**
 * 寄出时「放进金句墙」的选择（#1022，单独同意）：预览推荐句 + 墙上署名（后端单源，
 * 所见即所得）、「换一句」、两个同分量按钮（同样式同宽，永不预选）。
 *
 * 卡片背面（MyCard）与首程页共用；无推荐句 / 已授权时宿主渲染原单按钮，本组件不出现。
 * 规则与文案在 domain/quote-suggestion（node --test 钉住，与 web 逐条对齐）。
 */
import { useState } from 'react'
import { Button, Text, View } from '@tarojs/components'
import { currentSuggestion, nextSuggestion, QUOTE_SEND_COPY, type QuoteSuggestion } from '@/domain/quote-suggestion'
import styles from './index.module.css'

import type { QuotePick } from '@/domain/quote-send'

export default function QuoteSendChoice({
  suggestions,
  attribution,
  busy,
  onSend
}: {
  suggestions: QuoteSuggestion[]
  attribution: string
  busy: boolean
  /** pick = 这一句（先授权匿名档再寄出）；null = 只寄出到相册 */
  onSend: (pick: QuotePick | null) => void
}) {
  const [chosen, setChosen] = useState<QuoteSuggestion | null>(null)
  const [pressed, setPressed] = useState<'quote' | 'album' | null>(null)
  const current = currentSuggestion(suggestions, chosen)
  if (!current) return null

  const send = (withQuote: boolean) => {
    if (busy) return
    setPressed(withQuote ? 'quote' : 'album')
    onSend(withQuote ? { questionKey: current.questionKey, start: current.start, len: current.len } : null)
  }
  const label = (kind: 'quote' | 'album', text: string) => (busy && pressed === kind ? QUOTE_SEND_COPY.sending : text)

  return (
    <View>
      <View className={styles.quoteChoice}>
        <Text className={styles.quoteChoiceEyebrow}>{QUOTE_SEND_COPY.eyebrow}</Text>
        <Text className={styles.quoteChoiceText}>{`「${current.sentence}」`}</Text>
        <View className={styles.quoteChoiceMeta}>
          <Text className={styles.quoteChoiceCite}>{attribution}</Text>
          {suggestions.length > 1 && (
            <Button className={styles.quoteChoiceShuffle} disabled={busy} onClick={() => setChosen(nextSuggestion(suggestions, current))}>
              {QUOTE_SEND_COPY.shuffle}
            </Button>
          )}
        </View>
      </View>
      <View className={styles.quoteChoiceActions}>
        <Button
          className={`${styles.sendBtn} ${styles.quoteChoiceWithQuote} ${busy ? styles.sendBtnBusy : ''}`}
          disabled={busy}
          onClick={() => send(true)}
        >
          {label('quote', QUOTE_SEND_COPY.withQuote)}
        </Button>
        <Button
          className={`${styles.sendBtn} ${styles.quoteChoiceAlbumOnly} ${busy ? styles.sendBtnBusy : ''}`}
          disabled={busy}
          onClick={() => send(false)}
        >
          {label('album', QUOTE_SEND_COPY.albumOnly)}
        </Button>
      </View>
      <Text className={styles.sendNote}>{QUOTE_SEND_COPY.note}</Text>
    </View>
  )
}
