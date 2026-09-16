/// <reference types="@tarojs/taro" />

declare module '*.png'
declare module '*.gif'
declare module '*.jpg'
declare module '*.jpeg'
declare module '*.svg'
declare module '*.css'
declare module '*.less'
declare module '*.scss'
declare module '*.sass'
declare module '*.styl'

declare module '*.module.css' {
  const classes: { readonly [key: string]: string }
  export default classes
}

declare namespace NodeJS {
  interface ProcessEnv {
    /** NODE 环境 */
    NODE_ENV: 'development' | 'production'
    /** 当前构建的平台类型 weapp / tt / xhs / ... */
    TARO_ENV:
      | 'weapp'
      | 'swan'
      | 'alipay'
      | 'h5'
      | 'rn'
      | 'tt'
      | 'qq'
      | 'jd'
      | 'harmony'
      | 'xhs'
    /** 是否小程序 */
    TARO_APP_ID: string
  }
}

declare const defineAppConfig: (config: Record<string, unknown>) => Record<string, unknown>
declare const definePageConfig: (config: Record<string, unknown>) => Record<string, unknown>
declare const __GRAPHQL_ENDPOINT__: string
declare const __E2E_MOCK__: boolean
declare const __PLATFORM_NAME__: string
// 订阅消息模板 ID 映射（构建期由 config/index.ts 的 WECHAT_SCENARIOS /
// TT_SCENARIOS 列表生成；键集与 SubscriptionScenario 的双射由
// tests/subscription-build.test.mjs 守卫——本文件是 global script，引入 type
// import 会把它变成 module 并让上面所有 declare const 失去全局性，故此处
// 不收窄键类型）。
declare const __WECHAT_TEMPLATE_IDS__: Record<string, string>
declare const __TT_TEMPLATE_IDS__: Record<string, string>

declare module '*.module.css' {
  const classes: Record<string, string>
  export default classes
}
