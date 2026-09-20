/**
 * tabBar 页面路径单源（app.config.ts tabBar.list / 深链导航 / 登录回跳共用）。
 *
 * 为什么需要单源：微信 tabBar 页面是特殊公民——只能 `switchTab` 进入、
 * `switchTab` 不接受 query 参数、`navigateTo`/`redirectTo` 跳它会直接失败。
 * 需要判断「这是不是 Tab 页」的地方有三处（深链落地 `domain/entry`、登录
 * 回跳 `pages/login`、新增入口），清单各自硬编码必然漂移——表现为线上某条
 * 路径静默失灵，且不会有类型错误兜底。
 *
 * 按端分：裁剪端（tt/xhs）未注册长廊，只有 2 Tab。模块自身零环境依赖，
 * 端清单由调用方传入（同 `domain/entry` 的参数注入模式，可被 node --test 直跑）。
 */

/** 微信全量端（与 app.config.ts fullTabList、components/AppTabBar 三处同步） */
export const FULL_TAB_PATHS: readonly string[] = [
  'pages/discover/index',
  'pages/flashback-corridor/index',
  'pages/workspace/index',
  'pages/profile/index'
]

/** 裁剪端（抖音/小红书）：2 Tab 漏斗，无工作台/长廊 */
export const CUT_TAB_PATHS: readonly string[] = ['pages/discover/index', 'pages/my-enrollments/index']

/** 规范化：去前导斜杠与 query（Taro 的 options.path 无前导斜杠，navigateTo 的 url 带） */
function normalize(path: string): string {
  return path.replace(/^\/+/, '').split('?')[0]
}

/** 目标是否 tabBar 页面——决定用 switchTab（Tab 页唯一合法入口）还是普通导航 */
export function isTabPath(path: string, tabPaths: readonly string[]): boolean {
  return tabPaths.includes(normalize(path))
}
