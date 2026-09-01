import Taro from '@tarojs/taro'
import type { PlatformPhonePayload, SubscriptionScenario } from '@/domain/models'

// 各平台订阅消息模板 ID（runtime env 注入，缺配时给出可读错误，不 crash）
// 微信：三场景（含 Owner 审批提醒）；抖音：仅学习者两场景（裁剪端无工作台）
const wechatTemplateIds: Record<SubscriptionScenario, string> = {
  approval_result: __WECHAT_TEMPLATE_APPROVAL_RESULT__,
  approval_reminder: __WECHAT_TEMPLATE_APPROVAL_REMINDER__,
  event_reminder: __WECHAT_TEMPLATE_EVENT_REMINDER__
}

const ttTemplateIds: Partial<Record<SubscriptionScenario, string>> = {
  approval_result: __TT_TEMPLATE_APPROVAL_RESULT__,
  event_reminder: __TT_TEMPLATE_EVENT_REMINDER__
}

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

export async function requestPlatformSubscription(
  scenario: SubscriptionScenario
): Promise<boolean> {
  if (__E2E_MOCK__) return true

  const platform = currentPlatform()
  // 小红书服务通知：由平台后台规则下发，无前端授权弹窗；前端仅上报配额（grant）
  if (platform === 'xhs') return true

  const templateId = platform === 'tt' ? ttTemplateIds[scenario] : wechatTemplateIds[scenario]
  if (!templateId) {
    throw new Error(`缺少${__PLATFORM_NAME__}订阅消息模板 ID，请在环境变量中配置后重试`)
  }
  const result = await Taro.requestSubscribeMessage({
    tmplIds: [templateId]
  } as Taro.requestSubscribeMessage.Option)
  if ('errCode' in result) throw new Error(result.errMsg || '订阅授权失败')
  return result[templateId] === 'accept'
}
