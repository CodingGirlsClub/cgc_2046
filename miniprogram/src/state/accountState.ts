import Taro from '@tarojs/taro'
import type { NotificationItem } from '@/domain/models'
import { STORAGE_KEYS } from '@/state/storage'
import { retainedNotifications, validNotification } from '@/domain/notifications'
import { isAccountWipeKey } from '@/domain/account'

const ACTIVE_USER_KEY = 'cgc.active_user_id'
const LEGACY_NOTIFICATION_KEY = 'cgc.local_notifications'
let accountEpoch = 0

export interface AccountScope { userId: string; epoch: number }

export function captureAccountScope(): AccountScope | null {
  const userId = getActiveAccountId()
  return userId ? { userId, epoch: accountEpoch } : null
}

export function accountScopeCurrent(scope: AccountScope): boolean {
  return scope.epoch === accountEpoch && scope.userId === getActiveAccountId()
}

function feedKey(userId: string): string { return `cgc.notification_feed.v1.${userId}` }

export function cacheNotificationFeed(scope: AccountScope, items: NotificationItem[]): void {
  if (!accountScopeCurrent(scope)) return
  const safe = items.slice(0, 20).map(({ id, type, title, body, createdAt, readAt, deepLink }) =>
    ({ id, type, title, body, createdAt, readAt, deepLink }))
  Taro.setStorageSync(feedKey(scope.userId), { items: safe, fetchedAt: new Date().toISOString() })
}

export function cachedNotificationFeed(scope: AccountScope): NotificationItem[] | null {
  if (!accountScopeCurrent(scope)) return null
  const value = Taro.getStorageSync<{ items?: unknown; fetchedAt?: unknown }>(feedKey(scope.userId))
  if (!value) return null
  if (!Array.isArray(value.items) || !value.items.every(validNotification) ||
      typeof value.fetchedAt !== 'string' || !Number.isFinite(Date.parse(value.fetchedAt))) {
    Taro.removeStorageSync(feedKey(scope.userId))
    return null
  }
  return retainedNotifications(value.items)
}

function notificationKey(userId: string): string {
  return `cgc.local_notifications.${userId}`
}

export function getActiveAccountId(): string | null {
  return Taro.getStorageSync<string>(ACTIVE_USER_KEY) || null
}

export function activateAccount(userId: string): void {
  const previous = getActiveAccountId()
  if (previous !== userId) accountEpoch += 1
  Taro.removeStorageSync(notificationKey(userId))
  if (previous && previous !== userId) {
    Taro.removeStorageSync(STORAGE_KEYS.lastEnrollment)
  }
  // 旧全局通知 key 只删除、永不读取；不碰另一账号的 namespaced 通知与 pending scene
  Taro.removeStorageSync(LEGACY_NOTIFICATION_KEY)
  Taro.setStorageSync(ACTIVE_USER_KEY, userId)
}

export function clearAccountState(options?: { clearPendingScene?: boolean }): void {
  accountEpoch += 1
  const activeId = getActiveAccountId()
  if (activeId) Taro.removeStorageSync(notificationKey(activeId))
  if (activeId) Taro.removeStorageSync(feedKey(activeId))
  Taro.removeStorageSync(ACTIVE_USER_KEY)
  Taro.removeStorageSync(LEGACY_NOTIFICATION_KEY)
  Taro.removeStorageSync(STORAGE_KEYS.lastEnrollment)
  if (options?.clearPendingScene) Taro.removeStorageSync(STORAGE_KEYS.pendingScene)
}

/**
 * 主动退出时作废本机持有的闪念间链接身份（STORAGE_KEYS.flashbackToken）。
 * web 端同语义载体是 sessionStorage（关页即失）；小程序 storage 永久，不清的话
 * 共用设备上下一个登录者可经 claim=1 认领上一位的卡。
 * 只在主动退出时调用——会话过期不清：认领流程依赖「过期 → 登录 → claim=1 回跳续跑」。
 */
export function clearFlashbackLinkIdentity(): void {
  Taro.removeStorageSync(STORAGE_KEYS.flashbackToken)
}

/**
 * 主动退出时一并清掉「户主侧」账号持久键（#1079 账号切换隔离）：
 * 愿望草稿（按 owner 前缀）与闪念间入口意图 / 访客圈选残留不再落到下一账号。
 * 判据单源 `domain/account.ts`；登录事务的 `clearAccountState` 不变（登录成功后
 * 由真实 Session 水合，无需抢跑）。仅在主动退出面调用（api.signOut 唯一入口）。
 */
export function wipeAccountLocal(): void {
  try {
    const info = Taro.getStorageInfoSync()
    for (const key of info.keys) {
      if (isAccountWipeKey(key)) Taro.removeStorageSync(key)
    }
  } catch {
    /* 不支持 getStorageInfoSync 的环境就不会退出：本函数在最坏情况下失败只影响
       本机草稿清除（账号隔离仍由 token 无效决定，服务端权威） */
  }
}


export function takePendingScene(routeScene?: string): string {
  const scene = routeScene ?? Taro.getStorageSync<string>(STORAGE_KEYS.pendingScene) ?? ''
  Taro.removeStorageSync(STORAGE_KEYS.pendingScene)
  return scene
}
