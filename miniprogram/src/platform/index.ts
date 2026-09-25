import Taro from '@tarojs/taro'
import type { PlatformPhonePayload, SubscriptionScenario } from '@/domain/models'
import { acceptedScenarios, configuredScenarios, subscriptionTransport } from '@/domain/subscription'

// 各平台订阅消息模板 ID 映射（构建期注入，见 config/index.ts；键集与
// SubscriptionScenario 的双射由 tests/subscription-build.test.mjs 守卫）。
// 微信：全量场景；抖音：仅学习者两场景（裁剪端无工作台）。
// 缺配 = 空串（不是 undefined）——由 configuredScenarios 过滤，绝不把空串递给微信。
const wechatTemplateIds: Record<SubscriptionScenario, string> = __WECHAT_TEMPLATE_IDS__

const ttTemplateIds: Partial<Record<SubscriptionScenario, string>> = __TT_TEMPLATE_IDS__

export function currentPlatform(): 'wechat' | 'tt' | 'xhs' {
  if (process.env.TARO_ENV === 'tt') return 'tt'
  if (process.env.TARO_ENV === 'xhs') return 'xhs'
  return 'wechat'
}

export async function preparePlatformLogin(
  phonePayload: PlatformPhonePayload
): Promise<PlatformPhonePayload> {
  if (__E2E_MOCK__) {
    return { loginCode: 'mock-login-code', encryptedData: 'mock-phone-data', iv: 'mock-iv' }
  }

  // Taro.login 跨平台转发：weapp→wx.login / tt→tt.login / xhs→xhs.login（runtime 动态映射）
  const login = await Taro.login()
  // weapp/tt 新契约优先：getPhoneNumber 回调给动态 code（phoneCode）→ 服务端
  // 直取手机号（wechat getuserphonenumber / tt get_phone_number），不要求
  // encryptedData/iv（也不该再触碰 session_key）。tt 新版基础库（3.51.0+）
  // 的 getPhoneNumber 只回 code——legacy 解密路径在抖音真机已不可达。
  const isNewPhonePlatform =
    process.env.TARO_ENV === 'weapp' || process.env.TARO_ENV === 'tt'
  if (isNewPhonePlatform && phonePayload.code) {
    if (!login.code) {
      throw new Error('登录凭证获取失败，请重试')
    }
    return { ...phonePayload, loginCode: login.code }
  }
  const encryptedData = phonePayload.encryptedData
  const iv = phonePayload.iv
  if (!login.code || !encryptedData || !iv) {
    throw new Error('手机号授权数据不完整，请重新授权后重试')
  }
  return { ...phonePayload, loginCode: login.code, encryptedData, iv }
}

/**
 * 请求订阅授权，返回**被接受**的场景子集。
 *
 * - 一次可请求多个场景（微信 `tmplIds` 单次上限 3；必须由用户点击或支付回调触发）；
 * - 未配置模板 ID 的场景由 `configuredScenarios` 剔除；剔除后为空 → 抛可读错误
 *   （不是静默成功，也绝不把空串递给微信）；
 * - `grantConsent` 由调用方对返回的每个场景分别上报（一次授权 = 后端 +1 配额）。
 */
export async function requestPlatformSubscriptions(
  scenarios: SubscriptionScenario[]
): Promise<SubscriptionScenario[]> {
  if (scenarios.length === 0) return []

  // 路径优先级**先于**缺配检查：mock 构建与 CI 都没有真实模板 ID，若先查缺配，
  // mock 下点订阅会抛「缺少模板 ID」而不是成功（e2e 走 mock transport）。
  // 小红书服务通知由平台后台规则下发，无前端授权弹窗——前端仅上报配额（grant）。
  if (__E2E_MOCK__ && scenarios.includes('flashback_wish_echo')) {
    const result = Taro.getStorageSync('cgc.e2e.wish-reminder-result')
    if (result === 'denied') return []
    if (result === 'error') throw new Error('订阅暂不可用（合成验收）')
  }
  if (subscriptionTransport(__E2E_MOCK__, currentPlatform()) === 'passthrough') return scenarios

  const table = currentPlatform() === 'tt' ? ttTemplateIds : wechatTemplateIds
  const requested = configuredScenarios(scenarios, table)
  if (requested.length === 0) {
    throw new Error(`缺少${__PLATFORM_NAME__}订阅消息模板 ID，请在环境变量中配置后重试`)
  }

  const tmplIds = requested.map((scenario) => table[scenario] ?? '')
  const result = await Taro.requestSubscribeMessage({
    tmplIds
  } as Taro.requestSubscribeMessage.Option)
  if ('errCode' in result) throw new Error(result.errMsg || '订阅授权失败')

  return acceptedScenarios(requested, tmplIds, result as Record<string, string>)
}
