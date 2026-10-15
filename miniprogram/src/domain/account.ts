/**
 * 账号切换 / 退出登录的客户端持久键（主动退出）处置口径（#1079）。
 *
 * 只覆盖本「清空键」字面值，登录事务的 `clearAccountState` 不变：
 * 登录成功后由真实 Session 水合，无需墙间抢跑——本函数面向「退出登录」这一
 * 单一逃生面，按 userId 前缀匹配清掉（`wish-draft` 的 owner 键、闪念间入口
 * 重置意图与访客圈选），让「户主侧」用户数据不再可写入下一账号。
 *
 * - `cgc.wish-draft.<owner>`：写愿望草稿（owner = userId / 'guest'）。
 * - `cgc.flashback_entry_intent` 与 `cgc.flashback_last_guest_quote`：闪念间 UI
 *   意图与访客圈选——跨账号残留会让下一账号看到上一账号的草稿圈选。
 * `cgc.wish-draft.login-handoff` 按交接协议保留（与 `clearAccountState` 对
 * `pendingScene` 同口径的「扫码→登录交接」豁免——续跑后由自身流转消费/清）。
 */
export const WIPE_ACCOUNT_KEY_PREFIXES: readonly string[] = [
  'cgc.wish-draft.'
]

export const WIPE_ACCOUNT_EXACT_KEYS: readonly string[] = [
  'cgc.flashback_entry_intent',
  'cgc.flashback_last_guest_quote'
]

/**
 * 本机持久键是否属于「主动退出必须清」那一组（按字面前缀 / 精确名）——
 * 纯函数目的：把「应清哪些 key」的判据下沉 domain（页面无渲染测试），
 * 由 node --test 钉住，accountState 只需要 `Taro.getStorageInfoSync().keys` 过滤。
 */
export function isAccountWipeKey(key: string): boolean {
  if (key === 'cgc.wish-draft.login-handoff') return false
  if (WIPE_ACCOUNT_EXACT_KEYS.includes(key)) return true
  return WIPE_ACCOUNT_KEY_PREFIXES.some((prefix) => key.startsWith(prefix))
}
