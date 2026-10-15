/**
 * ICP 备案号（页脚/隐私页展示单源；#1079 抖音。
 *
 * 同一主体（北京方圆修己科技有限公司）下按小程序/站点分别为不同备案记录：
 * - weapp（微信）：-6X
 * - xhs / tt（抖音/小红书）：-7X（同一主体同一份备案记录覆盖两端——抖音开放平台
 *   控制台 2026-10-15 由主控核实，AppID tt8792f12f19e9090101，状态「生效中」；
 *   两端的展示来源各自独立取值——将来备案记录分叉或简称修订时只改本处，
 *   不会误伤对端）
 * - 我们平台文档里的「备案信息」（web 主站）是 -2，不要与小程序记录互抄。
 *
 * `null` 语义：未备案/未到展示阶段——调用方不得渲染（fail-closed）。
 */
export type PlatformKind = 'weapp' | 'xhs' | 'tt'

const FILING_BY_PLATFORM: Record<PlatformKind, string | null> = {
  weapp: '京ICP备16008426号-6X',
  xhs: '京ICP备16008426号-7X',
  tt: '京ICP备16008426号-7X'
}

export function filingNumber(platform: PlatformKind): string | null {
  return FILING_BY_PLATFORM[platform]
}
