import type { CatalogItem, EnrollmentBadge, EnrollmentStatus } from './models'

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
 * venue JsonString → 展示文本（KTD5/R3）。解析遵循严格四键形状（与 backend
 * Venue.valid?/1 同构）：对象恰有 country/province/city/district 四键且值均为
 * string 才算解析成功；缺键/多键/非字符串值/JSON.parse 失败/输入非 string
 * 一律 null（展示层兜底「地点待定」，同 web parseVenue 解析失败按 nil 的
 * 容错纪律：展示层不假定结构，不报错不出空白）。四键全空串同样 null。
 */
function parseVenue(raw: string | null): { country: string; province: string; city: string; district: string } | null {
  if (typeof raw !== 'string') return null
  try {
    const parsed: unknown = JSON.parse(raw)
    if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) return null
    const venue = parsed as Record<string, unknown>
    if (Object.keys(venue).length !== 4) return null
    if (
      typeof venue.country !== 'string' ||
      typeof venue.province !== 'string' ||
      typeof venue.city !== 'string' ||
      typeof venue.district !== 'string'
    ) {
      return null
    }
    return { country: venue.country, province: venue.province, city: venue.city, district: venue.district }
  } catch {
    return null
  }
}

/** venue → 单行展示（空段跳过；解析失败/全空 → null，展示层兜底「地点待定」，R3） */
export function venueText(raw: string | null): string | null {
  const venue = parseVenue(raw)
  if (!venue) return null
  const parts = [venue.country, venue.province, venue.city, venue.district].filter((s) => s.trim() !== '')
  return parts.length > 0 ? parts.join(' ') : null
}
