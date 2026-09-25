/**
 * 隐私政策 · 微信全量端原文（#355-11）。含「微信」等平台名——只进 weapp 产物
 * （构建期 `config/index.ts` 的 `privacy-content$` alias 选定本文件），
 * 裁剪端产物由 alias 指向 xhs 变体，本文件物理不进包，零导流扫描可确定性通过。
 * 与源档（docs/合规上架/隐私政策.md）三方同步义务见 `domain/privacy.ts` 头注。
 */
import { privacyIntro, privacySections, type PrivacySpec } from './privacy.ts'

const spec: PrivacySpec = {
  introScope:
    '欢迎使用 CGC 平台（codingirlsclub.com，含微信/抖音/小红书小程序端，以下合称「本平台」）。',
  phoneItem:
    '手机号码：短信验证码登录；微信/抖音/小红书小程序手机号快捷登录（经平台授权组件，我们仅收到授权结果中的号码；使用对应登录方式时必填）',
  platformIdentityItem:
    '第三方平台身份标识（openid/unionid）：您经微信（含扫码与小程序）、抖音、小红书登录时，平台返回的匿名标识，用于识别同一账号。',
  paymentPurposeItem:
    '订单与支付：订单信息；支付由微信支付/支付宝处理，我们仅收到支付结果与必要对账信息（详见第 5 节）',
  thirdPartyItems: [
    '腾讯云（境内）：服务器与数据库托管——业务数据存储',
    '微信开放平台/微信支付：登录、订阅消息、支付——openid、订单与支付要素',
    '支付宝：支付——订单与支付要素',
    '抖音/小红书开放平台：小程序登录与订阅消息——openid',
    'SendCloud：交易类邮件（密码重置等）与短信验证码——收件邮箱/手机号、验证码内容'
  ],
  delegationLead:
    '见《隐私政策》第 5 节第三方服务表（腾讯云/微信/支付宝/抖音/小红书/SendCloud），均为履行服务所必需。'
}

export const PRIVACY_INTRO = privacyIntro(spec)
export const PRIVACY_SECTIONS = privacySections(spec)
