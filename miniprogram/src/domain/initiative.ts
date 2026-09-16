import type { PublicInitiativeEvent, QualificationBadge } from './models'

/**
 * 活动级状态文案（#628）：`cancelled`（中止）与 `closed`（收尾）必须分叉——
 * 中止 = 已作废 + 报名全额退，收尾 = 正常结束留档。两者都可直达（slug 是投放
 * 契约），文案是唯一的语义出口；判据下沉 domain（页面无渲染测试面）。
 */
export function initiativeStatusText(status: string): string {
  switch (status) {
    case 'closed': return '已结束 · 活动留档'
    case 'cancelled': return '已取消 · 活动中止'
    default: return '进行中'
  }
}

/** 发现页卡片的状态短文案（同一次分叉，与 web `initiative-index` 同口径）。 */
export function initiativeCardStatusText(status: string): string {
  switch (status) {
    case 'closed': return '已结束'
    case 'cancelled': return '已取消'
    default: return '进行中'
  }
}

/** 中止说明行：仅 `cancelled` 渲染（closed 留档无此行）。 */
export function initiativeCancelledNotice(status: string): string | null {
  return status === 'cancelled' ? '活动已中止：相关场次已取消，已付报名全额退款。' : null
}

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
