// 平台导航结构测试（P0-5，D2a：小红书 Tab = 发现 / 我的）。
// 判据：XHS_TABS 形状、tabPathsForPlatform 分派、Tab 指向页必须注册
// （platform-pages 单源——「Tab 指向未注册页 = switchTab 静默失败」的铁律）。
import assert from 'node:assert/strict'
import { describe, test } from 'node:test'

import { CUT_TABS, XHS_TABS, XHS_TAB_PATHS, cutJoinLanding, tabPathsForPlatform } from '../src/domain/tab-routes.ts'
import { XHS_PAGES, TT_PAGES, pageRegistered } from '../src/domain/platform-pages.ts'

describe('小红书 Tab 结构（D2a：发现 / 我的）', () => {
  test('XHS_TABS = 发现 + 我的（我的报名收进「我的」，不再是 Tab）', () => {
    assert.equal(XHS_TABS.length, 2)
    assert.equal(XHS_TABS[0].key, 'discover')
    assert.equal(XHS_TABS[0].path, '/pages/discover/index')
    assert.equal(XHS_TABS[1].key, 'profile')
    assert.equal(XHS_TABS[1].text, '我的')
    assert.equal(XHS_TABS[1].path, '/pages/profile-lite/index')
  })

  test('tabPathsForPlatform：xhs 用自己的 Tab 集合（我的报名不在其中）', () => {
    assert.deepEqual(tabPathsForPlatform('xhs'), XHS_TAB_PATHS)
    const paths = tabPathsForPlatform('xhs')
    assert.ok(paths.includes('/pages/profile-lite/index'))
    assert.ok(!paths.includes('/pages/my-enrollments/index'))
  })

  test('tt 维持原 2 Tab（发现 / 我的报名）', () => {
    const paths = tabPathsForPlatform('tt')
    assert.ok(paths.includes('/pages/my-enrollments/index'))
    assert.ok(!paths.includes('/pages/profile-lite/index'))
  })
})

describe('Tab 指向页必须注册（switchTab 静默失败铁律）', () => {
  test('XHS_TABS 指向的页都在 XHS_PAGES 里', () => {
    for (const tab of XHS_TABS) {
      assert.ok(pageRegistered(tab.path, 'xhs'), `${tab.path} 未注册于 XHS_PAGES`)
    }
  })

  test('CUT_TABS 指向的页都在 TT_PAGES 里', () => {
    for (const tab of CUT_TABS) {
      assert.ok(pageRegistered(tab.path, 'tt'), `${tab.path} 未注册于 TT_PAGES`)
    }
  })

  test('XHS 注册集包含「我的」精简页、隐私页、我的报名（非 Tab 普通页）与薄壳页', () => {
    assert.ok(XHS_PAGES.includes('pages/profile-lite/index'))
    assert.ok(XHS_PAGES.includes('pages/privacy/index'))
    assert.ok(XHS_PAGES.includes('pages/my-enrollments/index'))
    assert.ok(XHS_PAGES.includes('pages/flashback/index'))
  })
})

describe('加入工作台后的落点（join 页 reLaunch 清栈）', () => {
  // reLaunch 清空页面栈：落点若不是 Tab 页，用户既无 TabBar 也无返回——死胡同。
  // D2a 把小红书的「我的报名」降为普通页后，落点必须改为「我的」Tab。
  test('裁剪端落点必须是本端 Tab 页', () => {
    for (const platform of ['tt', 'xhs'] as const) {
      const landing = cutJoinLanding(platform)
      assert.ok(tabPathsForPlatform(platform).includes(landing), `${platform} 落点 ${landing} 不是 Tab 页`)
    }
  })

  test('xhs 落「我的」（我的报名入口在其中），tt 落「我的报名」', () => {
    assert.equal(cutJoinLanding('xhs'), '/pages/profile-lite/index')
    assert.equal(cutJoinLanding('tt'), '/pages/my-enrollments/index')
  })
})
