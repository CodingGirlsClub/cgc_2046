/**
 * 冷/热启动统一路由判定纯函数（plan 011 D-2 热启动 + 冷启动补齐）。
 *
 * 冷启动（`useLaunch`）与热启动（`Taro.onAppShow`）走**同一个判定**：原
 * `useLaunch` 只解 `scene`，`id`/`slug` 深链冷启动被静默丢弃——而站外投放的
 * scheme / 小程序码正是冷启动为主（热启动见 spike §3.2 F05）。
 *
 * 优先级：shareId 最先（公开卡链接，#771——出现即意图唯一，先判才不会被转发链
 * 里的本人面参数劫持）；scene 次之（join 邀请链路独占，与 pendingScene 互斥）；
 * query 含 id 才跳 event-detail，且当前不在**同一个** event-detail（同 id 不打断
 * 已在看的详情；不同 id 是换了一张分享卡片，必须打开目标）；否则 slug 跳
 * initiative-detail。kind 缺省/非法值回落 event——与 event-detail 页面的三态
 * 回落一致。
 *
 * P0-4：目标按平台过滤（`platformFallbackRoute`）——未注册页面一律稳态回落，
 * 名单单源 `domain/platform-pages.ts`。
 */
import { pageRegistered, type RoutePlatform } from './platform-pages.ts'

export type { RoutePlatform }

export interface AppShowQuery {
  quoteId?: string
  city?: string
  scene?: string
  id?: string
  kind?: string
  slug?: string
  /** 首程链接身份（KTD2）：只用于路由到旅程页，页面读入后落 storage */
  token?: string
  /**
   * 卡片站外公开标识（#771）：分享给朋友的链接带它，落公开卡页。
   * **公开面唯一合法参数**——分享路径不带 token/slug（参数会留在转发链里）。
   */
  shareId?: string
  /** 公开许愿树深链：直接读取该愿望，不依赖长廊或分页。 */
  wishId?: string
}

/** 公开金句墙：可选 quoteId 定位到单句。 */
export const FLASHBACK_VOICES_ROUTE = 'pages/flashback-voices/index'

/** 公开卡页 path（分享卡片 path 单源；#771）——无前导斜杠形态供路由比较 */
export const FLASHBACK_SHARED_CARD_ROUTE = 'pages/flashback-shared-card/index'

/** 公开卡分享链接（#771）：只带 shareId——token/slug/scene 都是本人面/邀请面
 *  参数，进了转发链就等于泄漏入口，故一律不拼。 */
export function buildFlashbackCardSharePath(shareId: string): string {
  return `/${FLASHBACK_SHARED_CARD_ROUTE}?shareId=${encodeURIComponent(shareId)}`
}

/**
 * 转发分享卡片的 imageUrl（#771）：品牌火苗，**不是**本人卡截图。
 *
 * 常量是打包产物里的代码包路径字面量（Taro 对
 * `import flame from '@/assets/brand/cgc-flame.png'` 的产物即
 * `publicPath("/") + "assets/brand/cgc-flame.png"`，见 dist/weapp/common.js）。
 * 之所以用字面量而非 import：本模块被 `node --experimental-strip-types` 直接
 * 加载（tests/share-route.test.ts），该 runner 转不了 .png——import 会让路由
 * 纯函数的测试整体挂掉。图片资产仍由 pages/discover、pages/login 的 import
 * 保证进入每个端产物。
 */
export const FLASHBACK_CARD_SHARE_IMAGE = '/assets/brand/cgc-flame.png'

/** 闪念间入口页（批次二：旅程/长廊/场次）——分享卡片 path 与专属深链的落地面。
 * 这些页无 id/slug 定位参数，「已在目标页」判定退化为 path 相等（entryIsTarget）。 */
export const FLASHBACK_ENTRY_ROUTES = [
  FLASHBACK_VOICES_ROUTE,
  'pages/flashback-wishes/index',
  'pages/flashback-journey/index',
  'pages/flashback-corridor/index',
  'pages/flashback-event/index'
] as const

/**
 * 闪念间入口 path（分享卡片 path 与公开卡「找回」单源，#929）：落闪念间 Tab（长廊）——
 * 未登录看公开首页，有档案进自己的长廊。token 是链接身份，分享卡片不带（R32）；
 * 不带 token 的首程页只留给真正失效的链接——转发落在那里，新人会先看到「没有找到这张邀请函」。
 * Tab 页：页内跳转用 switchTab（applyEntry 冷热启动同理）。
 */
export function buildFlashbackEntryPath(): string {
  return '/pages/flashback-corridor/index'
}

/** join 页邀请链接 path（#415 分享出口；scene 必须 encodeURIComponent） */
export function buildJoinSharePath(scene: string): string {
  return `/pages/join/index?scene=${encodeURIComponent(scene)}`
}

export function buildInitiativeSharePath(slug: string): string {
  return `/pages/initiative-detail/index?slug=${encodeURIComponent(slug)}`
}

/**
 * 深链按平台过滤（P0-4）：目标 url 必须是本端已注册页面（名单单源
 * `domain/platform-pages.ts`），否则稳态回落——闪念间族 → 薄壳页
 * `pages/flashback/index`；其余 → 发现页。回落目标即当前页时返回 null
 * （防重复叠壳）。weapp（缺省）直通不过滤。
 */
export function platformFallbackRoute(url: string | null, platform: RoutePlatform, currentRoute: string): string | null {
  if (!url || platform === 'wechat') return url
  const path = normalizePath(url.split('?')[0])
  if (pageRegistered(path, platform)) return url
  const fallback = path.startsWith('pages/flashback') ? 'pages/flashback/index' : 'pages/discover/index'
  if (fallback === normalizePath(currentRoute)) return null
  return `/${fallback}`
}

/** query + 当前栈顶页面 route → 跳转 url；null = 不跳 */
export function resolveAppShowRoute(
  query: AppShowQuery,
  currentRoute: string,
  currentQuery: AppShowQuery = {},
  platform: RoutePlatform = 'wechat'
): string | null {
  return platformFallbackRoute(innerAppShowRoute(query, currentRoute, currentQuery), platform, currentRoute)
}

function innerAppShowRoute(query: AppShowQuery, currentRoute: string, currentQuery: AppShowQuery = {}): string | null {
  // 公开卡（#771）**最先判**，先于 scene/id/slug/token：shareId 只出现在公开卡
  // 分享链接里，出现即意图唯一。反过来（让 scene/id/slug 先判）会把一条夹带了
  // 本人面参数的转发链接劫持成旅程页/详情页——「朋友点开看到我的卡」当场失效。
  const shareId = query.shareId?.trim()
  if (shareId) {
    // 同 id 不打断已在看的那张卡；换一张（不同 id）必须打开目标（与 id/slug 同款
    // 按值比较）。路径按**精确相等**判定（Taro 的 route 不带 query）——公开卡页
    // 之外的任何 route 都不算「已在目标页」。
    if (
      normalizePath(currentRoute) === FLASHBACK_SHARED_CARD_ROUTE &&
      currentQuery.shareId?.trim() === shareId
    ) {
      return null
    }
    return buildFlashbackCardSharePath(shareId)
  }

  const quoteId = query.quoteId?.trim()
  if (quoteId) {
    if (normalizePath(currentRoute) === FLASHBACK_VOICES_ROUTE && currentQuery.quoteId?.trim() === quoteId) return null
    return `/${FLASHBACK_VOICES_ROUTE}?quoteId=${encodeURIComponent(quoteId)}`
  }

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
  if (slug) {
    // 与 id 分支同款：两侧都 trim 后再比。只 trim 入参会让「当前页 slug 带首尾
    // 空白」（冷启动 ?slug=%20abc%20 的残留）与干净入参不相等，误判成换目标而
    // 叠一层重复页。
    if (currentRoute.includes('pages/initiative-detail') && currentQuery.slug?.trim() === slug) return null
    return buildInitiativeSharePath(slug)
  }

  // Single-wish shares resolve independently of list pagination and archive access.
  const wishId = query.wishId?.trim()
  if (wishId) {
    if (normalizePath(currentRoute) === 'pages/flashback-wishes/index' && currentQuery.wishId?.trim() === wishId) return null
    return `/pages/flashback-wishes/index?wishId=${encodeURIComponent(wishId)}`
  }
  // 首程专属深链（管理员定向发的链接/卡片带 token；R1）：token 只用于路由，
  // 不做值比较的「已在目标页」判定（KTD2：token 不是路由键）
  const token = query.token?.trim()
  if (token) {
    if (currentRoute.includes('pages/flashback-journey') && currentQuery.token?.trim() === token) return null
    return `/pages/flashback-journey/index?token=${encodeURIComponent(token)}`
  }
  return null
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
  const quoteId = params.get('quoteId')
  if (quoteId !== null) return quoteId === (query.quoteId?.trim() ?? '')
  const id = params.get('id')
  if (id !== null) return id === (query.id?.trim() ?? '')
  const slug = params.get('slug')
  if (slug !== null) return slug === (query.slug?.trim() ?? '')
  // 公开卡（#771）：shareId 是定位参数（决定看哪张卡），必须按值比较——
  // 否则「从 A 的卡跳到 B 的卡」在冷启动入口被误判成「已在目标页」而静默不跳。
  const shareId = params.get('shareId')
  if (shareId !== null) return shareId === (query.shareId?.trim() ?? '')
  // 无定位参数：闪念间入口页（旅程/长廊/场次）与裁剪端薄壳页（P0-4 回落目标，
  // 同样是无定位参数的入口面）path 相同即目标——token 等参数属链接身份，不做值
  // 比较（KTD2）。join（scene 链路）保持不抑制：pendingScene 必须落盘且 join 页
  // 消费语义未变。
  const noIdEntryRoutes: readonly string[] = [...FLASHBACK_ENTRY_ROUTES, 'pages/flashback/index']
  return noIdEntryRoutes.includes(normalizePath(path))
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
export function resolveEntry(
  options: AppEntryOptions,
  pages: EntryPage[] = [],
  platform: RoutePlatform = 'wechat'
): EntryDecision {
  const query = options?.query ?? {}
  const top = pages[pages.length - 1]
  const path = normalizePath(options.path ?? '')
  const collectionKey = path === FLASHBACK_VOICES_ROUTE ? 'quoteId' :
    path === 'pages/flashback-wishes/index' ? 'wishId' : null
  // Whole-collection shares must not inherit a previous item or city landing.
  const resetCollection = collectionKey !== null && normalizePath(top?.route ?? '') === path &&
    !query[collectionKey]?.trim() && !query.city?.trim() &&
    !!(top?.options?.[collectionKey]?.trim() || top?.options?.city?.trim())
  const rawUrl = resetCollection ? `/${path}` :
    innerAppShowRoute(query, top?.route ?? '', top?.options ?? {}) ??
    flashbackEntryUrl(options, top?.route ?? '')
  const url = platformFallbackRoute(rawUrl, platform, top?.route ?? '')
  return {
    scene: query.scene?.trim() || null,
    url,
    // Only an empty stack uses the launch path as evidence of the current page.
    // Warm entries carry path too; the actual stack above decides whether to open.
    navigate: url !== null && !(pages.length === 0 && entryIsTarget(options, url))
  }
}

/** 入口 path 是闪念间页 → 目标 url（原样带 query 参数）；否则 null。
 *  公开卡（#771）不在此列：它由 `resolveAppShowRoute` 的 shareId 分支处理，
 *  且 shareId 是定位参数（需按值比较），混进本兜底会绕过该判定。 */
function flashbackEntryUrl(options: AppEntryOptions, currentRoute: string): string | null {
  const entry = normalizePath(options?.path ?? '')
  if (!(FLASHBACK_ENTRY_ROUTES as readonly string[]).includes(entry)) return null
  if (normalizePath(currentRoute) === entry) return null
  const query = options?.query ?? {}
  const search = new URLSearchParams(
    Object.entries(query).flatMap(([key, value]) =>
      typeof value === 'string' && value ? [[key, value] as [string, string]] : []
    )
  ).toString()
  return `/${entry}${search ? `?${search}` : ''}`
}
