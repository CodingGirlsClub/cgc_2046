/**
 * 入口决策的落地（plan 011 深链；#check 审查缺口修复）。
 *
 * `resolveEntry` 只算「该不该跳」；本模块负责「按决策调 Taro」——把它从
 * `.tsx` 里抽出来（而非就地写）是为了让接线本身可测：Node 原生
 * test runner（`--experimental-strip-types`）转不了 `.tsx`，测试无法 import
 * `app.tsx`。Taro 作为参数注入，模块只 import 纯数据（tab-routes），测试可直接跑。
 *
 * 冷启动与热启动共用：`useLaunch` 与 `Taro.onAppShow` 拿到的 options 同构。
 */
import { resolveEntry, type AppEntryOptions, type EntryPage } from './share-route.ts'
import { FULL_TAB_PATHS, isTabPath } from './tab-routes.ts'
/** 本模块用到的最小 Taro 面（真实 Taro 是其超集，可结构传入） */
export interface EntryTaro {
  getCurrentPages(): EntryPage[]
  setStorageSync(key: string, value: string): void
  navigateTo(options: { url: string }): unknown
  switchTab(options: { url: string }): unknown
}

/**
 * 落 pendingScene（一次性邀请凭据，join 页初始化消费）+ 按需导航。
 *
 * 页面栈由调用方现取：冷启动时为空（`resolveEntry` 的 `navigate` 抑制
 * 见 `EntryDecision.navigate`），热启动时为栈顶页。
 *
 * wish2 U9（KTD7）：目标是 tabBar 页（如长廊 wishId 深链）时 `navigateTo`
 * 会被微信拒绝（tab 页只能 `switchTab` 且不带 query）——定位参数先落
 * `pendingWishKey`，目标页 `useDidShow` 读后即清（flashbackEntry 同款
 * 一次性语义）。
 */
export function applyEntry(
  taro: EntryTaro,
  options: AppEntryOptions,
  pendingSceneKey: string,
  pendingWishKey?: string
): void {
  const { scene, url, navigate } = resolveEntry(options, taro.getCurrentPages())
  if (scene) taro.setStorageSync(pendingSceneKey, scene)
  if (!(url && navigate)) return
  const [path, search = ''] = url.split('?')
  if (isTabPath(path, FULL_TAB_PATHS)) {
    const wishId = new URLSearchParams(search).get('wishId')
    if (wishId && pendingWishKey) taro.setStorageSync(pendingWishKey, wishId)
    taro.switchTab({ url: path })
  } else {
    taro.navigateTo({ url })
  }
}
