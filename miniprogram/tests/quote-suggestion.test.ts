import assert from 'node:assert/strict'
import { describe, test } from 'node:test'
import {
  shouldOfferQuoteChoice,
  currentSuggestion,
  nextSuggestion,
  quoteLicenseBadge,
  quoteSuggestions
} from '../src/domain/quote-suggestion.ts'

const answer = (questionKey: string, rawText: string, fogSpans: { start: number; len: number }[] = []) => ({
  questionKey,
  rawText,
  fogSpans
})

describe('quoteSuggestions（#1022 寄出时「放进金句墙」的推荐句；规则与 web 逐条对齐）', () => {
  test('只从当年自由文本题取句，os / social_media 不推荐；自我介绍在前', () => {
    const list = quoteSuggestions(
      [
        answer('os', 'Windows 7 旗舰版，用了很多年。'),
        answer('funny_thing', '用 Excel 做过一个小游戏。'),
        answer('self_intro', '一个刚毕业的文科生。想亲眼看看代码是不是魔法。'),
        answer('social_media', '每天刷微博到半夜。')
      ],
      '王晓雨',
      '王'
    )

    assert.deepEqual(
      list.map((s) => s.sentence),
      ['一个刚毕业的文科生。', '想亲眼看看代码是不是魔法。', '用 Excel 做过一个小游戏。']
    )
    assert.deepEqual(
      { questionKey: list[0].questionKey, start: list[0].start, len: list[0].len },
      { questionKey: 'self_intro', start: 0, len: 10 }
    )
  })

  test('雾住的句子不推荐', () => {
    const list = quoteSuggestions([answer('self_intro', '我是一个文科生。我在深圳做设计。', [{ start: 8, len: 8 }])], '王晓雨', '王')

    assert.deepEqual(list.map((s) => s.sentence), ['我是一个文科生。'])
  })

  test('含本人全名或名（≥ 2 字）、疑似手机号或邮箱、不足 6 字的句子都不推荐', () => {
    const list = quoteSuggestions(
      [
        answer(
          'self_intro',
          '大家好，我是王晓雨。叫我晓雨就好。电话 13800138000。邮箱 wxy@example.com。你好。想亲眼看看代码是不是魔法。'
        )
      ],
      '王晓雨',
      '王'
    )

    assert.deepEqual(list.map((s) => s.sentence), ['想亲眼看看代码是不是魔法。'])
  })

  test('姓氏缺失或不匹配时仍过滤含名字的句子', () => {
    for (const surname of [null, '', '李']) {
      assert.deepEqual(quoteSuggestions([answer('self_intro', '大家叫我晓雨就好。')], '王晓雨', surname), [])
    }
  })

  test('名只有一个字时不按名过滤（避免误伤含同字的句子）', () => {
    const list = quoteSuggestions([answer('self_intro', '我想做一个芳草地的小网站。')], '李芳', '李')

    assert.deepEqual(list.map((s) => s.sentence), ['我想做一个芳草地的小网站。'])
  })
})

describe('currentSuggestion / nextSuggestion', () => {
  const list = quoteSuggestions([answer('self_intro', '第一句话在这里。第二句话在这里。第三句话在这里。')], '王晓雨', '王')

  test('没选过 → 第一句；「换一句」循环', () => {
    assert.equal(currentSuggestion(list, null)?.sentence, '第一句话在这里。')
    assert.equal(nextSuggestion(list, list[0])?.sentence, '第二句话在这里。')
    assert.equal(nextSuggestion(list, list[2])?.sentence, '第一句话在这里。')
  })

  test('选中的句从候选里消失 → 顺延到它之后的一句', () => {
    const remaining = list.filter((s) => s.start !== list[1].start)

    assert.equal(currentSuggestion(remaining, list[1])?.sentence, '第三句话在这里。')
    assert.equal(currentSuggestion(remaining, list[0])?.sentence, '第一句话在这里。')
  })

  test('没有候选 → null', () => {
    assert.equal(currentSuggestion([], null), null)
    assert.equal(nextSuggestion([], null), null)
  })
})

describe('quoteLicenseBadge（长廊底栏「← 金句授权」后缀）', () => {
  const span = [{ questionKey: 'self_intro', start: 0, len: 10 }]

  test('关闭 → 无后缀；开档且有句 → 匿名 ✓ / 实名 ✓', () => {
    assert.equal(quoteLicenseBadge('off', span), '')
    assert.equal(quoteLicenseBadge('anonymous', span), ' · 匿名 ✓')
    assert.equal(quoteLicenseBadge('credited', span), ' · 实名 ✓')
  })

  test('开档零句 = 墙上什么都没有：不给 ✓，说「未选句」', () => {
    assert.equal(quoteLicenseBadge('anonymous', []), ' · 未选句')
    assert.equal(quoteLicenseBadge('credited', null), ' · 未选句')
  })
})

// 同意文案两端逐字一致：读 web 的 zh-CN 源文件比对，任一端单独改都会红
describe('QUOTE_SEND_COPY 与 web 文案逐字一致', async () => {
  const { readFileSync } = await import('node:fs')
  const { QUOTE_SEND_COPY } = await import('../src/domain/quote-suggestion.ts')
  const { QUOTE_LEVEL_OPTIONS } = await import('../src/domain/flashback.ts')
  const zh = JSON.parse(readFileSync(new URL('../../web/messages/zh-CN.json', import.meta.url), 'utf8')).flashback

  test('寄出时的选择 + 授权面板零句提示', () => {
    assert.equal(QUOTE_SEND_COPY.eyebrow, zh.sendRegister.quoteChoiceTitle)
    assert.equal(QUOTE_SEND_COPY.withQuote, zh.sendRegister.confirmSendWithQuote)
    assert.equal(QUOTE_SEND_COPY.albumOnly, zh.sendRegister.confirmSendAlbumOnly)
    assert.equal(QUOTE_SEND_COPY.shuffle, zh.sendRegister.quoteShuffle)
    assert.equal(QUOTE_SEND_COPY.note, zh.sendRegister.quoteChoiceNote)
    assert.equal(QUOTE_SEND_COPY.sentWithQuote, zh.sendRegister.sentWithQuote)
    assert.equal(QUOTE_SEND_COPY.noPickHint, zh.licensePanel.noPickHint)
  })

  test('匿名档说明不再承诺「平台代挑」（web 为「匿名金句——」+ 同一句说明）', () => {
    const anonymous = QUOTE_LEVEL_OPTIONS.find((option) => option.value === 'anonymous')!
    assert.equal(`${anonymous.label}——${anonymous.desc}`, zh.write.quote_anonymous)
    assert.doesNotMatch(anonymous.desc, /平台可从/)
  })
})


test('寄出授权只在开档且已选句时跳过；零句仍提供选择', () => {
  assert.equal(shouldOfferQuoteChoice('off', true), true)
  assert.equal(shouldOfferQuoteChoice('anonymous', false), true)
  assert.equal(shouldOfferQuoteChoice('credited', false), true)
  assert.equal(shouldOfferQuoteChoice('anonymous', true), false)
  assert.equal(shouldOfferQuoteChoice('credited', true), false)
})
