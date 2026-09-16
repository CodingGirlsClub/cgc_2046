/**
 * 冷/热启动统一路由判定纯函数（plan 011 D-2 热启动 + 冷启动补齐）。
 *
 * 冷启动（`useLaunch`）与热启动（`Taro.onAppShow`）走**同一个判定**：原
 * `useLaunch` 只解 `scene`，`id`/`slug` 深链冷启动被静默丢弃——而站外投放的
 * scheme / 小程序码正是冷启动为主（热启动见 spike §3.2 F05）。
 *
 * 优先级：scene 优先（join 邀请链路独占，与 pendingScene 互斥）；query 含 id
 * 才跳 event-detail，且当前不在**同一个** event-detail（同 id 不打断已在看的
 * 详情；不同 id 是换了一张分享卡片，必须打开目标）；否则 slug 跳
 * initiative-detail。kind 缺省/非法值回落 event——与 event-detail 页面的三态
 * 回落一致。
 */

export interface AppShowQuery {
  scene?: string
  id?: string
  kind?: string
  slug?: string
}

/** join 页邀请链接 path（#415 分享出口；scene 必须 encodeURIComponent） */
export function buildJoinSharePath(scene: string): string {
  return `/pages/join/index?scene=${encodeURIComponent(scene)}`
}

export function buildInitiativeSharePath(slug: string): string {
  return `/pages/initiative-detail/index?slug=${encodeURIComponent(slug)}`
}

/** query + 当前栈顶页面 route → 跳转 url；null = 不跳 */
export function resolveAppShowRoute(query: AppShowQuery, currentRoute: string, currentQuery: AppShowQuery = {}): string | null {
  const scene = query.scene?.trim()
  if (scene) return buildJoinSharePath(scene)

  const id = query.id?.trim()
  if (id) {
    // 同 id 才 no-op（不打断当前详情）；不同 id 是「换一张分享卡片」，
    // 必须打开目标——与下方 slug 分支同款按值比较
    if (currentRoute.includes('pages/event-detail') && currentQuery.id?.trim() === id) return null
    const kind = query.kind === 'course' ? 'course' : 'event'
    return `/pages/event-detail/index?id=${encodeURIComponent(id)}&kind=${kind}`
  }

  const slug = query.slug?.trim()
  if (!slug) return null
  if (currentRoute.includes('pages/initiative-detail') && currentQuery.slug === slug) return null
  return buildInitiativeSharePath(slug)
}

/** 栈顶页面的最小形状（Taro.getCurrentPages 元素；route 在极早启动时可能缺失） */
export interface EntryPage {
  route?: string
  options?: AppShowQuery
}

/** 启动 / 前后台切换回调参数的最小形状（useLaunch 与 Taro.onAppShow 同构） */
export interface AppEntryOptions {
  query?: AppShowQuery
  /** 入口页面路径：冷启动时即用户已落在的页面（Taro navigateTo 只接受相对路径，故不参与导航） */
  path?: string
}

export interface EntryDecision {
  /** 需落 pendingScene 的一次性邀请凭据（无则 null） */
  scene: string | null
  /** 需 navigateTo 的目标（无需导航则 null） */
  url: string | null
  /**
   * 是否真的执行 navigateTo。
   *
   * 冷启动时 `getCurrentPages()` 为空——`resolveAppShowRoute` 的「已在目标页不跳」
   * 守卫拿不到栈，会算出用户**当前就在**的详情页（分享卡片/小程序码的 path 本身
   * 就是详情页），于是 navigateTo 叠一层重复页（返回要按两次 + 详情重复取数）。
   * 入口 path/query 是冷启动唯一的「我已在哪」信号，据此抑制；`scene` 链路不做
   * 抑制（pendingScene 必须落盘，且 join 页消费语义未变）。
   */
  navigate: boolean
}

/** 路径比较用的规范化：去掉前导斜杠（Taro 的 options.path 不带，navigateTo 的 url 带） */
function normalizePath(path: string): string {
  return path.replace(/^\/+/, '')
}

/** 栈顶页是否就是入口本身（冷启动信号：pages 为空，只能看 options.path） */
function entryIsTarget(options: AppEntryOptions, url: string | null): boolean {
  if (!url || !options.path) return false
  const [path, search = ''] = url.split('?')
  if (normalizePath(options.path) !== normalizePath(path)) return false

  const params = new URLSearchParams(search)
  const query = options.query ?? {}
  const id = params.get('id')
  if (id !== null) return id === (query.id?.trim() ?? '')
  return params.get('slug') === (query.slug?.trim() ?? '')
}

/**
 * 冷启动 + 热启动共用的入口决策（app.tsx 唯一调用点，副作用留给调用方）。
 *
 * 路由单源在 `resolveAppShowRoute`；本函数补三件该纯函数之外的事：
 * 1. 从 query 抽出待落盘的 `scene`（join 页初始化消费，一次性凭据语义不变）；
 * 2. 页面栈为空（冷启动入口）时 `currentRoute` 取空串——「已在目标页不跳」的
 *    守卫因而不会误拦首次导航；
 * 3. 冷启动 `navigate` 抑制（见 `EntryDecision.navigate`）。
 */
export function resolveEntry(options: AppEntryOptions, pages: EntryPage[] = []): EntryDecision {
  const query = options?.query ?? {}
  const top = pages[pages.length - 1]
  const url = resolveAppShowRoute(query, top?.route ?? '', top?.options ?? {})
  return {
    scene: query.scene?.trim() || null,
    url,
    navigate: url !== null && !entryIsTarget(options, url)
  }
}
