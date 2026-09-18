/**
 * campaign 页与发现页入口卡测试（R19，plan U9）。
 *
 * 覆盖面：
 * 1. 三入口跳转目标与品牌邮箱复制（Taro 注入 → 断言真实调起，同 tests/entry.test.ts 的理由）；
 * 2. campaign 页与发现页入口卡的渲染内容 + 零导流禁词（BANNED_TERMS 单源，同 CI 的
 *    scripts/check-no-diversion.mjs）；
 * 3. **分流点断言**：入口卡与 campaign 页只在微信端出现——裁剪端（tt/xhs）既不渲染入口卡，
 *    页清单也不登记 campaign，否则是一条死链。
 */

import { describe, expect, it, vi } from 'vitest'
import { createElement } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import { BANNED_TERMS } from '../scripts/diversion-policy.mjs'

const mocks = vi.hoisted(() => ({ navigateTo: vi.fn(), setClipboardData: vi.fn(), showToast: vi.fn() }))

vi.mock('@tarojs/components', () => ({ Button: 'button', Image: 'img', Input: 'input', ScrollView: 'div', Text: 'span', View: 'div' }))
vi.mock('@tarojs/taro', () => ({
  default: {
    navigateTo: mocks.navigateTo,
    setClipboardData: mocks.setClipboardData,
    showToast: mocks.showToast,
    // AppTabBar（发现页底部栏）在 useState 初始化即读缓存
    getStorageSync: () => false,
    hideTabBar: () => Promise.resolve()
  },
  useDidShow: vi.fn(),
  useDidHide: vi.fn(),
  useUnload: vi.fn()
}))
vi.mock('../src/api', () => ({ api: { getCatalog: vi.fn(), getSession: vi.fn() } }))
vi.mock('../src/api/initiatives', () => ({ getPublicInitiatives: vi.fn() }))

import CampaignPage from '../src/pages/campaign'
import DiscoverPage from '../src/pages/discover'
import {
  CAMPAIGN_BRAND_EMAIL,
  CAMPAIGN_PAGE_PATH,
  CAMPAIGN_INITIATIVE_SLUG,
  campaignEntryUrl,
  openCampaignEntry,
  openCampaignPage
} from '../src/domain/campaign'

/** 假 Taro（只取本单元用到的三个方法） */
function fakeTaro(copyFails = false) {
  return {
    navigateTo: vi.fn(),
    setClipboardData: copyFails ? vi.fn().mockRejectedValue(new Error('denied')) : vi.fn().mockResolvedValue(undefined),
    showToast: vi.fn()
  }
}

/** 指定 TARO_ENV 渲染（页面在渲染期读 process.env.TARO_ENV，成对恢复） */
function withPlatform<T>(platform: string, render: () => T): T {
  const original = process.env.TARO_ENV
  process.env.TARO_ENV = platform
  try {
    return render()
  } finally {
    process.env.TARO_ENV = original
  }
}

const renderDiscover = (platform: string) =>
  withPlatform(platform, () => renderToStaticMarkup(createElement(DiscoverPage)))

/** 零导流禁词（脚本单源）：文案不得出现跨端引导字样，否则 CI 的 check:diversion 会红 */
function expectNoBannedTerms(html: string) {
  for (const term of BANNED_TERMS) expect(html).not.toContain(term)
}

describe('campaign 三入口（R19）', () => {
  it('「我要参加」→ 小程序既有的活动详情页（上线检查单 R16 创建的 Initiative slug）', () => {
    expect(CAMPAIGN_INITIATIVE_SLUG).toBe('hackerstart1024')
    expect(campaignEntryUrl('join')).toBe('/pages/initiative-detail/index?slug=hackerstart1024')
  })

  it('「成为志愿者」→ 招募流页面（U10 承载，本单元只引用路径）', () => {
    expect(campaignEntryUrl('volunteer')).toBe('/pages/volunteer-apply/index')
  })

  it('「品牌合作」无页面可跳：复制邮箱而不是 navigateTo', () => {
    expect(campaignEntryUrl('brand')).toBeNull()
    const taro = fakeTaro()
    openCampaignEntry(taro, 'brand')
    expect(taro.setClipboardData).toHaveBeenCalledWith({ data: CAMPAIGN_BRAND_EMAIL })
    expect(taro.navigateTo).not.toHaveBeenCalled()
  })

  it('两个可跳入口各自 navigateTo 到自己的目标（不串台）', () => {
    for (const key of ['join', 'volunteer'] as const) {
      const taro = fakeTaro()
      openCampaignEntry(taro, key)
      expect(taro.navigateTo).toHaveBeenCalledWith({ url: campaignEntryUrl(key) })
      expect(taro.setClipboardData).not.toHaveBeenCalled()
    }
  })

  it('复制失败 → 提示手动记录（不静默、不抛）', async () => {
    const taro = fakeTaro(true)
    expect(() => openCampaignEntry(taro, 'brand')).not.toThrow()
    await vi.waitFor(() => expect(taro.showToast).toHaveBeenCalledWith({ title: '复制失败，请手动记录', icon: 'none' }))
  })

  it('发现页入口卡落点 = campaign 页（唯一跨页调起口）', () => {
    expect(CAMPAIGN_PAGE_PATH).toBe('/pages/campaign/index')
    const taro = fakeTaro()
    openCampaignPage(taro)
    expect(taro.navigateTo).toHaveBeenCalledWith({ url: '/pages/campaign/index' })
  })
})

describe('campaign 页内容（weapp 渲染）', () => {
  const html = renderToStaticMarkup(createElement(CampaignPage))

  it('hero：十周年 + 关键数字 + 幂标记', () => {
    for (const text of ['十周年 CAMPAIGN', 'Hacker Start 1024', '让普通人第一次亲手用 Agent 做出能跑的作品', '1,024', '10.24', '个品牌席位']) {
      expect(html).toContain(text)
    }
    // 幂标记（2⁰ / 2³ / 2⁴ / 2⁵ / 2⁶ / 2¹⁰）逐个在位
    for (const exponent of [0, 3, 4, 5, 6, 10]) expect(html).toContain(`data-testid="pow-${exponent}"`)
  })

  it('三入口卡齐全（JOIN / VOLUNTEER / BRAND）且各带自己的标题', () => {
    for (const text of ['>JOIN<', '>VOLUNTEER<', '>BRAND<', '我要参加一场', '成为志愿者', '品牌专场合作']) {
      expect(html).toContain(text)
    }
  })

  it('hero 两个 CTA 各就各位（参加 / 志愿者）', () => {
    expect(html).toContain('data-testid="campaign-hero-join"')
    expect(html).toContain('data-testid="campaign-hero-volunteer"')
    expect(html).toContain('我要参加')
  })

  it('品牌合作：页内展示邮箱 + 复制按钮（不用 mailto）', () => {
    expect(html).toContain(CAMPAIGN_BRAND_EMAIL)
    expect(html).toContain('复制邮箱')
    expect(html).toContain('data-testid="campaign-copy-email"')
    expect(html).not.toContain('mailto')
  })

  it('时间线三节点（2026.10.24 启动 → 首期 64 场 → 批次滚动）', () => {
    for (const text of ['2026.10.24 启动', '首期 64 场', '批次滚动', '直至 1,024 场']) expect(html).toContain(text)
  })

  it('十年浓缩段：历史累计标注在列 + 可查证背书 + 杠杆句', () => {
    for (const text of ['2016 年成立', '2016-2025 历史累计', '4,000+', '2,000 万+', 'ICSE CHASE 2021', '中国日报', '本轮一个 campaign 的参与人数目标']) {
      expect(html).toContain(text)
    }
  })

  it('口径纪律：无价格、无厂商名（与 web 宣传页 U6 同口径）', () => {
    for (const forbidden of ['¥', '69', 'OpenClacky', '免费']) expect(html).not.toContain(forbidden)
  })

  it('零导流禁词：campaign 页文案不含跨端引导字样', () => {
    expectNoBannedTerms(html)
  })
})

describe('发现页入口卡与分流点（R19）', () => {
  it('微信端：入口卡渲染在发现页顶部', () => {
    const html = renderDiscover('weapp')
    expect(html).toContain('data-testid="campaign-entry"')
    expect(html).toContain('Hacker Start 1024')
    expect(html).toContain('十周年 CAMPAIGN')
  })

  it.each(['tt', 'xhs'])('%s 端：不渲染入口卡（裁剪端没有 campaign 页，避免死链）', (platform) => {
    const html = renderDiscover(platform)
    expect(html).not.toContain('data-testid="campaign-entry"')
    expect(html).not.toContain('Hacker Start 1024')
  })

  it.each(['weapp', 'tt', 'xhs'])('%s 端：发现页文案不含跨端引导字样（共用页，导流扫描红线）', (platform) => {
    expectNoBannedTerms(renderDiscover(platform))
  })
})

describe('campaign 页注册：微信端专属', () => {
  async function loadAppConfig(platform: string) {
    vi.stubGlobal('defineAppConfig', (config: unknown) => config)
    const original = process.env.TARO_ENV
    process.env.TARO_ENV = platform
    try {
      vi.resetModules()
      const { default: config } = await import('../src/app.config')
      return config as { pages: string[]; tabBar: { list: Array<{ pagePath: string }> } }
    } finally {
      process.env.TARO_ENV = original
      vi.unstubAllGlobals()
    }
  }

  it('微信端页清单登记 campaign，且 4 Tab 结构原样', async () => {
    const config = await loadAppConfig('weapp')
    expect(config.pages).toContain('pages/campaign/index')
    expect(config.tabBar.list.map(({ pagePath }) => pagePath)).toEqual([
      'pages/discover/index',
      'pages/my-enrollments/index',
      'pages/workspace/index',
      'pages/profile/index'
    ])
  })

  it.each(['tt', 'xhs'])('%s 端页清单不挂 campaign（裁剪端不登记）', async (platform) => {
    const config = await loadAppConfig(platform)
    expect(config.pages).not.toContain('pages/campaign/index')
    expect(config.pages).toContain('pages/discover/index')
  })
})
