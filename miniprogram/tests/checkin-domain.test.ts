import assert from 'node:assert/strict'
import test from 'node:test'
import { buildCheckInPayload, parseCheckInScan, CHECK_IN_PAYLOAD_PREFIX } from '../src/domain/checkin.ts'

// #508 选项 A：核销 QR payload（自定义格式，非 URL）的生成与解析。
// 解析器兼容：新 payload / PR #548 遗留 web 相对路径 QR / 裸 6 位码（手输）。

const EVENT_ID = 'a8c1f4e2-7b3d-4e5f-9a6b-1c2d3e4f5a6b'
const CODE = '042317'

test('build/parse 往返：新 payload 提取 eventId 与 code', () => {
  const payload = buildCheckInPayload(EVENT_ID, CODE)
  assert.equal(payload, `${CHECK_IN_PAYLOAD_PREFIX}${EVENT_ID}:${CODE}`)
  assert.deepEqual(parseCheckInScan(payload), { code: CODE, eventId: EVENT_ID })
})

test('新 payload：非 UUID 的 eventId（mock 数据形态）同样接受', () => {
  assert.deepEqual(parseCheckInScan(buildCheckInPayload('event-1', CODE)), {
    code: CODE,
    eventId: 'event-1'
  })
})

test('遗留 web QR（slug 段）：提取 code，eventId 为 null 走页面上下文', () => {
  const legacy = `/events/paid-event/check-in?code=${CODE}`
  assert.deepEqual(parseCheckInScan(legacy), { code: CODE, eventId: null })
})

test('遗留 web QR（UUID 段 + locale 前缀 + 多余参数）：code 与 eventId 双提取', () => {
  const legacy = `/en/events/${EVENT_ID}/check-in?from=qr&code=${CODE}&x=1`
  assert.deepEqual(parseCheckInScan(legacy), { code: CODE, eventId: EVENT_ID })
})

test('裸码手输：剥空白与连字符（「123 456」「123-456」习惯输入）', () => {
  assert.deepEqual(parseCheckInScan('123 456'), { code: '123456', eventId: null })
  assert.deepEqual(parseCheckInScan('123-456'), { code: '123456', eventId: null })
  assert.deepEqual(parseCheckInScan(` ${CODE} `), { code: CODE, eventId: null })
})

test('前导零保留：码按字符串处理，绝不转数字', () => {
  const parsed = parseCheckInScan(buildCheckInPayload(EVENT_ID, '000001'))
  assert.equal(parsed?.code, '000001')
})

test('无法识别的输入返回 null（本地提示，不消耗后端失败节流计数）', () => {
  for (const raw of [
    '',
    '   ',
    'hello',
    '12345', // 5 位
    '1234567', // 7 位
    'abcdef',
    CHECK_IN_PAYLOAD_PREFIX, // 空前缀体
    `${CHECK_IN_PAYLOAD_PREFIX}:${CODE}`, // 空 eventId
    `${CHECK_IN_PAYLOAD_PREFIX}${EVENT_ID}:`, // 空 code
    `${CHECK_IN_PAYLOAD_PREFIX}${EVENT_ID}:12345`,
    `/events/x/check-in?code=12345`, // 遗留格式但码位数不对
    `/check-in?code=${CODE}` // 无 events 段
  ]) {
    assert.equal(parseCheckInScan(raw), null, `应拒绝：${JSON.stringify(raw)}`)
  }
})

test('null/undefined 输入返回 null', () => {
  assert.equal(parseCheckInScan(null), null)
  assert.equal(parseCheckInScan(undefined), null)
})
