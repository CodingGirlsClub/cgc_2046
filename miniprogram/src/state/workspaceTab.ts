import Taro from '@tarojs/taro'
import type { WorkspaceSummary } from '@/domain/models'

const KEY = 'cgc.workspace_tab_visible'
const EVENT = 'cgc.workspace_tab_changed'

export function rememberWorkspaceTab(workspaces: WorkspaceSummary[]): void {
  const next = workspaces.length > 0
  if (hasWorkspaceTab() === next) return
  Taro.setStorageSync(KEY, next)
  Taro.eventCenter.trigger(EVENT, next)
}

export function clearWorkspaceTab(): void {
  if (!hasWorkspaceTab()) return
  Taro.removeStorageSync(KEY)
  Taro.eventCenter.trigger(EVENT, false)
}

export function hasWorkspaceTab(): boolean {
  return Taro.getStorageSync<boolean>(KEY) || false
}

export function subscribeWorkspaceTab(listener: (visible: boolean) => void): () => void {
  Taro.eventCenter.on(EVENT, listener)
  return () => Taro.eventCenter.off(EVENT, listener)
}
