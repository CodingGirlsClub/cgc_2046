import type { FlashbackCapsule, FlashbackFogSpan, FlashbackMeAnswer, FlashbackMyActionCard } from './models'

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

// ── Action 卡视图（R13 四态） ─────────────────────────────────────────

export type ActionCardStatus = 'proposed' | 'forming' | 'scheduled' | 'done'

export function cardStatusText(status: string): string {
  switch (status) {
    case 'proposed':
      return '提议中'
    case 'forming':
      return '附议中'
    case 'scheduled':
      return '已成场'
    case 'done':
      return '已落地'
    default:
      return status
  }
}

export type EndorseAction =
  | { kind: 'endorse'; label: string; hint: string }
  | { kind: 'goEvent'; label: string; hint: string }
  | { kind: 'done'; label: string; hint: string }

/** 附议按钮状态机：每张卡任何时刻都有可见的下一步动作（R13）。 */
export function endorseAction(card: FlashbackMyActionCard): EndorseAction {
  switch (card.status) {
    case 'proposed':
    case 'forming':
      return {
        kind: 'endorse',
        label: card.endorsedByMe ? '已附议（调整角色）' : '附议 +1',
        hint: card.endorsedByMe
          ? `已有 ${card.endorsementCount} 人附议`
          : `当前 ${card.endorsementCount} 人附议，附议成场时会通知你`
      }
    case 'scheduled':
      return {
        kind: 'goEvent',
        label: '成场了，去报名',
        hint: `已有 ${card.endorsementCount} 人附议`
      }
    case 'done':
      return { kind: 'done', label: '已落地', hint: '活动回顾已贴回卡片' }
    default:
      return { kind: 'done', label: cardStatusText(card.status), hint: '' }
  }
}

/** 行动板分组：已附议在前（回访者最关心自己参与的卡），其余按态。 */
export function splitActionCards(cards: FlashbackMyActionCard[]): {
  endorsed: FlashbackMyActionCard[]
  open: FlashbackMyActionCard[]
} {
  const endorsed = cards.filter((card) => card.endorsedByMe)
  const open = cards.filter((card) => !card.endorsedByMe)
  return { endorsed, open }
}

/** scheduled 卡的直链（不在闪念间内部闭环，R13）；无 slug → null（页面兜底文案）。 */
export function actionCardTarget(card: FlashbackMyActionCard): string | null {
  if (card.status === 'scheduled' && card.eventId) {
    return `/pages/event-detail/index?id=${card.eventId}&kind=event`
  }
  return null
}

/** 附议角色选项（organizer/promoter/venue，与后端 Endorsements @roles 同集）。 */
export const ENDORSE_ROLES = [
  { value: 'organizer', label: '组织者' },
  { value: 'promoter', label: '宣传拉人' },
  { value: 'venue', label: '场地资源' }
] as const

// ── 金句授权（R31 两档 + 关） ─────────────────────────────────────────

export type QuoteLevel = 'off' | 'anonymous' | 'credited'

export const QUOTE_LEVEL_OPTIONS: { value: QuoteLevel; label: string; desc: string }[] = [
  { value: 'off', label: '不授权', desc: '你的答案只对自己可见' },
  { value: 'anonymous', label: '匿名金句', desc: '平台可筛选你当年的答案匿名传播（姓** · 年 · 城）' },
  { value: 'credited', label: '实名支持', desc: '匿名档之上补充近况并实名公开，可作品牌素材' }
]

export function quoteLevelText(level: string): string {
  return QUOTE_LEVEL_OPTIONS.find((option) => option.value === level)?.label ?? level
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
