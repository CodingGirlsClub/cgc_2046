import type { FlashbackCapsule } from './models.ts'

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
    unmatched: { title: '暂时还没找到你的那一张', description: '当前账号尚未匹配到历史档案。如果当年使用了其他手机号或邮箱，也可能暂时找不到。\n没有历史档案，也可以从今天开始。', button: '写下我的愿望 →', action: 'write' },
    error: { title: '暂时没能完成查找', description: '请再试一次。你也可以先听听金句，看看大家的愿望。', button: '重新查找 ↻', action: 'retry' }
  } as const
  return views[kind]
}

export function shouldRevealRecoveredCard(previousPerson: string | null, person: string, welcome: boolean): boolean {
  return previousPerson !== person && !welcome
}
