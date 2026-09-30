/** Browser login is a dedicated entry; it must never become a workspace invitation. */
export const WEB_LOGIN_PATH = 'pages/web-login/index'
export type WebLoginStatus = 'PENDING' | 'APPROVED' | 'CONSUMED' | 'CANCELLED' | 'EXPIRED'
export interface WebLoginRequest { status: WebLoginStatus; expiresAt?: string | null }
export function webLoginEntry(path: string, query: Record<string, string | undefined>, platform: string): string | null {
  if (platform !== 'wechat' || path.replace(/^\//, '') !== WEB_LOGIN_PATH) return null
  // Taro 4 injects this timestamp into useRouter.params (runtime onLoad), not native page.options.
  const allowed = new Set(['scene', 'cq', 'requestId', 'scancode_time', '$taroTimestamp'])
  if (Object.keys(query).some(key => query[key] && !allowed.has(key))) return null
  const values = [query.scene, query.cq].filter((v): v is string => !!v)
  if (values.some(value => !/^wl_[A-Za-z0-9_-]{22}$/.test(value))) return null
  const ids = values.map(value => value.slice(3))
  if (query.requestId) ids.push(query.requestId)
  return ids.length > 0 && ids.every(id => /^[A-Za-z0-9_-]{22}$/.test(id) && id === ids[0]) ? ids[0] : null
}
export function canConfirmWebLogin(request: WebLoginRequest | null, authenticated: boolean, now: number): boolean {
  return !!request && authenticated && request.status === 'PENDING' &&
    typeof request.expiresAt === 'string' && Date.parse(request.expiresAt) > now
}
export function webLoginCopy(request: WebLoginRequest | null, now: number, local: { exited?: boolean; confirmationAttempted?: boolean } = {}): string {
  // Leaving this page is not a server cancellation. A lost response can hide an approval.
  if (local.exited) {
    if (request?.status === 'CONSUMED') return '网页版已登录，退出此页不会退出网页版。请返回原网页查看。'
    if (local.confirmationAttempted || request?.status === 'APPROVED') return '你可能已授权网页登录。退出此页不会撤销授权，请返回原网页查看或取消。'
    return '已退出本次确认，请返回原网页查看或取消登录请求。'
  }
  if (!request) return '正在检查登录请求…'
  if (request.status === 'CONSUMED') return '网页版已登录，请返回刚才的网页。'
  if (request.status === 'CANCELLED') return '这次登录已取消，请在网页重新发起。'
  if (request.status === 'EXPIRED' || !request.expiresAt || Date.parse(request.expiresAt) <= now) return '登录请求已过期，请在网页重新发起。'
  if (request.status === 'APPROVED') return '这次网页登录已获授权，请返回原网页查看。'
  return '仅确认你本人刚刚发起的登录。'
}


export type WebLoginPageState = 'active' | 'confirmation_attempted' | 'confirmed' | 'exited' | 'exited_after_attempt'
export type WebLoginPageAction =
  | { type: 'confirm_started' }
  | { type: 'confirm_received'; status: WebLoginStatus }
  | { type: 'exit' }

/** Local exit never revokes server approval, including an approval whose response was lost. */
export function transitionWebLoginPage(state: WebLoginPageState, action: WebLoginPageAction): WebLoginPageState {
  if (state === 'confirmed' || state === 'exited' || state === 'exited_after_attempt') return state
  switch (action.type) {
    case 'confirm_started': return 'confirmation_attempted'
    case 'confirm_received': return state === 'confirmation_attempted' && action.status === 'APPROVED' ? 'confirmed' : state
    case 'exit': return state === 'confirmation_attempted' ? 'exited_after_attempt' : 'exited'
  }
}

export function webLoginPageView(request: WebLoginRequest | null, state: WebLoginPageState, now: number, error = '') {
  const confirmed = state === 'confirmed'
  const exited = state === 'exited' || state === 'exited_after_attempt'
  const refreshable = !confirmed && !exited
  return {
    title: confirmed ? '已确认登录' : exited ? '已退出确认' : '登录网页版',
    description: confirmed ? '请返回刚才的网页，网页将自动完成登录。' : error && !request && !exited
      ? '请返回原网页检查登录请求。'
      : webLoginCopy(request, now, { exited, confirmationAttempted: state === 'confirmation_attempted' || state === 'exited_after_attempt' }),
    active: refreshable && canConfirmWebLogin(request, true, now),
    refreshable
  }
}
