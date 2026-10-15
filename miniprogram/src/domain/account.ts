/**
 * 账号切换 / 退出登录的客户端持久键（主动退出）处置口径（#1079）。
 *
 * **确定性键集**：调用方必须对返回的每一个 key 逐一 `removeStorageSync`，**不得**
 * 依赖 `Taro.getStorageInfoSync().keys` 枚举——枚举失败（返回空/partial/抛错）
 * 会把草稿留着而不报错，下一个登录者读到上一账号的愿望草稿（本次 review 找到的根因）。
 *
 * 覆盖：
 * - `cgc.wish-draft.<activeUserId>`：当前活跃账号的愿望草稿（userId = getActiveAccountId()）。
 * - `cgc.wish-draft.guest`：游客愿望草稿（任何退出都删——共用设备上「未登录读愿望」读到它）。
 * - `cgc.flashback_entry_intent` 与 `cgc.flashback_last_guest_quote`：闪念间 UI 意图与访客圈选。
 *
 * 保留（不在 wipe 职责内）：
 * - `cgc.wish-draft.login-handoff`：交接协议标记。对应草稿已被删，marker 孤立无害
 *   （receiveWishDraft 需 transfer=requestId 完全匹配；请求号不可能再对上）。
 * - 其他持久键：token / pendingScene / 通知缓存由 `clearAccountState` 语义持有。
 * - 历史其他账号的 `cgc.wish-draft.<uid>`：每账号独立桶，只能被 `currentOwner()` 读到——
 *   不是「下一账号」暴露面，不删有利于「换回该账号时草稿还在」的用户体验。
 */
export function wipeAccountKeys(activeUserId: string | null): readonly string[] {
  const drafts = activeUserId ? [activeUserId, 'guest'] : ['guest']
  return [
    ...drafts.map((owner) => `cgc.wish-draft.${owner}`),
    'cgc.flashback_entry_intent',
    'cgc.flashback_last_guest_quote'
  ]
}
