import Taro from '@tarojs/taro'

/**
 * 闪念间入口 intent（长廊是 tabBar 页面后 `switchTab` 不能带 query，
 * `?welcome=1` / `?future=1` 两个入口语义改由此单次传递）。
 *
 * 消费即清（`consumeFlashbackEntry` 读到后立刻移出 storage）：
 * - 用户切 Tab 离开再回来，不会重复触发（快门不再弹、滚动不再跳）
 * - 冷启动/深链无 intent 时行为与「无参数」一致（默认弹快门 / 不滚未来段）
 *
 * `welcome`：首程刚结束落地长廊——抑制快门仪式 + 推一次金句授权引导。
 * `future`：从场次页「看看未来」回长廊——数据就绪后滚到未来段。
 */
export type FlashbackEntryIntent = 'welcome' | 'future'

const KEY = 'cgc.flashback_entry_intent'

export function setFlashbackEntry(intent: FlashbackEntryIntent): void {
  Taro.setStorageSync(KEY, intent)
}

/** 读后即清（一次性）；无 intent 或值非法（storage 被外部污染）返回 null */
export function consumeFlashbackEntry(): FlashbackEntryIntent | null {
  const value = Taro.getStorageSync<FlashbackEntryIntent>(KEY)
  if (!value) return null
  Taro.removeStorageSync(KEY)
  return value === 'welcome' || value === 'future' ? value : null
}
