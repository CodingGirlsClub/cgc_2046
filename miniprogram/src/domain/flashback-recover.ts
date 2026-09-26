/**
 * 小程序内找回（#932）：已登录但没匹配到档案的人（当年用别的号码报名），凭当年留的邮箱找回。
 * 发起同 web（flashbackRecover：命中与未命中同形返回，不泄露存在性）→ 找回邮件里的入口链接
 * 贴回小程序 → flashbackRecoverClaimForAccount 把同邮箱的档案绑到**当前账号**（不另建账号）。
 *
 * 手机号找回暂停（2026-09-26：库里人人有邮箱、未必有手机号，短信按条计费）：PHONE_RECOVERY_ENABLED
 * 关——手机号就地提示填邮箱、不发起；打开时手机号 → 验证码 → flashbackRecoverVerifyForAccount。
 * 重新开放须同时打开后端 :flashback_recover_phone_enabled、先补短信投递（见 backend
 * Flashback.Recover），并把下面的文案改回手机号 / 邮箱两用。
 */

export const PHONE_RECOVERY_ENABLED = false

export const RECOVER_COPY = {
  entry: '没找到？用当年报名的邮箱找回 →',
  title: '找回当年的那一张',
  lead: '留下当年报名用的邮箱，我们把找回链接发过去；把链接贴回这里，就收进你现在登录的账号。',
  identifierPlaceholder: '当年报名用的邮箱',
  send: '发送找回邮件',
  emailRequired: '请填写当年报名用的邮箱。',
  linkSentHint: '如果这个邮箱在当年的名单里，找回邮件已经发出（没收到就看看垃圾邮件）。打开邮件，复制里面的链接，粘贴到下面。',
  linkHint: '打开找回邮件，复制里面的链接，粘贴到下面。',
  linkPlaceholder: '粘贴找回邮件里的链接',
  claim: '收进我的账号',
  pasteEntry: '已经收到找回邮件？直接粘贴链接 →',
  codeHint: '如果这个号码在当年的名单里，验证码已经发出。',
  codePlaceholder: '验证码',
  verify: '验证并找回',
  back: '回到闪念间',
  close: '先不找了',
  errorRetry: '刚才那步没有成功，请稍后重试。'
} as const

/** 贴回来的链接失效三态：找回口径（旅程页的「邀请函」口径在 flashback-journey INVALID_COPY）。 */
export const RECOVER_LINK_ERRORS: Record<string, string> = {
  flashback_token_not_found: '没认出这条链接。请复制找回邮件里的完整链接再粘贴。',
  flashback_token_claimed: '这条链接已经用过了。重新发一封找回邮件，用新的链接再试。',
  flashback_token_revoked: '这条链接已经失效了。重新发一封找回邮件，用新的链接再试。'
}

export type RecoverChannel = 'phone' | 'email'

/** 通道：含 @ 走邮件（同后端 classify）；其余按手机号——通道暂停时不成通道。 */
export function recoverChannel(identifier: string, phoneEnabled: boolean = PHONE_RECOVERY_ENABLED): RecoverChannel | null {
  const value = identifier.trim()
  if (!value) return null
  if (value.includes('@')) return 'email'
  return phoneEnabled ? 'phone' : null
}

/** 有内容即可按：认不出的输入由面板就地提示填邮箱，而不是让按钮无故变灰。 */
export function canSendRecover(identifier: string, busy: boolean): boolean {
  return !busy && identifier.trim() !== ''
}

/** 链接原样上送（服务端取其中的 fb_ token，认不出 → token_not_found）；有内容即可按。 */
export function canClaimRecover(link: string, busy: boolean): boolean {
  return !busy && link.trim() !== ''
}

/** 与 web 找回表单同口径：验证码至少 4 位才放行。 */
export function canVerifyRecover(code: string, busy: boolean): boolean {
  return !busy && code.trim().length >= 4
}

export function recoverDoneText(count: number): string {
  return `找到了你的 ${count} 张卡，已经绑到你现在登录的账号。`
}
