import assert from 'node:assert/strict'
import test from 'node:test'
import {
  canManageMembers,
  enrollmentBadgeText,
  isUrgent,
  parseEnrollmentBadge,
  parseEnrollmentPolicy,
  parseEnrollmentStatus,
  enrollmentBlockedNotice,
  remainingLabel,
  scheduleText,
  venueText
} from '../src/domain/format.ts'


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

// ── U7（R15/R3/KTD1）：详情页新字段展示助手 ──

test('时间展示：双全为区间，单值带方向，全空兜底「时间待定」（R3）', () => {
  const start = '2026-08-25T06:00:00Z'
  const end = '2026-08-26T10:00:00Z'
  // 与详情页既有截止日期同款 toLocaleString 惯例；期望值用同一 API 现算，环境无关
  const fmt = (iso: string) => new Date(iso).toLocaleString()
  assert.equal(scheduleText(start, end), `${fmt(start)} - ${fmt(end)}`)
  assert.equal(scheduleText(start, null), `${fmt(start)} 开始`)
  assert.equal(scheduleText(null, end), `${fmt(end)} 结束`)
  assert.equal(scheduleText(null, null), '时间待定')
})

test('venue 严格四键解析：恰四键 string 拼接；缺键/多键/非字符串值/非法输入兜底 null（展示层显「地点待定」，R3）', () => {
  assert.equal(
    venueText('{"country":"中国","province":"北京市","city":"北京","district":"海淀区"}'),
    '中国 北京市 北京 海淀区'
  )
  // 空段跳过、全空兜底（同 web formatVenue）
  assert.equal(
    venueText('{"country":"中国","province":"","city":"杭州","district":""}'),
    '中国 杭州'
  )
  assert.equal(venueText('{"country":"","province":"","city":"","district":""}'), null)
  // 缺键 → null（backend Venue.valid? 恰四键，非子集匹配）
  assert.equal(venueText('{"city":"上海","district":"杨浦区"}'), null)
  // 多键 → null
  assert.equal(
    venueText('{"country":"中国","province":"浙江省","city":"杭州市","district":"西湖区","extra":"x"}'),
    null
  )
  // 四键齐全但值非 string → null
  assert.equal(venueText('{"country":"中国","province":"浙江省","city":1,"district":"西湖区"}'), null)
  assert.equal(venueText('{"country":1,"city":null}'), null)
  assert.equal(venueText(null), null)
  assert.equal(venueText(''), null)
  assert.equal(venueText('not-json'), null)
  assert.equal(venueText('["线上"]'), null)
  // 输入非 string → null
  assert.equal(venueText(123 as unknown as string), null)
})

test('报名标签 fail-closed，展示文案覆盖报名中/即将开始/报名截止/已满', () => {
  assert.equal(parseEnrollmentBadge('enrolling'), 'enrolling')
  assert.equal(parseEnrollmentBadge('starting_soon'), 'starting_soon')
  assert.equal(parseEnrollmentBadge('closed'), 'closed')
  assert.equal(parseEnrollmentBadge('full'), 'full')
  assert.throws(() => parseEnrollmentBadge('legacy'), /未知报名标签/)
  assert.throws(() => parseEnrollmentBadge(null), /未知报名标签/)
  assert.equal(enrollmentBadgeText.enrolling, '报名中')
  assert.equal(enrollmentBadgeText.starting_soon, '即将开始')
  assert.equal(enrollmentBadgeText.closed, '报名截止')
  assert.equal(enrollmentBadgeText.full, '已满')
})

test('closed/full 阻断报名入口，enrolling/starting_soon 不拦截', () => {
  assert.equal(enrollmentBlockedNotice('closed'), '报名已截止，不再接受新的报名。')
  assert.equal(enrollmentBlockedNotice('full'), '名额已满，不再接受新的报名。')
  assert.equal(enrollmentBlockedNotice('enrolling'), null)
  assert.equal(enrollmentBlockedNotice('starting_soon'), null)
})
