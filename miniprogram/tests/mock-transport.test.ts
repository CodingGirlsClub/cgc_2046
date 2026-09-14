import assert from 'node:assert/strict'
import test from 'node:test'
import { mockGraphQLRequest } from '../src/api/mockTransport.ts'
import {
  CatalogQueryDocument,
  CatalogSearchQueryDocument,
  ConfirmEnrollmentMutationDocument,
  CreateEnrollmentMutationDocument,
  CreateOrderMutationDocument,
  EventDetailQueryDocument,
  MyEnrollmentsQueryDocument,
  SignInWithPlatformMutationDocument
} from '../src/api/operations.ts'

interface CatalogResults {
  listEvents: { results: Array<{ id: string; title: string }> }
  listCourses: { results: Array<{ id: string; title: string }> }
}

function searchVariables(pattern: string) {
  return {
    first: 50,
    eventFilter: {
      status: { eq: 'open' },
      visibility: { eq: 'public' },
      title: { ilike: pattern }
    },
    courseFilter: {
      status: { eq: 'open' },
      visibility: { eq: 'public' },
      title: { ilike: pattern }
    }
  }
}

test('mock Catalog 无 filter 变量 → 全量目录（原行为不变）', () => {
  const data = mockGraphQLRequest<CatalogResults>(CatalogQueryDocument, { first: 50 })
  assert.equal(data.listEvents.results.length, 3)
  assert.equal(data.listCourses.results.length, 1)
})

test('mock CatalogSearch：title ilike 过滤，大小写不敏感', () => {
  const data = mockGraphQLRequest<CatalogResults>(CatalogSearchQueryDocument, searchVariables('%python%'))
  assert.deepEqual(data.listEvents.results.map(({ id }) => id), ['event-1'])
  assert.deepEqual(data.listCourses.results, [])
})

test('mock CatalogSearch：中文关键词命中课程', () => {
  const data = mockGraphQLRequest<CatalogResults>(CatalogSearchQueryDocument, searchVariables('%成长%'))
  assert.deepEqual(data.listEvents.results, [])
  assert.deepEqual(data.listCourses.results.map(({ id }) => id), ['course-1'])
})

test('mock CatalogSearch：无命中 → 空结果', () => {
  const data = mockGraphQLRequest<CatalogResults>(CatalogSearchQueryDocument, searchVariables('%不存在的词%'))
  assert.deepEqual(data.listEvents.results, [])
  assert.deepEqual(data.listCourses.results, [])
})

// U11（R10/R11）：押金场样例——详情缴费块与看码链在 mock 上可走通
test('mock 押金场：详情查询带押金字段', () => {
  const data = mockGraphQLRequest<{
    getEvent: { depositEnabled: boolean; depositAmountCents: number | null } | null
  }>(EventDetailQueryDocument, { id: 'event-deposit' })
  assert.equal(data.getEvent?.depositEnabled, true)
  assert.equal(data.getEvent?.depositAmountCents, 6900)
})

test('mock 押金场：报名落 payment_pending（零档位）→ 押金单金额 = 押金 → 核销后仅 confirmed 出码', () => {
  mockGraphQLRequest(SignInWithPlatformMutationDocument, { platform: 'wechat', code: 'mock-login' })

  const created = mockGraphQLRequest<{
    createEnrollment: { result: { status: string; checkInCode: string | null } }
  }>(CreateEnrollmentMutationDocument, { input: { userId: 'user-1', eventId: 'event-deposit' } })
  assert.equal(created.createEnrollment.result.status, 'payment_pending')
  // 付押金前无码可核（KTD5：出示按 confirmed 门控）
  assert.equal(created.createEnrollment.result.checkInCode, null)

  const order = mockGraphQLRequest<{ createOrder: { result: { amountCents: number } } }>(
    CreateOrderMutationDocument,
    { input: { enrollmentId: 'enrollment-1' } }
  )
  assert.equal(order.createOrder.result.amountCents, 6900)

  mockGraphQLRequest(ConfirmEnrollmentMutationDocument, { id: 'enrollment-1' })
  const mine = mockGraphQLRequest<{
    enrollments: { results: Array<{ checkInCode: string | null }> }
  }>(MyEnrollmentsQueryDocument, { userId: 'user-1' })
  assert.equal(mine.enrollments.results[0]?.checkInCode, '042317')
})
