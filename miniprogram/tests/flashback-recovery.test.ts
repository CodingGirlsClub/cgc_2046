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
