import type { FlashbackCapsule, FlashbackCapsuleArchive, FlashbackFutureFrame } from './models.ts'

export type PublicRecovery = 'checking' | 'guest' | 'unmatched' | 'error'
export type RecoveryState = { generation: number } & (
  | { kind: PublicRecovery }
  | { kind: 'member'; capsule: FlashbackCapsule; token: string | null }
)
export type RecoveryAction =
  | { type: 'start' | 'guest' | 'unmatched' | 'error'; generation: number }
  | { type: 'member'; generation: number; capsule: FlashbackCapsule; token: string | null }
export const initialRecovery = (): RecoveryState => ({ kind: 'checking', generation: 0 })
export function recoveryReducer(state: RecoveryState, action: RecoveryAction): RecoveryState {
  if (action.type === 'start') return { kind: 'checking', generation: action.generation }
  if (state.generation !== action.generation) return state
  if (action.type === 'member') return { kind: 'member', generation: action.generation, capsule: action.capsule, token: action.token }
  return { kind: action.type, generation: action.generation }
}
export function recoveryView(kind: PublicRecovery) {
  const views = {
    guest: { title: '你也在那些年里吗？', description: '找回当年写下的答案，也看看今天的自己。', button: '找回你的那一张 →', action: 'login' },
    checking: { title: '正在找回你的那一张…', description: '请稍候，正在确认你的历史档案。', button: '正在查找…', action: null },
    unmatched: { title: '暂时还没找到你的那一张', description: '当前账号还没匹配到历史档案——当年用了别的手机号或邮箱也可能暂时找不到；没有历史档案，也可以从今天开始。', button: '写下我的愿望 →', action: 'write' },
    error: { title: '暂时没能完成查找', description: '请再试一次。你也可以先听听金句，看看大家的愿望。', button: '重新查找 ↻', action: 'retry' }
  } as const
  return views[kind]
}

export function shouldRevealRecoveredCard(previousPerson: string | null, person: string, welcome: boolean): boolean {
  return previousPerson !== person && !welcome
}

/** 场次页视角：与长廊同一个找回状态机派生。登录引导只给未登录（guest）——
 * 已登录未匹配若再给登录按钮，登录回跳仍未匹配，形成死循环并耗尽登录限流额度。 */
export type EventView =
  | { kind: 'loading' | 'error' }
  | { kind: 'member'; archive: FlashbackCapsuleArchive; futureEvents: FlashbackFutureFrame[] }
  | { kind: 'viewer'; guide: 'login' | 'recover' | null }
export function eventView(state: RecoveryState, key: string): EventView {
  if (state.kind !== 'member') {
    if (state.kind === 'checking') return { kind: 'loading' }
    if (state.kind === 'error') return { kind: 'error' }
    return { kind: 'viewer', guide: state.kind === 'guest' ? 'login' : 'recover' }
  }
  const archive = state.capsule.archives.find((item) => item.key === key)
  return archive ? { kind: 'member', archive, futureEvents: state.capsule.futureEvents } : { kind: 'viewer', guide: null }
}

/**
 * 场次页相册来源（#933 相册对所有已登录用户开放）：
 * - 有档案 → 胶囊里的场次（capsule）；
 * - 已登录但没档案 → 相册读面（archives，未寄出者只有姓氏遮罩）；
 * - 未登录 → 直接去登录页（login），登录后回到这一场；
 * - 其余（加载中 / 失败 / 有档案但不在本场）→ 无相册（none）。
 */
export function eventAlbumSource(view: EventView): 'capsule' | 'archives' | 'login' | 'none' {
  if (view.kind === 'member') return 'capsule'
  if (view.kind !== 'viewer') return 'none'
  if (view.guide === 'recover') return 'archives'
  return view.guide === 'login' ? 'login' : 'none'
}

/** 登录后回到这一场：场次 key 编码进 returnUrl，returnUrl 再整体编码一次。 */
export function eventLoginUrl(key: string): string {
  return `/pages/login/index?returnUrl=${encodeURIComponent(`/pages/flashback-event/index?key=${encodeURIComponent(key)}`)}`
}
