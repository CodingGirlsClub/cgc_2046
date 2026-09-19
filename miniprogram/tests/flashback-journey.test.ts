import assert from 'node:assert/strict'
import { describe, test } from 'node:test'
import { futureEventCards } from '../src/domain/flashback.ts'
import type { FlashbackCapsuleArchive, FlashbackMeAnswer, FlashbackPublicStatsArchive, FlashbackRosterEntry } from '../src/domain/models.ts'
import {
  cardFaceAnswers,
  corridorFrames,
  corridorPiles,
  eventFogLine,
  eventStats,
  journeyIntroLead,
  journeyQuiz,
  quizResultText,
  revealStamp,
  statsFrames,
  todayFrameLabel
} from '../src/domain/flashback-journey.ts'

// 判据与文案全部下沉 domain（页面无渲染测试，AGENTS.md）；本文件用 node --test
// 钉住 mp 版原型 F 的旅程（R6/R3/R7）、长廊（R12/R32/R34）与场次页判据。

const answer = (overrides: Partial<FlashbackMeAnswer> = {}): FlashbackMeAnswer => ({
  id: 'a1',
  questionKey: 'self_intro',
  rawText: '我在盛大做测试。',
  fogSpans: [],
  text: '',
  ...overrides
})

const roster = (overrides: Partial<FlashbackRosterEntry> = {}): FlashbackRosterEntry => ({
  id: 'r1',
  surnameMasked: '王**',
  fullName: null,
  appliedAt: null,
  city: '北京',
  occupationThen: '学生',
  sentToWallAt: null,
  today: null,
  answers: [],
  ...overrides
})

const archive = (overrides: Partial<FlashbackCapsuleArchive> = {}): FlashbackCapsuleArchive => ({
  key: '2014-01-11-bj',
  name: 'Rails Girls Beijing',
  city: '北京',
  occurredOn: '2014-01-11',
  appliedCount: 344,
  attendedCount: 102,
  isMine: true,
  roster: [],
  ...overrides
})

describe('journeyQuiz（R6 场次确认）', () => {
  test('2014-01-11 北京 → 命中池内「六城同日」，正确项首位、dunno 末位', () => {
    const quiz = journeyQuiz({ name: 'Rails Girls Beijing', city: '北京', occurredOn: '2014-01-11' })
    assert.equal(quiz.correct, 'six2014')
    assert.equal(quiz.options[0].id, 'six2014')
    assert.equal(quiz.options[0].label, '2014.1.11 · 六城同日')
    assert.equal(quiz.options[quiz.options.length - 1].id, 'dunno')
    // 干扰项不含与正确项重复的池项
    assert.ok(!quiz.options.slice(1, -1).some((option) => option.id === 'six2014'))
  })

  test('未命中池（2016 成都）→ 从档案生成正确项 label，hint=场次名', () => {
    const quiz = journeyQuiz({ name: 'Rails Girls Chengdu', city: '成都', occurredOn: '2016-05-14' })
    assert.equal(quiz.correct, 'mine')
    assert.equal(quiz.options[0].label, '2016 · 成都')
    assert.equal(quiz.options[0].hint, 'Rails Girls Chengdu')
    // 池内四个历史场次全部成为干扰项（2016 不在池内，全部保留）
    assert.deepEqual(quiz.options.slice(1, -1).map((option) => option.id), ['sh2012', 'bj2012', 'six2014', 'gz2015'])
  })

  test('无档案 → 兜底「当年那一场」', () => {
    const quiz = journeyQuiz(null)
    assert.equal(quiz.correctLabel, '当年那一场')
    assert.equal(quiz.options[0].label, '当年那一场')
  })

  test('quizResultText 三分支：答对 / dunno / 答错告知正确场次', () => {
    const quiz = journeyQuiz({ city: '北京', occurredOn: '2014-01-11' })
    assert.match(quizResultText('six2014', quiz), /答对了/)
    assert.match(quizResultText('dunno', quiz), /我们替你记得/)
    assert.match(quizResultText('sh2012', quiz), /六城同日/)
    assert.equal(quizResultText(null, quiz), '')
  })
})

describe('旅程文案（R3/R7）', () => {
  test('journeyIntroLead 相对年数动态；无时间戳回落', () => {
    assert.equal(journeyIntroLead('2014-01-11T13:06:00Z', new Date('2026-09-18T00:00:00Z')), '12 年前，你写过一些答案。')
    assert.equal(journeyIntroLead(null), '在这一切开始之前，你写过一些答案。')
    assert.equal(journeyIntroLead('not-a-date'), '在这一切开始之前，你写过一些答案。')
  })

  test('cardFaceAnswers 只取免费题、限张数', () => {
    const answers = [
      answer({ id: 'a1', questionKey: 'self_intro' }),
      answer({ id: 'a2', questionKey: 'funny_thing' }),
      answer({ id: 'a3', questionKey: 'why_join' }),
      answer({ id: 'a4', questionKey: 'os' })
    ]
    assert.deepEqual(cardFaceAnswers(answers).map(({ id }) => id), ['a1', 'a2'])
    assert.deepEqual(cardFaceAnswers(answers, 1).map(({ id }) => id), ['a1'])
  })

  test('revealStamp：2014.01.11 13:06 形态；缺省回落「当年」', () => {
    assert.equal(revealStamp('2014-01-11T13:06:00Z'), '2014.01.11 13:06')
    assert.equal(revealStamp('2014-01-11T13:06:00Z'.slice(0, 10)), '2014.01.11')
    assert.equal(revealStamp(null), '当年')
  })
})

describe('corridorPiles（R12/R34 城市堆）', () => {
  test('按城市聚合计数：计数降序、同数城市字典序；空城名过滤', () => {
    const piles = corridorPiles([
      roster({ city: '北京' }),
      roster({ city: '上海' }),
      roster({ city: '北京' }),
      roster({ city: '广州' }),
      roster({ city: '北京' }),
      roster({ city: '上海' }),
      roster({ city: null }),
      roster({ city: '  ' })
    ])
    assert.deepEqual(piles, [
      { city: '北京', count: 3, returned: 0 },
      { city: '上海', count: 2, returned: 0 },
      { city: '广州', count: 1, returned: 0 }
    ])
  })

  test('堆级已回来:per-city sentToWallAt 计数(G 原型:堆下「N 位已回来」)', () => {
    const piles = corridorPiles([
      roster({ city: '北京', sentToWallAt: '2026-01-01' }),
      roster({ city: '北京' }),
      roster({ city: '上海', sentToWallAt: '2026-01-02' }),
      roster({ city: '上海', sentToWallAt: '2026-01-03' }),
      roster({ city: '上海' })
    ])
    assert.deepEqual(piles, [
      { city: '上海', count: 3, returned: 2 },
      { city: '北京', count: 2, returned: 1 }
    ])
  })

  test('上限 4 堆（原型 slice(0,4)）', () => {
    const five = corridorPiles(['北京', '上海', '广州', '深圳', '成都'].map((city) => roster({ city })))
    assert.equal(five.length, 4)
  })
})

describe('corridorFrames / statsFrames（R12/R32 长廊帧）', () => {
  test('按场次时间升序（顶上是 2012，底部是未来），无日期者排最后；returned 计数', () => {
    const frames = corridorFrames([
      archive({ key: 'b', occurredOn: '2015-08-01', roster: [roster({ sentToWallAt: '2026-01-01' }), roster()] }),
      archive({ key: 'a', occurredOn: '2012-02-26' }),
      archive({ key: 'c', occurredOn: null })
    ])
    assert.deepEqual(frames.map(({ key }) => key), ['a', 'b', 'c'])
    assert.equal(frames[0].when, '2012.02.26')
    assert.equal(frames[1].returned, 1)
  })

  test('statsFrames：路人态只有统计堆（城市 + 走进教室人数），无名单无 returned', () => {
    const stats: FlashbackPublicStatsArchive[] = [
      { key: 'k1', name: 'A', city: '上海', occurredOn: '2012-02-26', appliedCount: 30, attendedCount: 12 },
      { key: 'k2', name: 'B', city: null, occurredOn: '2014-01-11', appliedCount: 344, attendedCount: null }
    ]
    const frames = statsFrames(stats)
    assert.deepEqual(frames[0].piles, [{ city: '上海', count: 12 }])
    // 走进教室缺失回落报名数（仍不泄露任何名单）；无城市的场次不渲染堆
    assert.deepEqual(frames[1].piles, [])
    assert.ok(frames.every(({ returned }) => returned === 0))
  })
})

describe('todayFrameLabel / 场次页判据', () => {
  test('今天格标头不补零（原型形态）', () => {
    assert.equal(todayFrameLabel(new Date('2026-09-18T04:00:00Z')), '⚡ 今天 2026.9.18 · 此刻 · 一闪念间')
  })

  test('eventStats：报名数缺失透传 null（不编造 0），returned 按寄出计数', () => {
    const stats = eventStats(
      archive({
        appliedCount: null,
        attendedCount: 102,
        roster: [roster({ sentToWallAt: '2026-01-01' }), roster(), roster({ sentToWallAt: '2026-01-02' })]
      })
    )
    assert.deepEqual(stats, { applied: null, attended: 102, returned: 2 })
  })

  test('eventFogLine：城市 · 职业 · 答案还在等她；全缺只剩尾句', () => {
    assert.equal(eventFogLine({ city: '北京', occupationThen: '学生' }), '北京 · 学生 · 答案还在等她')
    assert.equal(eventFogLine({ city: null, occupationThen: '学生' }), '学生 · 答案还在等她')
    assert.equal(eventFogLine({ city: null, occupationThen: null }), '答案还在等她')
  })
})

// ── U3 未来段:场次三行卡判据(AE1) ─────────────────────────────────
test('futureEventCards:可报名亮金带 CTA;满员/截止灰卡状态标签', () => {
  const frames = [
    {
      initiativeSlug: 'hackerstart1024',
      initiativeName: 'Hacker Start 1024',
      events: [
        { id: 'ev-1', slug: 'hs-1', title: 'Agent 入门工作坊', city: '北京', startsAt: '2026-10-24T06:00:00Z', capacity: 32, confirmedCount: 23, registrationDeadline: null },
        { id: 'ev-2', slug: 'hs-2', title: '上海站', city: '上海', startsAt: '2026-11-24T06:00:00Z', capacity: 16, confirmedCount: 16, registrationDeadline: null },
        { id: 'ev-3', slug: 'hs-3', title: '广州站(截止)', city: '广州', startsAt: '2026-12-01T06:00:00Z', capacity: 24, confirmedCount: 5, registrationDeadline: '2026-09-01T00:00:00Z' }
      ]
    }
  ]
  const cards = futureEventCards(frames)
  assert.equal(cards.length, 3)
  assert.equal(cards[0].status, 'open')
  assert.ok(cards[0].meta.includes('北京'))
  assert.ok(cards[0].meta.includes('23 人已报名'))
  assert.equal(cards[1].status, 'full')
  assert.equal(cards[2].status, 'closed')
  // 满员+截止同时命中 → 优先报满员
  const both = futureEventCards([{ initiativeSlug: 'x', initiativeName: 'x', events: [{ id: 'e', slug: 's', title: 't', city: null, startsAt: null, capacity: 10, confirmedCount: 10, registrationDeadline: '2020-01-01T00:00:00Z' }] }])
  assert.equal(both[0].status, 'full')
})

// ── U5/U6 判据:弹层可见性与回环出口数据 ───────────────────────────
test('futureEventCards:场次页回环「下一场」取首个 open(AE4/回环数据面)', () => {
  const frames = [{
    initiativeSlug: 'x', initiativeName: 'x',
    events: [
      { id: 'ev-full', slug: 's1', title: '满员场', city: null, startsAt: null, capacity: 10, confirmedCount: 10, registrationDeadline: null },
      { id: 'ev-open', slug: 's2', title: '可报名场', city: null, startsAt: null, capacity: 20, confirmedCount: 3, registrationDeadline: null }
    ]
  }]
  const next = futureEventCards(frames).find((card) => card.status === 'open')
  assert.equal(next?.id, 'ev-open')
  // 全满/全截止 → 无「下一场」出口(渲染层隐藏该钮)
  const allFull = futureEventCards([{ initiativeSlug: 'x', initiativeName: 'x', events: frames[0].events.map((e) => ({ ...e, id: e.id + 'x', confirmedCount: e.capacity ?? 10 })) }])
  assert.equal(allFull.find((card) => card.status === 'open'), undefined)
})
