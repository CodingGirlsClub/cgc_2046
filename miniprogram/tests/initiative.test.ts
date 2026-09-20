import { beforeEach, describe, expect, it, vi } from 'vitest'
import { createElement } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import { parse, visit } from 'graphql'
import type { CatalogItem, PublicInitiative } from '../src/domain/models'

const mocks = vi.hoisted(() => ({ graphqlRequest: vi.fn(), navigateTo: vi.fn() }))
vi.mock('../src/api/client', () => ({ graphqlRequest: mocks.graphqlRequest }))
vi.mock('../src/api', () => ({ api: {} }))
vi.mock('@tarojs/components', () => ({ View: 'div', Text: 'span', Button: 'button', ScrollView: 'div' }))
vi.mock('@tarojs/taro', () => ({
  default: { navigateTo: mocks.navigateTo },
  useDidHide: vi.fn(), useDidShow: vi.fn(), useUnload: vi.fn(), useShareAppMessage: vi.fn(), useRouter: () => ({ params: {} })
}))

import { getPublicInitiative, getPublicInitiatives } from '../src/api/initiatives'
import { EventDetailQueryDocument, PublicInitiativeQueryDocument, PublicInitiativesQueryDocument } from '../src/api/operations'
import { InitiativeContent } from '../src/pages/initiative-detail'
import { EventRegistrationActions } from '../src/pages/event-detail'
import { detailQualificationBadgeText, filterInitiatives, formatAmountShort, initiativeCancelledNotice, initiativeCardStatusText, initiativeStatusText, parseQualificationBadge, participationConditionText, qualificationBadgeText } from '../src/domain/initiative'

const initiative: PublicInitiative = {
  id: 'initiative-1', slug: 'hackerstart1024', name: 'hackerstart1024', hashtag: '#hackerstart1024',
  description: '全国共同创作', status: 'closed', windowStartsAt: null, windowEndsAt: null,
  cityCount: 7, eventCount: 11, confirmedCount: 89, qualifiedEventCount: 5,
  cities: [{ city: '线上 / 待定', events: [
    { id: 'event-1', slug: 'event-1', title: '已取消场次', status: 'cancelled', startsAt: null, endsAt: null, registrationDeadline: null, venue: null, archived: true, qualificationBadge: 'cancelled', shortBy: null, paymentMode: 'free', deposit: { enabled: false, amountCents: null, refundableOnCheckIn: null }, minAge: null, priceRangeMinCents: null },
    { id: 'event-2', slug: 'event-2', title: '城市见面', status: 'open', startsAt: null, endsAt: null, registrationDeadline: null, venue: JSON.stringify({ country: '中国', province: '湖南省', city: '长沙市', district: '岳麓区' }), archived: false, qualificationBadge: 'short_by', shortBy: 3, paymentMode: 'deposit', deposit: { enabled: true, amountCents: 6900, refundableOnCheckIn: true }, minAge: 18, priceRangeMinCents: null }
  ] }]
}

beforeEach(() => { vi.clearAllMocks() })

describe('Initiative 公开 API 契约', () => {
  it('四项统计和城市分组原样使用后端结果，不按返回卡片重算', async () => {
    mocks.graphqlRequest.mockResolvedValue({ publicInitiative: initiative })
    expect(await getPublicInitiative('hackerstart1024')).toEqual(initiative)
    expect(mocks.graphqlRequest).toHaveBeenCalledWith(PublicInitiativeQueryDocument, { slug: 'hackerstart1024' })
  })

  it('not_found 与空列表有明确值，网络错误保留给页面重试', async () => {
    mocks.graphqlRequest.mockResolvedValueOnce({ publicInitiative: null }).mockResolvedValueOnce({ publicInitiatives: [] }).mockRejectedValueOnce(new Error('offline'))
    expect(await getPublicInitiative('missing')).toBeNull()
    expect(await getPublicInitiatives()).toEqual([])
    await expect(getPublicInitiative('retry')).rejects.toThrow('offline')
  })

  it('Event 卡片只查询派生徽章/留档，不取原始计数和成员字段', () => {
    const fields: string[] = []
    visit(parse(PublicInitiativeQueryDocument), {
      Field(node) {
        if (node.name.value === 'events') visit(node, { Field(field) { fields.push(field.name.value) } })
      }
    })
    expect(fields).toEqual(expect.arrayContaining(['archived', 'qualificationBadge', 'shortBy']))
    // 阶段4：与 web initiative 场次卡对齐的公开字段（venue/deadline 由公开投影给出）
    expect(fields).toEqual(expect.arrayContaining(['venue', 'registrationDeadline']))
    // #627 参与条件披露：白名单四键进选择集
    expect(fields).toEqual(expect.arrayContaining(['paymentMode', 'deposit', 'minAge', 'priceRangeMinCents']))
    expect(fields).not.toEqual(expect.arrayContaining(['confirmedCount']))
    for (const forbidden of ['workspaceId', 'capacity', 'minParticipants', 'qualificationStatus', 'rules', 'locked', 'valueJson', 'pricingEnabled', 'depositEnabled']) expect(fields).not.toContain(forbidden)
  })

  it('Initiative 卡片查询与 web 卡片同字段（description/窗口）', () => {
    const fields: string[] = []
    visit(parse(PublicInitiativesQueryDocument), { Field: (node) => { fields.push(node.name.value) } })
    expect(fields).toEqual(expect.arrayContaining(['description', 'windowStartsAt', 'windowEndsAt']))
  })

  it('发现页关键词过滤：命中 name/hashtag/description，大小写不敏感，空词原样返回', () => {
    const cards = [
      { name: '1024 程序员节', hashtag: '#1024', description: '跨城市共学' },
      { name: '开源之夏', hashtag: null, description: 'OSPP 2026' }
    ]
    const names = (input: string) => filterInitiatives(cards, input).map(({ name }) => name)
    expect(filterInitiatives(cards, '')).toBe(cards)
    expect(filterInitiatives(cards, '   ')).toBe(cards)
    expect(names('1024')).toEqual(['1024 程序员节'])
    expect(names('ospp')).toEqual(['开源之夏'])
    expect(names('#1024')).toEqual(['1024 程序员节'])
    expect(names('不存在的词')).toEqual([])
  })

  it('既有 Event 详情允许读取公开留档且查询同源徽章', () => {
    const document = parse(EventDetailQueryDocument)
    const fields: string[] = []
    const statuses: string[] = []
    visit(document, { Field: (node) => { fields.push(node.name.value) }, StringValue: (node) => { statuses.push(node.value) } })
    expect(statuses).toEqual(expect.arrayContaining(['open', 'closed', 'cancelled', 'public']))
    expect(fields).toEqual(expect.arrayContaining(['qualificationBadge', 'shortBy']))
    // 阶段1：回链落点字段必须在详情文档里（匿名可读，见后端 X1 契约测试）
    expect(fields).toContain('initiativeId')
  })
})

describe('Initiative 与留档详情展示', () => {
  it('城市/四计数/closed/取消徽章均呈现后端结果', () => {
    const html = renderToStaticMarkup(createElement(InitiativeContent, { data: initiative }))
    for (const text of ['城市', '场次', '报名', '>成班<', '>7<', '>11<', '>89<', '>5<', '线上 / 待定', '已结束 · 活动留档', '已取消', '还差 3 人成班', '查看活动留档', '地点：中国 湖南省 长沙市 岳麓区', '地点：地点待定', '报名截止：无截止']) expect(html).toContain(text)
  })

  // #627 卡片实际渲染内容（D4 覆盖证据）：三态缴费 + 年龄门槛在卡片上，成班进度在徽章上
  it('场次卡渲染参与条件：押金三态 / 年龄门槛 / 成班进度各就各位（#627）', () => {
    const html = renderToStaticMarkup(createElement(InitiativeContent, { data: initiative }))
    // 押金态场次（event-2）：金额 + 到场退 + 年龄门槛存在性
    for (const text of ['押金 ¥69（到场退） · 限 18+']) expect(html).toContain(text)
    // 免费态场次（event-1）：单槽只出「免费」，不并列押金
    expect(html).toContain('>免费<')
    expect(html).not.toContain('免费 · 押金')
    // 成班进度仍由既有徽章承载（不新增第二个进度数字）
    expect(html).toContain('还差 3 人成班')
    expect(html).not.toContain('人成班 · ')
    expect(html).not.toContain('¥0')
  })

  it('公开 Initiative 没有场次时显示空态', () => {
    const html = renderToStaticMarkup(createElement(InitiativeContent, { data: { ...initiative, cities: [], eventCount: 0 } }))
    expect(html).toContain('暂时还没有公开场次')
  })

  it.each(['closed', 'cancelled'])('%s Event 即便报名徽章过时也没有报名写入口', (status) => {
    const item = { status, enrollmentBadge: 'enrolling', myEnrollment: null } as CatalogItem
    const html = renderToStaticMarkup(createElement(EventRegistrationActions, { item, onRegister: vi.fn() }))
    expect(html).toContain('仅供查看')
    expect(html).not.toContain('register-action')
  })

  it('普通 open Event 保持报名入口', () => {
    const item = { status: 'open', enrollmentBadge: 'enrolling', myEnrollment: null } as CatalogItem
    expect(renderToStaticMarkup(createElement(EventRegistrationActions, { item, onRegister: vi.fn() }))).toContain('register-action')
  })

  it('closed 活动上的活跃报名保留「查看我的报名」入口（closed ≠ 活动结束）', () => {
    const item = { status: 'closed', enrollmentBadge: 'closed', endsAt: null, myEnrollment: { id: 'enr-1', status: 'confirmed', approvalDeadline: null } } as CatalogItem
    const html = renderToStaticMarkup(createElement(EventRegistrationActions, { item, onRegister: vi.fn() }))
    expect(html).toContain('view-my-enrollment')
    expect(html).not.toContain('仅供查看')
  })

  it('closed 且 endsAt 未过：提示「报名已截止」而非「活动已结束」', () => {
    const item = { status: 'closed', enrollmentBadge: 'closed', endsAt: '2099-01-01T00:00:00.000Z', myEnrollment: null } as CatalogItem
    const html = renderToStaticMarkup(createElement(EventRegistrationActions, { item, onRegister: vi.fn() }))
    expect(html).toContain('报名已截止，仅供查看。')
    expect(html).not.toContain('register-action')
  })

  it('closed 且 endsAt 已过：提示「活动已结束」', () => {
    const item = { status: 'closed', enrollmentBadge: 'closed', endsAt: '2020-01-01T00:00:00.000Z', myEnrollment: null } as CatalogItem
    expect(renderToStaticMarkup(createElement(EventRegistrationActions, { item, onRegister: vi.fn() }))).toContain('活动已结束，仅供查看。')
  })

  it('parseQualificationBadge：契约可空值 → null，未知非空值仍 throw', () => {
    expect(parseQualificationBadge(null)).toBeNull()
    expect(parseQualificationBadge(undefined)).toBeNull()
    expect(parseQualificationBadge('confirmed')).toBe('confirmed')
    expect(() => parseQualificationBadge('bogus')).toThrow('服务端返回未知成班状态')
  })

  it('成班事实与短缺数只翻译后端标签', () => {
    expect(qualificationBadgeText({ qualificationBadge: 'confirmed', shortBy: null })).toBe('已成班')
    expect(qualificationBadgeText({ qualificationBadge: 'closed', shortBy: null })).toBe('已结束')
    expect(qualificationBadgeText({ qualificationBadge: 'open', shortBy: null })).toBe('开放报名')
  })

  it('详情页徽章隐藏 open（与报名标签语义重复），其余照译', () => {
    expect(detailQualificationBadgeText({ qualificationBadge: null, shortBy: null })).toBeNull()
    expect(detailQualificationBadgeText({ qualificationBadge: 'open', shortBy: null })).toBeNull()
    expect(detailQualificationBadgeText({ qualificationBadge: 'short_by', shortBy: 3 })).toBe('还差 3 人成班')
    expect(detailQualificationBadgeText({ qualificationBadge: 'cancelled', shortBy: null })).toBe('已取消')
  })

  // #628：活动级状态文案分叉（detail 与 found 两处口径，三端一致）
  it('活动级状态文案：cancelled（中止）与 closed（收尾）分叉', () => {
    expect(initiativeStatusText('open')).toBe('进行中')
    expect(initiativeStatusText('closed')).toBe('已结束 · 活动留档')
    expect(initiativeStatusText('cancelled')).toBe('已取消 · 活动中止')
    expect(initiativeCardStatusText('open')).toBe('进行中')
    expect(initiativeCardStatusText('closed')).toBe('已结束')
    expect(initiativeCardStatusText('cancelled')).toBe('已取消')
    expect(initiativeStatusText('closed')).not.toBe(initiativeStatusText('cancelled'))
  })

  it('中止说明行只在 cancelled 出现', () => {
    expect(initiativeCancelledNotice('cancelled')).toContain('全额退款')
    expect(initiativeCancelledNotice('closed')).toBeNull()
    expect(initiativeCancelledNotice('open')).toBeNull()
  })
})


describe('三平台页面注册', () => {
  it.each(['weapp', 'tt', 'xhs'])('%s 包含 Initiative 与 Event 详情页', async (platform) => {
    const original = process.env.TARO_ENV
    vi.stubGlobal('defineAppConfig', (config: unknown) => config)
    try {
      process.env.TARO_ENV = platform
      vi.resetModules()
      const { default: config } = await import('../src/app.config')
      expect(config.pages).toContain('pages/initiative-detail/index')
      expect(config.pages).toContain('pages/event-detail/index')
    } finally {
      if (original === undefined) delete process.env.TARO_ENV
      else process.env.TARO_ENV = original
      vi.unstubAllGlobals()
    }
  })

  // #771：公开卡页只在微信全量端注册——它由分享链接进入，裁剪端没有闪念间
  // 深度场景（页内「站外公开」文案也过不了 check:diversion 词表）。
  // 平台清单在模块加载期读 process.env，故必须逐平台 resetModules + 动态 import。
  it('公开卡页仅微信全量端注册（裁剪端不挂）', async () => {
    const original = process.env.TARO_ENV
    vi.stubGlobal('defineAppConfig', (config: unknown) => config)
    try {
      for (const platform of ['weapp', 'tt', 'xhs']) {
        process.env.TARO_ENV = platform
        vi.resetModules()
        const { default: config } = await import('../src/app.config')
        if (platform === 'weapp') {
          expect(config.pages).toContain('pages/flashback-shared-card/index')
        } else {
          expect(config.pages).not.toContain('pages/flashback-shared-card/index')
        }
      }
    } finally {
      if (original === undefined) delete process.env.TARO_ENV
      else process.env.TARO_ENV = original
      vi.unstubAllGlobals()
    }
  })
})

/**
 * #627 参与条件披露：缴费槽**单槽三态** + 年龄门槛存在性。文案与 web
 * `/initiatives/[slug]` 场次卡逐字一致（zh）。
 */
describe('参与条件文案（#627）', () => {
  const base = { paymentMode: 'free' as const, deposit: { enabled: false, amountCents: null, refundableOnCheckIn: null }, minAge: null as number | null, priceRangeMinCents: null as number | null }

  it('押金态：金额 + 到场退 + 年龄门槛存在性', () => {
    expect(participationConditionText({ ...base, paymentMode: 'deposit', deposit: { enabled: true, amountCents: 6900, refundableOnCheckIn: true }, minAge: 18 }))
      .toBe('押金 ¥69（到场退） · 限 18+')
  })

  it('押金金额缺失/非正：不表态形态，绝不 ¥0（两个脏分支）', () => {
    for (const amount of [null, 0, -1]) {
      const text = participationConditionText({ ...base, paymentMode: 'deposit', deposit: { enabled: true, amountCents: amount, refundableOnCheckIn: true } })
      expect(text).toBe('押金（金额待定）')
      expect(text).not.toContain('¥0')
      expect(text).not.toContain('免费')
    }
  })

  it('收费态：金额锚出「起」；无金额锚走降级文案', () => {
    expect(participationConditionText({ ...base, paymentMode: 'pricing', priceRangeMinCents: 9900 })).toBe('收费 ¥99 起')
    expect(participationConditionText({ ...base, paymentMode: 'pricing', priceRangeMinCents: null })).toBe('收费（档位以活动页为准）')
  })

  it('免费态：单槽只出「免费」，无年龄门槛时不带「限」', () => {
    expect(participationConditionText(base)).toBe('免费')
    expect(participationConditionText(base)).not.toContain('限')
  })

  // F5 客户端同纪律：非正 minAge 不渲染门槛（与后端 positive_int 同判据）
  it('非正 minAge 不渲染「限 N+」', () => {
    for (const dirty of [0, -3]) {
      const text = participationConditionText({ ...base, minAge: dirty })
      expect(text).toBe('免费')
      expect(text).not.toContain('限')
    }
  })

  // F4：未知/缺失缴费态不得 fail-open 成「免费」（#586 病根：用默认值冒充事实）
  it('未知/缺失 paymentMode 落「缴费信息待定」，不冒充免费', () => {
    for (const mode of [undefined, null, 'unknown_mode'] as unknown[]) {
      const text = participationConditionText({ ...base, paymentMode: mode as never, minAge: 18 })
      expect(text).toBe('缴费信息待定 · 限 18+')
      expect(text).not.toContain('免费')
    }
  })

  it('短式格式化（与 web lib/payment 同式）；金额守卫单源已迁 domain/payment', () => {
    // F3：后端以「分」为整数单位；0.4 经 formatAmountShort 会四舍五入成 '0.00'
    // → 必须被 Number.isInteger 挡住（否则徽章显示「押金 ¥0.00（到场退）」）；
    // 守卫本体用例随函数迁到 payment-domain.test.ts（#675 单源）
    expect(formatAmountShort(0.4)).toBe('0.00')
    expect(formatAmountShort(6900)).toBe('69')
    expect(formatAmountShort(9950)).toBe('99.50')
  })

  it('成班进度不并入条件文案：单槽三态里不出现人数（复用徽章口径）', () => {
    const text = participationConditionText({ ...base, paymentMode: 'deposit', deposit: { enabled: true, amountCents: 6900, refundableOnCheckIn: true } })
    expect(text).not.toContain('人成班')
    // 徽章仍独立承载成班语义
    expect(qualificationBadgeText({ qualificationBadge: 'short_by', shortBy: 3 })).toBe('还差 3 人成班')
  })

  it('取消留档场照常带参与条件（卡片渲染源）', () => {
    const cancelled = initiative.cities[0].events[0]
    expect(participationConditionText(cancelled)).toBe('免费')
    expect(qualificationBadgeText(cancelled)).toBe('已取消')
  })
})
