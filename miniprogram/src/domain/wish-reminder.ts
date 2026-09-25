import { requestAndGrant, wishEchoTouchpoint, type SubscriptionFeedback } from './subscription.ts'
import type { SubscriptionScenario } from './models.ts'

type ReminderDeps = {
  request: (scenarios: SubscriptionScenario[]) => Promise<SubscriptionScenario[]>
  grant: (scenario: SubscriptionScenario) => Promise<unknown>
}
export type WishReminderResult = SubscriptionFeedback | { kind: 'off' }

export async function requestWishReminder(deps: ReminderDeps): Promise<SubscriptionFeedback> {
  let result: SubscriptionFeedback = { kind: 'denied', title: wishEchoTouchpoint().deniedCopy }
  await requestAndGrant(wishEchoTouchpoint(), { ...deps, notify: feedback => { result = feedback } })
  return result
}

/** Grant before saving the opt-in; a failed subscription must not discard the contribution. */
export async function endorseWithReminder(
  notify: boolean,
  deps: ReminderDeps & { save: () => Promise<unknown> }
): Promise<WishReminderResult> {
  const result: WishReminderResult = notify ? await requestWishReminder(deps) : { kind: 'off' }
  await deps.save()
  return result
}

export function reminderReceipt(result: WishReminderResult) {
  switch (result.kind) {
    case 'accepted': return { canRetry: false, copy: '出力已保存，本次回响订阅授权已记录。已经发布的回响不会补发，可在许愿树查看。' }
    case 'off': return { canRetry: false, copy: '出力已保存，未开启提醒。你可以随时来许愿树查看回响。' }
    case 'denied': return { canRetry: true, copy: '出力已保存。你暂未授权回响提醒，可再次订阅，也可以随时来许愿树查看。' }
    case 'error': return { canRetry: true, copy: '出力已保存，但提醒未能开启。可重试订阅，也可以稍后来许愿树查看回响。' }
  }
}
