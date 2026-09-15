/**
 * 核销码 QR payload 单源（#508 选项 A：小程序扫码核销主路径）。
 *
 * payload 不是 URL——扫码方是主理人小程序内 `Taro.scanCode`，拿到原始字符串
 * 自行解析，不再需要「能被相机/微信原生扫码打开的链接」（web 端 QR 曾编码相对
 * 路径、原生扫码只得纯文本的问题随本格式消解）。web/ 与小程序共用同一格式，
 * web 侧单源在 `web/lib/check-in.ts` 的 buildCheckInPayload（两端同文字，互指）。
 *
 * 解析器兼容三类输入（主理人扫到什么都尽量落成核销动作）：
 * - 新 payload：`cgc2046:checkin:<eventId>:<6位码>`
 * - 遗留 web QR（PR #548 期间发出的卡）：`.../events/<slug|eventId>/check-in?code=XXXXXX`
 *   ——提取 code；路段是 eventId 时一并提取供交叉校验，是 slug 则只靠页面上下文
 * - 裸 6 位码（手输同函数归一：剥空白/连字符）
 */

export const CHECK_IN_PAYLOAD_PREFIX = 'cgc2046:checkin:'

const CODE_PATTERN = /^\d{6}$/
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const LEGACY_CODE_PATTERN = /[?&]code=(\d{6})(?:&|$)/
const LEGACY_SEGMENT_PATTERN = /\/events\/([^/?]+)\/check-in/

export interface CheckInScan {
  code: string
  /**
   * payload 携带的 eventId；裸码与遗留 slug 段为 null（调用方按页面当前活动
   * 提交，eventId 非空且与页面不一致时给「其他活动的核销码」提示）。
   */
  eventId: string | null
}

/** 参与者 QR 内容：eventId + 6 位码（eventId 供主理人端交叉校验，不做保密用途） */
export function buildCheckInPayload(eventId: string, code: string): string {
  return `${CHECK_IN_PAYLOAD_PREFIX}${eventId}:${code}`
}

/**
 * 扫码/手输结果归一：合法 → { code, eventId? }；无法识别 → null（调用方给
 * 「不是核销码」本地提示，不发 mutation——无效输入不该消耗后端失败节流计数）。
 */
export function parseCheckInScan(raw: string | null | undefined): CheckInScan | null {
  if (!raw) return null
  const text = raw.trim()

  if (text.startsWith(CHECK_IN_PAYLOAD_PREFIX)) {
    const rest = text.slice(CHECK_IN_PAYLOAD_PREFIX.length)
    const sep = rest.lastIndexOf(':')
    if (sep <= 0) return null
    const eventId = rest.slice(0, sep)
    const code = rest.slice(sep + 1)
    if (!eventId || !CODE_PATTERN.test(code)) return null
    return { code, eventId }
  }

  const segment = LEGACY_SEGMENT_PATTERN.exec(text)?.[1] ?? null
  if (segment) {
    // 形如核销 URL：code 参数必须合法，否则不再做其他解读（防止把任意带
    // code= 的二维码误当核销码——误吞会白耗后端失败节流计数）
    const legacyCode = LEGACY_CODE_PATTERN.exec(text)
    if (!legacyCode) return null
    return {
      code: legacyCode[1],
      eventId: UUID_PATTERN.test(segment) ? segment : null
    }
  }

  const compact = text.replace(/[\s-]/g, '')
  if (CODE_PATTERN.test(compact)) return { code: compact, eventId: null }
  return null
}
