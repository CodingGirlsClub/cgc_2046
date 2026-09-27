/**
 * URL Link cq 承接（#770）：触达邮件主 CTA 是
 * `{批次级 url_link}?cq={本人明文 token}`，落地回访页（pages/flashback）
 * 时 query 携带 cq。
 *
 * 判定纯函数（页面层只负责写 storage）：非空且落在明文 token 字符集
 * `[A-Za-z0-9_-]`（后端 mint 的 43 字符 base64url；找回邮件形态带 fb_
 * 前缀同属该集）内才采纳——防启动参数污染 storage（`flashbackEntry`
 * 同款「被外部污染即弃」纪律）。
 */
export function adoptableCqToken(cq: unknown): string | null {
  if (typeof cq !== 'string' || cq === '') return null

  return /^[A-Za-z0-9_-]+$/.test(cq) ? cq : null
}

// not_bound 引导句按端分派（零导流红线：tt/xhs 产物不得出现「微信」，
// check-no-diversion.mjs 扫构建产物文本）。TARO_ENV 是构建期常量，
// 必须在**本模块内**直接比较——经变量中转（页面 isCut 先例）不会被
// 压缩器折叠，死分支字符串会残留在裁剪端产物里。
export const NOT_BOUND_LEAD =
  process.env.TARO_ENV === 'tt' || process.env.TARO_ENV === 'xhs'
    ? '打开我们发给你的专属链接完成首程。'
    : '在手机微信里打开我们发给你的专属链接，完成首程。'
