import type { CatalogItem, EnrollmentBadge, EnrollmentStatus, SchemaField } from './models'

const labels: Record<string, string> = {
  audience: '适合人群',
  duration: '时长',
  sections: '内容安排',
  location: '地点',
  tutor: 'Tutor',
  format: '形式',
  materials: '材料'
}

function printable(value: unknown): string {
  if (Array.isArray(value)) return value.map(printable).join('、')
  if (value && typeof value === 'object') {
    return Object.entries(value)
      .map(([key, nested]) => `${labels[key] ?? key}：${printable(nested)}`)
      .join('；')
  }
  return String(value ?? '—')
}

export function schemaFieldsFromJson(raw: string | null): SchemaField[] {
  if (!raw) return []
  try {
    const parsed = JSON.parse(raw) as unknown
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return []
    return Object.entries(parsed).map(([key, value]) => ({
      key,
      label: labels[key] ?? key,
      value: printable(value)
    }))
  } catch {
    return [{ key: 'details', label: '详情', value: raw }]
  }
}

export function remainingLabel(deadline: string | null, now = Date.now()): string {
  if (!deadline) return '未设置截止时间'
  const remaining = new Date(deadline).getTime() - now
  if (remaining <= 0) return '已到期'
  const hours = Math.floor(remaining / 3_600_000)
  const minutes = Math.floor((remaining % 3_600_000) / 60_000)
  return `${hours} 小时 ${minutes} 分钟`
}

export function isUrgent(deadline: string | null, now = Date.now()): boolean {
  if (!deadline) return false
  const remaining = new Date(deadline).getTime() - now
  return remaining > 0 && remaining <= 24 * 3_600_000
}

export function canManageMembers(abilities: string[]): boolean {
  return abilities.includes('manage_members')
}

export function parseEnrollmentPolicy(value: string): CatalogItem['enrollmentPolicy'] {
  if (value === 'open' || value === 'request' || value === 'invite_only') return value
  throw new Error(`服务端返回未知报名策略：${value}`)
}

export function parseEnrollmentStatus(value: string): EnrollmentStatus {
  if (value === 'pending' || value === 'payment_pending' || value === 'confirmed' || value === 'rejected' || value === 'expired' || value === 'cancelled') return value
  throw new Error(`服务端返回未知报名状态：${value}`)
}

export function parseEnrollmentBadge(value: string | null): EnrollmentBadge {
  if (value === 'enrolling' || value === 'starting_soon' || value === 'full') return value
  throw new Error(`服务端返回未知报名标签：${value}`)
}

/** badge 展示文案（KTD1；公开面以派生标签替代原始名额计数） */
export const enrollmentBadgeText: Record<EnrollmentBadge, string> = {
  enrolling: '报名中',
  starting_soon: '即将开始',
  full: '已满'
}

// 与详情页既有截止日期同款 toLocaleString 惯例（R15 随行展示不引新格式）
export function formatDateTime(iso: string): string {
  return new Date(iso).toLocaleString()
}

/** 时间行展示（R3）：双全为区间，单值带方向，全空兜底「时间待定」 */
export function scheduleText(startsAt: string | null, endsAt: string | null): string {
  if (startsAt && endsAt) return `${formatDateTime(startsAt)} - ${formatDateTime(endsAt)}`
  if (startsAt) return `${formatDateTime(startsAt)} 开始`
  if (endsAt) return `${formatDateTime(endsAt)} 结束`
  return '时间待定'
}

/**
 * venue JsonString → 展示文本（country/province/city/district 四键非空拼接，KTD5）。
 * 解析失败/结构非法/全空 → null（展示层兜底「地点待定」，同 parseSponsorshipTiers
 * 静默丢弃纪律：展示层不假定结构，不报错不出空白）。
 */
export function venueText(raw: string | null): string | null {
  if (!raw) return null
  try {
    const parsed = JSON.parse(raw) as unknown
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return null
    const venue = parsed as Record<string, unknown>
    const parts = ['country', 'province', 'city', 'district']
      .map((key) => venue[key])
      .filter((value): value is string => typeof value === 'string' && value.trim().length > 0)
    return parts.length > 0 ? parts.join(' ') : null
  } catch {
    return null
  }
}
