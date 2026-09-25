import { beforeEach, expect, test, vi } from 'vitest'
import { emptyWishDraft } from '../src/domain/wish-writing'
import { readWishDraft, saveWishDraft, prepareWishLogin, receiveWishDraft, clearWishDraft } from '../src/state/wishDraft'
const storage = vi.hoisted(() => new Map<string, unknown>())
vi.mock('@tarojs/taro', () => ({ default: {
  getStorageSync: (key: string) => storage.get(key),
  setStorageSync: (key: string, value: unknown) => storage.set(key, value),
  removeStorageSync: (key: string) => storage.delete(key)
} }))
beforeEach(() => storage.clear())
test('取消登录保留游客草稿；成功交接一次后不复活游客副本', () => {
  const draft = { ...emptyWishDraft('once'), content: '愿望', visibility: 'private' as const }
  prepareWishLogin(null, draft)
  expect(receiveWishDraft(null)).toEqual(draft)
  expect(receiveWishDraft('a', 'once')).toEqual(draft)
  expect(readWishDraft(null).content).toBe('')
  clearWishDraft('a')
  expect(receiveWishDraft('a', 'once').content).toBe('')
})
test('过期账号重登时不将私密草稿交给另一个账号', () => {
  const draft = { ...emptyWishDraft('a-request'), content: 'A 的私密草稿' }
  prepareWishLogin('a', draft)
  expect(receiveWishDraft('b', 'a-request').content).toBe('')
  expect(readWishDraft('a')).toEqual(draft)
  expect(readWishDraft(null).content).toBe('')
  expect(receiveWishDraft('a', 'a-request')).toEqual(draft)
})
test('常规切换账号不读取别人的草稿；损坏缓存不会进入提交', () => {
  saveWishDraft('a', { ...emptyWishDraft('a'), content: '账号 A' })
  saveWishDraft('b', { ...emptyWishDraft('b'), content: '账号 B' })
  expect(receiveWishDraft('a').content).toBe('账号 A')
  expect(receiveWishDraft('b').content).toBe('账号 B')
  storage.set('cgc.wish-draft.guest', { content: '损坏', visibility: 'invalid' })
  expect(readWishDraft(null).content).toBe('')
})
