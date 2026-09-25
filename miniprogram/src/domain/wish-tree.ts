import type { ViewerWish } from './flashback.ts'
export type TreeState = {
  status: 'loading' | 'ready' | 'gone' | 'error'
  generation: number
  rows: ViewerWish[]
  id: string | null
  offset: number
  more: boolean
  appending: boolean
  error: string
}
export const initialTree = (): TreeState => ({ status: 'loading', generation: 0, rows: [], id: null, offset: 0, more: false, appending: false, error: '' })
export type TreeAction =
  | { type: 'load'; generation: number; append: boolean }
  | { type: 'ready'; generation: number; rows: ViewerWish[]; selectedId: string | null; offset: number; more: boolean }
  | { type: 'gone'; generation: number }
  | { type: 'error'; generation: number; error: string }
  | { type: 'select'; id: string }
  | { type: 'expect'; generation: number; id: string; expected: boolean; count: number }
export function treeReducer(state: TreeState, action: TreeAction): TreeState {
  if (action.type === 'load') return action.append ? { ...state, generation: action.generation, appending: true, error: '' } : { ...initialTree(), generation: action.generation }
  if (action.type === 'select') return state.rows.some(row => row.id === action.id) ? { ...state, id: action.id } : state
  if (action.generation !== state.generation) return state
  if (action.type === 'gone') return { ...initialTree(), generation: state.generation, status: 'gone' }
  if (action.type === 'error') return { ...state, status: state.appending ? 'ready' : 'error', appending: false, error: action.error }
  if (action.type === 'expect') return { ...state, rows: state.rows.map(row => row.id === action.id ? { ...row, expectedByViewer: action.expected, expectationCount: action.count } : row) }
  const unique = new Map((state.appending ? state.rows : []).map(row => [row.id, row]))
  for (const row of action.rows) unique.set(row.id, row)
  const rows = [...unique.values()]
  return { ...state, status: 'ready', rows, id: rows.some(r => r.id === action.selectedId) ? action.selectedId : rows[0]?.id ?? null, offset: action.offset, more: action.more, appending: false, error: '' }
}
export function wishTreePath(city: string | null = null): string {
  return '/pages/flashback-wishes/index' + (city ? `?city=${encodeURIComponent(city)}` : '')
}
export function wishTreeShare(wish: ViewerWish | null) {
  const query = wish ? `wishId=${encodeURIComponent(wish.id)}` : ''
  return { title: wish ? `闪念间 · ${wish.content.slice(0, 45)}` : '闪念间 · 每个愿望，都可能成为下一次相聚', path: wishTreePath() + (query ? `?${query}` : ''), query }
}

/** WeChat keeps encoded query values in page options; decode at the page boundary. */
export function parseCityParam(value?: string): string | null {
  if (!value) return null
  try { return decodeURIComponent(value).trim().slice(0, 40) || null }
  catch { return null }
}
