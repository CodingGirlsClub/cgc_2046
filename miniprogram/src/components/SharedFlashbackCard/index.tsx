/**
 * 对外分享卡（#771）单源渲染：**本人预览与访客页共用同一个组件、同一份形状**
 * （`FlashbackSharedCard` —— 白名单字段 + 段结构）。本人预览不是另一套模板：
 * 若预览与访客看到的不一致，「朋友将看到的全文卡」这句承诺当场作废。
 *
 * 两条不可回归的红线：
 * 1. **雾段不渲染任何字符**。段文本已由服务端置空（`api/real.mapSharedCard`
 *    的 fail-closed：fog 段只要可能带原文就丢弃），本组件对 fog 段只画定宽雾块
 *    ——不读 `text`，也**不按 `len` 画宽度**（长度同样是信息，雾块的宽度不该
 *    泄露原句长短）。
 * 2. **没有回退到本人卡原文的代码路径**。入参形状里根本没有 rawText，页面也
 *    不得拿 `me.answers` 去补段。
 *
 * 与本人卡（components/MyCard 的 TodayReview）共用纸卡语言：纸白 #f6f2e8 +
 * 当年照片窗（米灰渐变）+ 今天相纸（#efe9db）+ 厚下巴署名行。区别只在只读：
 * 对外卡没有任何可点句、没有编辑入口、没有隐私开关（那是本人的面）。
 */
import { Text, View } from '@tarojs/components'
import { questionLabel } from '@/domain/flashback'
import type { FlashbackRosterAnswer, FlashbackSharedCard } from '@/domain/models'
import styles from './index.module.css'

/** 段列表：非雾段出文本，雾段出定宽雾块（定宽 = 不泄露原句长度）。 */
function Segments({ section }: { section: FlashbackRosterAnswer }) {
  return (
    <View className={styles.answer}>
      {section.segments.map((segment, index) =>
        segment.fog ? (
          <View key={index} className={styles.fogSeg} data-testid='fb-shared-card-fog' />
        ) : (
          <Text key={index} className={styles.seg}>
            {segment.text}
          </Text>
        )
      )}
    </View>
  )
}

export default function SharedFlashbackCard({ card }: { card: FlashbackSharedCard }) {
  // 报名时间戳（`2014-01-05T…` → `2014.01.05`）；不可解析则不出（不编造日期）
  const day = card.appliedAt?.slice(0, 10)
  const stamp = day && /^\d{4}-\d{2}-\d{2}$/.test(day) ? day.replace(/-/g, '.') : null
  const year = stamp ? stamp.slice(0, 4) : null
  // 排除空文本段：无段、或全是空文本且无雾段 → 不渲染。**雾段一律算有内容**
  // ——雾住的是真话，只是不能说，漏掉它等于告诉访客「这题她没写」。
  const withContent = (section: FlashbackRosterAnswer): boolean =>
    section.segments.some((segment) => segment.fog || segment.text.length > 0)
  const answers = card.answers.filter(withContent)
  const today = card.today.filter(withContent)

  return (
    <View className={styles.card} data-testid='fb-shared-card'>
      <View className={styles.head}>
        <Text className={styles.kicker}>IN A FLASH · 闪念间</Text>
        {(card.city || stamp) && (
          <Text className={styles.stamp}>{[card.city, stamp].filter(Boolean).join(' · ')}</Text>
        )}
      </View>

      {answers.length > 0 && (
        <View className={styles.photoPast}>
          <Text className={styles.photoTitle}>当年的你{year ? ` · ${year}` : ''}</Text>
          {answers.map((section) => (
            <View key={section.questionKey} className={styles.qa}>
              <Text className={styles.question}>{questionLabel(section.questionKey)}</Text>
              <Segments section={section} />
            </View>
          ))}
        </View>
      )}

      {today.length > 0 && (
        <View className={styles.photoToday}>
          <Text className={styles.photoTitle}>今天的你</Text>
          {today.map((section) => (
            <View key={section.questionKey} className={styles.qa}>
              <Text className={styles.todayQuestion}>{questionLabel(section.questionKey)}</Text>
              <Segments section={section} />
            </View>
          ))}
        </View>
      )}

      <View className={styles.signRow}>
        <Text className={styles.signName}>{card.displayName}</Text>
        {stamp && <Text className={styles.signTime}>{stamp}</Text>}
      </View>

      <Text className={styles.fogNote}>雾住的句子不会出现在这张卡上</Text>
    </View>
  )
}
