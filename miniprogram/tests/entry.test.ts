/**
 * 入口接线测试（plan 011 深链；#check 审查缺口修复）。
 *
 * 纯函数 resolveEntry 的测试打不到「谁按决策调 Taro」——把 useLaunch 回退成只解
 * scene、保留 resolveEntry，纯函数测试仍全绿。本文件打的是 applyEntry（app.tsx
 * 两条启动路径的唯一落地口）：Taro 作为参数注入，断言 navigateTo / pendingScene
 * 的真实调用，含冷启动重复导航抑制。
 */
import assert from 'node:assert/strict'
import test from 'node:test'
import { applyEntry } from '../src/domain/entry.ts'
import type { EntryPage } from '../src/domain/share-route.ts'
import { CUT_TAB_PATHS, FULL_TAB_PATHS, tabPathsForPlatform } from '../src/domain/tab-routes.ts'

const PENDING_SCENE_KEY = 'cgc.pending_scene'

function fakeTaro(pages: EntryPage[] = []) {
  const navigated: string[] = []
  const switched: string[] = []
  const stored: Array<[string, string]> = []
  return {
    navigated,
    switched,
    stored,
    taro: {
      getCurrentPages: () => pages,
      navigateTo: ({ url }: { url: string }) => navigated.push(url),
      switchTab: ({ url }: { url: string }) => switched.push(url),
      setStorageSync: (key: string, value: string) => stored.push([key, value])
    }
  }
}

// Real onAppShow carries path too: query-only tests miss warm-entry regressions.
for (const [path, key] of [
  ['pages/flashback-voices/index', 'quoteId'],
  ['pages/flashback-wishes/index', 'wishId']
] as const) {
  test(`${key}: cold entry does not duplicate; warm entry opens the requested item`, () => {
    const options = { path, query: { [key]: 'target' } }
    assert.deepEqual(entry(options).navigated, [])
    assert.deepEqual(entry(options, [{ route: 'pages/discover/index' }]).navigated, [`/${path}?${key}=target`])
    assert.deepEqual(entry(options, [{ route: path, options: { [key]: 'old' } }]).navigated, [`/${path}?${key}=target`])
    assert.deepEqual(entry(options, [{ route: path, options: { [key]: 'target' } }]).navigated, [])
  })
  test(`${key}: whole collection clears item and city landing parameters`, () => {
    assert.deepEqual(entry({ path, query: {} }, [{ route: path, options: { [key]: 'old' } }]).navigated, [`/${path}`])
    assert.deepEqual(entry({ path, query: {} }, [{ route: path, options: { city: '成都' } }]).navigated, [`/${path}`])
    assert.deepEqual(entry({ path, query: {} }, [{ route: 'pages/discover/index' }]).navigated, [`/${path}`])
    assert.deepEqual(entry({ path, query: {} }).navigated, [])
    assert.deepEqual(entry({ path, query: {} }, [{ route: path }]).navigated, [])
  })
}

function entry(
  options: Parameters<typeof applyEntry>[1],
  pages: EntryPage[] = []
) {
  const { taro, navigated, switched, stored } = fakeTaro(pages)
  applyEntry(taro, options, PENDING_SCENE_KEY)
  return { navigated, switched, stored }
}

test('冷启动 id 深链（scheme / 卡片）→ navigateTo 详情页', () => {
  assert.deepEqual(
    entry({ path: 'pages/discover/index', query: { id: 'evt-1', kind: 'event' } }).navigated,
    ['/pages/event-detail/index?id=evt-1&kind=event']
  )
})

test('冷启动 slug 深链（initiative 卡片 / 小程序码）→ navigateTo 详情页', () => {
  assert.deepEqual(
    entry({ path: 'pages/discover/index', query: { slug: '1024 北京&周末' } }).navigated,
    ['/pages/initiative-detail/index?slug=1024%20%E5%8C%97%E4%BA%AC%26%E5%91%A8%E6%9C%AB']
  )
})

test('冷启动入口就是目标页（卡片 path 自带 detail）→ 抑制重复 navigateTo', () => {
  assert.deepEqual(
    entry({ path: 'pages/initiative-detail/index', query: { slug: 'hackerstart1024' } }).navigated,
    []
  )
  assert.deepEqual(
    entry({ path: 'pages/event-detail/index', query: { id: 'evt-1', kind: 'event' } }).navigated,
    []
  )
})

test('冷启动入口是别的页面 → 照常导航', () => {
  assert.deepEqual(
    entry({ path: 'pages/discover/index', query: { id: 'evt-1', kind: 'event' } }).navigated,
    ['/pages/event-detail/index?id=evt-1&kind=event']
  )
})

test('冷启动 scene → 落 pendingScene 且 navigateTo join（scene 链路不抑制）', () => {
  const { navigated, stored } = entry({ path: 'pages/join/index', query: { scene: ' SC_1 ' } })
  assert.deepEqual(stored, [[PENDING_SCENE_KEY, 'SC_1']])
  assert.deepEqual(navigated, ['/pages/join/index?scene=SC_1'])
})

test('冷启动无目标参数 → 不落盘不导航', () => {
  const { navigated, stored } = entry({ path: 'pages/discover/index', query: {} })
  assert.deepEqual(stored, [])
  assert.deepEqual(navigated, [])
})

test('热启动（有页面栈）与冷启动同判定：同 slug 不导航，不同 slug 导航', () => {
  const pages: EntryPage[] = [
    { route: 'pages/initiative-detail/index', options: { slug: 'same' } }
  ]
  assert.deepEqual(entry({ query: { slug: 'same' } }, pages).navigated, [])
  assert.deepEqual(entry({ query: { slug: 'next' } }, pages).navigated, [
    '/pages/initiative-detail/index?slug=next'
  ])
})

test('热启动已在同一 event-detail（同 id）→ 不导航；换场次 → 导航', () => {
  assert.deepEqual(
    entry({ query: { id: 'evt-1', kind: 'event' } }, [
      { route: 'pages/event-detail/index', options: { id: 'evt-1' } }
    ]).navigated,
    []
  )
  assert.deepEqual(
    entry({ query: { id: 'evt-2', kind: 'event' } }, [
      { route: 'pages/event-detail/index', options: { id: 'evt-1' } }
    ]).navigated,
    ['/pages/event-detail/index?id=evt-2&kind=event']
  )
})

// Public wishes now have a standalone, non-tab landing page.
test('热启动 wishId 直接进入许愿树，不依赖长廊的分页', () => {
  const result = entry({ query: { wishId: 'w-9' } }, [{ route: 'pages/discover/index' }])
  assert.deepEqual(result.switched, [])
  assert.deepEqual(result.navigated, ['/pages/flashback-wishes/index?wishId=w-9'])
  assert.deepEqual(result.stored, [])
})
test('同一愿望不重复导航；切换分享愿望正常定位', () => {
  const page = [{ route: 'pages/flashback-wishes/index', options: { wishId: 'w-9' } }]
  assert.deepEqual(entry({ query: { wishId: 'w-9' } }, page).navigated, [])
  assert.deepEqual(entry({ query: { wishId: 'w-10' } }, page).navigated, ['/pages/flashback-wishes/index?wishId=w-10'])
})

// ── P0-4：applyEntry 按本端平台过滤 URL 与 Tab 集合 ─────────────────────

function entryPlatform(
  platform: 'wechat' | 'tt' | 'xhs',
  options: Parameters<typeof applyEntry>[1],
  pages: EntryPage[] = []
) {
  const { taro, navigated, switched, stored } = fakeTaro(pages)
  applyEntry(taro, options, PENDING_SCENE_KEY, platform)
  return { navigated, switched, stored }
}

test('P0-4 xhs：wishId（本端未注册页）回落薄壳页且 navigateTo（薄壳非 Tab）', () => {
  const result = entryPlatform('xhs', { query: { wishId: 'w-9' } }, [{ route: 'pages/discover/index' }])
  assert.deepEqual(result.navigated, ['/pages/flashback/index'])
  assert.deepEqual(result.switched, [])
})

test('P0-4 xhs：event id 深链照常 navigateTo（已注册目标不过滤）', () => {
  const result = entryPlatform('xhs', { query: { id: 'evt-1', kind: 'event' } }, [{ route: 'pages/discover/index' }])
  assert.deepEqual(result.navigated, ['/pages/event-detail/index?id=evt-1&kind=event'])
})

test('P0-4 tabPathsForPlatform：Tab 集合按平台分派（不再永远按微信 tabs）', () => {
  // 深链落 Tab 页时 switchTab 与否取决于本端 Tab 集合：profile 是微信 Tab；
  // 抖音裁剪端 = 发现/我的报名；小红书（D2a）= 发现/我的
  assert.deepEqual(tabPathsForPlatform('wechat'), FULL_TAB_PATHS)
  assert.deepEqual(tabPathsForPlatform('tt'), CUT_TAB_PATHS)
  assert.equal(tabPathsForPlatform('xhs').includes('/pages/profile-lite/index'), true)
  assert.equal(tabPathsForPlatform('xhs').includes('/pages/discover/index'), true)
})
