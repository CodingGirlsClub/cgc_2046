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
  // U9/R28：闪念间主容器=长廊（页内 Tab：时间廊|我的卡，U2 完整化后卡面单源
  // 在 components/MyCard）。旧独立页仅保留给裁剪端（tt/xhs 未注册长廊，diversion
  // 词表限制），微信端不再注册。
  'pages/flashback-journey/index',
  'pages/flashback-corridor/index',
  'pages/flashback-event/index'
]

const cutTabList = [
  { pagePath: 'pages/discover/index', text: '发现' },
  { pagePath: 'pages/my-enrollments/index', text: '我的报名' }
]

const fullTabList = [
  { pagePath: 'pages/discover/index', text: '发现' },
  { pagePath: 'pages/my-enrollments/index', text: '我的报名' },
  { pagePath: 'pages/workspace/index', text: '工作台' },
  { pagePath: 'pages/profile/index', text: '我的' }
]

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
