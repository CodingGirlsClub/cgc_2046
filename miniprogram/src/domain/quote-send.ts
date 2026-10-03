import type { MiniProgramApi } from './models'
import type { QuoteSuggestion } from './quote-suggestion'

export type QuotePick = Pick<QuoteSuggestion, 'questionKey' | 'start' | 'len'>
type SendApi = Pick<MiniProgramApi, 'flashbackSubmitToday' | 'flashbackSetQuoteLicense' | 'flashbackSendToWall'>
type Today = Parameters<SendApi['flashbackSubmitToday']>[0]

/** 两个寄出入口共用顺序。三个独立请求不能回滚：失败反馈须说明已完成哪一步。
 * 不把保存后的 reload 插进流程，避免组件重挂载丢掉用户选句与失败重试状态。
 * committedPick：上一轮已写入的授权句子（寄出失败留下的部分成功态）。本次即使
 * 用户改点「寄出到相册」，授权已在墙、无法在安全范围内替用户撤销（可能覆盖其
 * 此前的实名档），因此只寄出并把结果如实记作带句。
 */
export async function sendWithQuoteChoice(
  api: SendApi, today: Today, pick: QuotePick | null, token: string | null,
  committedPick: QuotePick | null = null
): Promise<{ ok: true; withQuote: boolean } | { ok: false; message: string; licenseCommitted: QuotePick | null }> {
  let stage: 'today' | 'license' | 'send' = 'today'
  try {
    await api.flashbackSubmitToday(today, token)
    if (pick) {
      stage = 'license'
      await api.flashbackSetQuoteLicense('anonymous', [pick], token)
    }
    stage = 'send'
    await api.flashbackSendToWall(token)
    return { ok: true, withQuote: pick !== null || committedPick !== null }
  } catch (error) {
    const detail = error instanceof Error ? error.message : '请重试'
    const licenseCommitted = stage === 'send' ? pick ?? committedPick : null
    const prefix = stage === 'today' ? '保存失败，尚未寄出'
      : stage === 'license' ? '金句授权没有调好——寄出已在此暂停'
        : licenseCommitted ? '金句已授权，相册寄出失败' : '相册寄出失败'
    return { ok: false, message: `${prefix}：${detail}`, licenseCommitted }
  }
}
