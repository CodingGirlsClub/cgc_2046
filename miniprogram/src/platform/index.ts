import Taro from '@tarojs/taro'
import type { PlatformPhonePayload, SubscriptionScenario } from '@/domain/models'
import { acceptedScenarios, configuredScenarios, subscriptionTransport } from '@/domain/subscription'

// 各平台订阅消息模板 ID 映射（构建期注入，见 config/index.ts；键集与
// SubscriptionScenario 的双射由 tests/subscription-build.test.mjs 守卫）。
// 微信：全量场景；抖音：仅学习者两场景（裁剪端无工作台）。
// 缺配 = 空串（不是 undefined）——由 configuredScenarios 过滤，绝不把空串递给微信。
const wechatTemplateIds: Record<SubscriptionScenario, string> = __WECHAT_TEMPLATE_IDS__

const ttTemplateIds: Partial<Record<SubscriptionScenario, string>> = __TT_TEMPLATE_IDS__

// 小红书原生全局（Taro xhs 插件 1.2.2 停更，未代理 chooseSystemFile——迁移规划
// X-3）。字段名按小红书官方文档 https://miniapp.xiaohongshu.com/doc/DC777404
// （2026-09-27 抓取）；真机可用性未核实（xhs 模拟器 3.133.1 实测 2026-09-27：
// chooseSystemFile 为 undefined，canIUse('chooseSystemFile') 为 false——见下方
// chooseResumeTempFile 的 canIUse 守卫，release 前需在真机复核）。不要写进
// types/global.d.ts（那是 global script，见其头注释的 import 陷阱）。
declare const xhs: {
  canIUse(name: string): boolean
  chooseSystemFile(option: {
    type: 'file'
    extension: string[]
    success: (res: { tempFiles: { fileName: string; fileSize: number; path: string }[] }) => void
    fail: (err: unknown) => void
  }): void
}

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
// preparePlatformLogin 只消费暂存——缺失/过期不补取，改为重新预取并抛可恢复
// 错误请用户重新点按（新 tap 的加密数据配新 code）。
// ponytail: 4 分钟硬编码有效期（平台 code 5 分钟），留余量；真机若出现长停留
// 场景再改成 checkSession 校验。
const XHS_LOGIN_CODE_TTL_MS = 4 * 60 * 1000
let xhsStagedLogin: { code: string; at: number } | null = null
let xhsStageSeq = 0

/** 预取登录码。返回 true = 暂存就绪（可点「同意并登录」）。
 *  发起即作废旧暂存：新 login 会刷新 session_key，旧 code 必然失配；
 *  迟到的旧结果按序号丢弃——两次预取重叠时，后返回的旧 code 不得盖住新 session（B2）。 */
export async function stagePlatformLoginCode(): Promise<boolean> {
  if (process.env.TARO_ENV !== 'xhs' || __E2E_MOCK__) return true
  const seq = ++xhsStageSeq
  xhsStagedLogin = null
  try {
    const code = await platformLoginCode()
    if (seq !== xhsStageSeq) return false
    xhsStagedLogin = { code, at: Date.now() }
    return true
  } catch {
    return false
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

/**
 * 选一个本地文件，结果已归一为 `{ name, path, size }`（advisor-plans/010，简历
 * 上传适配小红书）：微信「从聊天记录选择文件」`chooseMessageFile` 的
 * `tempFiles[i].{name,size}` / 小红书 `chooseSystemFile` 的
 * `tempFiles[i].{fileName,fileSize}` 字段名不同，此处统一。
 *
 * 用户取消 / 选择失败 → null（静默，不提示）；小红书端 `canIUse` 为 false（当前
 * 不支持选文件）→ toast 提示后返回 null。
 */
export async function chooseResumeTempFile(
  extension: string[]
): Promise<{ name: string; path: string; size: number } | null> {
  if (currentPlatform() === 'xhs') {
    if (!xhs.canIUse('chooseSystemFile')) {
      Taro.showToast({ title: '当前版本不支持选择文件，请升级小红书后重试', icon: 'none' })
      return null
    }
    return new Promise((resolve) => {
      xhs.chooseSystemFile({
        type: 'file',
        extension,
        success: (res) => {
          const file = res.tempFiles?.[0]
          resolve(file ? { name: file.fileName, path: file.path, size: file.fileSize } : null)
        },
        fail: () => resolve(null)
      })
    })
  }
  try {
    const result = await Taro.chooseMessageFile({ count: 1, type: 'file', extension })
    const file = result.tempFiles?.[0]
    return file ? { name: file.name, path: file.path, size: file.size } : null
  } catch {
    // 取消也走 fail 回调：不提示（用户主动放弃不是错误）
    return null
  }
}
