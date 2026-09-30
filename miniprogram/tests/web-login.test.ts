import assert from 'node:assert/strict'
import test from 'node:test'
import { webLoginEntry, canConfirmWebLogin, webLoginCopy } from '../src/domain/web-login.ts'
import { resolveEntry } from '../src/domain/share-route.ts'
import { mockGraphQLRequest } from '../src/api/mockTransport.ts'
import { WebLoginPreviewDocument, WebLoginConfirmDocument } from '../src/api/operations.ts'
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
test('leaving after a lost confirmation response does not claim authorization was cancelled', () => {
  const request = { status: 'PENDING' as const, expiresAt: '2026-10-01T00:00:00Z' }
  const now = Date.parse('2026-09-30T00:00:00Z')
  // The last known preview remains PENDING when the approval response is lost.
  assert.equal(webLoginCopy(request, now, { exited: true, confirmationAttempted: true }),
    '你可能已授权网页登录。退出此页不会撤销授权，请返回原网页查看或取消。')
  assert.equal(webLoginCopy(request, now, { exited: true }),
    '已退出本次确认，请返回原网页查看或取消登录请求。')
})
test('reopening approved or consumed requests never presents them as awaiting confirmation', () => {
  const now = Date.parse('2026-09-30T00:00:00Z')
  const approved = { status: 'APPROVED' as const, expiresAt: '2026-10-01T00:00:00Z' }
  assert.equal(canConfirmWebLogin(approved, true, now), false)
  assert.equal(webLoginCopy(approved, now), '这次网页登录已获授权，请返回原网页查看。')
  assert.equal(webLoginCopy(approved, now, { exited: true }),
    '你可能已授权网页登录。退出此页不会撤销授权，请返回原网页查看或取消。')
  assert.equal(webLoginCopy({ ...approved, status: 'CONSUMED' }, now, { exited: true }),
    '网页版已登录，退出此页不会退出网页版。请返回原网页查看。')
})
test('lost-response E2E fixture commits approval before throwing and exposes it on refresh', () => {
  const variables = { requestId: 'lost_abcdefghijklmnopq' }
  type Preview = { wechatMiniWebLoginPreview: { status: string } }
  assert.equal(mockGraphQLRequest<Preview>(WebLoginPreviewDocument, variables).wechatMiniWebLoginPreview.status, 'PENDING')
  assert.throws(() => mockGraphQLRequest(WebLoginConfirmDocument, variables), /lost approval response/)
  assert.equal(mockGraphQLRequest<Preview>(WebLoginPreviewDocument, variables).wechatMiniWebLoginPreview.status, 'APPROVED')
})

test('page transitions preserve an unknown approval through refresh and local exit', async () => {
  const { transitionWebLoginPage, webLoginPageView } = await import('../src/domain/web-login.ts')
  const request = { status: 'PENDING' as const, expiresAt: '2026-10-01T00:00:00Z' }
  const now = Date.parse('2026-09-30T00:00:00Z')
  const attempted = transitionWebLoginPage('active', { type: 'confirm_started' })
  assert.equal(attempted, 'confirmation_attempted')
  assert.equal(webLoginPageView(request, attempted, now).refreshable, true)
  // A failed network response leaves the attempt fact intact; preview does not reset it.
  const exited = transitionWebLoginPage(attempted, { type: 'exit' })
  const view = webLoginPageView(request, exited, now)
  assert.equal(view.description, '你可能已授权网页登录。退出此页不会撤销授权，请返回原网页查看或取消。')
  assert.equal(view.refreshable, false)
  assert.equal(view.active, false)
  assert.equal(transitionWebLoginPage(exited, { type: 'confirm_received', status: 'APPROVED' }), exited)
})

test('page transitions require approved response and keep confirmed or exited states terminal', async () => {
  const { transitionWebLoginPage, webLoginPageView } = await import('../src/domain/web-login.ts')
  const request = { status: 'PENDING' as const, expiresAt: '2026-10-01T00:00:00Z' }
  const now = Date.parse('2026-09-30T00:00:00Z')
  assert.equal(webLoginPageView(request, 'active', now).title, '登录网页版')
  const attempted = transitionWebLoginPage('active', { type: 'confirm_started' })
  assert.equal(transitionWebLoginPage(attempted, { type: 'confirm_received', status: 'CANCELLED' }), attempted)
  const confirmed = transitionWebLoginPage(attempted, { type: 'confirm_received', status: 'APPROVED' })
  assert.equal(confirmed, 'confirmed')
  assert.equal(transitionWebLoginPage(confirmed, { type: 'exit' }), confirmed)
  assert.deepEqual(webLoginPageView({ ...request, status: 'APPROVED' }, confirmed, now), {
    title: '已确认登录', description: '请返回刚才的网页，网页将自动完成登录。', active: false, refreshable: false
  })
  const exited = transitionWebLoginPage('active', { type: 'exit' })
  assert.equal(webLoginPageView(request, exited, now).description, '已退出本次确认，请返回原网页查看或取消登录请求。')
  assert.equal(transitionWebLoginPage(exited, { type: 'confirm_started' }), exited)
  assert.equal(webLoginPageView({ ...request, status: 'APPROVED' }, 'active', now).active, false)
  assert.equal(webLoginPageView(request, 'active', Date.parse(request.expiresAt)).active, false)
})
