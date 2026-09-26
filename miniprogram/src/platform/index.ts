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

/** 回访静默登录（#930）只要平台登录凭证：wx.login / tt.login / xhs.login 的 code（不碰手机号） */
export async function platformLoginCode(): Promise<string> {
  if (__E2E_MOCK__) return 'mock-login-code'
  const login = await Taro.login()
  if (!login.code) throw new Error('登录凭证获取失败，请重试')
  return login.code
}

// xhs 官方约束（《获取手机号》）：在 getPhoneNumber 回调里再调 xhs.login 会刷新
// session_key，回调加密数据（encryptedData/iv）将解密失败——登录码必须在用户点
// 「同意并登录」**之前**预取。登录页打开授权弹层时调 stagePlatformLoginCode()；
// preparePlatformLogin 消费暂存，缺失/过期才原地补取（兜底，可能解密失败，
// 由错误文案引导重试——重试会先走静默登录重新预取）。
// ponytail: 4 分钟硬编码有效期（平台 code 5 分钟），留余量；真机若出现长停留
// 场景再改成 checkSession 校验。
const XHS_LOGIN_CODE_TTL_MS = 4 * 60 * 1000
let xhsStagedLogin: { code: string; at: number } | null = null

export async function stagePlatformLoginCode(): Promise<void> {
  if (process.env.TARO_ENV !== 'xhs' || __E2E_MOCK__) return
  try {
    const code = await platformLoginCode()
    xhsStagedLogin = { code, at: Date.now() }
  } catch {
    xhsStagedLogin = null
  }
}

function consumeStagedLoginCode(): string | null {
  const staged = xhsStagedLogin
  xhsStagedLogin = null
  if (staged && Date.now() - staged.at < XHS_LOGIN_CODE_TTL_MS) return staged.code
  return null
}

export async function preparePlatformLogin(
  phonePayload: PlatformPhonePayload
): Promise<PlatformPhonePayload> {
  if (__E2E_MOCK__) {
    return { loginCode: 'mock-login-code', encryptedData: 'mock-phone-data', iv: 'mock-iv' }
  }

  // xhs：只消费「授权弹层打开前」预取的登录码（session_key 时序约束见上方注释）。
  // 预取缺失/过期时**不能**回调内原地补调 login——那会刷新 session_key，而加密数
  // 据是旧 key 加密的，必然解密失败（评审 B2：重试/长停留场景）。正确做法：重新
  // 预取（新 tap 的加密数据会用新 key），并请用户重新点按。weapp/tt 不受影响——
  // phoneCode 契约不依赖 session_key，回调内 login 是既有已验证行为，一字不动。
  if (process.env.TARO_ENV === 'xhs') {
    const staged = consumeStagedLoginCode()
    if (!staged) {
      void stagePlatformLoginCode()
      throw new Error('授权信息已过期，请重新点按「同意并登录」重试')
    }
    return finalizeXhsLogin(phonePayload, staged)
  }
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

/** xhs 专用：消费预取码组装 legacy 三件套（encryptedData/iv 由平台回调带给本函数） */
function finalizeXhsLogin(phonePayload: PlatformPhonePayload, stagedCode: string): PlatformPhonePayload {
  if (!phonePayload.encryptedData || !phonePayload.iv) {
    throw new Error('手机号授权数据不完整，请重新授权后重试')
  }
  return { ...phonePayload, loginCode: stagedCode, encryptedData: phonePayload.encryptedData, iv: phonePayload.iv }
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
  if (__E2E_MOCK__ && scenarios.includes('flashback_wish_echo')) {
    const result = Taro.getStorageSync('cgc.e2e.wish-reminder-result')
    if (result === 'denied') return []
    if (result === 'error') throw new Error('订阅暂不可用（合成验收）')
  }
  const transport = subscriptionTransport(__E2E_MOCK__, currentPlatform())
  // 小红书平台无订阅消息能力（模板 0/27）：零 grant 短路——漏拦的触点退化为
  // denied 反馈，而不是向后端骗配额（fail-closed 语义不变，见 domain 注释）
  if (transport === 'unsupported') return []
  if (transport === 'passthrough') return scenarios

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
