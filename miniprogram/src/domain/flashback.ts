import type { FlashbackCapsule, FlashbackFogSpan, FlashbackFutureFrame, FlashbackMeAnswer, FlashbackMyCard } from './models'

/**
 * 「我的闪念间」（U9/R28）页面判据与文案——页面无渲染测试（AGENTS.md），
 * 一切可测逻辑下沉于此，tests/flashback-domain.test.ts 用 node --test 钉住。
 *
 * 数据源：flashbackCapsule query（登录态 = person.user_id 绑定档案；
 * token 面归 web 首程 H5，小程序只做回访正门）。
 */

/** R3 相对年数：按本人 applied_at 动态计算（跨年即 +1，无全局常数）。
 * null / 不可解析 → null（页面回落「当年」文案，AE1 第三分支）。 */
export function yearsAgoText(appliedAt: string | null, now: Date = new Date()): string | null {
  if (!appliedAt) return null
  const applied = new Date(appliedAt)
  if (Number.isNaN(applied.getTime())) return null
  let years = now.getUTCFullYear() - applied.getUTCFullYear()
  const beforeAnniversary =
    now.getUTCMonth() < applied.getUTCMonth() ||
    (now.getUTCMonth() === applied.getUTCMonth() && now.getUTCDate() < applied.getUTCDate())
  if (beforeAnniversary) years -= 1
  return years > 0 ? `${years} 年前` : null
}

// ── 雾化编辑（R16/KTD4：句子级开关） ─────────────────────────────────

export interface SentenceRange {
  start: number
  len: number
  text: string
  fogged: boolean
}

/** 原文按中英文句读切句（保留分隔符，区间可完整重组原文）。 */
export function splitSentences(rawText: string): SentenceRange[] {
  if (!rawText) return []
  const sentences: SentenceRange[] = []
  let cursor = 0
  const boundary = /[。！？!?\n]+/g
  let match: RegExpExecArray | null
  while ((match = boundary.exec(rawText)) !== null) {
    const end = match.index + match[0].length
    if (end > cursor) sentences.push({ start: cursor, len: end - cursor, text: rawText.slice(cursor, end), fogged: false })
    cursor = end
  }
  if (cursor < rawText.length) {
    sentences.push({ start: cursor, len: rawText.length - cursor, text: rawText.slice(cursor), fogged: false })
  }
  return sentences
}

/** 句子与 span 是否相交（span 与句子都落在同一段原文坐标上）。 */
function spansOverlap(a: FlashbackFogSpan, b: SentenceRange): boolean {
  return a.start < b.start + b.len && b.start < a.start + a.len
}

/** 句子级雾化视图：fogged = 与既有任一 span 相交。 */
export function sentencesWithFog(answer: FlashbackMeAnswer): SentenceRange[] {
  return splitSentences(answer.rawText).map((sentence) => ({
    ...sentence,
    fogged: (answer.fogSpans ?? []).some((span) => spansOverlap(span, sentence))
  }))
}

/** 切换某句雾/解雾 → 新 spans（句子雾 = 整句区间；解雾 = 剔除相交 span）。
 * 输出按 start 排序，供 flashbackAdjustFog 原样提交（后端校验重叠/越界）。 */
export function toggleSentenceFog(
  answer: FlashbackMeAnswer,
  sentence: SentenceRange
): FlashbackFogSpan[] {
  const existing = answer.fogSpans ?? []
  const hit = existing.some((span) => spansOverlap(span, sentence))
  const next = hit
    ? existing.filter((span) => !spansOverlap(span, sentence))
    : [...existing, { start: sentence.start, len: sentence.len, reason: 'owner' }]
  return next.sort((a, b) => a.start - b.start)
}

// ── R35 金句圈选（候选句 = 按句切分、排除雾面段） ──────────────────────

export interface QuoteCandidate {
  questionKey: string
  /** 展示用（首尾空白已去；区间仍覆盖整句，含句读） */
  sentence: string
  /** 原文偏移（与 fog span 同一坐标系：splitSentences 的切片口径） */
  start: number
  len: number
}

/** 金句候选（R35，与 web write.tsx 的 quoteCandidatesOf 同规则）：
 *  - 按句读切分（splitSentences，保留分隔符）；
 *  - **排除雾面段**（雾面句对外不可见，不能当金句——KTD4/R14 纪律）；
 *  - 空白句丢弃；grapheme 偏移随句携带，圈选后原样回填 chosen_quote_span。
 * 「未圈选 = 不上墙」：候选只是选项，真正授权由调用方在选中时提交。 */
export function quoteCandidatesOf(answers: FlashbackMeAnswer[]): QuoteCandidate[] {
  const result: QuoteCandidate[] = []
  for (const answer of answers) {
    for (const sentence of sentencesWithFog(answer)) {
      if (sentence.fogged) continue
      const sentenceText = sentence.text.trim()
      if (!sentenceText) continue
      result.push({
        questionKey: answer.questionKey,
        sentence: sentenceText,
        start: sentence.start,
        len: sentence.len
      })
    }
  }
  return result
}

/** 圈选命中判定（存档态回显与列表高亮共用）：区间与来源题同时相等 */
export function isCandidatePicked(
  candidate: QuoteCandidate,
  picked: { questionKey: string | null; start: number; len: number } | null
): boolean {
  if (!picked) return false
  return (
    picked.questionKey === candidate.questionKey &&
    picked.start === candidate.start &&
    picked.len === candidate.len
  )
}

// ── R36 作者侧点赞数 / R37 分享 opt-in ────────────────────────────────

/** 我的卡上的点赞徽章（R36）：上墙且有点赞才出现，否则 null（不占位） */
export function quoteLikeBadge(me: FlashbackMyCard): string | null {
  if (!me.today?.sentToWallAt) return null
  const count = me.quoteStats?.likeCount ?? 0
  return count > 0 ? `你的话被 ${count} 人点赞` : null
}

/** 分享 opt-in 三态（R37）：
 *  - hidden：卡上没有可回填的选定金句（未圈选/未授权无 span）→ 不显示选项；
 *  - already：已授权（anonymous/credited）→ 勾选态 + 禁用（分享改不了档位）；
 *  - available：可勾选，默认不勾（授权永不预选）。 */
export function shareOptInState(me: FlashbackMyCard): 'hidden' | 'already' | 'available' {
  if (me.quoteLevel === 'anonymous' || me.quoteLevel === 'credited') return 'already'
  if (!me.quote || !me.quoteQuestionKey || !me.quoteSpan) return 'hidden'
  return 'available'
}

// ── 金句授权（R31 两档 + 关） ─────────────────────────────────────────

export type QuoteLevel = 'off' | 'anonymous' | 'credited'

export const QUOTE_LEVEL_OPTIONS: { value: QuoteLevel; label: string; desc: string }[] = [
  // 文案与 web 端 i18n(flashback.write.quote_*)逐字对齐——同一授权动作跨端一致;
  // web 端经 UAT 定稿,「你的语言,会成为别人的勇气。」底部语两端同源
  { value: 'off', label: '关闭', desc: '（默认）你的答案只对自己可见' },
  { value: 'anonymous', label: '匿名金句', desc: '平台可从当年答案挑一句匿名传播（署「王** · 年 · 城」）' },
  { value: 'credited', label: '实名支持', desc: '补充你现在在做什么，实名公开（可作品牌素材）' }
]

export function quoteLevelText(level: string): string {
  return QUOTE_LEVEL_OPTIONS.find((option) => option.value === level)?.label ?? level
}

/** 授权档 fail-closed 解析（P3）：capsule.me.quoteLevel 原始 string → 合法档；
 * 非法/未知/缺省一律回落 off（R31 默认关——授权是白名单行为，不做透传）。 */
export function parseQuoteLevel(value: string | null | undefined): QuoteLevel {
  return value === 'anonymous' || value === 'credited' ? value : 'off'
}

// ── 我的卡视图 ────────────────────────────────────────────────────────

export interface MyCardView {
  headline: string
  subline: string
  wallState: 'on_wall' | 'off_wall'
}

/** 我的卡头部文案：相对年数（R3）+ 分线（R2）+ 寄出态（R11）。 */
export function myCardView(capsule: FlashbackCapsule, now: Date = new Date()): MyCardView {
  const { me } = capsule
  const years = yearsAgoText(me.appliedAt, now)
  const when = years ? `${years}的你` : '当年的你'
  const line = me.participation === 'attended' ? '记忆线' : '圆梦线'
  return {
    headline: `${me.fullName} · ${when}`,
    subline: `${line}${me.city ? ` · ${me.city}` : ''}`,
    wallState: me.today?.sentToWallAt ? 'on_wall' : 'off_wall'
  }
}

// ── R14 小程序侧分享（用户定稿 ③，原型 F 分享浮层） ─────────────────────

/** 分享文案（转发好友/朋友圈共用标题）：相对年数动态计算 */
export function shareMessage(me: FlashbackMyCard, now: Date = new Date()): { title: string } {
  const years = yearsAgoText(me.appliedAt, now)
  const tail = years ? `${years}的自己` : '当年的自己'
  return { title: `我找到了 ${tail} · 闪念间` }
}

/** 摘要卡折行（纯函数，node --test 钉住）：CJK 全角计 1em、其余计 0.5em，
 * 超宽折行；超过 maxLines 截断并加省略号。canvas 只按行绘制——
 * 排版判据下沉 domain（页面无渲染测试），也免去 measureText 的平台差异。 */
export function wrapCardText(text: string, maxEmPerLine: number, maxLines: number): string[] {
  if (!text || maxLines <= 0 || maxEmPerLine <= 0) return []
  const widthOf = (ch: string): number => (/[\u2E80-\u9FFF\u3000-\u303F\uFF00-\uFF60\uFE30-\uFE4F]/.test(ch) ? 1 : 0.5)
  const lines: string[] = []
  let line = ''
  let lineEm = 0
  for (const ch of Array.from(text)) {
    if (ch === '\n') {
      if (line) lines.push(line)
      line = ''
      lineEm = 0
      continue
    }
    const w = widthOf(ch)
    if (line && lineEm + w > maxEmPerLine) {
      lines.push(line)
      line = ''
      lineEm = 0
    }
    line += ch
    lineEm += w
  }
  if (line) lines.push(line)
  if (lines.length <= maxLines) return lines
  const kept = lines.slice(0, maxLines)
  const last = Array.from(kept[maxLines - 1])
  kept[maxLines - 1] = `${last.slice(0, Math.max(1, last.length - 1)).join('')}…`
  return kept
}

/** 摘要卡绘图模型（R14：时间戳+城市+金句+今天的你，竖版 3:4）——纯函数，
 * canvas 绘制与保存流程（页面层）消费；title 兜底链：金句 → 想做的事 → 当年文案 */
export function summaryCardModel(me: FlashbackMyCard, now: Date = new Date()): {
  stamp: string
  quote: string
  todayLine: string | null
  footer: string
} {
  const years = yearsAgoText(me.appliedAt, now)
  const date = me.appliedAt ? me.appliedAt.slice(0, 10).replace(/-/g, '.') : ''
  const stamp = [date, me.city].filter(Boolean).join(' · ')
  const quote = (me.quote ?? '').trim() || (me.today?.want ?? '').trim() || '答案还在显影中'
  const todayLine = (me.today?.want ?? me.today?.nowStatus ?? '').trim() || null
  const footer = years ? `${years} · IN A FLASH 闪念间` : 'IN A FLASH · 闪念间'
  return { stamp, quote, todayLine, footer }
}

/** 摘要卡版式（纯函数，node --test 钉住）：给定画布尺寸算出每一段的行与坐标，
 * **保证全部落在画布内**（旧版 today/脚注越界即此判据缺失）。canvas 只按结果绘制。 */
export function summaryCardLayout(
  model: { quote: string; todayLine: string | null; footer: string },
  width = 600,
  height = 800
): {
  W: number
  H: number
  kickerTop: number
  stampTop: number
  quoteLines: string[]
  quoteTop: number
  quoteLineHeight: number
  todayLines: string[]
  todayTop: number
  todayLineHeight: number
  dividerY: number
  footerTop: number
} {
  const W = width
  const H = height
  const quoteLineHeight = 46
  const todayLineHeight = 34
  const quoteLines = wrapCardText(`“${model.quote}”`, (W - 160) / 30, 5)
  const todayLines = model.todayLine ? wrapCardText(`今天的我：${model.todayLine}`, (W - 200) / 22, 3) : []
  const footerTop = H - 72
  const todayTop = todayLines.length ? footerTop - 44 - todayLines.length * todayLineHeight : footerTop
  const dividerY = todayLines.length ? todayTop - 30 : footerTop - 60
  const quoteTop = Math.max(210, Math.min(300, dividerY - quoteLines.length * quoteLineHeight - 34))
  return {
    W,
    H,
    kickerTop: 84,
    stampTop: 136,
    quoteLines,
    quoteTop,
    quoteLineHeight,
    todayLines,
    todayTop,
    todayLineHeight,
    dividerY,
    footerTop
  }
}

// ── U3 未来段:场次三行卡判据(节点测试钉住) ─────────────────────────

export interface FutureEventCardView {
  id: string
  slug: string
  title: string
  /** 城市钉联动行:城市 · 日期 · N 人已报名 */
  meta: string
  /** 可报名=亮金带 CTA;满员/截止=灰卡状态标签 */
  status: 'open' | 'full' | 'closed'
}

/** 场次卡视图(KTD4 三行简卡):满员=capacity≠null 且 confirmed≥capacity;
 * 截止=deadline<now;两者皆命中优先报「满员」。 */
export function futureEventCards(
  frames: FlashbackFutureFrame[],
  now: Date = new Date()
): FutureEventCardView[] {
  const cards: FutureEventCardView[] = []
  for (const frame of frames) {
    for (const event of frame.events) {
      const full =
        event.capacity !== null && event.confirmedCount >= event.capacity
      const closed =
        !full &&
        event.registrationDeadline !== null &&
        new Date(event.registrationDeadline) < now
      const date = event.startsAt ? new Date(event.startsAt).toLocaleDateString('zh-CN', { month: 'numeric', day: 'numeric' }) : ''
      const parts = [event.city, date, `${event.confirmedCount} 人已报名`].filter(Boolean)
      cards.push({
        id: event.id,
        slug: event.slug,
        title: event.title,
        meta: parts.join(' · '),
        status: full ? 'full' : closed ? 'closed' : 'open'
      })
    }
  }
  return cards
}
