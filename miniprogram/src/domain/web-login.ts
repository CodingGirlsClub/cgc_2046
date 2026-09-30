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
  return !!request && authenticated && ['PENDING', 'APPROVED'].includes(request.status) &&
    typeof request.expiresAt === 'string' && Date.parse(request.expiresAt) > now
}
export function webLoginCopy(request: WebLoginRequest | null, now: number): string {
  if (!request) return '正在检查登录请求…'
  if (request.status === 'CONSUMED') return '网页版已登录，请返回刚才的网页。'
  if (request.status === 'CANCELLED') return '这次登录已取消，请在网页重新发起。'
  if (request.status === 'EXPIRED' || !request.expiresAt || Date.parse(request.expiresAt) <= now) return '登录请求已过期，请在网页重新发起。'
  return '仅确认你本人刚刚发起的登录。'
}
