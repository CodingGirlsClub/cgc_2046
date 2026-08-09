import Taro from '@tarojs/taro'
import type { NotificationItem } from '@/domain/models'
import { STORAGE_KEYS } from '@/state/storage'

const ACTIVE_USER_KEY = 'cgc.active_user_id'
const LEGACY_NOTIFICATION_KEY = 'cgc.local_notifications'
const MAX_NOTIFICATIONS = 50

function notificationKey(userId: string): string {
  return `cgc.local_notifications.${userId}`
}

export function getActiveAccountId(): string | null {
  return Taro.getStorageSync<string>(ACTIVE_USER_KEY) || null
}

export function activateAccount(userId: string): void {
  const previous = getActiveAccountId()
  if (previous && previous !== userId) {
    Taro.removeStorageSync(STORAGE_KEYS.lastEnrollment)
  }
  // 旧全局通知 key 只删除、永不读取；不碰另一账号的 namespaced 通知与 pending scene
  Taro.removeStorageSync(LEGACY_NOTIFICATION_KEY)
  Taro.setStorageSync(ACTIVE_USER_KEY, userId)
}

export function clearAccountState(options?: { clearPendingScene?: boolean }): void {
  const activeId = getActiveAccountId()
  if (activeId) Taro.removeStorageSync(notificationKey(activeId))
  Taro.removeStorageSync(ACTIVE_USER_KEY)
  Taro.removeStorageSync(LEGACY_NOTIFICATION_KEY)
  Taro.removeStorageSync(STORAGE_KEYS.lastEnrollment)
  if (options?.clearPendingScene) Taro.removeStorageSync(STORAGE_KEYS.pendingScene)
}

export function appendLocalNotification(title: string, body: string): void {
  const activeId = getActiveAccountId()
  if (!activeId) return
  const notifications = readLocalNotifications()
  notifications.unshift({
    id: `${Date.now()}`,
    title,
    body,
    createdAt: new Date().toISOString(),
    read: false
  })
  Taro.setStorageSync(notificationKey(activeId), notifications.slice(0, MAX_NOTIFICATIONS))
}

export function readLocalNotifications(): NotificationItem[] {
  const activeId = getActiveAccountId()
  if (!activeId) return []
  return Taro.getStorageSync<NotificationItem[]>(notificationKey(activeId)) || []
}

export function takePendingScene(routeScene?: string): string {
  const scene = routeScene ?? Taro.getStorageSync<string>(STORAGE_KEYS.pendingScene) ?? ''
  Taro.removeStorageSync(STORAGE_KEYS.pendingScene)
  return scene
}
