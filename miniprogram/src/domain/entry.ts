/**
 * 入口决策的落地（plan 011 深链；#check 审查缺口修复）。
 *
 * `resolveEntry` 只算「该不该跳」；本模块负责「按决策调 Taro」——把它从
 * `app.tsx` 抽出来（而非在 .tsx 里就地写）是为了让接线本身可测：Node 原生
 * test runner（`--experimental-strip-types`）转不了 `.tsx`，测试无法 import
 * `app.tsx`。Taro 作为参数注入，模块自身零 import，测试可直接跑。
 *
 * 冷启动与热启动共用：`useLaunch` 与 `Taro.onAppShow` 拿到的 options 同构。
 */
import { resolveEntry, type AppEntryOptions, type EntryPage } from './share-route.ts'

/** 本模块用到的最小 Taro 面（真实 Taro 是其超集，可结构传入） */
export interface EntryTaro {
  getCurrentPages(): EntryPage[]
  setStorageSync(key: string, value: string): void
  navigateTo(options: { url: string }): unknown
}

/**
 * 落 pendingScene（一次性邀请凭据，join 页初始化消费）+ 按需导航。
 *
 * 页面栈由调用方现取：冷启动时为空（`resolveEntry` 的 `navigate` 抑制
 * 见 `EntryDecision.navigate`），热启动时为栈顶页。
 */
export function applyEntry(
  taro: EntryTaro,
  options: AppEntryOptions,
  pendingSceneKey: string
): void {
  const { scene, url, navigate } = resolveEntry(options, taro.getCurrentPages())
  if (scene) taro.setStorageSync(pendingSceneKey, scene)
  if (url && navigate) taro.navigateTo({ url })
}
