import type { UserConfigExport } from '@tarojs/cli'
import './env'
import { resolve } from 'node:path'

const developmentEndpoint = 'http://localhost:4001/api/graphql'
const graphqlEndpoint = process.env.CGC_GRAPHQL_ENDPOINT ?? developmentEndpoint

export default {
  projectName: 'cgc-miniprogram',
  date: '2026-08-08',
  designWidth: 750,
  deviceRatio: {
    640: 2.34 / 2,
    750: 1,
    828: 1.81 / 2
  },
  sourceRoot: 'src',
  alias: {
    '@': resolve(__dirname, '..', 'src')
  },
  // 按平台分目录输出，便于三端产物并存比对
  outputRoot: `dist/${process.env.TARO_ENV || 'weapp'}`,
  plugins: ['@tarojs/plugin-platform-xhs'],
  defineConstants: {
    __GRAPHQL_ENDPOINT__: JSON.stringify(graphqlEndpoint),
    __E2E_MOCK__: JSON.stringify(process.env.CGC_E2E_MOCK === 'true'),
    // 当前平台显示名（构建期单值：微信/抖音/小红书）——裁剪端产物不含「微信」字样（零导流红线）
    __PLATFORM_NAME__: JSON.stringify(
      process.env.TARO_ENV === 'tt' ? '抖音'
        : process.env.TARO_ENV === 'xhs' ? '小红书'
        : '微信'
    ),
    __WECHAT_TEMPLATE_APPROVAL_RESULT__: JSON.stringify(
      process.env.CGC_WECHAT_TEMPLATE_APPROVAL_RESULT ?? ''
    ),
    __WECHAT_TEMPLATE_APPROVAL_REMINDER__: JSON.stringify(
      process.env.CGC_WECHAT_TEMPLATE_APPROVAL_REMINDER ?? ''
    ),
    __WECHAT_TEMPLATE_EVENT_REMINDER__: JSON.stringify(
      process.env.CGC_WECHAT_TEMPLATE_EVENT_REMINDER ?? ''
    ),
    __TT_TEMPLATE_APPROVAL_RESULT__: JSON.stringify(
      process.env.CGC_DOUYIN_TEMPLATE_APPROVAL_RESULT ?? ''
    ),
    __TT_TEMPLATE_EVENT_REMINDER__: JSON.stringify(
      process.env.CGC_DOUYIN_TEMPLATE_EVENT_REMINDER ?? ''
    )
  },
  copy: {
    patterns: [],
    options: {}
  },
  framework: 'react',
  compiler: 'webpack5',
  cache: {
    enable: false
  },
  mini: {
    postcss: {
      pxtransform: {
        enable: true,
        config: {}
      },
      cssModules: {
        enable: true,
        config: {
          namingPattern: 'module',
          generateScopedName: '[name]__[local]___[hash:base64:5]'
        }
      }
    }
  },
  h5: {}
} satisfies UserConfigExport
