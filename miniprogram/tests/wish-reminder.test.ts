import assert from 'node:assert/strict'
import test from 'node:test'
import { endorseWithReminder, requestWishReminder, reminderReceipt } from '../src/domain/wish-reminder.ts'

for (const mode of ['accepted', 'denied', 'request-error', 'grant-error', 'off'] as const) {
  test(`endorsement survives reminder ${mode}, grants only actual acceptance`, async () => {
    const calls: string[] = []
    const result = await endorseWithReminder(mode !== 'off', {
      request: async () => { calls.push('request'); if (mode === 'request-error') throw Error('provider unavailable'); return mode === 'denied' ? [] : ['flashback_wish_echo'] },
      grant: async () => { calls.push('grant'); if (mode === 'grant-error') throw Error('network down') },
      save: async () => { calls.push('save') }
    })
    assert.equal(calls.at(-1), 'save')
    assert.equal(calls.filter(c => c === 'save').length, 1)
    assert.equal(calls.includes('grant'), ['accepted', 'grant-error'].includes(mode))
    assert.equal(result.kind, mode.endsWith('error') ? 'error' : mode)
    const receipt = reminderReceipt(result)
    assert.equal(receipt.canRetry, ['denied', 'request-error', 'grant-error'].includes(mode))
    assert.ok(receipt.copy.includes('已保存'))
    assert.ok(!receipt.copy.includes('provider unavailable'))
    if (mode === 'accepted') assert.ok(receipt.copy.includes('不会补发'))
  })
}
test('failed endorsement is not presented as saved', async () => {
  await assert.rejects(endorseWithReminder(false, { request: async () => [], grant: async () => {}, save: async () => { throw Error('save failed') } }), /save failed/)
})
test('retrying reminder performs request/grant only', async () => {
  const calls: string[] = []
  const result = await requestWishReminder({ request: async () => { calls.push('request'); return ['flashback_wish_echo'] }, grant: async () => { calls.push('grant') } })
  assert.deepEqual(calls, ['request', 'grant'])
  assert.equal(result.kind, 'accepted')
  assert.equal(reminderReceipt(result).canRetry, false)
})
