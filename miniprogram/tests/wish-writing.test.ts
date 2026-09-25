import test from 'node:test'
import assert from 'node:assert/strict'
import { emptyWishDraft, editWishDraft, wishDraftKey, transferWishDraft, wishValidation, wishStatusCopy, wishWriteReturnUrl } from '../src/domain/wish-writing.ts'

test('编辑生成新请求号；原样重试保持请求号与可见性', () => {
  const first = emptyWishDraft('one')
  const typed = editWishDraft(first, { content: '一起写作品', city: '成都', visibility: 'private' }, 'two')
  assert.equal(typed.requestId, 'two')
  assert.deepEqual(editWishDraft(typed, { content: typed.content }, 'three'), typed)
  assert.equal(typed.visibility, 'private')
})
test('草稿按账号隔离；只有显式登录交接能接走游客草稿', () => {
  const draft = emptyWishDraft('guest-request')
  assert.notEqual(wishDraftKey(null), wishDraftKey('account-a'))
  assert.notEqual(wishDraftKey('account-a'), wishDraftKey('account-b'))
  assert.equal(transferWishDraft(draft, null, 'a', null), null)
  assert.deepEqual(transferWishDraft(draft, null, 'a', 'guest-request'), draft)
  assert.equal(transferWishDraft(draft, 'a', 'b', 'guest-request'), null)
  assert.equal(transferWishDraft(draft, null, null, 'guest-request'), null)
  assert.equal(transferWishDraft(draft, null, 'a', 'old-key'), null)
  assert.ok(wishWriteReturnUrl('guest-request').includes('transfer=guest-request'))
})
test('提交校验：正文、城市、额度；游客先写不要求历史档案', () => {
  const draft = { ...emptyWishDraft('one'), content: '愿望', city: '成都' }
  assert.equal(wishValidation(draft, null), '')
  assert.equal(wishValidation(draft, 2), '')
  assert.match(wishValidation(draft, 0), /用完/)
  assert.match(wishValidation({ ...draft, city: '' }, 2), /城市/)
  assert.match(wishValidation({ ...draft, content: '字'.repeat(501) }, 2), /500/)
  assert.match(wishValidation({ ...draft, content: '  ' }, 2), /愿望/)
})
test('提交反馈准确区分公开、待审和私密；未知状态不假装公开', () => {
  assert.equal(wishStatusCopy('listed'), '已公开')
  assert.equal(wishStatusCopy('pending_review'), '待审核')
  assert.equal(wishStatusCopy('private'), '仅自己和主办方可见')
  assert.equal(wishStatusCopy('unexpected'), '状态待确认')
})
