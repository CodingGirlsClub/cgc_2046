import assert from 'node:assert/strict'
import { test } from 'node:test'
import { sendWithQuoteChoice } from '../src/domain/quote-send.ts'

const pick = { questionKey: 'self_intro', start: 8, len: 12 }
const today = { nowStatus: '正在做设计' }

function fixture(fail?: string) {
  const calls: unknown[][] = []
  const call = async (name: string, ...args: unknown[]) => {
    calls.push([name, ...args])
    if (name === fail) throw new Error('测试失败')
  }
  return {
    calls,
    api: {
      flashbackSubmitToday: (...args: unknown[]) => call('today', ...args),
      flashbackSetQuoteLicense: (...args: unknown[]) => call('license', ...args),
      flashbackSendToWall: (...args: unknown[]) => call('send', ...args)
    }
  }
}

test('只寄出到相册：保存今天后寄出，不写授权；token 传给两次请求', async () => {
  const { api, calls } = fixture()
  assert.deepEqual(await sendWithQuoteChoice(api, today, null, 'test-token'), { ok: true, withQuote: false })
  assert.deepEqual(calls, [['today', today, 'test-token'], ['send', 'test-token']])
})

test('明确放句：保存今天、授权当前一句、寄出，使用同一身份', async () => {
  const { api, calls } = fixture()
  assert.deepEqual(await sendWithQuoteChoice(api, today, pick, null), { ok: true, withQuote: true })
  assert.deepEqual(calls, [['today', today, null], ['license', 'anonymous', [pick], null], ['send', null]])
})

test('授权失败暂停寄出，文案说明停在哪一步；可用相同选择重试', async () => {
  const failed = fixture('license')
  const result = await sendWithQuoteChoice(failed.api, today, pick, 'test-token')
  assert.equal(result.ok, false)
  assert.match('message' in result ? result.message : '', /金句授权.*寄出.*暂停/)
  assert.deepEqual(failed.calls.map(([name]) => name), ['today', 'license'])
  const retry = fixture()
  assert.equal((await sendWithQuoteChoice(retry.api, today, pick, 'test-token')).ok, true)
  assert.deepEqual(retry.calls[1], ['license', 'anonymous', [pick], 'test-token'])
})

test('保存今天失败不授权；授权成功但寄出失败明确部分成功', async () => {
  const save = fixture('today')
  assert.equal((await sendWithQuoteChoice(save.api, today, pick, null)).ok, false)
  assert.deepEqual(save.calls.map(([name]) => name), ['today'])
  const send = fixture('send')
  const result = await sendWithQuoteChoice(send.api, today, pick, null)
  assert.match('message' in result ? result.message : '', /金句已授权.*相册.*失败/)
})
