import Taro from '@tarojs/taro'
import type { PlatformPhonePayload, SubscriptionScenario } from '@/domain/models'

const templateIds: Record<SubscriptionScenario, string> = {
  approval_result: __WECHAT_TEMPLATE_APPROVAL_RESULT__,
  approval_reminder: __WECHAT_TEMPLATE_APPROVAL_REMINDER__,
  event_reminder: __WECHAT_TEMPLATE_EVENT_REMINDER__
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

  const login = await Taro.login()
  const encryptedData = phonePayload.encryptedData
  const iv = phonePayload.iv
  if (!login.code || !encryptedData || !iv) {
    throw new Error('手机号授权数据不完整，请使用支持 encryptedData/iv 的基础库重试')
  }
  return { ...phonePayload, loginCode: login.code, encryptedData, iv }
}

export async function requestPlatformSubscription(
  scenario: SubscriptionScenario
): Promise<boolean> {
  if (__E2E_MOCK__) return true
  if (currentPlatform() !== 'wechat') throw new Error('本阶段仅启用微信订阅消息授权')

  const templateId = templateIds[scenario]
  if (!templateId) throw new Error('缺少微信订阅消息模板 ID')
  const result = await Taro.requestSubscribeMessage({
    tmplIds: [templateId]
  } as Taro.requestSubscribeMessage.Option)
  if ('errCode' in result) throw new Error(result.errMsg || '订阅授权失败')
  return result[templateId] === 'accept'
}
