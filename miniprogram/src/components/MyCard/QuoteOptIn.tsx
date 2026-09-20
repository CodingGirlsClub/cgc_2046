/**
 * R37 授权引导勾选（ShareSheet 与卡片页共用单源）。
 *
 * 判据 `shareOptInState`：只有「圈了金句但还没授权」可勾（默认不勾，授权永不
 * 预选）；已授权显示为勾上态；卡上没有可回填的金句则整个不出现。
 *
 * **双向**：勾选即开匿名档（span = 卡片金句，多句时提交全部选中区间）；
 * 已授权时点按即关闭——撤回与给予同样是一次点按（GDPR Art. 7(3)），
 * 不把用户推到别处去找开关。
 *
 * `variant`：`card`（默认，ShareSheet 在 #f7f7f7 面板上的白底卡）；
 * `plain`（卡片页用：页面本身是米色纸，无白底、字号更小更灰——避免这行
 * 看起来像「分享的必填项」）。
 */
import { useState } from 'react'
import { Text, View } from '@tarojs/components'
import type { FlashbackMyCard } from '@/domain/models'
import { shareOptInState } from '@/domain/flashback'
import { useQuoteLicense } from './useQuoteLicense'
import styles from './index.module.css'

export default function QuoteOptIn({
  me,
  onWrite,
  variant = 'card'
}: {
  me: FlashbackMyCard
  onWrite: () => void
  variant?: 'card' | 'plain'
}) {
  const [checked, setChecked] = useState(false)
  const { quoteBusy, submitLicense } = useQuoteLicense(onWrite)
  const mode = shareOptInState(me)
  if (mode === 'hidden') return null
  // 已授权 = 勾上（文案也已是「已允许」）；本地 state 只管未授权时的勾选
  const checkedView = mode === 'already' || checked

  return (
    <View
      className={`${styles.shareOptIn} ${variant === 'plain' ? styles.shareOptInPlain : ''} ${
        mode === 'already' ? styles.shareOptInOn : ''
      }`}
      data-testid='fb-share-optin'
      onClick={() => {
        if (quoteBusy) return
        // 已授权 → 点按 = 关闭（对称撤回；quoteBusy 期间不响应，避免连点）
        if (mode === 'already') {
          void submitLicense('off', [])
          return
        }
        const next = !checked
        setChecked(next)
        if (!next) return
        const spans = (me.quoteSpans ?? []).map((s) => ({
          questionKey: s.questionKey,
          start: s.start,
          len: s.len
        }))
        void submitLicense('anonymous', spans).then((ok) => {
          if (!ok) setChecked(false)
        })
      }}
    >
      <Text className={styles.shareOptInBox}>{checkedView ? '☑' : '☐'}</Text>
      <Text className={styles.shareOptInLabel}>
        {mode === 'already' ? '已允许金句放进金句墙 · 点按关闭' : '同时允许金句放进金句墙'}
      </Text>
    </View>
  )
}
