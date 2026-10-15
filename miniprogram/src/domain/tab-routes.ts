/**
 * tabBar 的唯一真源 + 路由分流判断。
 *
 * ## 为什么需要单源
 *
 * tabBar 有三处消费方，各自需要不同形状：
 * 1. `app.config.ts` 的 `tabBar.list`（微信要求 `{ pagePath, text }` 且路径无前导斜杠）；
 * 2. `components/AppTabBar` 的自绘渲染（需要 key/绝对路径；图标按 key 取线性 SVG，见组件样式）；
 * 3. 路由分流（`isTabPath`——判断该用 `switchTab` 还是 `navigateTo`）。
 *
 * 手工维护三份必然漂移，而漂移的后果是**静默失败**：微信 tabBar 页面只能
 * `switchTab` 进入、`switchTab` 不接受 query、`navigateTo`/`redirectTo` 跳它
 * 会直接报错——没有任何编译期检查会拦住「改了 list 忘了改渲染」。
 *
 * ## 形状
 *
 * 微信端 Tab 分三段：头部固定段 + 能力条件段（工作台，有权限才出现）+
 * 尾部固定段。裁剪端（tt/xhs）是独立的 2 项清单——未注册长廊故无闪念间、
 * 未注册「我的」页故我的报名仍是 Tab。
 *
 * 本模块零运行时依赖（可被 node --test 直跑、可被 app.config 安全 import）。
 */

/** 自绘 TabBar 的高亮键（`AppTabBar` 的 `selected` 取值） */
export type TabKey = 'discover' | 'flashback' | 'enrollments' | 'workspace' | 'profile'

export interface TabDef {
  key: TabKey
  text: string
  /** 绝对路径（Taro 导航 API 格式；app.config 侧用 `toTabBarEntry` 去前导斜杠） */
  path: string
}

/** 微信全量端 · 头部固定段 */
export const FULL_HEAD_TABS: readonly TabDef[] = [
  { key: 'discover', text: '发现', path: '/pages/discover/index' },
  { key: 'flashback', text: '闪念间', path: '/pages/flashback-corridor/index' }
]

/** 微信全量端 · 能力条件段（有工作台权限才渲染；在头部与尾部之间） */
export const WORKSPACE_TAB: TabDef = {
  key: 'workspace',
  text: '工作台',
  path: '/pages/workspace/index'
}

/** 微信全量端 · 尾部固定段 */
export const FULL_TAIL_TABS: readonly TabDef[] = [
  { key: 'profile', text: '我的', path: '/pages/profile/index' }
]

/**
 * 抖音端（#1079 #P0）：发现 / 我的——「我的报名」收进「我的」页
 * （pages/profile-lite），与 xhs D2a 同构；我的报名页降级为普通页。
 * 此前是「发现 / 我的报名」2 Tab 漏斗：tt 没有可登录后退出的居所，
 * 退出必须能脱离报名面——本端注册 profile-lite 后同步收敛。
 */
export const TT_TABS: readonly TabDef[] = [
  { key: 'discover', text: '发现', path: '/pages/discover/index' },
  { key: 'profile', text: '我的', path: '/pages/profile-lite/index' }
]

/**
 * 小红书端（P0-5，D2a）：发现 / 我的——「我的报名」收进「我的」页
 * （pages/profile-lite），与微信端同构；我的报名页降级为普通页。
 * P2：闪念间升 Tab（与微信端同构），落长廊。
 */
export const XHS_TABS: readonly TabDef[] = [
  { key: 'discover', text: '发现', path: '/pages/discover/index' },
  { key: 'flashback', text: '闪念间', path: '/pages/flashback-corridor/index' },
  { key: 'profile', text: '我的', path: '/pages/profile-lite/index' }
]

/** 微信全量端清单（含条件段——app.config 必须声明全部可能出现的 Tab） */
export const FULL_TABS: readonly TabDef[] = [...FULL_HEAD_TABS, WORKSPACE_TAB, ...FULL_TAIL_TABS]

/** `app.config.ts` 用：微信要求 tabBar.list 的路径不带前导斜杠 */
export function toTabBarEntry(tab: TabDef): { pagePath: string; text: string } {
  return { pagePath: tab.path.replace(/^\//, ''), text: tab.text }
}

/** 路由分流用：微信端 Tab 路径集合 */
export const FULL_TAB_PATHS: readonly string[] = FULL_TABS.map((tab) => tab.path)

/** 路由分流用：抖音端 Tab 路径集合（#1079：发现 / 我的） */
export const TT_TAB_PATHS: readonly string[] = TT_TABS.map((tab) => tab.path)

/** 路由分流用：小红书端 Tab 路径集合（D2a：发现 / 我的） */
export const XHS_TAB_PATHS: readonly string[] = XHS_TABS.map((tab) => tab.path)

/**
 * 按平台分派 Tab 集合（P0-4）。`(url)` 深链落 Tab 页时用 `switchTab`，
 * 判定必须用**本端** Tab 集合——固定按微信 tabs 会把裁剪端 tab 页
 * （发现/我的报名）误判成普通页 navigateTo（I6）。
 * 返回引用不复制（只读消费）。
 */
export function tabPathsForPlatform(platform: 'wechat' | 'tt' | 'xhs'): readonly string[] {
  if (platform === 'xhs') return XHS_TAB_PATHS
  if (platform === 'wechat') return FULL_TAB_PATHS
  return TT_TAB_PATHS
}

/**
 * 裁剪端加入工作台后的落点（join 页 reLaunch 清栈，落点必须是本端 Tab 页,
 * 否则用户既无 TabBar 也无返回）。裁剪端无工作台：两端我的报名都已收进
 * 「我的」Tab（入口在其中）——落「我的」。
 */
export function cutJoinLanding(_platform: 'tt' | 'xhs'): string {
  return '/pages/profile-lite/index'
}

/** 规范化：去前导斜杠与 query（Taro 的 options.path 无前导斜杠，navigateTo 的 url 带） */
function normalize(path: string): string {
  return path.replace(/^\/+/, '').split('?')[0]
}

/** 目标是否 tabBar 页面——决定用 switchTab（Tab 页唯一合法入口）还是普通导航。
 *  两侧都规范化（调用方 path 可能带/不带前导斜杠，tabPaths 恒带）——只规范
 *  一侧会让带斜杠的调用方永远 false（login returnUrl 回跳 tab 页即此坑）。 */
export function isTabPath(path: string, tabPaths: readonly string[]): boolean {
  const target = normalize(path)
  return tabPaths.some((tab) => normalize(tab) === target)
}
