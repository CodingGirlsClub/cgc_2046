import type { FlashbackCapsule, FlashbackFogSpan, FlashbackFutureFrame, FlashbackMeAnswer, FlashbackMyCard, FlashbackMyToday } from './models'
import type { FlashbackPublicWishEcho } from './models'

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

// ── 今天的你句级雾(与当年同坐标同语义) ──────────────────────

/** today 字段文本按句切分并标记雾态(spans 与当年同口径) */
export function todaySentencesWithFog(
  rawText: string,
  spans: Array<{ start: number; len: number }> | undefined
): SentenceRange[] {
  return splitSentences(rawText).map((sentence) => ({
    ...sentence,
    fogged: (spans ?? []).some((span) => spansOverlap(span, sentence))
  }))
}

/** 切换 today 某句雾/解雾 → 该字段整份新 spans(提交 flashbackAdjustTodayFog) */
export function toggleTodaySentenceFog(
  spans: Array<{ start: number; len: number }> | undefined,
  sentence: SentenceRange
): Array<{ start: number; len: number }> {
  const existing = spans ?? []
  const hit = existing.some((span) => spansOverlap(span, sentence))
  const next = hit
    ? existing.filter((span) => !spansOverlap(span, sentence))
    : [...existing, { start: sentence.start, len: sentence.len }]
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
  /** U10:雾句灰显不可选（想选先去解雾;当年与今天同规则） */
  fogged?: boolean
}

/** 今天的你字段单表(今天的你与当年答案同套雾/金句语言):
 *  questionKey=金句/雾 span 宿主键;field=FlashbackMyToday 字段;fog=雾区间键(后端 field 名);
 *  label/placeholder=写入面与回看卡的行文案。MyCard/TodayReview/候选/mock 共用。 */
export const TODAY_FIELDS = [
  { questionKey: 'today.now', field: 'nowStatus', fog: 'now', label: '现在在做什么', placeholder: '比如:还在写代码,下班带娃' },
  { questionKey: 'today.want', field: 'want', fog: 'want', label: '想做的事 / 想学的东西', placeholder: '比如:学 Rust,做一个小工具' },
  { questionKey: 'today.need', field: 'need', fog: 'need', label: '需要什么帮助', placeholder: '比如:想找人一起组队学习' },
  { questionKey: 'today.say', field: 'say', fog: 'say', label: '想对 CGC 说', placeholder: '比如:十周年快乐!' }
] as const

export type TodayField = (typeof TODAY_FIELDS)[number]['field']

/** 卡面题干（questionKey → 中文；白名单外的 key 原样显示兜底）。
 *  从 flashback-journey 迁来：它是纯文案映射（与 TODAY_FIELDS 同类），
 *  放本模块后 recordCardModel 可直接消费，且消除 journey → card 的反向依赖。
 *
 *  `os` / `social_media` 是导入期的结构化题（import.ex 的列映射），两处白名单
 *  都会用到（alumni_projection.ex: roster/enter 出 4 题、公开卡出 3 题含 os），
 *  但这里原先没有分支——它们会回落成原始 key，于是题干显示为字面量「os」。
 *  文案对齐 web（messages/zh-CN.json 的 flashback.questionLabels）。 */
export function questionLabel(questionKey: string): string {
  if (questionKey === 'self_intro') return '请简单的介绍一下自己'
  if (questionKey === 'funny_thing') return '你做过的有意思的事情'
  if (questionKey === 'os') return '当时的操作系统'
  if (questionKey === 'social_media') return '当时的社交媒体'
  if (questionKey === 'today.now') return '现在在做什么'
  if (questionKey === 'today.want') return '想做的事 / 想学的东西'
  if (questionKey === 'today.need') return '需要什么帮助'
  if (questionKey === 'today.say') return '想对 CGC 说'
  return questionKey
}

/** 金句候选（R35/U10）：当年答案 + 今天三/四行,同一切句口径;
 * 雾句不再排除——带 fogged 标记由渲染层灰显锁定(「这句被雾住了所以不能选」)。 */
export function quoteCandidatesOf(answers: FlashbackMeAnswer[], today?: FlashbackMyToday | null): QuoteCandidate[] {
  const result: QuoteCandidate[] = []
  for (const answer of answers) {
    for (const sentence of sentencesWithFog(answer)) {
      const sentenceText = sentence.text.trim()
      if (!sentenceText) continue
      result.push({
        questionKey: answer.questionKey,
        sentence: sentenceText,
        start: sentence.start,
        len: sentence.len,
        fogged: sentence.fogged || undefined
      })
    }
  }
  if (today) {
    for (const host of TODAY_FIELDS) {
      const raw = today[host.field]
      if (!raw) continue
      for (const sentence of todaySentencesWithFog(raw, today.fogSpans?.[host.fog])) {
        const sentenceText = sentence.text.trim()
        if (!sentenceText) continue
        result.push({
          questionKey: host.questionKey,
          sentence: sentenceText,
          start: sentence.start,
          len: sentence.len,
          fogged: sentence.fogged || undefined
        })
      }
    }
  }
  return result
}

/** 圈选命中判定（存档态回显与列表高亮共用）：区间与来源题同时相等 */
export function isCandidatePicked(
  candidate: QuoteCandidate,
  picked: { questionKey: string; start: number; len: number }[] | null
): boolean {
  if (!picked || picked.length === 0) return false
  return picked.some(
    (item) =>
      item.questionKey === candidate.questionKey &&
      item.start === candidate.start &&
      item.len === candidate.len,
  )
}

// ── R36 作者侧点赞数 ──────────────────────────────────────────────────

/** 我的卡上的点赞徽章（R36）：上墙且有点赞才出现，否则 null（不占位） */
export function quoteLikeBadge(me: FlashbackMyCard): string | null {
  if (!me.today?.sentToWallAt) return null
  const count = me.quoteStats?.likeCount ?? 0
  return count > 0 ? `你的话被 ${count} 人点赞` : null
}

/** R37 分享 opt-in 的显示判据（ShareSheet 消费）：
 *  - hidden：卡上没有可回填的选定金句（未圈选/未授权无 span）→ 不显示选项；
 *  - already：已授权（anonymous/credited）→ 勾选态 + 禁用（分享改不了档位）；
 *  - available：可勾选，默认不勾（授权永不预选）。 */
export function shareOptInState(me: FlashbackMyCard): 'hidden' | 'already' | 'available' {
  if (me.quoteLevel === 'anonymous' || me.quoteLevel === 'credited') return 'already'
  if (!me.quote || !(me.quoteSpans ?? []).length) return 'hidden'
  return 'available'
}

// ── 金句授权（R31 两档 + 关） ─────────────────────────────────────────

export type QuoteLevel = 'off' | 'anonymous' | 'credited'

export const QUOTE_LEVEL_OPTIONS: { value: QuoteLevel; label: string; desc: string }[] = [
  // 文案与 web 端 i18n(flashback.write.quote_*)逐字对齐——同一授权动作跨端一致;
  // 「你的语言,会成为别人的勇气。」底部语两端同源
  { value: 'off', label: '关闭', desc: '（默认）你的答案只对自己可见' },
  { value: 'anonymous', label: '匿名金句', desc: '平台可从当年答案挑一句匿名传播（署「王** · 年 · 城」）' },
  { value: 'credited', label: '实名支持', desc: '用你的名字公开这句话' }
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

/**
 * 分享面板入口清单（P0-6 小红书止血）。
 * 「朋友圈」是微信概念（xhs 没有该入口）；「保存卡片」依赖 Canvas 2D（xhs 无
 * Canvas 2D 节点能力，保存静默失败）——xhs 只保留「转发」。P2-4 服务端出图
 * 落地后恢复（卡片图改 https 资源即可下载，恢复即把本函数收敛回全量）。
 */
export type ShareSheetEntry = 'forward' | 'timeline' | 'saveCard'

export function shareSheetEntries(platform: 'wechat' | 'tt' | 'xhs'): ShareSheetEntry[] {
  if (platform === 'xhs') return ['forward']
  return ['forward', 'timeline', 'saveCard']
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
  // 分享物只显未雾句(雾住的句子不进卡,也不画雾块)
  const visibleToday = (field: TodayField): string => {
    const host = TODAY_FIELDS.find((row) => row.field === field)
    const raw = me.today?.[field]
    if (!host || !raw) return ''
    return todaySentencesWithFog(raw, me.today?.fogSpans?.[host.fog])
      .filter((sentence) => !sentence.fogged)
      .map((sentence) => sentence.text)
      .join('')
      .trim()
  }
  const quote = (me.quote ?? '').trim() || visibleToday('want') || '答案还在显影中'
  const todayLine = visibleToday('want') || visibleToday('nowStatus') || null
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

// ── 卡片四态（保存/分享的落版） ──────────────────────────────────────

/** 卡片形态：摘要卡（R14 分享默认物：金句版式 + 固定 3:4）与记录态三选。 */
export type FlashbackCardMode = 'summary' | 'today' | 'past' | 'both'

/** 形态切换器的选项单表（卡片页 chip 条消费）。
 *  顺序 = 用户价值序：合起来（全貌，默认）→ 当年的你（重逢，保存/分享冲动最强）
 *  → 今天的你（自己刚写的，已知）→ 摘要卡（派生成品）。 */
export const CARD_MODES: Array<{ value: FlashbackCardMode; label: string }> = [
  { value: 'both', label: '合起来' },
  { value: 'past', label: '当年的你' },
  { value: 'today', label: '今天的你' },
  { value: 'summary', label: '摘要卡' }
]

/** 记录卡的一段：题干 + 逐句内容（fogged 由 canvas 画灰块） */
export interface CardSection {
  title: string
  sentences: Array<{ text: string; fogged: boolean }>
}

export interface RecordCardModel {
  stamp: string
  sections: CardSection[]
  footer: string
}

/** 记录卡内容模型（today / past / both）。
 *
 *  **雾句保留并标记**——与预览（`rvFog` 灰块）和校友墙（`viewFog` 灰块）
 *  同口径。旧摘要卡的「只显未雾句、也不画雾块」口径已废弃：它让句子凭空
 *  消失、标点悬空（「今天在做什么：，下班带娃。」），且与"这张卡在别人眼里
 *  的样子"自相矛盾。摘要卡（summary）走 summaryCardModel，不受影响。 */
export function recordCardModel(
  me: FlashbackMyCard,
  mode: 'today' | 'past' | 'both',
  now: Date = new Date()
): RecordCardModel {
  const date = me.appliedAt ? me.appliedAt.slice(0, 10).replace(/-/g, '.') : ''
  const stamp = [date, me.city].filter(Boolean).join(' · ')
  const years = yearsAgoText(me.appliedAt, now)
  const footer = years ? `${years} · IN A FLASH 闪念间` : 'IN A FLASH · 闪念间'

  const todaySections: CardSection[] = TODAY_FIELDS.flatMap((row) => {
    const raw = me.today?.[row.field]
    if (!raw) return []
    return [
      {
        title: row.label,
        sentences: todaySentencesWithFog(raw, me.today?.fogSpans?.[row.fog]).map((s) => ({
          text: s.text,
          fogged: s.fogged
        }))
      }
    ]
  })

  const pastSections: CardSection[] = me.answers.map((answer) => ({
    title: questionLabel(answer.questionKey),
    sentences: sentencesWithFog(answer).map((s) => ({ text: s.text, fogged: s.fogged }))
  }))

  const sections =
    mode === 'today' ? todaySections : mode === 'past' ? pastSections : [...todaySections, ...pastSections]

  return { stamp, sections, footer }
}

/** 记录卡版式（纯函数，node --test 钉住）：**动态高度**——内容驱动且完整
 *  保留（「保存过去的回答」若被截断就失去意义）；超 maxHeight 时截断尾部
 *  并置 `truncated`（调用方据此提示）。canvas 只按返回坐标绘制。 */
export function recordCardLayout(
  model: RecordCardModel,
  width = 600,
  maxHeight = 2400
): {
  W: number
  H: number
  kickerTop: number
  stampTop: number
  blocks: Array<{
    title: string
    titleTop: number
    /** 逐行坐标：fogged 行 canvas 画灰块（宽度按文本测量） */
    lines: Array<{ text: string; fogged: boolean; top: number }>
  }>
  lineHeight: number
  dividerY: number
  footerTop: number
  truncated: boolean
} {
  const W = width
  const lineHeight = 38
  const titleGap = 54
  const sectionGap = 26
  const linesPerEm = (W - 120) / 26

  const blocks: Array<{ title: string; titleTop: number; lines: Array<{ text: string; fogged: boolean; top: number }> }> = []
  let cursor = 208
  let truncated = false

  for (const section of model.sections) {
    if (cursor + titleGap > maxHeight - 140) {
      truncated = true
      break
    }
    const lines: Array<{ text: string; fogged: boolean; top: number }> = []
    cursor += titleGap
    for (const sentence of section.sentences) {
      for (const line of wrapCardText(sentence.text, linesPerEm, 99)) {
        if (cursor + lineHeight > maxHeight - 140) {
          truncated = true
          break
        }
        lines.push({ text: line, fogged: sentence.fogged, top: cursor })
        cursor += lineHeight
      }
      if (truncated) break
      cursor += 8
    }
    if (lines.length) blocks.push({ title: section.title, titleTop: lines[0].top - titleGap, lines })
    if (truncated) break
    cursor += sectionGap
  }

  // 高度：内容驱动，下限 800（保 3:4 视觉比例）、上限 maxHeight
  const H = Math.min(maxHeight, Math.max(800, cursor + 140))
  const footerTop = H - 72
  const dividerY = footerTop - 40

  return {
    W,
    H,
    kickerTop: 84,
    stampTop: 136,
    blocks,
    lineHeight,
    dividerY,
    footerTop,
    truncated
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

// ── U5 许愿年度额度(R20:每年 3 条,含私有与已软删,删除不退还) ─────────────

/** 提交判据:草稿去空白非空 且 额度未尽(quota===0 禁用;null 不拦,后端会以
 * flashback_wish_quota_exceeded 兜底拒绝)。 */
/**
 * wish2 U9（KTD2）：期待/举报的匿名去重键——`a:<device_uuid>`，口径与 web 的
 * lib/flashback-voter.ts 完全一致（格式 u:/a: + ≤64；首访落盘恒同键）。
 * 登录态服务端强制 `u:<user_id>`（客户端照常传设备键，服务端覆盖）。
 */
const VOTER_KEY_STORAGE = 'flashback.voterKey'
const VOTER_KEY_PATTERN = /^[ua]:[A-Za-z0-9_-]{1,60}$/

function wxLikeStorage(): { getStorageSync(k: string): unknown; setStorageSync(k: string, v: string): void } | null {
  const scope = globalThis as { wx?: { getStorageSync(k: string): unknown; setStorageSync(k: string, v: string): void } }
  return scope.wx ?? null
}

export function readWishVoterKey(): string | null {
  try {
    const raw = wxLikeStorage()?.getStorageSync(VOTER_KEY_STORAGE)
    const value = typeof raw === 'string' ? raw : null
    return value && VOTER_KEY_PATTERN.test(value) ? value : null
  } catch {
    return null
  }
}

export function ensureWishVoterKey(): string {
  const existing = readWishVoterKey()
  if (existing) return existing
  const created = `a:${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`
  try {
    wxLikeStorage()?.setStorageSync(VOTER_KEY_STORAGE, created)
  } catch {
    // 存储不可用：仅本次会话有效（期待按钮仍可用，跨会话可能重票——服务端幂等兜底）
  }
  return created
}

export function canSubmitWish(quota: number | null, draft: string): boolean {
  return draft.trim().length > 0 && quota !== 0
}

/** 弹层额度行文案:null 不渲染(未登录/无 person);>0 报剩余;0 报用完
 * （与 web zh-CN flashback.wish.quotaExhausted 同文案互指）。 */
export function wishQuotaCopy(quota: number | null): string | null {
  if (quota === null) return null
  if (quota === 0) return '今年许愿名额已用完（每年最多 3 条，删除不退还名额）'
  return `今年还可许 ${quota} 条`
}

// ── wish2 U9：viewer listed 公开树 + 附议表单（KTD3/KTD5/KTD7） ────────────

/** viewer 面公开愿望（flashbackPublicWishes 投影；listed 四条件由服务端保证） */
export interface ViewerWish {
  id: string
  content: string
  city: string | null
  signature: string
  expectationCount: number
  endorsementCount: number
  expectedByViewer: boolean
  endorsedByViewer: boolean
  /** 最新一条可见回响（#834；无则 null） */
  latestEcho: FlashbackPublicWishEcho | null
  /** 可见回响条数（#834） */
  echoCount: number
  /** 全部可见回响，按首次发布时间正序（#834） */
  echoes: FlashbackPublicWishEcho[]
}

/** #837 GraphQL 生成类型把枚举投为宽 string——把服务端可能返回的状态
 * fail-closed 收敛到公开读面允许的两个值；未知状态（draft/revoked 等）
 * 返回 null，调用方丢弃该条回响。 */
export function parsePublicWishEchoStatus(value: string | null | undefined): 'published' | 'corrected' | null {
  return value === 'published' || value === 'corrected' ? value : null
}

/** #837 把 GraphQL 行的回响（status 为宽 string）收敛到 domain.FlashbackPublicWishEcho。
 * status 非法时返回 null，调用方负责丢弃该条。 */
export function mapPublicWishEcho(echo: {
  id: string
  content: string
  status: string
  publishedAt: string
  correctedAt?: string | null
}): FlashbackPublicWishEcho | null {
  const status = parsePublicWishEchoStatus(echo.status)
  if (!status) return null
  return {
    id: echo.id,
    content: echo.content,
    status,
    publishedAt: echo.publishedAt,
    correctedAt: echo.correctedAt ?? null
  }
}

/** 附议出力类型（后端 contribution_types 枚举面，KTD3；顺序即表单展示序） */
export const WISH_CONTRIBUTION_OPTIONS = [
  { type: 'venue', label: '提供场地' },
  { type: 'organize', label: '帮忙组织' },
  { type: 'speak', label: '来分享' },
  { type: 'sponsor', label: '赞助支持' },
  { type: 'other', label: '其他方式' }
] as const

/** 附议留言上限（后端 flashback_wish_endorsement_message_too_long 同值） */
export const WISH_ENDORSE_MESSAGE_MAX = 500

/** 期望地候选名单条目（flashbackCities 读面投影） */
export interface CityOption {
  name: string
  pinyin: string
}

/**
 * 期望地实时候选（KTD11）：输入非空时，中文名含输入或拼音前缀命中且不等于
 * 输入的城市，≤6 个。归一判定在服务端（名单外提交报错带候选）——这里只做
 * 输入辅助，不阻止提交。
 */
export function cityCandidates(input: string, cities: readonly CityOption[]): string[] {
  const query = input.trim()
  if (!query) return []
  const lower = query.toLowerCase()
  return cities
    .filter((city) => city.name !== query && (city.name.includes(query) || city.pinyin.startsWith(lower)))
    .map((city) => city.name)
    .slice(0, 6)
}
