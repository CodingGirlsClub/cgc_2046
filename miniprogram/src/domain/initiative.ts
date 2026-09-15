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
