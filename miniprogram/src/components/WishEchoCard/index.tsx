/**
 * 回响卡(#837 一期 4/4 小程序)——公开读面渲染「这条愿望后来怎么样了」。
 *
 * 形状与 Web 端WishEchoCard (#836) 对齐:
 * - 主办 badge(主办 · 首次发布日期)
 * - 已更正 badge(status === 'corrected')
 * - body 保留换行(text-pre-line)
 * - 默认渲染最新一条;>1 条给「全部 N 条回响」toggle,展开时不重复渲染 latest
 *
 * 不渲染雾段、不渲染作者身份;回响即主办对外的公开回响(#834 R3)。
 */
import { useState } from 'react'
import { Text, View } from '@tarojs/components'
import type { FlashbackPublicWishEcho } from '@/domain/models'
import styles from './index.module.css'

export interface WishEchoCardProps {
  /** 全部回响(按首次发布时间正序),由父组件预过滤非法 status */
  echoes: FlashbackPublicWishEcho[]
}

/** ISO → YYYY.M.D(对齐 Web 端回响卡的日期呈现) */
function shortDate(iso: string): string {
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return ''
  return `${d.getUTCFullYear()}.${d.getUTCMonth() + 1}.${d.getUTCDate()}`
}

function EchoRow({ echo }: { echo: FlashbackPublicWishEcho }) {
  return (
    <View className={styles.echoRow} data-testid={`wish-echo-${echo.id}`}>
      <View className={styles.echoMeta}>
        <Text className={styles.orgBadge}>主办</Text>
        <Text className={styles.metaDate}>{shortDate(echo.publishedAt)}</Text>
        {echo.status === 'corrected' && <Text className={styles.correctedBadge}>已更正</Text>}
      </View>
      <Text className={styles.echoBody}>{echo.content}</Text>
    </View>
  )
}

export default function WishEchoCard({ echoes }: WishEchoCardProps) {
  const [expanded, setExpanded] = useState(false)
  if (!echoes || echoes.length === 0) return null

  const latest = echoes[echoes.length - 1]
  const rest = echoes.slice(0, echoes.length - 1)
  const showToggle = echoes.length > 1

  return (
    <View className={styles.echoCard} data-testid='wish-echo-card'>
      <View className={styles.echoHeader}>
        <Text className={styles.echoHeaderLabel}>回响</Text>
        <Text className={styles.echoHeaderCount}>{echoes.length} 条</Text>
      </View>
      {expanded && rest.map((e) => <EchoRow key={e.id} echo={e} />)}
      <EchoRow echo={latest} />
      {showToggle && (
        <View className={styles.toggleRow} onClick={() => setExpanded((v) => !v)}>
          <Text className={styles.toggleText}>{expanded ? '收起' : `全部 ${echoes.length} 条回响`}</Text>
        </View>
      )}
    </View>
  )
}
