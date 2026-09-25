// tabBar 清单的唯一真源在 domain/tab-routes（app.config 的 tabBar.list、
// components/AppTabBar 的渲染、路由分流判断三处共用）——手工维护多份必然
// 漂移，且漂移后果是 switchTab 静默失败（无编译期兜底）
import { CUT_TABS, FULL_TABS, toTabBarEntry } from './domain/tab-routes'

// 裁剪端（抖音/小红书）：2 Tab 漏斗——发现/我的报名 + 流程页，无管理/协作功能
const isCut = process.env.TARO_ENV === 'tt' || process.env.TARO_ENV === 'xhs'
const cutPages = [
  'pages/discover/index',
  'pages/initiative-detail/index',
  'pages/my-enrollments/index',
  'pages/event-detail/index',
  'pages/login/index',
  'pages/register-form/index',
  'pages/enrollment-result/index',
  'pages/join/index',
  // U9/R28：闪念间回访页（薄壳，渲染 components/MyCard）——tt/xhs 漏斗端注册
  // （成场通知深链与「我的」入口）。首程旅程/长廊/场次页**只在微信全量端注册**：
  // 闪念间深度场景不存在于裁剪端，且页面文案含跨端词（check:diversion）。
  'pages/flashback/index'
]

const fullPages = [
  'pages/discover/index',
  'pages/initiative-detail/index',
  'pages/event-detail/index',
  'pages/login/index',
  'pages/register-form/index',
  'pages/enrollment-result/index',
  'pages/order-pay/index',
  'pages/privacy/index',
  'pages/my-enrollments/index',
  'pages/workspace/index',
  'pages/profile/index',
  'pages/join/index',
  'pages/openclacky/index',
  // #508-A：主理人现场核销（管理面，裁剪端不挂）
  'pages/check-in/index',
  // R19：campaign 宣传页（微信端专属——发现页入口卡同款分流，见 pages/discover/index）
  'pages/campaign/index',
  // R20/R21：志愿者招募流（微信端专属——campaign 页「成为志愿者」入口的落点；
  // 审核面板不进小程序，管理面在 web）
  'pages/volunteer-apply/index',
  // U9/R28：闪念间主容器=长廊（页内 Tab：时间廊|我的卡，U2 完整化后卡面单源
  // 在 components/MyCard）。旧独立页仅保留给裁剪端（tt/xhs 未注册长廊，diversion
  // 词表限制），微信端不再注册。
  'pages/flashback-journey/index',
  'pages/flashback-corridor/index',
  'pages/flashback-event/index',
  'pages/flashback-today/index',
  // #771：公开卡页（朋友视角）——微信端专属：它只由分享链接进入，裁剪端
  // 无闪念间深度场景，且页内「卡片站外公开」文案含跨端词（check:diversion）
  'pages/flashback-shared-card/index',
  'pages/flashback-voices/index'
]

const cutTabList = CUT_TABS.map(toTabBarEntry)

const fullTabList = FULL_TABS.map(toTabBarEntry)

export default defineAppConfig({
  pages: isCut ? cutPages : fullPages,
  // 按需注入：启动只注入首页及所需组件代码（微信官方启动性能建议，
  // devtools 「lazyCodeLoading is not turned on」提示即此）
  lazyCodeLoading: 'requiredComponents',
  window: {
    backgroundTextStyle: 'light',
    navigationBarBackgroundColor: '#ffffff',
    navigationBarTitleText: '程序媛汇',
    navigationBarTextStyle: 'black'
  },
  tabBar: {
    color: '#7a7e83',
    selectedColor: '#ea5504',
    backgroundColor: '#ffffff',
    borderStyle: 'black',
    list: isCut ? cutTabList : fullTabList
  }
})
