import assert from 'node:assert/strict'
import test from 'node:test'
import { buildJoinSharePath, resolveAppShowRoute } from '../src/domain/share-route.ts'

// P4 热启动路由判定纯函数（plan 011 D-2，F05 复发面闭合）：
// scene 优先（与 pendingScene/join 链路一致）；query 含 id 才跳 event-detail，
// 且当前不在 event-detail（避免打断已在看的详情）；kind 缺省回落 event
// （与 event-detail 页面三态回落一致）。

test('query 含 id+kind 且当前不在 event-detail → 跳详情', () => {
  assert.equal(
    resolveAppShowRoute({ id: 'evt-1', kind: 'event' }, 'pages/discover/index'),
    '/pages/event-detail/index?id=evt-1&kind=event'
  )
})

test('kind=course 透传；kind 缺省/非法值回落 event', () => {
  assert.equal(
    resolveAppShowRoute({ id: 'crs-1', kind: 'course' }, 'pages/discover/index'),
    '/pages/event-detail/index?id=crs-1&kind=course'
  )
  assert.equal(
    resolveAppShowRoute({ id: 'crs-2' }, 'pages/discover/index'),
    '/pages/event-detail/index?id=crs-2&kind=event'
  )
  assert.equal(
    resolveAppShowRoute({ id: 'x-1', kind: 'workshop' }, 'pages/discover/index'),
    '/pages/event-detail/index?id=x-1&kind=event'
  )
})

test('当前已在 event-detail → 不跳（不打断当前详情）', () => {
  assert.equal(resolveAppShowRoute({ id: 'evt-1', kind: 'event' }, 'pages/event-detail/index'), null)
})

test('scene 优先于 id（join 链路独占，与 pendingScene 互斥）', () => {
  assert.equal(
    resolveAppShowRoute({ scene: 'SC_1', id: 'evt-1', kind: 'event' }, 'pages/discover/index'),
    '/pages/join/index?scene=SC_1'
  )
})

test('scene 需 encodeURIComponent', () => {
  assert.equal(
    resolveAppShowRoute({ scene: 'a b/c' }, 'pages/profile/index'),
    '/pages/join/index?scene=a%20b%2Fc'
  )
})

test('query 无 scene 无 id → null', () => {
  assert.equal(resolveAppShowRoute({}, 'pages/discover/index'), null)
  assert.equal(resolveAppShowRoute({ kind: 'event' }, 'pages/discover/index'), null)
})

test('仅 id 无 kind 且当前在 event-detail → 仍不跳（互斥优先于回落）', () => {
  assert.equal(resolveAppShowRoute({ id: 'evt-9' }, 'pages/event-detail/index'), null)
})

// #415 分享出口：转发卡片 path 构造（profile 页 useShareAppMessage 消费）
test('buildJoinSharePath 拼 join 路由并编码 scene', () => {
  assert.equal(buildJoinSharePath('SC_1'), '/pages/join/index?scene=SC_1')
  assert.equal(buildJoinSharePath('a b/c&d=e'), '/pages/join/index?scene=a%20b%2Fc%26d%3De')
})

test('Initiative 分享热启动按 slug 路由并编码', () => {
  assert.equal(
    resolveAppShowRoute({ slug: '1024 北京&周末' }, 'pages/discover/index'),
    '/pages/initiative-detail/index?slug=1024%20%E5%8C%97%E4%BA%AC%26%E5%91%A8%E6%9C%AB'
  )
})

test('Initiative 同 slug 不重复跳转，不同 slug 仍打开目标', () => {
  assert.equal(resolveAppShowRoute({ slug: 'new' }, 'pages/initiative-detail/index', { slug: 'new' }), null)
  assert.equal(
    resolveAppShowRoute({ slug: 'new' }, 'pages/initiative-detail/index', { slug: 'old' }),
    '/pages/initiative-detail/index?slug=new'
  )
})

test('join scene 与 Event id 保留各自分享入口', () => {
  assert.equal(resolveAppShowRoute({ scene: 'invite', slug: '1024' }, 'pages/discover/index'), '/pages/join/index?scene=invite')
  assert.equal(resolveAppShowRoute({ id: 'event-1', kind: 'event', slug: '1024' }, 'pages/discover/index'), '/pages/event-detail/index?id=event-1&kind=event')
})
