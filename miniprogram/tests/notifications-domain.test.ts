import test from 'node:test'
import assert from 'node:assert/strict'
import { notificationRoute, mergeNotifications, retainedNotifications } from '../src/domain/notifications.ts'

const row = { id: 'a', type: 'event_reminder', title: '开始提醒', body: '活动即将开始', createdAt: '2026-09-04T12:00:00.000Z', readAt: null, deepLink: null }
test('30-day cutoff excludes the exact boundary', () => {
  assert.deepEqual(retainedNotifications([row, { ...row, id: 'b', createdAt: '2026-09-04T12:00:00.001Z' }], Date.parse('2026-10-04T12:00:00.000Z')).map(r => r.id), ['b'])
})
test('safe notification routes enforce exact pages and parameter shapes', () => {
  assert.deepEqual(notificationRoute('/pages/my-enrollments/index', 'tt'), { method: 'switchTab', url: '/pages/my-enrollments/index' })
  assert.equal(notificationRoute('/pages/workspace/index', 'xhs'), null)
  for (const link of ['https://evil', '//evil', '/pages/login/index', '/pages/my-enrollments/index?token=secret', '/pages/event-detail/index?id=bad', '/pages/my-enrollments/index#claim']) assert.equal(notificationRoute(link, 'wechat'), null)
  assert.deepEqual(notificationRoute('/pages/event-detail/index?id=1ac8d8d6-4c3c-4f61-9364-6a4eb80ee23a', 'wechat'), { method: 'navigateTo', url: '/pages/event-detail/index?id=1ac8d8d6-4c3c-4f61-9364-6a4eb80ee23a' })
})
test('pagination de-duplicates IDs and cannot undo an acknowledged server read', () => {
  const read = { ...row, readAt: '2026-10-04T10:00:00Z' }
  assert.deepEqual(mergeNotifications([read], [row, { ...row, id: 'b' }]), [read, { ...row, id: 'b' }])
})

test('a new acceptance generation with the same source ID does not inherit read state', () => {
  const previous = { ...row, readAt: '2026-09-04T12:01:00Z' }
  const regenerated = { ...row, createdAt: '2026-10-05T12:00:00Z' }
  assert.deepEqual(mergeNotifications([previous], [regenerated]), [regenerated])
})
