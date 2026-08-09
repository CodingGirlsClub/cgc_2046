import assert from 'node:assert/strict'
import test from 'node:test'
import {
  canManageMembers,
  isUrgent,
  parseEnrollmentPolicy,
  parseEnrollmentStatus,
  remainingLabel,
  schemaFieldsFromJson
} from '../src/domain/format.ts'

test('schema JSON 按 key-value 生成稳定展示字段', () => {
  assert.deepEqual(schemaFieldsFromJson('{"audience":"零基础","sections":["介绍","练习"]}'), [
    { key: 'audience', label: '适合人群', value: '零基础' },
    { key: 'sections', label: '内容安排', value: '介绍、练习' }
  ])
})

test('无效 JSON 降级为可读详情，不丢内容', () => {
  assert.deepEqual(schemaFieldsFromJson('组织者补充说明'), [
    { key: 'details', label: '详情', value: '组织者补充说明' }
  ])
})

test('审批倒计时和 24 小时紧急阈值一致', () => {
  const now = Date.parse('2026-08-09T00:00:00Z')
  const deadline = '2026-08-09T12:30:00Z'
  assert.equal(remainingLabel(deadline, now), '12 小时 30 分钟')
  assert.equal(isUrgent(deadline, now), true)
  assert.equal(isUrgent('2026-08-10T12:30:00Z', now), false)
})

test('审批操作只对 manage_members ability 开放', () => {
  assert.equal(canManageMembers(['view_workspace']), false)
  assert.equal(canManageMembers(['view_workspace', 'manage_members']), true)
})

test('GraphQL 枚举值按领域合同 fail-closed', () => {
  assert.equal(parseEnrollmentPolicy('invite_only'), 'invite_only')
  assert.equal(parseEnrollmentStatus('expired'), 'expired')
  assert.throws(() => parseEnrollmentPolicy('legacy'), /未知报名策略/)
  assert.throws(() => parseEnrollmentStatus('legacy'), /未知报名状态/)
})
