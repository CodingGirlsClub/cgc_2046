// tabBar 清单的唯一真源在 domain/tab-routes（app.config 的 tabBar.list、
// components/AppTabBar 的渲染、路由分流判断三处共用）——手工维护多份必然
// 漂移，且漂移后果是 switchTab 静默失败（无编译期兜底）。
// 页面注册名单唯一真源在 domain/platform-pages（P0-4：深链过滤与本声明同源，
// 新增页面只改 platform-pages 一处）。
import { CUT_TABS, FULL_TABS, XHS_TABS, toTabBarEntry, type TabDef } from './domain/tab-routes'
import { pagesForPlatform, type RoutePlatform } from './domain/platform-pages'

// TARO_ENV（'weapp'/'tt'/'xhs'）→ domain 平台键（'wechat'/'tt'/'xhs'），与
// platform/index.ts currentPlatform() 同口径（app.config 不能 import Taro 依赖）
const platform: RoutePlatform =
  process.env.TARO_ENV === 'tt' ? 'tt' : process.env.TARO_ENV === 'xhs' ? 'xhs' : 'wechat'

// Tab 清单按平台分派：抖音 = 发现/我的报名（2 Tab 漏斗）；小红书 = 发现/我的
// （D2a，我的报名收进「我的」）；微信 = 全量（含条件段工作台）。
const tabsForPlatform = (env: RoutePlatform): readonly TabDef[] => {
  if (env === 'xhs') return XHS_TABS
  if (env === 'tt') return CUT_TABS
  return FULL_TABS
}

export default defineAppConfig({
  pages: pagesForPlatform(platform),
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
    list: tabsForPlatform(platform).map(toTabBarEntry)
  }
})
