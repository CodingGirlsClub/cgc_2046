import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import {
  RETRACT_COPY,
  DELETE_COPY,
  DELETE_CONFIRM_WORD,
  canRetract,
  canSubmitDelete,
  deleteFacts
} from '../src/domain/flashback-retract.ts'

// 失败方式：未寄出也给撤下入口；DELETE 大小写/空格宽松放行；删除摘要漏掉附议数；
// 小程序与 web 文案各改各的（撤下 / 删除是同一个动作，两端必须逐字一致）。
const web = JSON.parse(readFileSync(new URL('../../web/messages/zh-CN.json', import.meta.url), 'utf8')).flashback

test('撤下入口只在已寄出时出现', () => {
  assert.equal(canRetract({ today: { sentToWallAt: '2026-09-26T00:00:00Z' } }), true)
  assert.equal(canRetract({ today: { sentToWallAt: null } }), false)
  assert.equal(canRetract({ today: null }), false)
})

test('删除确认词必须逐字等于 DELETE，提交中不可重复提交', () => {
  assert.equal(DELETE_CONFIRM_WORD, 'DELETE')
  assert.equal(canSubmitDelete('DELETE', false), true)
  for (const input of ['delete', ' DELETE', 'DELETE ', '', 'DELET']) assert.equal(canSubmitDelete(input, false), false, input)
  assert.equal(canSubmitDelete('DELETE', true), false)
})

test('删除摘要：档案名 + 寄出态 + 附议数', () => {
  assert.deepEqual(deleteFacts({ fullName: '王小明', sentToWallAt: '2026-09-26T00:00:00Z', endorsementCount: 2 }), [
    '档案：王小明',
    '已寄出到校友墙；你的 2 条许愿附议与留言将一并删除'
  ])
  assert.deepEqual(deleteFacts({ fullName: '王小明', sentToWallAt: null, endorsementCount: 0 }), [
    '档案：王小明',
    '尚未寄出；你的 0 条许愿附议与留言将一并删除'
  ])
})

test('文案与 web 逐字一致（撤下 todaySlot.retract* / 删除 delete.*）', () => {
  assert.equal(RETRACT_COPY.title, web.todaySlot.retractTitle)
  assert.equal(RETRACT_COPY.body, web.todaySlot.retractBody)
  assert.equal(RETRACT_COPY.confirm, web.todaySlot.retractConfirm)
  assert.equal(RETRACT_COPY.cancel, web.todaySlot.retractCancel)
  assert.equal(RETRACT_COPY.error, web.todaySlot.retractError)
  for (const key of ['title', 'warning', 'error', 'confirmLabel', 'submit', 'cancel', 'doneTitle', 'doneBody'] as const) {
    assert.equal(DELETE_COPY[key], web.delete[key], key)
  }
  const facts = deleteFacts({ fullName: 'N', sentToWallAt: 'x', endorsementCount: 3 })
  assert.equal(facts[0], web.delete.factsName.replace('{name}', 'N'))
  assert.equal(facts[1], web.delete.factsOnWall.replace('{count}', '3'))
  assert.equal(deleteFacts({ fullName: 'N', sentToWallAt: null, endorsementCount: 3 })[1], web.delete.factsOffWall.replace('{count}', '3'))
})
