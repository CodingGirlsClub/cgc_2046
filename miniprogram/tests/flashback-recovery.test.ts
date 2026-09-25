import test from 'node:test'
import assert from 'node:assert/strict'
import { recoveryReducer, recoveryView, initialRecovery, type RecoveryState } from '../src/domain/flashback-recovery.ts'
import type { FlashbackCapsule } from '../src/domain/models.ts'

// Failure cases: claim/network failure rendered as no-match; late account response
// re-exposes private data; renewed checking leaves old capsule; no-match asks login again.
const capsule = { me: { fullName: '合成账号 A' } } as FlashbackCapsule

test('只有成功的未匹配结果进入无档案说明，失败保留独立重试状态', () => {
  const checking = recoveryReducer(initialRecovery(), { type: 'start', generation: 1 })
  const error = recoveryReducer(checking, { type: 'error', generation: 1 })
  assert.equal(error.kind, 'error')
  assert.equal(recoveryView(error.kind).action, 'retry')
  assert.equal(recoveryView(error.kind).title, '暂时没能完成查找')
  const unmatched = recoveryReducer(checking, { type: 'unmatched', generation: 1 })
  assert.equal(recoveryView(unmatched.kind).action, 'write')
  assert.match(recoveryView(unmatched.kind).description, /暂时找不到/)
  assert.doesNotMatch(recoveryView(unmatched.kind).button, /登录/)
})

test('查找中清除旧档案；晚到的旧账号成功或失败不能覆盖新结果', () => {
  const member: RecoveryState = { kind: 'member', generation: 1, capsule, token: null }
  const checking = recoveryReducer(member, { type: 'start', generation: 2 })
  assert.deepEqual(checking, { kind: 'checking', generation: 2 })
  assert.equal(recoveryReducer(checking, { type: 'member', generation: 1, capsule, token: null }), checking)
  const guest = recoveryReducer(checking, { type: 'guest', generation: 2 })
  assert.equal(recoveryReducer(guest, { type: 'error', generation: 1 }), guest)
  assert.equal(recoveryView(guest.kind).action, 'login')
})

test('已绑定及新认领均进入真实个人长廊；重试从独立查找态开始', () => {
  const error = recoveryReducer(initialRecovery(), { type: 'error', generation: 0 })
  const retry = recoveryReducer(error, { type: 'start', generation: 1 })
  assert.equal(recoveryView(retry.kind).action, null)
  const member = recoveryReducer(retry, { type: 'member', generation: 1, capsule, token: 'synthetic-link' })
  assert.equal(member.kind, 'member')
  if (member.kind === 'member') assert.equal(member.capsule, capsule)
})

test('同一人的页面返回和城市刷新不重复播放快门，新身份才显示', async () => {
  const { shouldRevealRecoveredCard } = await import('../src/domain/flashback-recovery.ts')
  assert.equal(shouldRevealRecoveredCard(null, 'a', false), true)
  assert.equal(shouldRevealRecoveredCard('a', 'a', false), false)
  assert.equal(shouldRevealRecoveredCard('a', 'b', false), true)
  assert.equal(shouldRevealRecoveredCard(null, 'a', true), false)
})

// 场次页视角（死循环回归）：场次页曾自带一套判定，把「已登录未匹配」当成未登录，
// 给已登录用户显示「登录后我们帮你找」+ 登录按钮 → 登录 → 回跳仍未匹配 → 再登录，
// 每圈都消耗登录限流额度。失败方式：未匹配给 login 引导；未登录落错误页；
// 查找失败被当成未匹配；已绑定但不在本场被当成未匹配。
test('场次页视角：只有未登录才引导登录，已登录未匹配给找回说明', async () => {
  const { eventView } = await import('../src/domain/flashback-recovery.ts')
  const archive = { key: '2014-01-11-bj' } as FlashbackCapsule['archives'][number]
  const bound = { ...capsule, archives: [archive], futureEvents: [] } as FlashbackCapsule
  assert.deepEqual(eventView({ kind: 'checking', generation: 1 }, archive.key), { kind: 'loading' })
  assert.deepEqual(eventView({ kind: 'guest', generation: 1 }, archive.key), { kind: 'viewer', guide: 'login' })
  assert.deepEqual(eventView({ kind: 'unmatched', generation: 1 }, archive.key), { kind: 'viewer', guide: 'recover' })
  assert.deepEqual(eventView({ kind: 'error', generation: 1 }, archive.key), { kind: 'error' })
  assert.deepEqual(eventView({ kind: 'member', generation: 1, capsule: bound, token: null }, archive.key), { kind: 'member', archive, futureEvents: [] })
  assert.deepEqual(eventView({ kind: 'member', generation: 1, capsule: bound, token: null }, 'other-key'), { kind: 'viewer', guide: null })
})

// #933：相册对所有已登录用户开放。失败方式：已登录无档案仍只给统计；未登录停在页面上
// 给登录按钮（应直接去登录页）；登录回跳丢掉场次 key。
test('场次页相册来源：有档案 → 胶囊；已登录无档案 → 相册读面；未登录 → 跳登录', async () => {
  const { eventAlbumSource, eventLoginUrl } = await import('../src/domain/flashback-recovery.ts')
  assert.equal(eventAlbumSource({ kind: 'member', archive: {} as never, futureEvents: [] }), 'capsule')
  assert.equal(eventAlbumSource({ kind: 'viewer', guide: 'recover' }), 'archives')
  assert.equal(eventAlbumSource({ kind: 'viewer', guide: 'login' }), 'login')
  assert.equal(eventAlbumSource({ kind: 'viewer', guide: null }), 'none')
  assert.equal(eventAlbumSource({ kind: 'loading' }), 'none')
  assert.equal(eventAlbumSource({ kind: 'error' }), 'none')
  assert.equal(
    eventLoginUrl('2014-01-11-bj'),
    '/pages/login/index?returnUrl=' + encodeURIComponent('/pages/flashback-event/index?key=2014-01-11-bj')
  )
})
