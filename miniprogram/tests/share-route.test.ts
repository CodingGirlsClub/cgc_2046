import assert from 'node:assert/strict'
import test from 'node:test'
import { buildJoinSharePath, resolveAppShowRoute, resolveEntry } from '../src/domain/share-route.ts'

// P4 冷/热启动路由判定纯函数（plan 011 D-2）：
// scene 优先（与 pendingScene/join 链路一致）；query 含 id 才跳 event-detail，
// 且当前不在 event-detail（避免打断已在看的详情）；kind 缺省回落 event
// （与 event-detail 页面三态回落一致）；slug → initiative-detail。
// resolveEntry 为冷启动（useLaunch，空页面栈）与热启动（onAppShow，栈顶页）
// 的共用入口：冷启动的 id/slug 深链不再被丢弃（站外投放主要形态）。

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

test('当前已在同一 event-detail（同 id）→ 不跳（不打断当前详情）', () => {
  assert.equal(
    resolveAppShowRoute({ id: 'evt-1', kind: 'event' }, 'pages/event-detail/index', { id: 'evt-1', kind: 'event' }),
    null
  )
})

test('当前已在 event-detail 但换了一张卡片（不同 id）→ 仍打开目标', () => {
  assert.equal(
    resolveAppShowRoute({ id: 'evt-2', kind: 'event' }, 'pages/event-detail/index', { id: 'evt-1', kind: 'event' }),
    '/pages/event-detail/index?id=evt-2&kind=event'
  )
})

test('当前页 options 读不到（currentQuery 缺省）→ 不视为同 id，照常打开', () => {
  assert.equal(
    resolveAppShowRoute({ id: 'evt-1', kind: 'event' }, 'pages/event-detail/index'),
    '/pages/event-detail/index?id=evt-1&kind=event'
  )
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

test('仅 id 无 kind：同一详情页不跳；换场次按 kind=event 回落打开', () => {
  assert.equal(resolveAppShowRoute({ id: 'evt-9' }, 'pages/event-detail/index', { id: 'evt-9' }), null)
  assert.equal(
    resolveAppShowRoute({ id: 'evt-9' }, 'pages/event-detail/index', { id: 'evt-1' }),
    '/pages/event-detail/index?id=evt-9&kind=event'
  )
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

// 冷启动补齐：useLaunch 空页面栈下 id/slug 深链必须导航（原实现只解 scene，
// 站外投放的 scheme / 小程序码主要落在冷启动）。
const sceneAndUrl = (decision: ReturnType<typeof resolveEntry>) => ({
  scene: decision.scene,
  url: decision.url
})

test('冷启动（空页面栈）id 深链导航，不再被静默丢弃', () => {
  const decision = resolveEntry({ query: { id: 'evt-1', kind: 'event' } })
  assert.deepEqual(sceneAndUrl(decision), {
    scene: null,
    url: '/pages/event-detail/index?id=evt-1&kind=event'
  })
  assert.equal(decision.navigate, true)
})

test('冷启动 slug 深链导航（initiative 分享卡片 / 小程序码）', () => {
  const decision = resolveEntry({ query: { slug: '1024 北京&周末' } })
  assert.deepEqual(sceneAndUrl(decision), {
    scene: null,
    url: '/pages/initiative-detail/index?slug=1024%20%E5%8C%97%E4%BA%AC%26%E5%91%A8%E6%9C%AB'
  })
  assert.equal(decision.navigate, true)
})

test('冷启动 scene 深链：pendingScene 待落盘 + join 导航同在', () => {
  const decision = resolveEntry({ query: { scene: ' SC_1 ' } })
  assert.deepEqual(sceneAndUrl(decision), {
    scene: 'SC_1',
    url: '/pages/join/index?scene=SC_1'
  })
  assert.equal(decision.navigate, true)
})

test('冷启动无目标参数 → 不落盘不导航', () => {
  for (const options of [{}, { query: {} }]) {
    const decision = resolveEntry(options)
    assert.deepEqual(sceneAndUrl(decision), { scene: null, url: null })
    assert.equal(decision.navigate, false)
  }
})

// 冷启动重复导航抑制：页面栈为空时守卫拿不到栈，卡片/二维码的 path 本身就是
// 详情页——入口 path/query 是唯一「我已在哪」信号（见 EntryDecision.navigate）。
// 注意 Taro 的 options.path 不带前导斜杠，比较前必须规范化（否则抑制永不生效）。
test('冷启动入口即目标页 → url 仍算出，但 navigate 抑制', () => {
  const decision = resolveEntry({
    path: 'pages/initiative-detail/index',
    query: { slug: 'hackerstart1024' }
  })
  assert.equal(decision.url, '/pages/initiative-detail/index?slug=hackerstart1024')
  assert.equal(decision.navigate, false)
})

test('冷启动入口是 event-detail 且 id 相同 → 抑制（带前导斜杠的 path 也认）', () => {
  assert.equal(
    resolveEntry({ path: '/pages/event-detail/index', query: { id: 'evt-1', kind: 'event' } }).navigate,
    false
  )
})

test('冷启动入口是别的页面（非同类详情）→ 不抑制', () => {
  assert.equal(
    resolveEntry({ path: 'pages/discover/index', query: { slug: 'hackerstart1024' } }).navigate,
    true
  )
  assert.equal(
    resolveEntry({ path: 'pages/discover/index', query: { id: 'evt-9', kind: 'event' } }).navigate,
    true
  )
})

// 热启动（有页面栈）：与冷启动同一判定，额外吃「已在目标页不打断」守卫。
// 守卫按值比较（同 id 才不打断）——换一张分享卡片仍须打开目标。
test('热启动已在同一 event-detail（同 id）→ 不导航；换场次 → 导航', () => {
  assert.equal(
    resolveEntry({ query: { id: 'evt-1', kind: 'event' } }, [{ route: 'pages/event-detail/index', options: { id: 'evt-1' } }]).url,
    null
  )
  assert.equal(
    resolveEntry({ query: { id: 'evt-2', kind: 'event' } }, [{ route: 'pages/event-detail/index', options: { id: 'evt-1' } }]).url,
    '/pages/event-detail/index?id=evt-2&kind=event'
  )
})

test('热启动已在同 slug initiative-detail → 不导航；不同 slug → 导航', () => {
  assert.equal(
    resolveEntry({ query: { slug: 'same' } }, [{ route: 'pages/initiative-detail/index', options: { slug: 'same' } }]).url,
    null
  )
  assert.equal(
    resolveEntry({ query: { slug: 'next' } }, [{ route: 'pages/initiative-detail/index', options: { slug: 'same' } }]).url,
    '/pages/initiative-detail/index?slug=next'
  )
})

test('热启动取栈顶页（多页栈只用最后一页判定）', () => {
  assert.equal(
    resolveEntry({ query: { id: 'evt-1' } }, [
      { route: 'pages/discover/index' },
      { route: 'pages/event-detail/index', options: { id: 'evt-1' } }
    ]).url,
    null
  )
})
