/**
 * 撤下与删除档案（#931）：判据与文案单源。
 *
 * 文案与 web `flashback.todaySlot.retract*` / `flashback.delete.*` 逐字一致——撤下与删除
 * 是同一个动作的两端入口，契约由 tests/flashback-retract.test.ts 读 web 文案断言，
 * 任何一端改文案都会让另一端的测试变红。
 */

export const RETRACT_COPY = {
  entry: '撤下这张卡',
  title: '撤下这张卡？',
  body: '撤下后，相册里只留下你的姓氏，其他人看不到你的卡了；随时可重新寄出。',
  confirm: '确认撤下',
  cancel: '再想想',
  error: '撤下没有成功——请再试一次。'
} as const

/** 撤下入口只在已寄出时出现（未寄出无可撤）。 */
export function canRetract(me: { today?: { sentToWallAt?: string | null } | null }): boolean {
  return !!me.today?.sentToWallAt
}

/** 与 web `CONFIRM_WORD` 同值：逐字相等才放行，不做大小写/空白宽松（不可逆动作）。 */
export const DELETE_CONFIRM_WORD = 'DELETE'

export const DELETE_COPY = {
  title: '删除我的档案',
  warning: '删除不可恢复：你的卡会从墙上撤下、专属链接立即失效、当年答案与回信将被清除、附议与金句授权一并删除。',
  error: '删除没有完成，请稍后重试。',
  confirmLabel: '输入 DELETE 确认删除',
  submit: '确认删除',
  cancel: '取消',
  doneTitle: '你的档案已清除',
  doneBody: '数据已删除、链接已失效。感谢你曾经来过。'
} as const

export interface FlashbackDeletePreview {
  fullName: string
  sentToWallAt: string | null
  endorsementCount: number
}

/** 删除前的「将失去什么」摘要（与 web factsName / factsOnWall / factsOffWall 同形）。 */
export function deleteFacts(preview: FlashbackDeletePreview): string[] {
  const count = preview.endorsementCount
  return [
    `档案：${preview.fullName}`,
    preview.sentToWallAt
      ? `已寄出到校友墙；你的 ${count} 条许愿附议与留言将一并删除`
      : `尚未寄出；你的 ${count} 条许愿附议与留言将一并删除`
  ]
}

export function canSubmitDelete(input: string, busy: boolean): boolean {
  return !busy && input === DELETE_CONFIRM_WORD
}
