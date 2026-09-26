import assert from 'node:assert/strict'
import test from 'node:test'
import { __setFlashbackUnclaimed, __setPlatformIdentityBound, __setWorkspaceAccessDenied, mockGraphQLRequest } from '../src/api/mockTransport.ts'
import {
  CatalogQueryDocument,
  CatalogSearchQueryDocument,
  ConfirmEnrollmentMutationDocument,
  CreateEnrollmentMutationDocument,
  CreateOrderMutationDocument,
  EventDetailQueryDocument,
  EnrollmentQueryDocument,
  FlashbackAdjustFogMutationDocument,
  FlashbackArchivesQueryDocument,
  FlashbackAdjustTodayFogMutationDocument,
  FlashbackAddWishCommentMutationDocument,
  FlashbackCapsuleQueryDocument,
  FlashbackClaimMutationDocument,
  FlashbackCreateWishMutationDocument,
  FlashbackDeleteWishMutationDocument,
  FlashbackEndorseWishMutationDocument,
  FlashbackPublicWishesQueryDocument,
  FlashbackSetCardSharingMutationDocument,
  FlashbackSendToWallMutationDocument,
  FlashbackRetractMutationDocument,
  FlashbackDeletePreviewQueryDocument,
  FlashbackDeleteMutationDocument,
  FlashbackRecoverMutationDocument,
  FlashbackRecoverVerifyForAccountMutationDocument,
  FlashbackSetQuoteLicenseMutationDocument,
  FlashbackSharedCardQueryDocument,
  FlashbackSubmitTodayMutationDocument,
  MyEnrollmentsQueryDocument,
  PublicInitiativeQueryDocument,
  PublicInitiativesQueryDocument,
  SessionQueryDocument,
  SignInWithPlatformMutationDocument,
  SignInWithPlatformIdentityMutationDocument,
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
    { input: { enrollmentId: 'enrollment-1', depositConsent: true } }
  )
  assert.equal(order.createOrder.result.amountCents, 6900)

  mockGraphQLRequest(ConfirmEnrollmentMutationDocument, { id: 'enrollment-1' })
  const mine = mockGraphQLRequest<{
    enrollments: { results: Array<{ checkInCode: string | null }> }
  }>(MyEnrollmentsQueryDocument, { userId: 'user-1' })
  assert.equal(mine.enrollments.results[0]?.checkInCode, '042317')
})

// #727：mock 门控投影——押金单未带 depositConsent → order_deposit_consent_required；
// 带 true 放行；非押金单忽略该字段（与后端 action 同语义，前端文案表命中同 code）
test('mock 押金同意门：押金单缺 consent 拒单、带 true 放行、非押金单忽略', () => {
  mockGraphQLRequest(SignInWithPlatformMutationDocument, { platform: 'wechat', code: 'mock-login' })

  // 押金场报名（event-deposit 带 minAge 18 → 需 ageConfirmed）
  const enrolled = mockGraphQLRequest<{
    createEnrollment: { result: { paymentMode: string | null; depositAmountCents: number | null } | null }
  }>(CreateEnrollmentMutationDocument, {
    input: { userId: 'user-1', eventId: 'event-deposit', ageConfirmed: true }
  })
  // #727：报名快照带押金金额（order-pay 创单前披露的金额源）
  assert.equal(enrolled.createEnrollment.result?.paymentMode, 'deposit')
  assert.equal(enrolled.createEnrollment.result?.depositAmountCents, 6900)

  const rejected = mockGraphQLRequest<{
    createOrder: {
      result: { orderKind: string } | null
      errors: Array<{ code: string | null }>
    }
  }>(CreateOrderMutationDocument, { input: { enrollmentId: 'enrollment-1' } })
  assert.equal(rejected.createOrder.result, null)
  assert.equal(rejected.createOrder.errors[0]?.code, 'order_deposit_consent_required')

  const passed = mockGraphQLRequest<{ createOrder: { result: { orderKind: string } | null } }>(
    CreateOrderMutationDocument,
    { input: { enrollmentId: 'enrollment-1', depositConsent: true } }
  )
  assert.equal(passed.createOrder.result?.orderKind, 'deposit')

  // 非押金场（免费 event-open）：不带 consent 也照常下单（字段被忽略）
  mockGraphQLRequest(CreateEnrollmentMutationDocument, {
    input: { userId: 'user-1', eventId: 'event-open' }
  })
  const nonDeposit = mockGraphQLRequest<{ createOrder: { result: { orderKind: string } | null } }>(
    CreateOrderMutationDocument,
    { input: { enrollmentId: 'enrollment-1' } }
  )
  assert.equal(nonDeposit.createOrder.result?.orderKind, 'enrollment')
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
    // #727：押金快照金额只给单条回查（order-pay 创单前门的金额源）——列表查询
    // 不选（该计算字段 load submission_payload，列表最多 100 行，白拉 JSONB）；
    // 少选即静默「金额待定」，多选即列表浪费，两侧都钉住
    if (name === 'EnrollmentQueryDocument') {
      assert.match(doc, /\bdepositAmountCents\b/, `${name} 缺 depositAmountCents（#727 押金披露金额源）`)
    } else {
      assert.doesNotMatch(
        doc,
        /\bdepositAmountCents\b/,
        `${name} 不应选 depositAmountCents（无消费方且列表拉 submission_payload）`
      )
    }
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

test('mock FlashbackCapsule 城市钉（R34）：cities 恒全量排序', () => {
  mockGraphQLRequest(SignInWithPlatformMutationDocument, { platform: 'wechat', code: 'mock-login' })
  type Capsule = { flashbackCapsule: { cities: string[] } }
  // 字节序去重排序（与后端 capsule_cities 同口径）：名册城市恒全量、不随 city 过滤收缩
  const all = mockGraphQLRequest<Capsule>(FlashbackCapsuleQueryDocument, {})
  assert.deepEqual(all.flashbackCapsule.cities, ['上海', '北京', '广州'])

  const beijing = mockGraphQLRequest<Capsule>(FlashbackCapsuleQueryDocument, { city: '北京' })
  assert.deepEqual(beijing.flashbackCapsule.cities, ['上海', '北京', '广州'])
})

test('mock 小程序内找回（#932）：发起同形；验证要求登录、错码与号码属于别人各有其码、通过即绑到当前账号', () => {
  type Errors = { errors?: Array<{ code: string }> }
  const verify = (code: string, identifier = '13900000011') =>
    mockGraphQLRequest<Errors & { flashbackRecoverVerifyForAccount?: { bound: boolean; cards: unknown[] } }>(
      FlashbackRecoverVerifyForAccountMutationDocument,
      { identifier, code }
    )

  mockGraphQLRequest(SignOutMutationDocument, {})
  assert.equal(verify('123456').errors?.[0]?.code, 'unauthorized')

  mockGraphQLRequest(SignInWithPlatformMutationDocument, { platform: 'wechat', code: 'mock-login' })
  __setFlashbackUnclaimed(true)
  const dispatched = mockGraphQLRequest<{ flashbackRecover: { dispatched: boolean } }>(FlashbackRecoverMutationDocument, { identifier: 'nobody@example.com' })
  assert.equal(dispatched.flashbackRecover.dispatched, true)

  assert.equal(verify('000000').errors?.[0]?.code, 'invalid_or_expired_code')
  assert.equal(verify('123456', '13900000099').errors?.[0]?.code, 'flashback_recover_account_conflict')
  // 失败两次都没有绑定
  assert.equal(mockGraphQLRequest<Errors>(FlashbackCapsuleQueryDocument, { city: null, token: null }).errors?.[0]?.code, 'flashback_person_not_bound')

  assert.equal(verify('123456').flashbackRecoverVerifyForAccount?.bound, true)
  // 绑定后会话腿读胶囊即参与态
  assert.equal(mockGraphQLRequest<Errors>(FlashbackCapsuleQueryDocument, { city: null, token: null }).errors, undefined)
  __setFlashbackUnclaimed(false)
})

test('mock 回访静默登录（#930）：默认本平台未绑定身份（不影响既有 e2e 的手机号登录流程）；绑定后一步登录', () => {
  type Result = { errors?: Array<{ code: string }>; signInWithPlatformIdentity?: { id: string } }
  mockGraphQLRequest(SignOutMutationDocument, {})
  const unbound = mockGraphQLRequest<Result>(SignInWithPlatformIdentityMutationDocument, { platform: 'wechat', code: 'c' })
  assert.equal(unbound.errors?.[0]?.code, 'platform_identity_not_found')
  assert.equal(mockGraphQLRequest<{ errors?: unknown[] }>(FlashbackCapsuleQueryDocument, {}).errors?.length, 1, '未绑定时仍是未登录')

  __setPlatformIdentityBound(true)
  const bound = mockGraphQLRequest<Result>(SignInWithPlatformIdentityMutationDocument, { platform: 'wechat', code: 'c' })
  assert.equal(bound.signInWithPlatformIdentity?.id, 'user-1')
  assert.equal(mockGraphQLRequest<{ errors?: unknown[] }>(FlashbackCapsuleQueryDocument, {}).errors, undefined, '静默登录后即已登录')
  __setPlatformIdentityBound(false)
})

type AlbumRoster = { surnameMasked: string; fullName: string | null; city: string | null; occupationThen: string | null; sentToWallAt: string | null }
type Album = { key: string; isMine: boolean; piles: Array<{ city: string; count: number; returned: number }>; roster: AlbumRoster[] }

test('mock FlashbackArchives（#933）：相册只对已登录开放', () => {
  mockGraphQLRequest(SignOutMutationDocument, {})
  const body = mockGraphQLRequest<{ errors?: Array<{ code: string }> }>(FlashbackArchivesQueryDocument, {})
  assert.equal(body.errors?.[0]?.code, 'flashback_auth_required')
})

test('mock 相册（#933）：未寄出者只剩姓氏遮罩；城市堆计入未寄出者；isMine 恒 false', () => {
  mockGraphQLRequest(SignInWithPlatformMutationDocument, { platform: 'wechat', code: 'mock-login' })
  const { flashbackArchives } = mockGraphQLRequest<{ flashbackArchives: { archives: Album[]; cities: string[] } }>(FlashbackArchivesQueryDocument, {})
  assert.deepEqual(flashbackArchives.cities, ['上海', '北京', '广州'])
  assert.ok(flashbackArchives.archives.every((archive) => !archive.isMine))
  const bj = flashbackArchives.archives.find((archive) => archive.key === '2014-01-11-bj')
  assert.ok(bj)
  const unsent = bj.roster.filter((entry) => !entry.sentToWallAt)
  assert.ok(unsent.length > 0)
  for (const entry of unsent) assert.deepEqual([entry.fullName, entry.city, entry.occupationThen], [null, null, null])
  assert.ok(bj.roster.filter((entry) => entry.sentToWallAt).every((entry) => entry.city))
  assert.deepEqual(bj.piles.map(({ city, count }) => [city, count]), [['北京', 3], ['上海', 2], ['广州', 1]])
})

test('mock 相册筛城市（#933）：名册只列该城已寄出者，城市堆仍按全员聚合，整场无人才撤下', () => {
  mockGraphQLRequest(SignInWithPlatformMutationDocument, { platform: 'wechat', code: 'mock-login' })
  const { flashbackArchives } = mockGraphQLRequest<{ flashbackArchives: { archives: Album[] } }>(FlashbackArchivesQueryDocument, { city: '广州' })
  // 广州只有一位且未寄出：名册为空（不然「周**」就被公开了城市），但这一场不从长廊消失
  assert.deepEqual(flashbackArchives.archives.map((archive) => [archive.key, archive.roster.length, archive.piles]), [
    ['2014-01-11-bj', 0, [{ city: '广州', count: 1, returned: 0 }]]
  ])
  const capsule = mockGraphQLRequest<{ flashbackCapsule: { archives: Album[] } }>(FlashbackCapsuleQueryDocument, { city: '广州' })
  assert.deepEqual(capsule.flashbackCapsule.archives.map((archive) => archive.roster.length), [0])
})

test('mock 闪念间写面落 state：adjustFog / setQuoteLicense 后 capsule 回读', () => {
  mockGraphQLRequest(SignInWithPlatformMutationDocument, { platform: 'wechat', code: 'mock-login' })

  // 雾面：解掉初始 [0,7) → capsule 回读空 spans（不再恒定初始区间）
  mockGraphQLRequest(FlashbackAdjustFogMutationDocument, { answerId: 'fb-answer-1', spans: [] })
  let capsule = mockGraphQLRequest<{
    flashbackCapsule: {
      me: { quoteLevel: string; answers: Array<{ fogSpans: Array<{ start: number; len: number }> }> }
    }
  }>(FlashbackCapsuleQueryDocument, {})
  assert.deepEqual(capsule.flashbackCapsule.me.answers[0]?.fogSpans, [])

  // 授权档：off → anonymous → capsule 回读（me.quoteLevel 不再恒定 off，P2/P3）
  mockGraphQLRequest(FlashbackSetQuoteLicenseMutationDocument, { level: 'anonymous' })
  capsule = mockGraphQLRequest<typeof capsule>(FlashbackCapsuleQueryDocument, {})
  assert.equal(capsule.flashbackCapsule.me.quoteLevel, 'anonymous')

})

test('mock FlashbackSetQuoteLicense：提交即覆盖——off 带区间保留圈选，缺省清空（关档不清圈选）', () => {
  mockGraphQLRequest(SignInWithPlatformMutationDocument, { platform: 'wechat', code: 'mock-login' })
  type Capsule = {
    flashbackCapsule: { me: { quoteLevel: string; quoteSpans: Array<{ start: number; len: number }> } }
  }
  const readMe = () => mockGraphQLRequest<Capsule>(FlashbackCapsuleQueryDocument, {}).flashbackCapsule.me
  const picked = [{ questionKey: 'today.say', start: 0, len: 6 }]

  // 圈选（授权档 + 区间）
  mockGraphQLRequest(FlashbackSetQuoteLicenseMutationDocument, { level: 'anonymous', chosenQuoteSpans: picked })
  assert.equal(readMe().quoteSpans.length, 1)

  // 关档但带上现有区间 → **保留**：关档只关档，撤回后能立刻再开
  mockGraphQLRequest(FlashbackSetQuoteLicenseMutationDocument, { level: 'off', chosenQuoteSpans: picked })
  assert.equal(readMe().quoteLevel, 'off')
  assert.equal(readMe().quoteSpans.length, 1, '关档带区间应保留圈选，而不是随档位一起清空')

  // 不带区间（前端真清空时传 null）→ 覆盖为空（对齐后端 Ash：nil 照写即清空）
  mockGraphQLRequest(FlashbackSetQuoteLicenseMutationDocument, { level: 'anonymous' })
  assert.deepEqual(readMe().quoteSpans, [], '缺省区间提交应清空（提交即覆盖）')
})

test('mock capsule 未来段（U1）：场次含满员/截止、公开愿含已附议态、私愿仅本人', () => {
  mockGraphQLRequest(SignInWithPlatformMutationDocument, { platform: 'wechat', code: 'mock-login' })
  type Capsule = {
    flashbackCapsule: {
      futureEvents: Array<{ events: Array<{ id: string; capacity: number | null; confirmedCount: number; registrationDeadline: string | null }> }>
      publicWishes: Array<{ id: string; endorsedByMe: boolean; comments: unknown[] }>
      myPrivateWishes: Array<{ id: string; mine: boolean }>
      myWishQuotaRemaining: number | null
    }
  }
  const data = mockGraphQLRequest<Capsule>(FlashbackCapsuleQueryDocument, {})
  const events = data.flashbackCapsule.futureEvents[0].events
  assert.equal(events.length, 3)
  // ev-2 满员 16/16、ev-3 截止(deadline 过去)
  assert.equal(events.find((e) => e.id === 'ev-2')?.confirmedCount, 16)
  assert.equal(events.find((e) => e.id === 'ev-3')?.registrationDeadline, '2026-09-01T00:00:00Z')
  assert.equal(data.flashbackCapsule.publicWishes.length, 2)
  assert.equal(data.flashbackCapsule.publicWishes[1].endorsedByMe, true)
  assert.equal(data.flashbackCapsule.publicWishes[0].comments.length, 1)
  assert.equal(data.flashbackCapsule.myPrivateWishes.length, 1)
  assert.equal(data.flashbackCapsule.myPrivateWishes[0].mine, true)
  // 种子私愿由本人在 2026 年创建，R20 年度额度包含私愿。
  const shanghaiYear = new Date(Date.now() + 8 * 3_600_000).getUTCFullYear()
  assert.equal(data.flashbackCapsule.myWishQuotaRemaining, shanghaiYear === 2026 ? 2 : 3)
})

// ── #771 卡片站外公开：mock 写面 → capsule 回读 + 匿名公开读面 ────────────
// 本组用例自带种子（每次先显式开/关再断言），不依赖彼此的执行顺序；
// 唯一例外是第一条——它断言的是**模块初始态**（没有任何隐式开启），
// 必须排在本文件所有 cardSharing 写操作之前。

interface ShareState { enabled: boolean; shareId: string | null; preview: ShareCard }
interface ShareCard {
  displayName: string
  city: string | null
  appliedAt: string | null
  answers: Array<{ questionKey: string; segments: Array<{ text: string; fog: boolean; len: number }> }>
  today: Array<{ questionKey: string; segments: Array<{ text: string; fog: boolean; len: number }> }>
}

const readCardSharing = (): ShareState => {
  const data = mockGraphQLRequest<{ flashbackCapsule: { me: { cardSharing: ShareState } } }>(
    FlashbackCapsuleQueryDocument,
    {}
  )
  return data.flashbackCapsule.me.cardSharing
}

const readSharedCard = (shareId: string): ShareCard | null =>
  mockGraphQLRequest<{ flashbackSharedCard: ShareCard | null }>(FlashbackSharedCardQueryDocument, { shareId })
    .flashbackSharedCard

const setSharing = (enabled: boolean, token?: string): ShareState =>
  mockGraphQLRequest<{ flashbackSetCardSharing: ShareState }>(
    FlashbackSetCardSharingMutationDocument,
    token === undefined ? { enabled } : { enabled, token }
  ).flashbackSetCardSharing

test('mock 公开开关默认关且无 id（没有任何隐式开启路径）', () => {
  mockGraphQLRequest(SignInWithPlatformMutationDocument, { platform: 'wechat', code: 'mock-login' })
  const sharing = readCardSharing()
  assert.equal(sharing.enabled, false)
  assert.equal(sharing.shareId, null)
  // 关着时预览仍在（本人视角），但公开读面不可达
  assert.ok(sharing.preview.answers.length > 0)

  // 从未开启过的人点「关闭」→ id 仍为 null：只有首次**开启**才铸 id，
  // 关闭不得宣告此人开过（否则凭空多出一个本该不存在的分享链接）
  const closed = setSharing(false)
  assert.equal(closed.enabled, false)
  assert.equal(closed.shareId, null)
  assert.equal(readCardSharing().shareId, null)
})

test('mock 公开开关要求本人身份：匿名不给写面，带 token 即可（链接腿）', () => {
  mockGraphQLRequest(SignOutMutationDocument, {})
  const denied = mockGraphQLRequest<{ errors?: Array<{ code: string }> }>(
    FlashbackSetCardSharingMutationDocument,
    { enabled: true }
  )
  assert.equal(denied.errors?.[0]?.code, 'flashback_auth_required')

  const enabled = setSharing(true, 'tk-first-trip')
  assert.equal(enabled.enabled, true)
  assert.match(enabled.shareId ?? '', /^[0-9a-f]{48}$/)
})

test('mock 公开开关：已作废的首程链接不构成写权限（claim 后 token 失效）', () => {
  mockGraphQLRequest(SignInWithPlatformMutationDocument, { platform: 'wechat', code: 'mock-login' })
  // 收好即作废该链接（与 capsule token 腿同源）
  mockGraphQLRequest(FlashbackClaimMutationDocument, { token: 'tk-consumed' })
  mockGraphQLRequest(SignOutMutationDocument, {})

  const denied = mockGraphQLRequest<{ errors?: Array<{ code: string }> }>(
    FlashbackSetCardSharingMutationDocument,
    { enabled: true, token: 'tk-consumed' }
  )
  assert.equal(denied.errors?.[0]?.code, 'flashback_token_claimed')
})

test('mock 公开读面匿名可达；关闭后同 id 不可读且 id 保留，重开复用同一 id', () => {
  mockGraphQLRequest(SignInWithPlatformMutationDocument, { platform: 'wechat', code: 'mock-login' })
  const opened = setSharing(true)
  const shareId = opened.shareId as string

  // 匿名（无登录态也能读——朋友视角）：不开任何会话腿
  mockGraphQLRequest(SignOutMutationDocument, {})
  const card = readSharedCard(shareId)
  assert.ok(card, '开启后匿名应能读到卡')
  assert.equal(card.displayName, '王**', '公开面只出隐名，不出全名')
  assert.equal(card.city, '北京')

  // 关闭 = 解除发布（读面立即 404），但 id 不变（ADR-0014 发布即锁死）
  mockGraphQLRequest(SignInWithPlatformMutationDocument, { platform: 'wechat', code: 'mock-login' })
  const closed = setSharing(false)
  assert.equal(closed.enabled, false)
  assert.equal(closed.shareId, shareId, '关闭不得重生成 id')
  mockGraphQLRequest(SignOutMutationDocument, {})
  assert.equal(readSharedCard(shareId), null, '关闭后公开读面必须为空')

  // 重开 → 复用同一 id，读面恢复
  mockGraphQLRequest(SignInWithPlatformMutationDocument, { platform: 'wechat', code: 'mock-login' })
  assert.equal(setSharing(true).shareId, shareId)
  mockGraphQLRequest(SignOutMutationDocument, {})
  assert.ok(readSharedCard(shareId))
})

test('mock 公开读面：未知 id / 错误 id / 空 id 一律 null', () => {
  mockGraphQLRequest(SignInWithPlatformMutationDocument, { platform: 'wechat', code: 'mock-login' })
  const shareId = setSharing(true).shareId as string
  mockGraphQLRequest(SignOutMutationDocument, {})

  assert.equal(readSharedCard('0'.repeat(48)), null)
  // 末位改成另一个字符——不能硬写 '0'：铸出的 hex 末位本身就是 '0' 时，
  // 这个「错 id」等于真 id，断言随机挂（1/16）
  const tampered = shareId.slice(0, 47) + (shareId.endsWith('0') ? '1' : '0')
  assert.equal(readSharedCard(tampered), null)
  assert.equal(readSharedCard(''), null)
})

test('mock 公开卡白名单：三题当年答案 + today 四问，姓名隐名', () => {
  mockGraphQLRequest(SignInWithPlatformMutationDocument, { platform: 'wechat', code: 'mock-login' })
  mockGraphQLRequest(FlashbackSubmitTodayMutationDocument, {
    input: { nowStatus: '还在写代码', want: '学 Rust', need: '想找人一起组队', say: '谢谢你还在' }
  })
  const shareId = setSharing(true).shareId as string
  mockGraphQLRequest(SignOutMutationDocument, {})

  const card = readSharedCard(shareId)
  assert.ok(card)
  // 白名单 = self_intro/funny_thing/os（PII 行 phone/email/social_media 不进）
  assert.deepEqual(
    card.answers.map(({ questionKey }) => questionKey),
    ['self_intro', 'funny_thing', 'os']
  )
  assert.deepEqual(
    card.today.map(({ questionKey }) => questionKey),
    ['today.now', 'today.want', 'today.need', 'today.say']
  )
  assert.ok(!JSON.stringify(card).includes('phone'))
  // 公开面不含任何全名
  assert.ok(!JSON.stringify(card).includes('王小明'))
})

test('mock 公开卡雾面 fail-closed：合法区间切雾段（text 恒空），非法区间整段全雾', () => {
  mockGraphQLRequest(SignInWithPlatformMutationDocument, { platform: 'wechat', code: 'mock-login' })
  // 合法区间：首句 7 字（mock 原文「我在盛大做测试。…」）
  mockGraphQLRequest(FlashbackAdjustFogMutationDocument, { answerId: 'fb-answer-1', spans: [{ start: 0, len: 7 }] })
  const shareId = setSharing(true).shareId as string
  mockGraphQLRequest(SignOutMutationDocument, {})

  const fogged = readSharedCard(shareId)
  assert.ok(fogged)
  const intro = fogged.answers.find(({ questionKey }) => questionKey === 'self_intro')
  assert.ok(intro)
  assert.equal(intro.segments[0].fog, true)
  assert.equal(intro.segments[0].text, '', '雾段不得携带原文字符')
  assert.equal(intro.segments[0].len, 7)
  assert.ok(intro.segments[1].text.length > 0, '雾外原文照常可见')
  // 唯一不可原谅的错误：雾住的原文字符出现在公开面
  assert.ok(!JSON.stringify(fogged).includes('我在盛大做测试'), '雾面原文不得出现在公开读面')

  // 非法区间（越界）→ 整段全雾，且仍不泄露原文
  mockGraphQLRequest(SignInWithPlatformMutationDocument, { platform: 'wechat', code: 'mock-login' })
  mockGraphQLRequest(FlashbackAdjustFogMutationDocument, { answerId: 'fb-answer-1', spans: [{ start: 0, len: 9999 }] })
  mockGraphQLRequest(SignOutMutationDocument, {})
  const allFog = readSharedCard(shareId)
  assert.ok(allFog)
  const foggedIntro = allFog.answers.find(({ questionKey }) => questionKey === 'self_intro')
  assert.deepEqual(foggedIntro?.segments.map(({ fog }) => fog), [true])
  assert.ok(!JSON.stringify(allFog).includes('我在盛大做测试'))
})

test('mock today 雾面同口径：公开面 today 段也走雾块', () => {
  mockGraphQLRequest(SignInWithPlatformMutationDocument, { platform: 'wechat', code: 'mock-login' })
  mockGraphQLRequest(FlashbackSubmitTodayMutationDocument, {
    input: { nowStatus: '还在写代码', want: null, need: null, say: null }
  })
  mockGraphQLRequest(FlashbackAdjustTodayFogMutationDocument, { field: 'now', spans: [{ start: 0, len: 2 }] })
  const shareId = setSharing(true).shareId as string
  mockGraphQLRequest(SignOutMutationDocument, {})

  const card = readSharedCard(shareId)
  assert.ok(card)
  const now = card.today.find(({ questionKey }) => questionKey === 'today.now')
  assert.ok(now)
  assert.equal(now.segments[0].fog, true)
  assert.equal(now.segments[0].text, '')
  assert.ok(!JSON.stringify(card).includes('还在写代码'), 'today 雾面原文不得出现在公开读面')
})

test('mock 本人预览与匿名读面同一份投影（关着也一致，不漂移）', () => {
  mockGraphQLRequest(SignInWithPlatformMutationDocument, { platform: 'wechat', code: 'mock-login' })
  const shareId = setSharing(true).shareId as string
  const preview = readCardSharing().preview

  mockGraphQLRequest(SignOutMutationDocument, {})
  assert.deepEqual(readSharedCard(shareId), preview, '预览与公开读面必须同形（关着时预览也照出）')

  // 关闭态：预览仍在（本人视角），公开读面为空
  mockGraphQLRequest(SignInWithPlatformMutationDocument, { platform: 'wechat', code: 'mock-login' })
  setSharing(false)
  assert.ok(readCardSharing().preview.answers.length > 0)
  mockGraphQLRequest(SignOutMutationDocument, {})
  assert.equal(readSharedCard(shareId), null)
})

test('mock 公开卡不受「上墙」与「金句授权」门控（公开的是全文卡，不是金句档）', () => {
  mockGraphQLRequest(SignInWithPlatformMutationDocument, { platform: 'wechat', code: 'mock-login' })
  // 关授权档 + 清空雾面（今天也没写 → 未上墙），公开卡仍必须完整可读
  mockGraphQLRequest(FlashbackSetQuoteLicenseMutationDocument, { level: 'off' })
  mockGraphQLRequest(FlashbackAdjustFogMutationDocument, { answerId: 'fb-answer-1', spans: [] })
  const shareId = setSharing(true).shareId as string
  mockGraphQLRequest(SignOutMutationDocument, {})

  const card = readSharedCard(shareId)
  assert.ok(card, 'quoteLevel=off 不是公开卡的门（两者互相独立）')
  // 未上墙也照出三题原文：R14 公开的是「全文卡」，不是上墙卡也不是金句卡
  assert.equal(card.answers.length, 3)
  const intro = card.answers.find(({ questionKey }) => questionKey === 'self_intro')
  assert.equal(intro?.segments.length, 1)
  assert.equal(intro?.segments[0].fog, false)
  assert.equal(intro?.segments[0].text, '我在盛大做测试。想亲眼看看是不是真的！后来我成了程序员。')
})

test('mock 公开开关与金句授权档互不牵连（关公开不动 quoteLevel/圈选，关授权不动 enabled）', () => {
  mockGraphQLRequest(SignInWithPlatformMutationDocument, { platform: 'wechat', code: 'mock-login' })
  type Me = {
    quoteLevel: string
    quoteSpans: Array<{ questionKey: string; start: number; len: number }>
    cardSharing: { enabled: boolean; shareId: string | null }
  }
  const readMe = () => mockGraphQLRequest<{ flashbackCapsule: { me: Me } }>(FlashbackCapsuleQueryDocument, {}).flashbackCapsule.me

  // 开公开 + 开授权档 + 圈一句
  const shareId = setSharing(true).shareId as string
  const picked = [{ questionKey: 'today.say', start: 0, len: 6 }]
  mockGraphQLRequest(FlashbackSetQuoteLicenseMutationDocument, { level: 'credited', chosenQuoteSpans: picked })
  assert.equal(readMe().quoteLevel, 'credited')

  // 关公开：授权档与圈选都不受影响（#771 设计要点 3：公开开关独立于金句授权；
  // 关闭只解除发布——撤回公开不等于撤回金句）
  setSharing(false)
  assert.equal(readMe().quoteLevel, 'credited')
  assert.deepEqual(readMe().quoteSpans, picked)
  assert.equal(readMe().cardSharing.enabled, false)

  // 重开：id 复用（不受授权档变动影响）
  assert.equal(setSharing(true).shareId, shareId)

  // 关授权档：公开开关不受影响
  mockGraphQLRequest(FlashbackSetQuoteLicenseMutationDocument, { level: 'off' })
  assert.equal(readMe().cardSharing.enabled, true)
  assert.equal(readMe().cardSharing.shareId, shareId)
})

// ── #837:wish 回响投影(capsule / 公开树)把 echoes 透出到读面 ──
test('#837 mock FlashbackPublicWishes 投影 latestEcho/echoCount/echoes(0/1/多条含 corrected)', async () => {
  const { FlashbackPublicWishesQueryDocument } = await import('../src/api/operations.ts')
  type Row = {
    id: string
    latestEcho: { id: string; status: string } | null
    echoCount: number
    echoes: Array<{ id: string; status: string }>
  }
  const data = mockGraphQLRequest<{ flashbackPublicWishes: Row[] }>(FlashbackPublicWishesQueryDocument, {
    voterKey: 'test-voter',
    limit: 60
  })
  const rows = data.flashbackPublicWishes
  const w1 = rows.find((r) => r.id === 'w-1')
  const w2 = rows.find((r) => r.id === 'w-2')
  assert.ok(w1 && w2, 'w-1 / w-2 应在公开读面')

  // w-1: 多条回响,最新是 e-1b(corrected)
  assert.equal(w1.echoCount, 2)
  assert.equal(w1.latestEcho?.id, 'e-1b')
  assert.equal(w1.latestEcho?.status, 'corrected')
  assert.deepEqual(w1.echoes.map((e) => e.id), ['e-1a', 'e-1b'])

  // w-2: 单条回响,已发布未更正
  assert.equal(w2.echoCount, 1)
  assert.equal(w2.latestEcho?.id, 'e-2a')
  assert.equal(w2.latestEcho?.status, 'published')
})

test('#837 mock flashbackCapsule.publicWishes 同形状投影 echo 字段(member 面)', async () => {
  mockGraphQLRequest(SignInWithPlatformMutationDocument, { platform: 'wechat', code: 'mock-login' })
  type Row = {
    id: string
    latestEcho: { id: string; status: string } | null
    echoCount: number
    echoes: Array<{ id: string; status: string }>
  }
  type Capsule = { flashbackCapsule: { publicWishes: Row[]; myPrivateWishes: Row[] } }
  const data = mockGraphQLRequest<Capsule>(FlashbackCapsuleQueryDocument, {})
  const pub = data.flashbackCapsule.publicWishes
  const w1 = pub.find((r) => r.id === 'w-1')
  assert.ok(w1)
  assert.equal(w1.echoCount, 2)
  assert.equal(w1.latestEcho?.id, 'e-1b')
  assert.equal(w1.latestEcho?.status, 'corrected')

  // 私愿无回响 (mock seed pw-1 echoes: []) —— 不渲染回响卡,不显示徽章
  const priv = data.flashbackCapsule.myPrivateWishes
  const pw1 = priv.find((r) => r.id === 'pw-1')
  assert.ok(pw1)
  assert.equal(pw1.echoCount, 0)
  assert.equal(pw1.latestEcho, null)
  assert.deepEqual(pw1.echoes, [])
})

// ── #790: workspace_access_denied → meWorkspaces=[] ──
test('#790 session query 默认带工作台(meWorkspaces 非空)', () => {
  mockGraphQLRequest(SignInWithPlatformMutationDocument, { platform: 'wechat', code: 'mock-login' })
  type Session = { me: { id: string } | null; meWorkspaces: Array<{ id: string }> }
  const data = mockGraphQLRequest<Session>(SessionQueryDocument, {})
  assert.ok(data.me, '登录后 me 非空')
  assert.equal(data.meWorkspaces.length, 1)
})

test('#790 __setWorkspaceAccessDenied(true) 后 meWorkspaces=[]', () => {
  __setWorkspaceAccessDenied(true)
  try {
    type Session = { me: { id: string } | null; meWorkspaces: Array<{ id: string }> }
    const data = mockGraphQLRequest<Session>(SessionQueryDocument, {})
    assert.ok(data.me, '登录后 me 非空')
    assert.deepEqual(data.meWorkspaces, [])
  } finally {
    __setWorkspaceAccessDenied(false)
  }
})

test('#790 愿望写面经 capsule 读回，年度额度含软删且不退还', () => {
  mockGraphQLRequest(SignInWithPlatformMutationDocument, { platform: 'wechat', code: 'mock-login' })
  type Wish = { id: string; content: string; endorsementCount: number; endorsedByMe: boolean; mine: boolean; comments: Array<{ content: string }> }
  type Capsule = { flashbackCapsule: { publicWishes: Wish[]; myWishQuotaRemaining: number } }
  const read = () => mockGraphQLRequest<Capsule>(FlashbackCapsuleQueryDocument, {}).flashbackCapsule
  const readPublic = () => mockGraphQLRequest<{ flashbackPublicWishes: Array<{ id: string; endorsementCount: number }> }>(
    FlashbackPublicWishesQueryDocument, { voterKey: 'e2e-voter' }
  ).flashbackPublicWishes
  const before = read()
  const create = mockGraphQLRequest<{ flashbackCreateWish: { id: string; status: string } }>(
    FlashbackCreateWishMutationDocument,
    { content: 'E2E 年度愿望', visibility: 'public', publicListingConsent: true }
  ).flashbackCreateWish
  assert.equal(create.status, 'listed')
  assert.equal(read().publicWishes.find((w) => w.id === create.id)?.mine, true)
  assert.equal(read().myWishQuotaRemaining, before.myWishQuotaRemaining - 1)

  const first = mockGraphQLRequest<{ flashbackEndorseWish: { endorsementCount: number } }>(
    FlashbackEndorseWishMutationDocument, { wishId: 'w-1', contributionTypes: ['writing'], notify: false }
  )
  const repeat = mockGraphQLRequest<{ flashbackEndorseWish: { endorsementCount: number } }>(
    FlashbackEndorseWishMutationDocument, { wishId: 'w-1', contributionTypes: ['writing'], notify: false }
  )
  assert.equal(first.flashbackEndorseWish.endorsementCount, 6)
  assert.equal(repeat.flashbackEndorseWish.endorsementCount, 6)
  assert.equal(read().publicWishes.find((w) => w.id === 'w-1')?.endorsementCount, 6)
  assert.equal(readPublic().find((w) => w.id === 'w-1')?.endorsementCount, 6)
  assert.ok(readPublic().some((w) => w.id === create.id))

  mockGraphQLRequest(FlashbackAddWishCommentMutationDocument, { wishId: 'w-1', content: 'E2E 留言' })
  assert.deepEqual(read().publicWishes.find((w) => w.id === 'w-1')?.comments.map((c) => c.content), ['算我一个', 'E2E 留言'])

  mockGraphQLRequest(FlashbackDeleteWishMutationDocument, { wishId: create.id })
  assert.equal(read().publicWishes.some((w) => w.id === create.id), false)
  assert.equal(read().myWishQuotaRemaining, before.myWishQuotaRemaining - 1)

  const unlisted = mockGraphQLRequest<{ flashbackCreateWish: { id: string; status: string } }>(
    FlashbackCreateWishMutationDocument,
    { content: '未授权挂树', visibility: 'public', publicListingConsent: false }
  ).flashbackCreateWish
  assert.equal(unlisted.status, 'private')
  assert.ok(read().publicWishes.some((w) => w.id === unlisted.id), '成员胶囊仍可见本人未挂树的公开愿')
  assert.equal(readPublic().some((w) => w.id === unlisted.id), false, '公开读面只显示已挂树愿望')

  const foreignDelete = mockGraphQLRequest<{ errors: Array<{ code: string }> }>(
    FlashbackDeleteWishMutationDocument, { wishId: 'w-1' }
  )
  assert.equal(foreignDelete.errors[0]?.code, 'flashback_forbidden_wish')
  const missingDelete = mockGraphQLRequest<{ errors: Array<{ code: string }> }>(
    FlashbackDeleteWishMutationDocument, { wishId: 'missing-wish' }
  )
  assert.equal(missingDelete.errors[0]?.code, 'flashback_wish_not_found')
  for (let i = 2; i < before.myWishQuotaRemaining; i++) {
    mockGraphQLRequest(FlashbackCreateWishMutationDocument, {
      content: `额度测试 ${i}`, visibility: 'private', publicListingConsent: false
    })
  }
  assert.equal(read().myWishQuotaRemaining, 0)
  const overQuota = mockGraphQLRequest<{ errors: Array<{ code: string }> }>(
    FlashbackCreateWishMutationDocument, { content: '超额', visibility: 'private' }
  )
  assert.equal(overQuota.errors[0]?.code, 'flashback_wish_quota_exceeded')
})

// #931：mock 必须镜像后端身份门——「无 token 且未登录」报 auth_required、登录未绑定报
// person_not_bound；否则寄出 / 撤下在 mock 上恒成功，e2e 绿着漏掉真后端的失败。
test('mock #931：寄出 / 撤下 / 删除镜像后端身份门', () => {
  type Errors = { errors?: Array<{ code?: string | null }> }
  mockGraphQLRequest(SignOutMutationDocument, {})
  for (const doc of [FlashbackSendToWallMutationDocument, FlashbackRetractMutationDocument, FlashbackDeletePreviewQueryDocument]) {
    assert.equal(mockGraphQLRequest<Errors>(doc, { token: null }).errors?.[0]?.code, 'flashback_auth_required')
  }

  mockGraphQLRequest(SignInWithPlatformMutationDocument, { platform: 'wechat', code: 'mock-login' })
  __setFlashbackUnclaimed(true)
  assert.equal(mockGraphQLRequest<Errors>(FlashbackSendToWallMutationDocument, { token: null }).errors?.[0]?.code, 'flashback_person_not_bound')
  __setFlashbackUnclaimed(false)

  const sent = mockGraphQLRequest<{ flashbackSendToWall: { sentToWallAt: string | null } }>(FlashbackSendToWallMutationDocument, { token: null })
  assert.ok(sent.flashbackSendToWall.sentToWallAt)
  const retracted = mockGraphQLRequest<{ flashbackRetract: { retracted: boolean; sentToWallAt: string | null } }>(FlashbackRetractMutationDocument, { token: null })
  assert.equal(retracted.flashbackRetract.retracted, true)
  assert.equal(retracted.flashbackRetract.sentToWallAt, null)

  const preview = mockGraphQLRequest<{ flashbackDeletePreview: { fullName: string; sentToWallAt: string | null; endorsementCount: number } }>(FlashbackDeletePreviewQueryDocument, { token: null })
  assert.equal(preview.flashbackDeletePreview.fullName, '王小明')
  assert.equal(preview.flashbackDeletePreview.sentToWallAt, null)

  assert.equal(mockGraphQLRequest<Errors>(FlashbackDeleteMutationDocument, { token: null, confirm: 'delete' }).errors?.[0]?.code, 'flashback_delete_confirm_required')
  const deleted = mockGraphQLRequest<{ flashbackDelete: { deleted: boolean } }>(FlashbackDeleteMutationDocument, { token: null, confirm: 'DELETE' })
  assert.equal(deleted.flashbackDelete.deleted, true)
  // 删除后按登录账号读胶囊 → 档案已不存在（与后端同形：person_not_bound）
  assert.equal(mockGraphQLRequest<Errors>(FlashbackCapsuleQueryDocument, { city: null, token: null }).errors?.[0]?.code, 'flashback_person_not_bound')
  __setFlashbackUnclaimed(false)
  mockGraphQLRequest(SignOutMutationDocument, {})
})
