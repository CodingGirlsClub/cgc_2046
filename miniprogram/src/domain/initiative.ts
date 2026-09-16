import type { PublicInitiativeEvent, QualificationBadge } from './models'

export function parseQualificationBadge(value: unknown): QualificationBadge | null {
  // 契约可空（EventDetailQuery 为 string | null）：key 存在但值为 null 不炸详情页
  if (value === null || value === undefined) return null
  if (value === 'cancelled' || value === 'closed' || value === 'confirmed' || value === 'short_by' || value === 'open') return value
  throw new Error('服务端返回未知成班状态')
}

/** 展示后端投影；不从报名计数或当前时间推算成班事实。 */
export function qualificationBadgeText(event: Pick<PublicInitiativeEvent, 'qualificationBadge' | 'shortBy'>): string {
  switch (event.qualificationBadge) {
    case 'cancelled': return '已取消'
    case 'closed': return '已结束'
    case 'confirmed': return '已成班'
    case 'short_by': return `还差 ${event.shortBy} 人成班`
    case 'open': return '开放报名'
  }
}

/**
 * 详情页成班徽章文案（对齐 web QualificationBadgeTag 的详情页口径）：`open`
 * 与报名标签语义重复，详情页不展示；null 同理隐藏。Initiative 卡片面仍走
 * qualificationBadgeText —— 那里 `open` 需要显示「开放报名」。
 */
export function detailQualificationBadgeText(event: {
  qualificationBadge: QualificationBadge | null
  shortBy: number | null
}): string | null {
  const badge = event.qualificationBadge
  if (!badge || badge === 'open') return null
  return qualificationBadgeText({ qualificationBadge: badge, shortBy: event.shortBy })
}

/**
 * 发现页倡导活动卡片的关键词过滤（阶段5）：与服务端 title ilike `%kw%` 同语义
 * ——大小写不敏感子串，命中 name / hashtag / description 任一。空关键词原样返回。
 *
 * 不走服务端：`publicInitiatives` 无 search 参数（分页/搜索见 issue #578），而
 * 该列表本就一次全量取回（服务端 LIMIT 100），客户端过滤相对返回集是精确的。
 */
export function filterInitiatives<
  T extends { name: string; hashtag: string | null; description: string | null }
>(cards: T[], keyword: string): T[] {
  const kw = keyword.trim().toLowerCase()
  if (!kw) return cards
  return cards.filter((card) =>
    [card.name, card.hashtag ?? '', card.description ?? ''].some((field) =>
      field.toLowerCase().includes(kw)
    )
  )
}
