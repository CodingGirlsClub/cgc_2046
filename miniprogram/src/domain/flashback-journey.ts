import type {
  FlashbackCapsuleArchive,
  FlashbackMeAnswer,
  FlashbackPublicStatsArchive,
  FlashbackRosterEntry
} from './models'
import { yearsAgoText } from './flashback.ts'

/**
 * 首程旅程（原型 E/F · mp 版）与长廊/场次页的判据与文案——页面无渲染测试
 * （AGENTS.md：一切可测逻辑下沉 domain），tests/flashback-journey.test.ts 用
 * node --test 钉住。
 *
 * 语义对齐 web 首程（web/components/flashback/journey.tsx）：enter 分流 →
 * 场次确认问答（R6：认领后的确认而非考察）→ 显影卡翻面写今天 → 寄出浮层
 * （R27 注册引导 + R29 期望管理）。
 */

// ── 场次确认问答（R6） ────────────────────────────────────────────────

export interface JourneyQuizOption {
  id: string
  label: string
  hint: string
}

export interface JourneyQuiz {
  question: string
  options: JourneyQuizOption[]
  /** 正确项 id（= 本人档案所属场次） */
  correct: string
  correctLabel: string
}

/** 历史场次池（与原型 data.ts 同源）：正确项从档案生成，其余做干扰项；
 * 命中即用池里的正式说法与提示（如「2014.1.11 · 六城同日」）。 */
const QUIZ_POOL: {
  id: string
  label: string
  hint: string
  year: string
  /** MM-DD：同日多城场次按日期命中（城市列不完整） */
  date?: string
  city?: string
}[] = [
  { id: 'sh2012', label: '2012 · 上海', hint: '中国首场', year: '2012', city: '上海' },
  { id: 'bj2012', label: '2012.12 · 北京', hint: '', year: '2012', city: '北京' },
  { id: 'six2014', label: '2014.1.11 · 六城同日', hint: '北京/成都/上海/深圳/西安/广州', year: '2014', date: '01-11' },
  { id: 'gz2015', label: '2015.8 · 广州', hint: '', year: '2015', city: '广州' }
]

function poolMatches(
  entry: (typeof QUIZ_POOL)[number],
  archive: { city?: string | null; occurredOn?: string | null }
): boolean {
  const occurred = archive.occurredOn ?? ''
  if (entry.date) return occurred.startsWith(`${entry.year}-${entry.date}`)
  return occurred.startsWith(entry.year) && (archive.city ?? '') === (entry.city ?? '')
}

/** 档案 → 确认题：正确项固定在首位（R6 定位为确认而非考察——她知道答案在哪；
 * 固定序也让 e2e 可按位置断言）。「我不记得了」兜底出口恒在末位（R6 出口）。 */
export function journeyQuiz(
  archive: { name?: string | null; city?: string | null; occurredOn?: string | null } | null
): JourneyQuiz {
  const matched = archive ? QUIZ_POOL.find((entry) => poolMatches(entry, archive)) : undefined
  const correctLabel =
    matched?.label ??
    (
      [(archive?.occurredOn ?? '').slice(0, 4), archive?.city].filter(Boolean).join(' · ') ||
      archive?.name ||
      '当年那一场'
    )
  const correct: JourneyQuizOption = {
    id: matched?.id ?? 'mine',
    label: correctLabel,
    hint: matched?.hint ?? archive?.name ?? ''
  }
  const distractors = QUIZ_POOL.filter(
    (entry) => !(archive && poolMatches(entry, archive))
  ).map((entry) => ({ id: entry.id, label: entry.label, hint: entry.hint }))

  return {
    question: '还记得……是哪一场吗？',
    options: [correct, ...distractors, { id: 'dunno', label: '我不记得了', hint: '没关系，我们记得' }],
    correct: correct.id,
    correctLabel
  }
}

/** 选择反馈文案：dunno 与答错都是出口（R6），答错则告知正确场次 */
export function quizResultText(choice: string | null, quiz: JourneyQuiz): string {
  if (!choice) return ''
  if (choice === 'dunno') return '没关系——我们替你记得'
  if (choice === quiz.correct) return '答对了。这张照片一直在等你。'
  return `差一点，其实是 ${quiz.correctLabel}。`
}

// ── 旅程文案（原型 F） ────────────────────────────────────────────────

/** 开场引子：相对年数动态（R3），无时间戳时回落「在这一切开始之前」 */
export function journeyIntroLead(appliedAt: string | null, now: Date = new Date()): string {
  const years = yearsAgoText(appliedAt, now)
  return years ? `${years}，你写过一些答案。` : '在这一切开始之前，你写过一些答案。'
}

/** 显影卡正面：免费题答案（与 web journey.tsx freeAnswers 同集），限张数。
 * 入参只要 id/questionKey/rawText（token 面的 enter answers 无雾化 text）。 */
const FREE_QUESTION_KEYS = ['self_intro', 'funny_thing', 'os', 'social_media']

export function cardFaceAnswers(
  answers: Array<Pick<FlashbackMeAnswer, 'id' | 'questionKey' | 'rawText'>>,
  max = 2
): Array<Pick<FlashbackMeAnswer, 'id' | 'questionKey' | 'rawText'>> {
  return answers.filter((answer) => FREE_QUESTION_KEYS.includes(answer.questionKey)).slice(0, max)
}

/** 显影卡时间戳（原型 PERSONA.timestamp 形态：2014.01.11 13:06） */
export function revealStamp(appliedAt: string | null): string {
  if (!appliedAt) return '当年'
  const date = appliedAt.slice(0, 10).replace(/-/g, '.')
  const time = appliedAt.slice(11, 16)
  return time ? `${date} ${time}` : date
}

/** 寄出浮层（R27 + R29；文案与任务定稿逐字一致） */
export const SEND_OVERLAY = {
  title: '照片正在贴上墙。',
  body: '想收好这张卡、并在你附议的场成真时收到通知吗？',
  primary: '微信一键收好',
  skip: '跳过，直接上墙',
  expectation: '你写下的愿望不会消失——我们会通过 Newsletter 和具体的人逐个回应。'
} as const

// ── 长廊（原型 F corridor） ───────────────────────────────────────────

export interface CorridorPile {
  city: string
  count: number
  /** 堆级已回来人数(该城市 sentToWallAt 非空;G 原型:堆下「N 位已回来」) */
  returned: number
}

/** 城市堆上限（原型 piles.slice(0, 4)：一帧最多四个堆，多的在计数里） */
export const CORRIDOR_PILE_LIMIT = 4

/** 名册 → 城市堆：按城市聚合计数（空城名过滤），计数降序、同数城市字典序——
 * 确定性排序（不依赖服务端顺序，e2e 与单测可精确断言）。 */
export function corridorPiles(
  roster: Pick<FlashbackRosterEntry, 'city' | 'sentToWallAt'>[],
  limit = CORRIDOR_PILE_LIMIT
): CorridorPile[] {
  const counts = new Map<string, { count: number; returned: number }>()
  for (const entry of roster) {
    const city = (entry.city ?? '').trim()
    if (!city) continue
    const prev = counts.get(city) ?? { count: 0, returned: 0 }
    counts.set(city, {
      count: prev.count + 1,
      returned: prev.returned + (entry.sentToWallAt ? 1 : 0)
    })
  }
  return [...counts.entries()]
    .map(([city, { count, returned }]) => ({ city, count, returned }))
    .sort((a, b) => b.count - a.count || a.city.localeCompare(b.city, 'zh-Hans-CN'))
    .slice(0, limit)
}

export interface CorridorFrame {
  key: string
  /** 时间标（2014.01.11 形态） */
  when: string
  /** 场次名（可空） */
  label: string
  piles: CorridorPile[]
  /** 这一场已回来人数（寄出者计数） */
  returned: number
}

/** 参与态长廊帧：按场次时间升序（顶上是 2012，底部是未来），无日期者排最后 */
export function corridorFrames(archives: FlashbackCapsuleArchive[]): CorridorFrame[] {
  return [...archives]
    .sort((a, b) => {
      const left = a.occurredOn ?? ''
      const right = b.occurredOn ?? ''
      if (left === right) return a.key.localeCompare(b.key)
      if (!left) return 1
      if (!right) return -1
      return left < right ? -1 : 1
    })
    .map((archive) => ({
      key: archive.key,
      when: archive.occurredOn ? archive.occurredOn.slice(0, 10).replace(/-/g, '.') : archive.key,
      // 叙事短标签（原型 D ia-frame-label）优先；导入未带时回落场次名
      label: archive.label ?? archive.name ?? '',
      piles: corridorPiles(archive.roster),
      returned: archive.roster.filter((entry) => entry.sentToWallAt).length
    }))
}

/** 路人态长廊帧（R32 统计层）：只有场次 + 城市 + 走进教室人数，无名单 */
export function statsFrames(archives: FlashbackPublicStatsArchive[]): CorridorFrame[] {
  return [...archives]
    .sort((a, b) => {
      const left = a.occurredOn ?? ''
      const right = b.occurredOn ?? ''
      if (left === right) return a.key.localeCompare(b.key)
      if (!left) return 1
      if (!right) return -1
      return left < right ? -1 : 1
    })
    .map((archive) => {
      const city = (archive.city ?? '').trim()
      const count = archive.attendedCount ?? archive.appliedCount ?? 0
      return {
        key: archive.key,
        when: archive.occurredOn ? archive.occurredOn.slice(0, 10).replace(/-/g, '.') : archive.key,
        label: archive.label ?? archive.name ?? '',
        piles: city ? [{ city, count, returned: 0 }] : [],
        returned: 0
      }
    })
}

/** ⚡今天格标头（原型：⚡ 今天 2026.9.17 · 此刻 · 一闪念间；不补零，与原型一致） */
export function todayFrameLabel(now: Date = new Date()): string {
  return `⚡ 今天 ${now.getFullYear()}.${now.getMonth() + 1}.${now.getDate()} · 此刻 · 一闪念间`
}

// ── 场次页（原型 F event 步） ─────────────────────────────────────────

export interface CorridorEventStats {
  /** 报名数：导入缺列 → null（不显示，不编造 0） */
  applied: number | null
  attended: number | null
  returned: number
}

export function eventStats(archive: FlashbackCapsuleArchive): CorridorEventStats {
  return {
    applied: archive.appliedCount ?? null,
    attended: archive.attendedCount ?? null,
    returned: archive.roster.filter((entry) => entry.sentToWallAt).length
  }
}

/** 未回来者的雾卡小字：城市 · 职业 · 答案还在等她（缺项过滤，全缺只剩尾句） */
export function eventFogLine(entry: Pick<FlashbackRosterEntry, 'city' | 'occupationThen'>): string {
  return [[entry.city, entry.occupationThen].filter(Boolean).join(' · '), '答案还在等她'].filter(Boolean).join(' · ')
}

