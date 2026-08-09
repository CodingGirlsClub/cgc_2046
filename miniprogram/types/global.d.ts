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
declare const __WECHAT_TEMPLATE_APPROVAL_RESULT__: string
declare const __WECHAT_TEMPLATE_APPROVAL_REMINDER__: string
declare const __WECHAT_TEMPLATE_EVENT_REMINDER__: string
declare const __TT_TEMPLATE_APPROVAL_RESULT__: string
declare const __TT_TEMPLATE_EVENT_REMINDER__: string

declare module '*.module.css' {
  const classes: Record<string, string>
  export default classes
}
