import assert from 'node:assert/strict'
import test from 'node:test'
import {
  canManageMembers,
  checkInCodeText,
  enrollmentBadgeText,
  enrollmentBlockedNotice,
  enrollmentHistoryTimeText,
  enrollmentMetricText,
  enrollmentScheduleText,
  enrollmentVenueText,
  formatDateTime,
  isUrgent,
  moderatorNames,
  parseEnrollmentBadge,
  parseEnrollmentPolicy,
  parseEnrollmentStatus,
  remainingLabel,
  scheduleText,
  venueCityDistrictText,
  venueText
} from '../src/domain/format.ts'
import type { CatalogItem } from '../src/domain/models.ts'


test('公开主理人投影回退链（#538）：displayName 优先，null/空串回退 memberNumber', () => {
  assert.deepEqual(
    moderatorNames([
      JSON.stringify({ display_name: '张三', member_number: 'CGC-000001' }),
      JSON.stringify({ display_name: null, member_number: 'CGC-000002' }),
      JSON.stringify({ display_name: '', member_number: 'CGC-000003' })
    ]),
    ['张三', 'CGC-000002', 'CGC-000003']
  )
})

test('公开主理人投影脏数据收窄（#538）：null/非 JSON/行结构非法 → 空或丢弃', () => {
  assert.deepEqual(moderatorNames(null), [])
  assert.deepEqual(moderatorNames(undefined), [])
  assert.deepEqual(moderatorNames([]), [])
  assert.deepEqual(moderatorNames(['not-json']), [])
  // 有 displayName 的行缺 member_number 仍合法；两标识皆缺才丢弃
  assert.deepEqual(
    moderatorNames([
      'not-json',
      JSON.stringify({ display_name: null }),
      JSON.stringify({ display_name: '李四' }),
      JSON.stringify({ display_name: null, member_number: 'CGC-000004' })
    ]),
    ['李四', 'CGC-000004']
  )
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

// ── #617：「我的报名」卡片时间/地点行（改期/开课提醒的权威落点）──

test('#617 时间行：event「活动时间」/ course「开课时间」，格式与 formatDateTime 逐字一致', () => {
  const start = '2026-09-20T07:00:00Z'
  // 时区纪律：期望值由被测的 formatDateTime 现算（与 scheduleText 用例同款），
  // 不写死本地时区字面量 → TZ=UTC 与 TZ=Asia/Shanghai 双跑同绿
  assert.equal(enrollmentScheduleText('event', start), `活动时间：${formatDateTime(start)}`)
  assert.equal(enrollmentScheduleText('course', start), `开课时间：${formatDateTime(start)}`)
})

test('#617 时间行负向：无 startsAt（时间待定）→ null，调用方不渲染空行', () => {
  assert.equal(enrollmentScheduleText('event', null), null)
  assert.equal(enrollmentScheduleText('course', null), null)
  assert.equal(enrollmentScheduleText('event', ''), null)
})

test('#617 地点行：入参是后端已文本化的 city+district，原样展示（不做 JSON 解析）', () => {
  // 契约形态来自后端：Enrollment.venue = Venue.text/1 结果（见
  // backend/test/cgc_2046_web/graphql_enrollment_my_query_test.exs 断言 "杭州市西湖区"）
  assert.equal(enrollmentVenueText('杭州市西湖区'), '地点：杭州市西湖区')
  assert.equal(enrollmentVenueText('北京市海淀区'), '地点：北京市海淀区')
  // 负向：null / 空串 / 全空白 / 非字符串 → null（卡面无值即无行，不编造「地点待定」）
  assert.equal(enrollmentVenueText(null), null)
  assert.equal(enrollmentVenueText(''), null)
  assert.equal(enrollmentVenueText('   '), null)
  assert.equal(enrollmentVenueText(undefined as unknown as string), null)
  // 关键回归：JsonString（CatalogItem.venue 那种形态）**不是**本字段的形态——
  // 之前误用 venueText 严格四键解析会让真机永远渲染不出地点行（mock 用 JsonString
  // 冒充文本，测试全绿而线上空白）。此处钉死「不做 JSON 解析」。
  assert.equal(
    enrollmentVenueText('{"country":"中国","province":"浙江省","city":"杭州市","district":"西湖区"}'),
    '地点：{"country":"中国","province":"浙江省","city":"杭州市","district":"西湖区"}'
  )
})

test('#617 venueCityDistrictText 镜像 Venue.text/1：city+district 拼接、nil 段跳过、空串 → null', () => {
  const raw = (o: Record<string, unknown>) => JSON.stringify(o)
  assert.equal(venueCityDistrictText(raw({ city: '杭州市', district: '西湖区' })), '杭州市西湖区')
  // 缺 district（nil 段跳过，无分隔符）
  assert.equal(venueCityDistrictText(raw({ city: '杭州市', district: null })), '杭州市')
  assert.equal(venueCityDistrictText(raw({ city: null, district: '西湖区' })), '西湖区')
  // 两端皆空串 → "" → null（Venue.text/1 的 "" 分支）
  assert.equal(venueCityDistrictText(raw({ city: '', district: '' })), null)
  // 非 map / 非法 JSON / 非字符串 → null
  assert.equal(venueCityDistrictText(raw(['线上'])), null)
  assert.equal(venueCityDistrictText('线上'), null)
  assert.equal(venueCityDistrictText(null), null)
})

test('#617 历史行文案：明示「报名于 <insertedAt>」，与主卡片「活动时间」不混读', () => {
  const insertedAt = '2026-09-01T08:00:00Z'
  assert.equal(enrollmentHistoryTimeText(insertedAt), `报名于 ${formatDateTime(insertedAt)}`)
  // 前缀存在是防混读的判据本身（裸时间串会被误当活动时间）
  assert.match(enrollmentHistoryTimeText(insertedAt), /^报名于 /)
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

test('报名门缴费门（P0 小红书止血，D1a）：xhs 收费/押金场置灰为中性说明，其余端不拦', () => {
  const paid = { status: 'open', endsAt: null, enrollmentBadge: 'enrolling', pricingEnabled: true, depositEnabled: false } as CatalogItem
  const deposit = { status: 'open', endsAt: null, enrollmentBadge: 'enrolling', pricingEnabled: false, depositEnabled: true, depositAmountCents: 6900 } as CatalogItem
  const free = { status: 'open', endsAt: null, enrollmentBadge: 'enrolling', pricingEnabled: false, depositEnabled: false } as CatalogItem

  // xhs：收费/押金场阻断为中性文案（详情可看，不出现去网页端的引导）；
  // 免费场不受影响
  assert.equal(enrollmentBlockedNotice(paid, 'xhs'), '本端暂未开放缴费报名')
  assert.equal(enrollmentBlockedNotice(deposit, 'xhs'), '本端暂未开放缴费报名')
  assert.equal(enrollmentBlockedNotice(free, 'xhs'), null)

  // wechat/tt 维持现状（缴费门只在小红书生效；tt 的既有文案/路径不变）
  assert.equal(enrollmentBlockedNotice(paid, 'wechat'), null)
  assert.equal(enrollmentBlockedNotice(paid, 'tt'), null)
  assert.equal(enrollmentBlockedNotice(deposit, 'tt'), null)

  // 状态门优先于缴费门：已截止的收费场仍是截止文案（xhs 也不例外）
  const closedPaid = { status: 'open', endsAt: null, enrollmentBadge: 'closed', pricingEnabled: true, depositEnabled: false } as CatalogItem
  assert.equal(enrollmentBlockedNotice(closedPaid, 'xhs'), '报名已截止，不再接受新的报名。')

  // 不传平台（调用方缺省）= 全量端口径，不拦缴费
  assert.equal(enrollmentBlockedNotice(paid), null)
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
