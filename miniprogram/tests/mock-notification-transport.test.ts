import test from 'node:test'
import assert from 'node:assert/strict'

// Dynamic imports intentionally exercise a new module instance after client reload; static imports reuse the same in-memory mock server.
test('mock server read state survives client reload and remains account private', async () => {
  const storage = new Map<string, unknown>()
  const runtime = globalThis as typeof globalThis & { wx?: unknown }
  runtime.wx = { getStorageSync: (key: string) => storage.get(key) ?? '', setStorageSync: (key: string, value: unknown) => storage.set(key, value) }
  try {
    const first = await import('../src/api/mockTransport.ts?inbox-first')
    first.mockGraphQLRequest('mutation SignInWithPlatform', {})
    storage.set('cgc.auth_token', 'e2e-mock-token')
    const feed = first.mockGraphQLRequest<{ notificationFeed: { results: Array<{ id: string; readAt: string | null }> } }>('query NotificationFeed', { first: 20 }).notificationFeed.results
    const id = feed[0].id
    const marked = first.mockGraphQLRequest<{ markNotificationRead: { result: { readAt: string } } }>('mutation MarkNotificationRead', { id }).markNotificationRead.result.readAt
    const reloaded = await import('../src/api/mockTransport.ts?inbox-reload')
    assert.equal(reloaded.mockGraphQLRequest<{ me: { id: string } | null }>('query Session', {}).me?.id, 'user-1')
    const history = reloaded.mockGraphQLRequest<{ notificationFeed: { results: Array<{ id: string; readAt: string | null }> } }>('query NotificationFeed', { first: 20 }).notificationFeed.results
    assert.equal(history.find(row => row.id === id)?.readAt, marked)
    storage.set('cgc.e2e.notification_account_b', '1')
    const b = reloaded.mockGraphQLRequest<{ notificationFeed: { results: Array<{ id: string }> } }>('query NotificationFeed', { first: 20 }).notificationFeed.results
    assert.equal(b.some(row => row.id === id), false)
    const denied = reloaded.mockGraphQLRequest<{ markNotificationRead: { result: null; errors: Array<{ code: string }> } }>('mutation MarkNotificationRead', { id }).markNotificationRead
    assert.equal(denied.result, null)
    assert.equal(denied.errors[0].code, 'not_found')
  } finally { delete runtime.wx }
})
