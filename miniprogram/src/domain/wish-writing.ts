/** Account-owned wishes: pure form/draft decisions, shared by native pages and tests. */
export interface WishDraft {
  content: string
  city: string
  visibility: 'public' | 'private'
  signatureChoice: 'anonymous' | 'display_name'
  requestId: string
}
export interface OwnedWish {
  id: string
  content: string
  city: string | null
  visibility: string
  signature: string
  status: string
  insertedAt: string
}
export interface MyWishes { quotaRemaining: number; wishes: OwnedWish[] }
export const emptyWishDraft = (requestId: string): WishDraft => ({ content: '', city: '', visibility: 'public', signatureChoice: 'anonymous', requestId })
export const wishDraftKey = (owner: string | null): string => `cgc.wish-draft.${owner ?? 'guest'}`
export function editWishDraft(draft: WishDraft, patch: Partial<Omit<WishDraft, 'requestId'>>, newId: string): WishDraft {
  const next = { ...draft, ...patch }
  return Object.keys(patch).some(key => next[key] !== draft[key]) ? { ...next, requestId: newId } : draft
}
export function transferWishDraft(draft: WishDraft | null, from: string | null, to: string | null, transfer: string | null): WishDraft | null {
  return draft && to && transfer === draft.requestId && (from === null || from === to) ? draft : null
}
export const wishWriteReturnUrl = (transfer?: string): string => '/pages/flashback-wish-write/index' + (transfer ? `?transfer=${encodeURIComponent(transfer)}` : '')
export function wishValidation(draft: WishDraft, quota: number | null): string {
  const length = Array.from(draft.content.trim()).length
  if (!length || length > 500) return '请写下 1 至 500 字的愿望。'
  if (!draft.city.trim()) return '请填写期待相聚的城市。'
  if (quota === 0) return '今年的许愿名额已用完，每年最多 3 条，删除不退还额度。'
  return ''
}
export function wishStatusCopy(status: string): string {
  return ({ listed: '已公开', pending_review: '待审核', private: '仅自己和主办方可见' })[status] ?? '状态待确认'
}
export function isWishDraft(value: unknown): value is WishDraft {
  if (!value || typeof value !== 'object') return false
  const v = value as WishDraft
  return typeof v.content === 'string' && typeof v.city === 'string' && typeof v.requestId === 'string'
    && ['public', 'private'].includes(v.visibility) && ['anonymous', 'display_name'].includes(v.signatureChoice)
}
