import assert from 'node:assert/strict'
import test from 'node:test'
import { webLoginEntry, canConfirmWebLogin } from '../src/domain/web-login.ts'
import { resolveEntry } from '../src/domain/share-route.ts'
const id = 'abcdefghijklmnopqrstuv'
test('only the dedicated WeChat entry accepts a login request', () => {
  assert.equal(webLoginEntry('pages/web-login/index', { scene: `wl_${id}` }, 'wechat'), id)
  assert.equal(webLoginEntry('pages/web-login/index', { cq: `wl_${id}` }, 'wechat'), id)
  assert.equal(webLoginEntry('pages/web-login/index', { requestId: id, $taroTimestamp: '123' }, 'wechat'), id)
  assert.equal(webLoginEntry('pages/web-login/index', { scene: `wl_${id}` }, 'xhs'), null)
  assert.equal(webLoginEntry('pages/join/index', { scene: `wl_${id}` }, 'wechat'), null)
  assert.equal(webLoginEntry('pages/web-login/index', { scene: `wl_${id}`, cq: 'wl_xxxxxxxxxxxxxxxxxxxxxx' }, 'wechat'), null)
  assert.equal(webLoginEntry('pages/web-login/index', { scene: `wl_${id}`, shareId: 'other' }, 'wechat'), null)
})
test('login scene is not persisted as an invitation on cold or warm start', () => {
  const cold = resolveEntry({ path: 'pages/web-login/index', query: { scene: `wl_${id}` } }, [], 'wechat')
  assert.equal(cold.scene, null)
  assert.equal(cold.navigate, false)
  const warm = resolveEntry({ path: 'pages/web-login/index', query: { cq: `wl_${id}` } }, [{ route: 'pages/discover/index' }], 'wechat')
  assert.equal(warm.scene, null)
  assert.equal(warm.url, `/pages/web-login/index?requestId=${id}`)
  assert.equal(warm.navigate, true)
})
test('warm same-page new request resets, malformed login cannot become invitation', () => {
  const result = resolveEntry({ path: 'pages/web-login/index', query: { scene: `wl_${id}` } }, [{ route: 'pages/web-login/index', options: { requestId: 'xxxxxxxxxxxxxxxxxxxxxx' } }], 'wechat')
  assert.equal(result.navigate, true)
  const bad = resolveEntry({ path: 'pages/web-login/index', query: { scene: 'invitation' } }, [], 'wechat')
  assert.equal(bad.scene, null)
  const same = resolveEntry({ path: 'pages/web-login/index', query: { scene: `wl_${id}` } }, [{ route: 'pages/web-login/index', options: { scene: `wl_${id}` } }], 'wechat')
  assert.equal(same.navigate, false)
  const wrongPath = resolveEntry({ path: 'pages/join/index', query: { scene: `wl_${id}` } }, [], 'wechat')
  assert.equal(wrongPath.scene, null)
})
test('expiry and authentication gate confirmation without submitting automatically', () => {
  const request = { status: 'PENDING' as const, expiresAt: '2026-10-01T00:00:00Z' }
  const now = Date.parse('2026-09-30T00:00:00Z')
  assert.equal(canConfirmWebLogin(request, true, now), true)
  assert.equal(canConfirmWebLogin(request, false, now), false)
  assert.equal(canConfirmWebLogin(request, true, Date.parse(request.expiresAt)), false)
  assert.equal(canConfirmWebLogin({ ...request, status: 'CONSUMED' }, true, now), false)
})
