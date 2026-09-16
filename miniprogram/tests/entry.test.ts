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

const PENDING_SCENE_KEY = 'cgc.pending_scene'

function fakeTaro(pages: EntryPage[] = []) {
  const navigated: string[] = []
  const stored: Array<[string, string]> = []
  return {
    navigated,
    stored,
    taro: {
      getCurrentPages: () => pages,
      navigateTo: ({ url }: { url: string }) => navigated.push(url),
      setStorageSync: (key: string, value: string) => stored.push([key, value])
    }
  }
}

function entry(options: Parameters<typeof applyEntry>[1], pages: EntryPage[] = []) {
  const { taro, navigated, stored } = fakeTaro(pages)
  applyEntry(taro, options, PENDING_SCENE_KEY)
  return { navigated, stored }
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

test('热启动已在 event-detail → 不导航（原有守卫保持）', () => {
  assert.deepEqual(
    entry({ query: { id: 'evt-1', kind: 'event' } }, [
      { route: 'pages/event-detail/index' }
    ]).navigated,
    []
  )
})
