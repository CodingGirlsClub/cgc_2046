import assert from 'node:assert/strict'
import { describe, test } from 'node:test'
import type { FlashbackCapsule, FlashbackMeAnswer } from '../src/domain/models.ts'
import {
  canSubmitWish,
  cityCandidates,
  myCardView,
  parseQuoteLevel,
  sentencesWithFog,
  splitSentences,
  toggleSentenceFog,
  wishQuotaCopy,
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
import {
  isCandidatePicked,
  quoteCandidatesOf,
  quoteLikeBadge,
  recordCardLayout,
  recordCardModel,
  shareMessage,
  shareOptInState,
  summaryCardLayout,
  summaryCardModel,
  wrapCardText
} from '../src/domain/flashback.ts'
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
  quoteSpans: [{ questionKey: 'self_intro', start: 0, len: 10 }],
  quoteStats: { likeCount: 0 },
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

// ── R35 选句器 / R36 点赞回显 / R37 分享 opt-in ─────────────────────────

const quoteAnswer = (over: Partial<FlashbackMeAnswer> = {}): FlashbackMeAnswer => ({
  id: 'a1',
  questionKey: 'self_intro',
  rawText: '我在盛大做测试。喜欢周末骑行。',
  fogSpans: [],
  text: '我在盛大做测试。喜欢周末骑行。',
  ...over
})

test('quoteCandidatesOf：按句切分、雾句灰显（U10）、区间可回切原文（R35）', () => {
  const candidates = quoteCandidatesOf([quoteAnswer()])

  assert.deepEqual(
    candidates.map((c) => c.sentence),
    ['我在盛大做测试。', '喜欢周末骑行。']
  )
  // 区间与展示同源：按 start/len 回切 = 原句（第二句起点 = 首句长度）
  for (const candidate of candidates) {
    assert.equal(quoteAnswer().rawText.slice(candidate.start, candidate.start + candidate.len), candidate.sentence)
  }

  // U10：雾面句不再被排除——带 fogged 标记（渲染层灰显锁定，想选先解雾）
  const fogged = quoteCandidatesOf([quoteAnswer({ fogSpans: [{ start: 0, len: 7 }] })])
  assert.deepEqual(
    fogged.map((c) => [c.sentence, c.fogged === true]),
    [
      ['我在盛大做测试。', true],
      ['喜欢周末骑行。', false]
    ]
  )

  // today 三/四行进候选（questionKey=today.*，带雾标记）
  const withToday = quoteCandidatesOf([quoteAnswer()], {
    nowStatus: '还在写代码，下班带娃。想开源一个工具。',
    want: null,
    need: null,
    say: '十周年快乐！',
    fogSpans: { now: [{ start: 0, len: 9 }] },
    sentToWallAt: null
  })
  const todayCands = withToday.filter((c) => c.questionKey.startsWith('today.'))
  assert.deepEqual(
    todayCands.map((c) => [c.questionKey, c.sentence, c.fogged === true]),
    [
      ['today.now', '还在写代码，下班带娃。', true],
      ['today.now', '想开源一个工具。', false],
      ['today.say', '十周年快乐！', false]
    ]
  )
  // 全雾面 → 候选保留但全部灰显锁定（想选先解雾）
  assert.deepEqual(
    quoteCandidatesOf([quoteAnswer({ fogSpans: [{ start: 0, len: 20 }] })]).map((c) => c.fogged === true),
    [true, true]
  )
  // 空文本/空白句丢弃；多题合并保留各自 questionKey
  assert.deepEqual(quoteCandidatesOf([quoteAnswer({ rawText: '   ' })]), [])
  const two = quoteCandidatesOf([quoteAnswer(), quoteAnswer({ id: 'a2', questionKey: 'funny_thing', rawText: '学过吉他。' })])
  assert.equal(two[two.length - 1].questionKey, 'funny_thing')
})

test('isCandidatePicked：区间与来源题同时相等才命中（多选白名单；存档回显/高亮）', () => {
  const candidate = quoteCandidatesOf([quoteAnswer()])[0]
  assert.equal(isCandidatePicked(candidate, null), false)
  assert.equal(
    isCandidatePicked(candidate, [
      { questionKey: 'self_intro', start: candidate.start, len: candidate.len },
    ]),
    true
  )
  // 长度或题不同 → 不命中（防止跨题同偏移误高亮）
  assert.equal(
    isCandidatePicked(candidate, [
      { questionKey: 'self_intro', start: candidate.start, len: candidate.len + 1 },
    ]),
    false
  )
  assert.equal(
    isCandidatePicked(candidate, [
      { questionKey: 'funny_thing', start: candidate.start, len: candidate.len },
    ]),
    false
  )
  // 多选：第二句命中也 true
  assert.equal(
    isCandidatePicked(candidate, [
      { questionKey: 'funny_thing', start: candidate.start, len: candidate.len },
      { questionKey: 'self_intro', start: candidate.start, len: candidate.len },
    ]),
    true
  )
})

test('quoteLikeBadge：上墙且有点赞才出现（R36）', () => {
  const base = me()
  assert.equal(quoteLikeBadge(base), null) // 未寄出（quoteStats 为 0 也只看上墙态）
  assert.equal(
    quoteLikeBadge({ ...base, today: { ...base.today!, sentToWallAt: '2026-09-18T00:00:00Z' } }),
    null
  ) // 上墙但 0 赞
  assert.equal(
    quoteLikeBadge({
      ...base,
      today: { ...base.today!, sentToWallAt: '2026-09-18T00:00:00Z' },
      quoteStats: { likeCount: 7 }
    }),
    '你的话被 7 人点赞'
  )
  // 未授权档（quoteStats null）→ 不显示
  assert.equal(
    quoteLikeBadge({ ...base, today: { ...base.today!, sentToWallAt: '2026-09-18T00:00:00Z' }, quoteStats: null }),
    null
  )
})

// ── 卡片四态（recordCardModel / recordCardLayout） ──────────────────

test('shareOptInState：未圈选不显示 / 已授权锁定 / 可勾选默认不勾（R37,多句）', () => {
  const base = { ...me(), quoteLevel: 'off' }
  // 有白名单句（quote + spans 齐备）→ 可勾选（默认不勾由页面 state 保证）
  assert.equal(shareOptInState(base), 'available')
  // 已授权（anonymous/credited）→ 锁定态
  assert.equal(shareOptInState({ ...base, quoteLevel: 'anonymous' }), 'already')
  assert.equal(shareOptInState({ ...base, quoteLevel: 'credited' }), 'already')
  // 无金句 / 白名单空 → 不显示（保守：无法可靠回填 spans）
  assert.equal(shareOptInState({ ...base, quote: null }), 'hidden')
  assert.equal(shareOptInState({ ...base, quoteSpans: [] }), 'hidden')
  assert.equal(shareOptInState({ ...base, quoteSpans: null }), 'hidden')
})

test('recordCardModel：三态内容切分 + 雾句保留标记（不再凭空消失）', () => {
  const withFog = me({
    answers: [
      {
        id: 'a1',
        questionKey: 'self_intro',
        rawText: '我在盛大做测试。想亲眼看看是不是真的！',
        text: '',
        fogSpans: [{ start: 0, len: 7 }]
      }
    ]
  })

  // today：题干取自 TODAY_FIELDS.label，只有有值的行成段（工厂 today 无 need）
  const today = recordCardModel(withFog, 'today')
  assert.deepEqual(
    today.sections.map((s) => s.title),
    ['现在在做什么', '想做的事 / 想学的东西']
  )

  // past：题干走 questionLabel；雾句**保留并标记**（旧口径会整句丢弃）
  const past = recordCardModel(withFog, 'past')
  assert.equal(past.sections[0].title, '请简单的介绍一下自己')
  assert.equal(past.sections[0].sentences[0].fogged, true)
  assert.equal(past.sections[0].sentences[0].text, '我在盛大做测试。')
  assert.equal(past.sections[0].sentences[1].fogged, false)

  // both：今天段在前、当年段在后
  const both = recordCardModel(withFog, 'both')
  assert.equal(both.sections.length, today.sections.length + past.sections.length)
  assert.equal(both.stamp, '2014.01.05 · 北京')
})

test('recordCardLayout：动态高（下限 800 / 内容驱动 / 超限截断）+ 坐标落在画布内', () => {
  const short = recordCardModel(me(), 'today')
  const shortLayout = recordCardLayout(short)
  assert.equal(shortLayout.H, 800)
  assert.equal(shortLayout.truncated, false)

  const heavy = recordCardModel(
    me({
      answers: Array.from({ length: 14 }, (_, i) => ({
        id: `a${i}`,
        questionKey: `q${i}`,
        rawText: '一段足够长的回答，用来把画布撑到上限。'.repeat(4),
        text: '',
        fogSpans: []
      }))
    }),
    'past'
  )
  const heavyLayout = recordCardLayout(heavy)
  assert.ok(heavyLayout.H > 800, '内容多应撑高')
  assert.ok(heavyLayout.H <= 2400, '不超过上限')
  assert.equal(heavyLayout.truncated, true, '超上限应标截断')

  for (const block of heavyLayout.blocks) {
    for (const line of block.lines) {
      assert.ok(line.top > 0 && line.top < heavyLayout.H, '行坐标应在画布内')
    }
  }
})


describe('许愿年度额度（R20：每年 3 条，含私有与已软删，删除不退还）', () => {
  test('canSubmitWish：草稿去空白非空 且 额度未尽', () => {
    // 空 draft（含纯空白）一律不可提交
    assert.equal(canSubmitWish(3, ''), false)
    assert.equal(canSubmitWish(3, '   \n\t '), false)
    // 额度 0 禁用（即使有内容）
    assert.equal(canSubmitWish(0, '想学 Rust'), false)
    // 正常：有内容 + 剩余额度
    assert.equal(canSubmitWish(3, '想学 Rust'), true)
    assert.equal(canSubmitWish(1, '想学 Rust'), true)
    // null（未登录/无 person）不拦——后端以 flashback_wish_quota_exceeded 兜底
    assert.equal(canSubmitWish(null, '想学 Rust'), true)
  })

  test('wishQuotaCopy：null 不渲染 / >0 报剩余 / 0 报用完', () => {
    assert.equal(wishQuotaCopy(null), null)
    assert.equal(wishQuotaCopy(3), '今年还可许 3 条')
    assert.equal(wishQuotaCopy(1), '今年还可许 1 条')
    assert.equal(wishQuotaCopy(0), '今年许愿名额已用完（每年最多 3 条，删除不退还名额）')
  })

  // wish2 U10（KTD11）：期望地实时候选——中文含输入 / 拼音前缀 / ≤6 截断，
  // 等于输入不重复提示；归一判定在服务端（不阻止名单外提交）
  test('cityCandidates：中文名包含匹配 + 拼音前缀 + 等值排除 + ≤6 截断', () => {
    const cities = [
      { name: '成都', pinyin: 'chengdu' },
      { name: '北京', pinyin: 'beijing' },
      { name: '上海', pinyin: 'shanghai' },
      { name: '广州', pinyin: 'guangzhou' },
      { name: '深圳', pinyin: 'shenzhen' },
      { name: '杭州', pinyin: 'hangzhou' },
      { name: '武汉', pinyin: 'wuhan' },
      { name: '西安', pinyin: 'xian' }
    ]
    assert.deepEqual(cityCandidates('', cities), [])
    assert.deepEqual(cityCandidates('  ', cities), [])
    // 拼音前缀
    assert.deepEqual(cityCandidates('chen', cities), ['成都'])
    assert.deepEqual(cityCandidates('Cheng', cities), ['成都'])
    // 等值不重复提示（已经是完整短名）
    assert.deepEqual(cityCandidates('成都', cities), [])
    // 中文包含
    assert.deepEqual(cityCandidates('京', cities), ['北京'])
    // 无命中
    assert.deepEqual(cityCandidates('亚特兰蒂斯', cities), [])
  })
})
