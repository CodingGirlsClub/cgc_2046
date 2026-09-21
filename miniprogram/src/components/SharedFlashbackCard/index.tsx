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
  // 头部场景定位：活动举办日（occurred_on，如 2014-01-11 → 2014.01.11）——
  // 记忆真正发生的那天。不可解析则不出（不编造日期）。
  const occurredDay = card.occurredOn?.slice(0, 10)
  const occurredStamp =
    occurredDay && /^\d{4}-\d{2}-\d{2}$/.test(occurredDay) ? occurredDay.replace(/-/g, '.') : null
  const occurredYear = occurredStamp ? occurredStamp.slice(0, 4) : null
  // 落款：报名时间（applied_at，精确到分）——她写下这张卡的那一刻。
  const appliedStamp = formatAppliedStamp(card.appliedAt)
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
        {(card.city || occurredStamp) && (
          <Text className={styles.stamp}>{[card.city, occurredStamp].filter(Boolean).join(' · ')}</Text>
        )}
      </View>

      {answers.length > 0 && (
        <View className={styles.photoPast}>
          <Text className={styles.photoTitle}>当年的你{occurredYear ? ` · ${occurredYear}` : ''}</Text>
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
        {appliedStamp && <Text className={styles.signTime}>{appliedStamp}</Text>}
      </View>
    </View>
  )
}

/** 落款时间：按数据真实精度分级显示，绝不渲染假精度（如 `13:06:42.000`）。
 *
 *  数据血统（导入两条路径）：ISO 字符串行可能自带毫秒/微秒；Excel 序号行
 *  只到秒（`excel_serial_to_utc` 的 `Time.new!(h, m, s)`）。两条路径存的都是
 *  **真 UTC**（Excel 墙钟按 +08:00 减 8h；ISO 带偏移的也归一到 UTC）。
 *  显示层必须转回北京墙钟（+08:00），否则「她写下那一刻」差 8 小时、
 *  凌晨提交的行连日期都会偏一天。
 *
 *  精度分级（跟随数据，不编造不截断）：
 *  - 有毫秒且非 `.000` → `2014.01.11 13:06:42.317`（保留真实毫秒）
 *  - 有秒且非 `:00` → `2014.01.11 13:06:42`
 *  - 秒为 `:00` 或只有分 → `2014.01.11 13:06`（`:00` 是精度占位，省略）
 *  不可解析回落日期部分；再不行返回 null（不编造）。 */
function formatAppliedStamp(appliedAt: string | null): string | null {
  if (!appliedAt) return null
  const date = new Date(appliedAt)
  if (Number.isNaN(date.getTime())) {
    const day = appliedAt.slice(0, 10)
    return /^\d{4}-\d{2}-\d{2}$/.test(day) ? day.replace(/-/g, '.') : null
  }
  // 转北京墙钟：UTC 毫秒 + 8h，再取 UTC 字段（等价于 Asia/Shanghai 的墙钟）
  const beijing = new Date(date.getTime() + 8 * 3600_000)
  const y = beijing.getUTCFullYear()
  const mo = String(beijing.getUTCMonth() + 1).padStart(2, '0')
  const d = String(beijing.getUTCDate()).padStart(2, '0')
  const hh = String(beijing.getUTCHours()).padStart(2, '0')
  const mm = String(beijing.getUTCMinutes()).padStart(2, '0')
  const ss = beijing.getUTCSeconds()
  const ms = beijing.getUTCMilliseconds()

  let stamp = `${y}.${mo}.${d} ${hh}:${mm}`
  // 秒为 0 时省略（`:00` 是精度占位，不是「她特意在整秒写下」）
  if (ss !== 0 || ms !== 0) {
    stamp += `:${String(ss).padStart(2, '0')}`
    // 毫秒仅在有真实值时追加——`.000` 是精度占位（Excel 序号导入到秒），不显示
    if (ms !== 0) stamp += `.${String(ms).padStart(3, '0')}`
  }
  return stamp
}
