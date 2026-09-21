/**
 * tabBar 的唯一真源 + 路由分流判断。
 *
 * ## 为什么需要单源
 *
 * tabBar 有三处消费方，各自需要不同形状：
 * 1. `app.config.ts` 的 `tabBar.list`（微信要求 `{ pagePath, text }` 且路径无前导斜杠）；
 * 2. `components/AppTabBar` 的自绘渲染（需要 key/icon/绝对路径）；
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
  /** 自绘 TabBar 的图标（文本符号，对齐项目既有风格） */
  icon: string
  /** 绝对路径（Taro 导航 API 格式；app.config 侧用 `toTabBarEntry` 去前导斜杠） */
  path: string
}

/** 微信全量端 · 头部固定段 */
export const FULL_HEAD_TABS: readonly TabDef[] = [
  { key: 'discover', text: '发现', icon: '⌕', path: '/pages/discover/index' },
  { key: 'flashback', text: '闪念间', icon: '⚡', path: '/pages/flashback-corridor/index' }
]

/** 微信全量端 · 能力条件段（有工作台权限才渲染；在头部与尾部之间） */
export const WORKSPACE_TAB: TabDef = {
  key: 'workspace',
  text: '工作台',
  icon: '◇',
  path: '/pages/workspace/index'
}

/** 微信全量端 · 尾部固定段 */
export const FULL_TAIL_TABS: readonly TabDef[] = [
  { key: 'profile', text: '我的', icon: '○', path: '/pages/profile/index' }
]

/** 裁剪端（抖音/小红书）：2 Tab 漏斗 */
export const CUT_TABS: readonly TabDef[] = [
  { key: 'discover', text: '发现', icon: '⌕', path: '/pages/discover/index' },
  { key: 'enrollments', text: '我的报名', icon: '✓', path: '/pages/my-enrollments/index' }
]

/** 微信全量端清单（含条件段——app.config 必须声明全部可能出现的 Tab） */
export const FULL_TABS: readonly TabDef[] = [...FULL_HEAD_TABS, WORKSPACE_TAB, ...FULL_TAIL_TABS]

/** `app.config.ts` 用：微信要求 tabBar.list 的路径不带前导斜杠 */
export function toTabBarEntry(tab: TabDef): { pagePath: string; text: string } {
  return { pagePath: tab.path.replace(/^\//, ''), text: tab.text }
}

/** 路由分流用：微信端 Tab 路径集合 */
export const FULL_TAB_PATHS: readonly string[] = FULL_TABS.map((tab) => tab.path)

/** 路由分流用：裁剪端 Tab 路径集合 */
export const CUT_TAB_PATHS: readonly string[] = CUT_TABS.map((tab) => tab.path)

/** 规范化：去前导斜杠与 query（Taro 的 options.path 无前导斜杠，navigateTo 的 url 带） */
function normalize(path: string): string {
  return path.replace(/^\/+/, '').split('?')[0]
}

/** 目标是否 tabBar 页面——决定用 switchTab（Tab 页唯一合法入口）还是普通导航 */
export function isTabPath(path: string, tabPaths: readonly string[]): boolean {
  return tabPaths.includes(normalize(path))
}
