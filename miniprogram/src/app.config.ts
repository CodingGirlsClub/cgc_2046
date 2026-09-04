// 裁剪端（抖音/小红书）：2 Tab 漏斗——发现/我的报名 + 流程页，无管理/协作功能（docs/01-定稿设计/小程序多端平台矩阵.md）
const isCut = process.env.TARO_ENV === 'tt' || process.env.TARO_ENV === 'xhs'

const cutPages = [
  'pages/discover/index',
  'pages/my-enrollments/index',
  'pages/event-detail/index',
  'pages/login/index',
  'pages/register-form/index',
  'pages/enrollment-result/index',
  'pages/join/index'
]

const fullPages = [
  'pages/discover/index',
  'pages/event-detail/index',
  'pages/login/index',
  'pages/register-form/index',
  'pages/enrollment-result/index',
  'pages/order-pay/index',
  'pages/my-enrollments/index',
  'pages/workspace/index',
  'pages/profile/index',
  'pages/join/index',
  'pages/openclacky/index'
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
    navigationBarTitleText: 'CGC',
    navigationBarTextStyle: 'black'
  },
  tabBar: {
    color: '#7a7e83',
    selectedColor: '#07c160',
    backgroundColor: '#ffffff',
    borderStyle: 'black',
    list: isCut ? cutTabList : fullTabList
  }
})
