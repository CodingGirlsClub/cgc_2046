/**
 * 隐私政策 · 小红书端变体（P0-5）。平台名引用收窄为小红书可承载措辞——
 * **D7 候选文本，待法务最终确认**（确认前不要把 dist/xhs 提交审核）。
 * 本文件严禁出现 diversion 词表任一词（词表见 scripts/diversion-policy.mjs）——只进 xhs 产物
 * （构建期 `config/index.ts` 的 `privacy-content$` alias 选定本文件），
 * `tests/privacy-content.test.ts` 以同词表机械断言锁住。
 * 数据处理事实与 wechat 变体一致，差异仅限平台名枚举处。
 */
import { privacyIntro, privacySections, type PrivacySpec } from './privacy.ts'

const spec: PrivacySpec = {
  introScope:
    '欢迎使用 CGC 平台（codingirlsclub.com 及小红书小程序端，以下合称「本平台」）。',
  phoneItem:
    '手机号码：短信验证码登录；小红书小程序手机号快捷登录（经平台授权组件，我们仅收到授权结果中的号码；使用对应登录方式时必填）',
  platformIdentityItem:
    '第三方平台身份标识（openid/unionid）：您经小红书等小程序平台登录时，平台返回的匿名标识，用于识别同一账号。',
  paymentPurposeItem:
    '订单与支付：订单信息；支付由合作支付机构处理，我们仅收到支付结果与必要对账信息（详见第 5 节）',
  thirdPartyItems: [
    '腾讯云（境内）：服务器与数据库托管——业务数据存储',
    '合作支付机构：支付——订单与支付要素',
    '抖音/小红书开放平台：小程序登录——openid',
    'SendCloud：交易类邮件（密码重置等）、验证码与活动唤醒触达（含「闪念间」专属链接邮件/短信）——收件邮箱/手机号、邮件/短信内容'
  ],
  delegationLead:
    '见《隐私政策》第 5 节第三方服务表（腾讯云/抖音/小红书/SendCloud/合作支付机构），均为履行服务所必需。'
}

export const PRIVACY_INTRO = privacyIntro(spec)
export const PRIVACY_SECTIONS = privacySections(spec)
