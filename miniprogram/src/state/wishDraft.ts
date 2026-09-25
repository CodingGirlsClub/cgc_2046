import Taro from '@tarojs/taro'
import { emptyWishDraft, isWishDraft, transferWishDraft, wishDraftKey, type WishDraft } from '@/domain/wish-writing'
const HANDOFF = 'cgc.wish-draft.login-handoff'
export const newWishRequestId = (): string => `${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`
export function readWishDraft(owner: string | null): WishDraft {
  const saved: unknown = Taro.getStorageSync(wishDraftKey(owner))
  return isWishDraft(saved) ? saved : emptyWishDraft(newWishRequestId())
}
export function saveWishDraft(owner: string | null, draft: WishDraft): void {
  Taro.setStorageSync(wishDraftKey(owner), draft)
}
export function clearWishDraft(owner: string | null): void { Taro.removeStorageSync(wishDraftKey(owner)) }
export function prepareWishLogin(owner: string | null, draft: WishDraft): void {
  saveWishDraft(owner, draft)
  Taro.setStorageSync(HANDOFF, { owner, requestId: draft.requestId })
}
export function receiveWishDraft(owner: string | null, transfer?: string): WishDraft {
  const handoff = Taro.getStorageSync<{ owner: string | null; requestId: string }>(HANDOFF)
  if (handoff && handoff.requestId === transfer) {
    const received = transferWishDraft(readWishDraft(handoff.owner), handoff.owner, owner, transfer ?? null)
    if (received) {
      if (handoff.owner !== owner) clearWishDraft(handoff.owner)
      saveWishDraft(owner, received)
      Taro.removeStorageSync(HANDOFF)
      return received
    }
  }
  return readWishDraft(owner)
}
