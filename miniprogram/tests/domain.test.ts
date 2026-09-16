import assert from 'node:assert/strict'
import test from 'node:test'
import {
  canManageMembers,
  checkInCodeText,
  enrollmentBadgeText,
  enrollmentBlockedNotice,
  enrollmentMetricText,
  isUrgent,
  parseEnrollmentBadge,
  parseEnrollmentPolicy,
  parseEnrollmentStatus,
  remainingLabel,
  scheduleText,
  venueText
} from '../src/domain/format.ts'
import type { CatalogItem } from '../src/domain/models.ts'


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

test('报名门双门（#574）：open 场按 badge 阻断，归档场按 status 阻断', () => {
  const open = (badge: CatalogItem['enrollmentBadge']): CatalogItem =>
    ({ status: 'open', endsAt: null, enrollmentBadge: badge }) as CatalogItem

  assert.equal(enrollmentBlockedNotice(open('closed')), '报名已截止，不再接受新的报名。')
  assert.equal(enrollmentBlockedNotice(open('full')), '名额已满，不再接受新的报名。')
  assert.equal(enrollmentBlockedNotice(open('enrolling')), null)
  assert.equal(enrollmentBlockedNotice(open('starting_soon')), null)

  // 已取消：截止未过 + 未满员（badge 仍是 enrolling）也必须阻断——register-form
  // 深链与「登录期间被取消」回跳都走这里
  const cancelled = { status: 'cancelled', endsAt: null, enrollmentBadge: 'enrolling' } as CatalogItem
  assert.equal(enrollmentBlockedNotice(cancelled), '活动已取消，仅供查看。')

  // closed 按 endsAt 区分已结束 / 报名已截止（沿用详情页既有文案）
  const ended = { status: 'closed', endsAt: '2020-01-01T00:00:00.000Z', enrollmentBadge: 'enrolling' } as CatalogItem
  const notEnded = { status: 'closed', endsAt: '2099-01-01T00:00:00.000Z', enrollmentBadge: 'enrolling' } as CatalogItem
  assert.equal(enrollmentBlockedNotice(ended), '活动已结束，仅供查看。')
  assert.equal(enrollmentBlockedNotice(notEnded), '报名已截止，仅供查看。')
})

test('详情页报名状态槽：open 用 badge，归档场用状态词（不再显示「报名中」）', () => {
  assert.equal(enrollmentMetricText({ status: 'open', enrollmentBadge: 'enrolling' } as CatalogItem), '报名中')
  assert.equal(enrollmentMetricText({ status: 'open', enrollmentBadge: 'full' } as CatalogItem), '已满')
  assert.equal(enrollmentMetricText({ status: 'cancelled', enrollmentBadge: 'enrolling' } as CatalogItem), '已取消')
  assert.equal(enrollmentMetricText({ status: 'closed', enrollmentBadge: 'enrolling' } as CatalogItem), '已结束')
  assert.equal(enrollmentMetricText({ status: 'draft', enrollmentBadge: 'enrolling' } as CatalogItem), '草稿')
})

// ── U11（R11/KTD5）：报名卡核销码出示 ──

test('核销码出示：仅 confirmed 报名且有码时出「核销码 xxxxxx」（前导零按字符串保留）', () => {
  assert.equal(checkInCodeText('confirmed', '042317'), '核销码 042317')
  assert.equal(checkInCodeText('confirmed', '999999'), '核销码 999999')
  // 未确认态不出示（含 payment_pending：付押金前无码可核）
  assert.equal(checkInCodeText('payment_pending', '042317'), null)
  assert.equal(checkInCodeText('pending', '042317'), null)
  assert.equal(checkInCodeText('cancelled', '042317'), null)
  assert.equal(checkInCodeText('rejected', '042317'), null)
  // 无码（course / 后端门控未给）不出示
  assert.equal(checkInCodeText('confirmed', null), null)
  assert.equal(checkInCodeText('confirmed', ''), null)
})
