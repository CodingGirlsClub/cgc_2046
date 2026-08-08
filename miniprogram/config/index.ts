import type { UserConfigExport } from '@tarojs/cli'

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
  // 按平台分目录输出，便于三端产物并存比对
  outputRoot: `dist/${process.env.TARO_ENV || 'weapp'}`,
  plugins: ['@tarojs/plugin-platform-xhs'],
  defineConstants: {},
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
