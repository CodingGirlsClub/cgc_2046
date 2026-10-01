/**
 * 寄出时「放进金句墙」（#1022）：推荐句规则 + 长廊底栏授权徽标。
 *
 * 规则与 web `components/flashback/quote-suggestion.ts` 逐条对齐——两端是独立包、
 * 不共享源码，这份重复是有意的；改规则须两端同 PR 同步（用例也逐条对齐）。
 */
import { parseQuoteLevel, todaySentencesWithFog } from './flashback.ts'

/** questionKey/start/len 即 chosenQuoteSpans 的一项 */
export interface QuoteSuggestion {
  questionKey: string
  start: number
  len: number
  /** 展示用（首尾空白已去；区间仍覆盖整句，含句读） */
  sentence: string
}

type SuggestionSpot = Pick<QuoteSuggestion, 'questionKey' | 'start'>
type SourceAnswer = { questionKey: string; rawText: string; fogSpans: Array<{ start: number; len: number }> | null }

/** 推荐来源 = 当年的自由文本题，按此顺序；os / social_media 是结构化答案，不当金句推荐 */
const SOURCE_KEYS = ['self_intro', 'funny_thing']
// ponytail: 字数门槛是经验值（挡「你好。」这类碎句），看到真实选句分布再调
const MIN_CHARS = 6
const PHONE_LIKE = /\d{7,}/

/**
 * 候选 = 来源题里未雾住的句子，排除：含本人全名或名（名 ≥ 2 字才比对，单字名
 * 误伤太多）、疑似手机号或邮箱、去空白后不足 6 字。当年答案几乎没有预先雾化，
 * 「我叫王晓雨」这类句子一旦被默认推荐，匿名就破了。
 */
export function quoteSuggestions(answers: SourceAnswer[], fullName: string, surname?: string | null): QuoteSuggestion[] {
  const givenName = surname && fullName.startsWith(surname) ? fullName.slice(surname.length) : Array.from(fullName).slice(1).join('')
  const names = Array.from(givenName).length >= 2 ? [fullName, givenName] : [fullName]

  return SOURCE_KEYS.flatMap((questionKey) =>
    answers
      .filter((answer) => answer.questionKey === questionKey)
      .flatMap((answer) =>
        todaySentencesWithFog(answer.rawText, answer.fogSpans ?? [])
          .filter((sentence) => !sentence.fogged)
          .map((sentence) => ({ questionKey, start: sentence.start, len: sentence.len, sentence: sentence.text.trim() }))
      )
  ).filter(
    ({ sentence }) =>
      Array.from(sentence).length >= MIN_CHARS &&
      !names.some((name) => name && sentence.includes(name)) &&
      !PHONE_LIKE.test(sentence) &&
      !sentence.includes('@')
  )
}

const sameSpot = (a: SuggestionSpot, b: SuggestionSpot) => a.questionKey === b.questionKey && a.start === b.start

const isAfter = (a: SuggestionSpot, b: SuggestionSpot) => {
  const order = SOURCE_KEYS.indexOf(a.questionKey) - SOURCE_KEYS.indexOf(b.questionKey)
  return order > 0 || (order === 0 && a.start > b.start)
}

/** 当前展示句：选中的还在候选里就是它；从候选里消失 → 顺延到它之后的一句，没有则回到第一句 */
export function currentSuggestion(list: QuoteSuggestion[], chosen: SuggestionSpot | null): QuoteSuggestion | null {
  if (!list.length) return null
  if (!chosen) return list[0]
  return list.find((item) => sameSpot(item, chosen)) ?? list.find((item) => isAfter(item, chosen)) ?? list[0]
}

/** 「换一句」：循环到下一句 */
export function nextSuggestion(list: QuoteSuggestion[], current: SuggestionSpot | null): QuoteSuggestion | null {
  if (!list.length) return null
  const index = current ? list.findIndex((item) => sameSpot(item, current)) : -1
  return list[(index + 1) % list.length]
}

/** 长廊底栏「← 金句授权」后缀：开档且有句才给 ✓；开档零句 = 墙上什么都没有，明说「未选句」 */
export function quoteLicenseBadge(level: string, spans: unknown[] | null): string {
  const parsed = parseQuoteLevel(level)
  if (parsed === 'off') return ''
  if (!spans?.length) return ' · 未选句'
  return parsed === 'anonymous' ? ' · 匿名 ✓' : ' · 实名 ✓'
}

/** 寄出时选择的文案（与 web flashback.sendRegister.* 逐字一致，tests/quote-suggestion.test.ts 钉住） */
export const QUOTE_SEND_COPY = {
  eyebrow: '放进金句墙的一句 · 匿名',
  withQuote: '寄出，并把这句匿名放进金句墙 →',
  albumOnly: '寄出到相册',
  shuffle: '换一句 ↻',
  note: '金句墙所有人可见、不用登录；相册只有登录的学员可见。两者都能随时撤回。',
  sending: '正在寄出…',
  sentWithQuote: '这句话已放进金句墙。',
  /** 长廊授权弹层：开档零句（与 web flashback.licensePanel.noPickHint 一致） */
  noPickHint: '还没选句子——墙上暂不显示。'
} as const

/** 开档不是完成授权；有具体选句时才跳过寄出时的选择。 */
export function shouldOfferQuoteChoice(level: string, hasSelectedQuotes: boolean): boolean {
  return parseQuoteLevel(level) === 'off' || !hasSelectedQuotes
}
