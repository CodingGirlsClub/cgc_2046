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
import { EventDetailQueryDocument, PublicInitiativeQueryDocument } from '../src/api/operations'
import { InitiativeContent } from '../src/pages/initiative-detail'
import { EventRegistrationActions } from '../src/pages/event-detail'
import { qualificationBadgeText } from '../src/domain/initiative'

const initiative: PublicInitiative = {
  id: 'initiative-1', slug: 'hackerstart1024', name: 'hackerstart1024', hashtag: '#hackerstart1024',
  description: '全国共同创作', status: 'closed', windowStartsAt: null, windowEndsAt: null,
  cityCount: 7, eventCount: 11, confirmedCount: 89, qualifiedEventCount: 5,
  cities: [{ city: '线上 / 待定', events: [
    { id: 'event-1', slug: 'event-1', title: '已取消场次', status: 'cancelled', startsAt: null, endsAt: null, archived: true, qualificationBadge: 'cancelled', shortBy: null },
    { id: 'event-2', slug: 'event-2', title: '城市见面', status: 'open', startsAt: null, endsAt: null, archived: false, qualificationBadge: 'short_by', shortBy: 3 }
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
    expect(fields).not.toEqual(expect.arrayContaining(['confirmedCount']))
    for (const forbidden of ['workspaceId', 'capacity', 'minParticipants', 'qualificationStatus']) expect(fields).not.toContain(forbidden)
  })

  it('既有 Event 详情允许读取公开留档且查询同源徽章', () => {
    const document = parse(EventDetailQueryDocument)
    const fields: string[] = []
    const statuses: string[] = []
    visit(document, { Field: (node) => { fields.push(node.name.value) }, StringValue: (node) => { statuses.push(node.value) } })
    expect(statuses).toEqual(expect.arrayContaining(['open', 'closed', 'cancelled', 'public']))
    expect(fields).toEqual(expect.arrayContaining(['qualificationBadge', 'shortBy']))
  })
})

describe('Initiative 与留档详情展示', () => {
  it('城市/四计数/closed/取消徽章均呈现后端结果', () => {
    const html = renderToStaticMarkup(createElement(InitiativeContent, { data: initiative }))
    for (const text of ['城市', '场次', '报名', '开成', '>7<', '>11<', '>89<', '>5<', '线上 / 待定', '已结束 · 活动留档', '已取消', '还差 3 人成班', '查看活动留档']) expect(html).toContain(text)
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

  it('成班事实与短缺数只翻译后端标签', () => {
    expect(qualificationBadgeText({ qualificationBadge: 'confirmed', shortBy: null })).toBe('已成班')
    expect(qualificationBadgeText({ qualificationBadge: 'closed', shortBy: null })).toBe('已结束')
    expect(qualificationBadgeText({ qualificationBadge: 'open', shortBy: null })).toBe('开放报名')
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
})
