import type { CatalogItem, EnrollmentStatus, SchemaField } from './models'

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
  if (value === 'pending' || value === 'confirmed' || value === 'rejected' || value === 'expired' || value === 'cancelled') return value
  throw new Error(`服务端返回未知报名状态：${value}`)
}
