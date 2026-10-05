import type { NotificationItem } from './models'
import { pageRegistered, type RoutePlatform } from './platform-pages.ts'
import { isTabPath, tabPathsForPlatform } from './tab-routes.ts'

export const NOTIFICATION_PAGE_SIZE = 20
export function retainedNotifications(items: NotificationItem[], now = Date.now()): NotificationItem[] {
  const cutoff = now - 30 * 86_400_000
  return items.filter(item => Number.isFinite(Date.parse(item.createdAt)) && Date.parse(item.createdAt) > cutoff)
}

export function validNotification(value: unknown): value is NotificationItem {
  if (!value || typeof value !== 'object') return false
  const row = value as Record<string, unknown>
  return ['id', 'type', 'title', 'body', 'createdAt'].every(key => typeof row[key] === 'string') &&
    Number.isFinite(Date.parse(row.createdAt as string)) &&
    (row.readAt === null || (typeof row.readAt === 'string' && Number.isFinite(Date.parse(row.readAt)))) &&
    (row.deepLink === null || typeof row.deepLink === 'string')
}

export function mergeNotifications(current: NotificationItem[], incoming: NotificationItem[]): NotificationItem[] {
  const rows = new Map(current.map(item => [item.id, item]))
  for (const item of incoming) {
    const previous = rows.get(item.id)
    rows.set(item.id, { ...item, readAt: previous?.createdAt === item.createdAt ? previous.readAt ?? item.readAt : item.readAt })
  }
  return [...rows.values()]
}

export function notificationRoute(raw: string | null, platform: RoutePlatform): { method: 'switchTab' | 'navigateTo'; url: string } | null {
  if (!raw || !pageRegistered(raw, platform)) return null
  const listRoutes: Record<string, true> = { '/pages/my-enrollments/index': true, '/pages/workspace/index': true }
  if (listRoutes[raw]) return { method: isTabPath(raw, tabPathsForPlatform(platform)) ? 'switchTab' : 'navigateTo', url: raw }
  const match = /^\/pages\/(event-detail|flashback-wishes)\/index\?(id|wishId)=([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$/i.exec(raw)
  if (!match || (match[1] === 'event-detail' ? match[2] !== 'id' : match[2] !== 'wishId')) return null
  return { method: 'navigateTo', url: raw }
}
