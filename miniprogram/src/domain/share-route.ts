/**
 * 热启动路由判定纯函数（plan 011 D-2，闭合 spike §3.2 F05 复发面）。
 *
 * scheme/分享链接热启动（小程序已打开再点链接）时 `Taro.onAppShow` 的
 * `event.query` 判定：scene 优先（join 邀请链路独占，与 pendingScene 互斥）；
 * query 含 id 才跳 event-detail，且当前不在 event-detail（不打断已在看的
 * 详情）。kind 缺省/非法值回落 event——与 event-detail 页面的三态回落一致。
 */

export interface AppShowQuery {
  scene?: string
  id?: string
  kind?: string
}

/** query + 当前栈顶页面 route → 跳转 url；null = 不跳 */
export function resolveAppShowRoute(query: AppShowQuery, currentRoute: string): string | null {
  const scene = query.scene?.trim()
  if (scene) return `/pages/join/index?scene=${encodeURIComponent(scene)}`

  const id = query.id?.trim()
  if (!id) return null
  if (currentRoute.includes('pages/event-detail')) return null

  const kind = query.kind === 'course' ? 'course' : 'event'
  return `/pages/event-detail/index?id=${encodeURIComponent(id)}&kind=${kind}`
}
