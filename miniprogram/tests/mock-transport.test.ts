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
  EnrollmentQueryDocument,
  FlashbackAdjustFogMutationDocument,
  FlashbackCapsuleQueryDocument,
  FlashbackEndorseMutationDocument,
  FlashbackSetQuoteLicenseMutationDocument,
  MyEnrollmentsQueryDocument,
  PublicInitiativeQueryDocument,
  PublicInitiativesQueryDocument,
  SignInWithPlatformMutationDocument,
  SignOutMutationDocument
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

// 阶段1：Initiative 公开投影 fixture——发现页卡片、详情页、event-detail 回链
test('mock PublicInitiatives：返回公开卡片（含 event-1 所属活动）', () => {
  const data = mockGraphQLRequest<{ publicInitiatives: Array<{ id: string; slug: string }> }>(
    PublicInitiativesQueryDocument,
    {}
  )
  assert.deepEqual(data.publicInitiatives.map(({ id }) => id), ['initiative-1'])
  assert.equal(data.publicInitiatives[0]?.slug, 'python-1024')
})

test('mock PublicInitiative：命中 slug → 城市分组的场次；未命中 → null', () => {
  const data = mockGraphQLRequest<{
    publicInitiative: { id: string; cities: Array<{ city: string; events: Array<{ id: string }> }> } | null
  }>(PublicInitiativeQueryDocument, { slug: 'python-1024' })
  assert.equal(data.publicInitiative?.id, 'initiative-1')
  assert.deepEqual(data.publicInitiative?.cities.map(({ city }) => city), ['北京'])
  assert.deepEqual(data.publicInitiative?.cities[0]?.events.map(({ id }) => id), ['event-1'])

  const missing = mockGraphQLRequest<{ publicInitiative: unknown }>(PublicInitiativeQueryDocument, {
    slug: 'nope'
  })
  assert.equal(missing.publicInitiative, null)
})

test('mock EventDetail：挂载场带出 initiativeId，未挂载场为 null', () => {
  const mounted = mockGraphQLRequest<{ getEvent: { initiativeId: string | null } | null }>(
    EventDetailQueryDocument,
    { id: 'event-1' }
  )
  assert.equal(mounted.getEvent?.initiativeId, 'initiative-1')

  const plain = mockGraphQLRequest<{ getEvent: { initiativeId: string | null } | null }>(
    EventDetailQueryDocument,
    { id: 'event-open' }
  )
  assert.equal(plain.getEvent?.initiativeId, null)
})

// U11（R10/R11）：押金场样例——详情缴费块与看码链在 mock 上可走通
test('mock 押金场：详情查询带押金字段', () => {
  const data = mockGraphQLRequest<{
    getEvent: { depositEnabled: boolean; depositAmountCents: number | null } | null
  }>(EventDetailQueryDocument, { id: 'event-deposit' })
  assert.equal(data.getEvent?.depositEnabled, true)
  assert.equal(data.getEvent?.depositAmountCents, 6900)
})

// #510：mock 门控投影——event-deposit 带 minAge: 18，未带 ageConfirmed → 业务错误
test('mock 年龄门槛：未带 ageConfirmed → enrollment_age_confirmation_required；带 true → 通过', () => {
  mockGraphQLRequest(SignInWithPlatformMutationDocument, { platform: 'wechat', code: 'mock-login' })

  const rejected = mockGraphQLRequest<{
    createEnrollment: { result: { status: string | null } | null; errors: Array<{ code: string | null }> }
  }>(CreateEnrollmentMutationDocument, { input: { userId: 'user-1', eventId: 'event-deposit' } })
  assert.equal(rejected.createEnrollment.result, null)
  assert.equal(
    rejected.createEnrollment.errors[0]?.code,
    'enrollment_age_confirmation_required'
  )

  const passed = mockGraphQLRequest<{
    createEnrollment: { result: { status: string | null } | null }
  }>(CreateEnrollmentMutationDocument, {
    input: { userId: 'user-1', eventId: 'event-deposit', ageConfirmed: true }
  })
  assert.equal(passed.createEnrollment.result?.status, 'payment_pending')
})

test('mock 押金场：报名落 payment_pending（零档位）→ 押金单金额 = 押金 → 核销后仅 confirmed 出码', () => {
  mockGraphQLRequest(SignInWithPlatformMutationDocument, { platform: 'wechat', code: 'mock-login' })

  const created = mockGraphQLRequest<{
    createEnrollment: { result: { status: string; checkInCode: string | null } }
  }>(CreateEnrollmentMutationDocument, {
    input: { userId: 'user-1', eventId: 'event-deposit', ageConfirmed: true }
  })
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

// ── #617：selection 契约 + mock 夹具 parity ──

test('#617 契约：两处报名 selection 都含 startsAt/venue', () => {
  // selection 的唯一真源 = operations.ts；生成物（src/api/generated）另由
  // check:ci 的 `codegen && git diff --exit-code` 门禁锁住。两条一起保证
  // mapEnrollment 读到的字段在真机上确实被请求（少一处 → 页面静默空白）。
  const documents = [
    ['MyEnrollmentsQueryDocument', MyEnrollmentsQueryDocument],
    ['EnrollmentQueryDocument', EnrollmentQueryDocument]
  ] as const
  for (const [name, doc] of documents) {
    assert.match(doc, /\bstartsAt\b/, `${name} 缺 startsAt`)
    assert.match(doc, /\bvenue\b/, `${name} 缺 venue`)
    assert.match(doc, /\bregistrationDeadline\b/, `${name} 缺 registrationDeadline（既有字段回归）`)
  }
})

test('#617 mock parity：e2e 走的读面回带 startsAt/venue（从目标记录派生，非硬编码）', () => {
  mockGraphQLRequest(SignInWithPlatformMutationDocument, { platform: 'wechat', code: 'mock-login' })
  mockGraphQLRequest(CreateEnrollmentMutationDocument, {
    input: { userId: 'user-1', eventId: 'event-1' }
  })
  const mine = mockGraphQLRequest<{
    enrollments: { results: Array<{ startsAt: string | null; venue: string | null }> }
  }>(MyEnrollmentsQueryDocument, { userId: 'user-1' })
  const row = mine.enrollments.results[0]
  // event-1 有档期与场地：两值都必须非空，否则 my-enrollments 的时间/地点行在
  // mock 构建（e2e）下不渲染——AGENTS.md：加字段要同步 mockTransport
  assert.equal(typeof row?.startsAt, 'string')
  // 关键：mock 必须给**文本化** venue（读面契约 = Venue.text/1 的 city+district），
  // 不能把目标记录里的 JsonString 直接透传——否则 mock/真机形态不一致
  assert.equal(row?.venue, '北京海淀区')
})
// ── U9 闪念间：会话腿拒绝态 + mock 写面落 state 后 capsule 回读（P2） ──

test('mock FlashbackCapsule：未登录 → 顶层 errors（flashback_auth_required）', () => {
  mockGraphQLRequest(SignOutMutationDocument, {})
  const body = mockGraphQLRequest<{ errors?: Array<{ code: string }> }>(FlashbackCapsuleQueryDocument, {})
  assert.equal(body.errors?.[0]?.code, 'flashback_auth_required')
})

test('mock 闪念间写面落 state：adjustFog / setQuoteLicense / endorse 后 capsule 回读', () => {
  mockGraphQLRequest(SignInWithPlatformMutationDocument, { platform: 'wechat', code: 'mock-login' })

  // 雾面：解掉初始 [0,7) → capsule 回读空 spans（不再恒定初始区间）
  mockGraphQLRequest(FlashbackAdjustFogMutationDocument, { answerId: 'fb-answer-1', spans: [] })
  let capsule = mockGraphQLRequest<{
    flashbackCapsule: {
      me: { quoteLevel: string; answers: Array<{ fogSpans: Array<{ start: number; len: number }> }> }
      actionCards: Array<{ id: string; endorsementCount: number; endorsedByMe: boolean }>
    }
  }>(FlashbackCapsuleQueryDocument, {})
  assert.deepEqual(capsule.flashbackCapsule.me.answers[0]?.fogSpans, [])

  // 授权档：off → anonymous → capsule 回读（me.quoteLevel 不再恒定 off，P2/P3）
  mockGraphQLRequest(FlashbackSetQuoteLicenseMutationDocument, { level: 'anonymous' })
  capsule = mockGraphQLRequest<typeof capsule>(FlashbackCapsuleQueryDocument, {})
  assert.equal(capsule.flashbackCapsule.me.quoteLevel, 'anonymous')

  // 附议：forming 卡计数 4 → 5、endorsedByMe 翻真
  mockGraphQLRequest(FlashbackEndorseMutationDocument, { cardId: 'card-forming', roleClaimed: 'organizer' })
  capsule = mockGraphQLRequest<typeof capsule>(FlashbackCapsuleQueryDocument, {})
  const forming = capsule.flashbackCapsule.actionCards.find((card) => card.id === 'card-forming')
  assert.equal(forming?.endorsementCount, 5)
  assert.equal(forming?.endorsedByMe, true)
})
