import assert from 'node:assert/strict'
import { describe, test } from 'node:test'
import type { FlashbackCapsule, FlashbackMeAnswer, FlashbackMyActionCard } from '../src/domain/models.ts'
import {
  actionCardTarget,
  cardStatusText,
  endorseAction,
  myCardView,
  parseQuoteLevel,
  sentencesWithFog,
  splitActionCards,
  splitSentences,
  toggleSentenceFog,
  yearsAgoText
} from '../src/domain/flashback.ts'

// 相对导入（models.ts 经 flashback.ts 转型再导入）在 strip-types runner 下直接可跑；
// FlashbackMeAnswer 手工构造避免整条 capsule fixture。

const answer = (overrides: Partial<FlashbackMeAnswer> = {}): FlashbackMeAnswer => ({
  id: 'a1',
  questionKey: 'self_intro',
  rawText: '我在盛大做测试。想亲眼看看是不是真的！后来我成了程序员。',
  fogSpans: [],
  text: '我在盛大做测试。想亲眼看看是不是真的！后来我成了程序员。',
  ...overrides
})

describe('yearsAgoText（R3 相对年数）', () => {
  test('2014-01-11 报名，2026-09-18 查看 → 12 年前（周年未到不减错）', () => {
    assert.equal(yearsAgoText('2014-01-11T13:06:00Z', new Date('2026-09-18T00:00:00Z')), '12 年前')
  })

  test('周年当天恰好满 N 年', () => {
    assert.equal(yearsAgoText('2014-09-18T00:00:00Z', new Date('2026-09-18T12:00:00Z')), '12 年前')
  })

  test('周年前一天少一年', () => {
    assert.equal(yearsAgoText('2014-09-19T00:00:00Z', new Date('2026-09-18T12:00:00Z')), '11 年前')
  })

  test('2012 上海首场 → 14 年前（AE1）；同年内 → null（回落「当年」文案）', () => {
    assert.equal(yearsAgoText('2012-02-26T10:00:00Z', new Date('2026-09-18T00:00:00Z')), '14 年前')
    assert.equal(yearsAgoText('2026-01-01T00:00:00Z', new Date('2026-09-18T00:00:00Z')), null)
  })

  test('null / 非法值 → null', () => {
    assert.equal(yearsAgoText(null), null)
    assert.equal(yearsAgoText('not-a-date'), null)
  })
})

describe('句子雾化（R16/KTD4）', () => {
  test('splitSentences：句读切分且区间可重组原文', () => {
    const source = answer()
    const sentences = splitSentences(source.rawText)
    assert.equal(sentences.length, 3)
    const rejoined = sentences.map(({ text }) => text).join('')
    assert.equal(rejoined, source.rawText)
    assert.deepEqual(
      sentences.map(({ start, len }) => [start, len]),
      [[0, 8], [8, 11], [19, 9]]
    )
  })

  test('toggleSentenceFog：加雾 = 整句区间；解雾 = 剔除相交 span；输出有序', () => {
    const source = answer()
    const fogged = toggleSentenceFog(source, { start: 0, len: 8, text: '', fogged: false })
    assert.deepEqual(fogged, [{ start: 0, len: 8, reason: 'owner' }])

    // 与后端部分重叠的 span 也一并剔除（句子是操作粒度，R16「任意句标记雾面」）
    const partial = answer({ fogSpans: [{ start: 2, len: 3 }] })
    const cleared = toggleSentenceFog(partial, { start: 0, len: 8, text: '', fogged: false })
    assert.deepEqual(cleared, [])

    // 多 span 输出按 start 排序
    const multi = toggleSentenceFog(
      answer({ fogSpans: [{ start: 18, len: 10 }] }),
      { start: 0, len: 8, text: '', fogged: false }
    )
    assert.deepEqual(multi.map(({ start }) => start), [0, 18])
  })

  test('sentencesWithFog：相交即视为已雾；空文 → 空数组', () => {
    assert.deepEqual(sentencesWithFog(answer({ rawText: '', text: '' })), [])
    const partial = answer({ fogSpans: [{ start: 1, len: 2 }] })
    assert.deepEqual(sentencesWithFog(partial).map(({ fogged }) => fogged), [true, false, false])
  })
})

describe('行动板（R13 四态）', () => {
  const card = (overrides: Partial<FlashbackMyActionCard>): FlashbackMyActionCard => ({
    id: 'c1',
    title: '骑行场',
    city: '北京',
    status: 'forming',
    eventId: null,
    eventSlug: null,
    endorsementCount: 3,
    endorsedByMe: false,
    rolesClaimed: [],
    ...overrides
  })

  test('cardStatusText 四态中文', () => {
    assert.equal(cardStatusText('proposed'), '提议中')
    assert.equal(cardStatusText('forming'), '附议中')
    assert.equal(cardStatusText('scheduled'), '已成场')
    assert.equal(cardStatusText('done'), '已落地')
  })

  test('endorseAction：每张卡任何时刻有下一步（R13）', () => {
    assert.equal(endorseAction(card({ status: 'proposed', endorsementCount: 0 })).kind, 'endorse')
    const mine = endorseAction(card({ endorsedByMe: true }))
    assert.equal(mine.kind, 'endorse')
    assert.match(mine.label, /已附议/)

    const scheduled = endorseAction(card({ status: 'scheduled', eventId: 'e1', eventSlug: 's1' }))
    assert.equal(scheduled.kind, 'goEvent')
    assert.match(scheduled.label, /去报名/)

    assert.equal(endorseAction(card({ status: 'done' })).kind, 'done')
  })

  test('splitActionCards：已附议在前；actionCardTarget 仅 scheduled 有直链', () => {
    const cards = [
      card({ id: 'open-1' }),
      card({ id: 'mine-1', endorsedByMe: true }),
      card({ id: 'done-1', status: 'done', endorsedByMe: true })
    ]
    const { endorsed, open } = splitActionCards(cards)
    assert.deepEqual(endorsed.map(({ id }) => id), ['mine-1', 'done-1'])
    assert.deepEqual(open.map(({ id }) => id), ['open-1'])

    assert.equal(actionCardTarget(card({ status: 'scheduled', eventId: 'e9' })), '/pages/event-detail/index?id=e9&kind=event')
    assert.equal(actionCardTarget(card({ status: 'forming', eventId: 'e9' })), null)
    assert.equal(actionCardTarget(card({ status: 'scheduled', eventId: null })), null)
  })
})

describe('myCardView（R2 分线 + R3 年数 + R11 寄出态）', () => {
  test('记忆线已寄出 / 圆梦线未寄出', () => {
    const capsule = (participation: 'attended' | 'not_selected', sentToWallAt: string | null): FlashbackCapsule => ({
      me: {
        id: 'p1',
        fullName: '王小明',
        surname: '王',
        city: '北京',
        occupationThen: null,
        participation,
        appliedAt: '2014-01-11T13:06:00Z',
        quote: null,
        quoteLevel: 'off',
        today: { nowStatus: null, want: null, say: null, sentToWallAt },
        answers: []
      },
      actionCards: [],
      cities: []
    })

    const onWall = myCardView(capsule('attended', '2026-09-01T00:00:00Z'), new Date('2026-09-18T00:00:00Z'))
    assert.equal(onWall.headline, '王小明 · 12 年前的你')
    assert.equal(onWall.subline, '记忆线 · 北京')
    assert.equal(onWall.wallState, 'on_wall')

    const offWall = myCardView(capsule('not_selected', null), new Date('2026-09-18T00:00:00Z'))
    assert.equal(offWall.subline, '圆梦线 · 北京')
    assert.equal(offWall.wallState, 'off_wall')
  })
})

describe('parseQuoteLevel（R31 授权档恢复，fail-closed）', () => {
  test('合法三档透传', () => {
    assert.equal(parseQuoteLevel('off'), 'off')
    assert.equal(parseQuoteLevel('anonymous'), 'anonymous')
    assert.equal(parseQuoteLevel('credited'), 'credited')
  })

  test('非法/未知/缺省 → off（默认关，不透传）', () => {
    assert.equal(parseQuoteLevel('whitelist'), 'off')
    assert.equal(parseQuoteLevel(''), 'off')
    assert.equal(parseQuoteLevel(null), 'off')
    assert.equal(parseQuoteLevel(undefined), 'off')
  })
})

// ── R14 分享（用户定稿 ③）：shareMessage / summaryCardModel ───────────────
import { shareMessage, summaryCardLayout, summaryCardModel, wrapCardText } from '../src/domain/flashback.ts'
import type { FlashbackMyCard } from '../src/domain/models'

const me = (over: Partial<FlashbackMyCard> = {}): FlashbackMyCard => ({
  id: 'p1',
  fullName: '王若愚',
  surname: '王',
  city: '北京',
  occupationThen: null,
  participation: 'attended',
  appliedAt: '2014-01-05T05:06:00.000Z',
  quote: '我想亲眼看看是不是。',
  quoteLevel: 'anonymous',
  today: { nowStatus: '还在写代码', want: '想骑行', say: null, sentToWallAt: null },
  answers: [],
  ...over
})

test('shareMessage：相对年数动态标题（2026-09 对 2014-01 = 12 年前）', () => {
  assert.equal(shareMessage(me(), new Date('2026-09-18T00:00:00Z')).title, '我找到了 12 年前的自己 · 闪念间')
  // 时间戳缺失 → 当年的自己
  assert.equal(shareMessage(me({ appliedAt: null })).title, '我找到了 当年的自己 · 闪念间')
})

test('summaryCardModel：时间戳+城市 / 金句兜底链 / 今天行 / 年份脚注', () => {
  const model = summaryCardModel(me(), new Date('2026-09-18T00:00:00Z'))
  assert.equal(model.stamp, '2014.01.05 · 北京')
  assert.equal(model.quote, '我想亲眼看看是不是。')
  assert.equal(model.todayLine, '想骑行')
  assert.equal(model.footer, '12 年前 · IN A FLASH 闪念间')

  // 金句缺失 → 想做的事兜底；再缺 → 显影占位
  const noQuote = summaryCardModel(me({ quote: null, today: null }))
  assert.equal(noQuote.quote, '答案还在显影中')
  assert.equal(noQuote.todayLine, null)
})

test('wrapCardText：全角 1em/半角 0.5em 折行 + 超行截断省略（摘要卡排版判据）', () => {
  // 全角 10em 宽：每行 5 个汉字
  assert.deepEqual(wrapCardText('一二三四五六七八九十', 5, 5), ['一二三四五', '六七八九十'])
  // 半角计 0.5em：10 个半角字符 = 5em → 一行放得下 20 个
  assert.deepEqual(wrapCardText('abcdefghij', 5, 5), ['abcdefghij'])
  // 超行数 → 截断 + 省略号（末行去掉一个字符再补 …）
  assert.deepEqual(wrapCardText('一二三四五六七八九十', 5, 1), ['一二三四…'])
  // 换行符按硬换行处理；空文本/非法上限返回空
  assert.deepEqual(wrapCardText('一\n二', 5, 5), ['一', '二'])
  assert.deepEqual(wrapCardText('', 5, 5), [])
  assert.deepEqual(wrapCardText('一', 5, 0), [])
  // 长金句的极端用例：绝不超过 maxLines（画布内不越界）
  const long = wrapCardText(`“${'我想知道写东西的人能不能学会让机器听懂人话。'.repeat(6)}”`, 440 / 30, 5)
  assert.equal(long.length, 5)
  assert.ok(long[4].endsWith('…'))
})

test('summaryCardLayout：kicker/时间戳/金句/今天的你/脚注全部落在 600×800 画布内', () => {
  const cases = [
    { quote: '我想亲眼看看是不是。', todayLine: '想骑行', footer: '12 年前 · IN A FLASH 闪念间' },
    { quote: '答案还在显影中', todayLine: null, footer: 'IN A FLASH · 闪念间' },
    { quote: '短', todayLine: '一二三四五六七八九十一二三四五六七八九十一二三四五六七八九十', footer: 'f' },
    { quote: '我想知道写东西的人能不能学会让机器听懂人话。'.repeat(8), todayLine: 'x'.repeat(200), footer: 'f' }
  ]
  for (const model of cases) {
    const l = summaryCardLayout(model)
    const lastQuoteBottom = l.quoteTop + l.quoteLines.length * l.quoteLineHeight
    const lastTodayBottom = l.todayTop + l.todayLines.length * l.todayLineHeight
    assert.ok(l.kickerTop >= 24, `kicker ${l.kickerTop}`)
    assert.ok(l.stampTop > l.kickerTop, 'stamp 在 kicker 之下')
    assert.ok(l.quoteTop > l.stampTop + 20, '金句在时间戳之下')
    // 下边界：金句不压分割线、今天的你不压脚注、脚注在内框之内
    assert.ok(lastQuoteBottom <= l.dividerY - 20, `金句底 ${lastQuoteBottom} vs 分割线 ${l.dividerY}`)
    if (l.todayLines.length) assert.ok(lastTodayBottom <= l.footerTop - 20, `今天底 ${lastTodayBottom} vs 脚注 ${l.footerTop}`)
    assert.ok(l.footerTop + 16 <= l.H - 24, `脚注底 ${l.footerTop + 16} 越内框`)
    assert.ok(l.dividerY <= l.H - 24 && l.todayTop <= l.H - 24, '分割线/今天起点在画布内')
    assert.ok(l.quoteLines.length <= 5 && l.todayLines.length <= 3, '行数封顶')
  }
})
