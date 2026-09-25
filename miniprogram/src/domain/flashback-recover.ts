/**
 * 小程序内找回（#932）：已登录但没匹配到档案的人（当年用别的号码报名），凭当年留的手机号 /
 * 邮箱找回。发起同 web（flashbackRecover：命中与未命中同形返回，不泄露存在性）：
 * - 手机号 → 验证码 → flashbackRecoverVerifyForAccount 绑定到**当前账号**（不另建账号）；
 * - 邮箱 → 找回邮件里是网页入口链接：在浏览器打开、用现在登录小程序的手机号收好，
 *   即绑到同一账号（账号以手机号为锚）。
 */

export const RECOVER_COPY = {
  entry: '当年用的是别的手机号或邮箱？在这里找回 →',
  title: '找回当年的那一张',
  lead: '留下当年报名时的手机号或邮箱，验证后绑到你现在登录的账号。',
  identifierPlaceholder: '当年的手机号或邮箱',
  send: '发送验证码',
  codeHint: '如果这个号码在当年的名单里，验证码已经发出。',
  codePlaceholder: '验证码',
  verify: '验证并找回',
  emailHint: '如果这个邮箱在当年的名单里，找回邮件已经发出——在浏览器里打开邮件里的链接，用你现在登录小程序的手机号收好那张卡。',
  back: '回到闪念间',
  close: '先不找了',
  errorRetry: '刚才那步没有成功，请稍后重试。'
} as const

export type RecoverChannel = 'phone' | 'email'

/** 通道：含 @ 走邮件，其余按手机号发码（格式由服务端归一与校验，识别不了同样同形返回）。 */
export function recoverChannel(identifier: string): RecoverChannel | null {
  const value = identifier.trim()
  if (!value) return null
  return value.includes('@') ? 'email' : 'phone'
}

export function canSendRecover(identifier: string, busy: boolean): boolean {
  return !busy && recoverChannel(identifier) !== null
}

/** 与 web 找回表单同口径：验证码至少 4 位才放行。 */
export function canVerifyRecover(code: string, busy: boolean): boolean {
  return !busy && code.trim().length >= 4
}

export function recoverDoneText(count: number): string {
  return `找到了你的 ${count} 张卡，已经绑到你现在登录的账号。`
}
