import assert from 'node:assert/strict'
import test from 'node:test'
import { groupEnrollmentsByTarget } from '../src/domain/enrollment-group.ts'
import type { ContentKind, EnrollmentStatus, EnrollmentSummary } from '../src/domain/models.ts'

// #411 我的报名折叠：同 (kind, targetId) 多条记录按组聚合，最新条主卡片、
// 其余进只读历史区。组内/组间均按 insertedAt desc。

function enrollment(
  id: string,
  kind: ContentKind,
  targetId: string,
  insertedAt: string,
  status: EnrollmentStatus = 'confirmed'
): EnrollmentSummary {
  return {
    id,
    workspaceId: 'ws-1',
    targetId,
    kind,
    title: `title-${id}`,
    status,
    approvalDeadline: null,
    rejectionReason: null,
    insertedAt
  }
}

test('同目标多条折叠：最新条为 latest，其余按 insertedAt desc 进 history', () => {
  const groups = groupEnrollmentsByTarget([
    enrollment('e-old', 'event', 'evt-1', '2026-08-01T10:00:00Z', 'rejected'),
    enrollment('e-mid', 'event', 'evt-1', '2026-08-05T10:00:00Z', 'rejected'),
    enrollment('e-new', 'event', 'evt-1', '2026-08-10T10:00:00Z', 'pending')
  ])

  assert.equal(groups.length, 1)
  assert.equal(groups[0].latest.id, 'e-new')
  assert.deepEqual(groups[0].history.map(({ id }) => id), ['e-mid', 'e-old'])
})

test('单条组原样：history 为空', () => {
  const groups = groupEnrollmentsByTarget([
    enrollment('e-1', 'course', 'crs-1', '2026-08-03T10:00:00Z')
  ])

  assert.equal(groups.length, 1)
  assert.equal(groups[0].latest.id, 'e-1')
  assert.deepEqual(groups[0].history, [])
})

test('同 targetId 不同 kind 不混组（event 与 course 各自成组）', () => {
  const groups = groupEnrollmentsByTarget([
    enrollment('ev', 'event', 'same-id', '2026-08-02T10:00:00Z'),
    enrollment('cs', 'course', 'same-id', '2026-08-01T10:00:00Z')
  ])

  assert.equal(groups.length, 2)
  const byKind = new Map(groups.map((g) => [g.latest.kind, g]))
  assert.equal(byKind.get('event')?.latest.id, 'ev')
  assert.equal(byKind.get('course')?.latest.id, 'cs')
})

test('组间顺序 = 各组最新条 insertedAt desc（含输入乱序）', () => {
  const groups = groupEnrollmentsByTarget([
    enrollment('a-old', 'event', 'evt-a', '2026-08-01T10:00:00Z'),
    enrollment('b-new', 'event', 'evt-b', '2026-08-09T10:00:00Z'),
    enrollment('a-new', 'event', 'evt-a', '2026-08-05T10:00:00Z'),
    enrollment('c-new', 'event', 'evt-c', '2026-08-07T10:00:00Z')
  ])

  assert.deepEqual(groups.map((g) => g.latest.id), ['b-new', 'c-new', 'a-new'])
  assert.deepEqual(groups[2].history.map(({ id }) => id), ['a-old'])
})

test('空列表 → 空分组', () => {
  assert.deepEqual(groupEnrollmentsByTarget([]), [])
})
