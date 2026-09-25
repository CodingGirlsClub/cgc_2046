import type { UserConfigExport } from '@tarojs/cli'
import './env'
import { resolve } from 'node:path'

const developmentEndpoint = 'http://localhost:4001/api/graphql'
const graphqlEndpoint = process.env.CGC_GRAPHQL_ENDPOINT ?? developmentEndpoint

// 订阅场景键列表（**构建期真源**）：驱动下面的 env 读取，一次性生成注入对象。
//
// 为什么是「一份列表 + 单一 define」而不是「一场景一条 defineConstants」：后者要在
// config/index.ts / types/global.d.ts / src/platform/index.ts 三处手抄平行清单，
// 少抄一处不报编译错、只在运行时炸——#606 的根因正是多处名单漂移（靠 allowlist
// 守卫测试兜底才暴露）。
//
// 本列表与 src/domain/models.ts 的 SubscriptionScenario 联合、src/domain/
// subscription.ts 的 ALL_SCENARIOS 三者双射，由 tests/subscription-build.test.mjs
// 钉住（纯文件扫描，不依赖真实模板 ID ⇒ CI 无 ID 也全绿）。
const WECHAT_SCENARIOS = [
  'approval_result',
  'approval_reminder',
  'event_reminder',
  'enrollment_completed',
  'enrollment_check_in_code',
  'event_qualification_confirmed',
  'event_qualification_underfilled',
  'event_qualification_manager',
  'event_schedule_changed',
  'event_moderator_assigned',
  'event_moderator_removed',
  'speaker_accepted',
  'speaker_completed',
  'learning_stagnation',
  'payment_succeeded',
  'payment_expired',
  'refund_succeeded',
  'refund_failed',
  'enrollment_submitted',
  'payment_received',
  // R14/R21 志愿者段位通知六键（模板 ID 待微信公众号后台申请；缺配 → 请求期
  // fail-closed 剔除，招募流照常提交，邮件为保底通道）
  'volunteer_application_submitted',
  'volunteer_application_interview',
  'volunteer_application_training',
  'volunteer_application_assigned',
  'volunteer_application_rejected',
  'volunteer_application_canceled',
  // wish2 U3/U9（KTD3）：附议 Echo 回响（2026-09-22 模板已配置；env 名机械推导
  // CGC_WECHAT_TEMPLATE_FLASHBACK_WISH_ECHO——.env.prod 已写真值）
  'flashback_wish_echo'
] as const

// 抖音裁剪端仅学习者两场景（裁剪端无工作台，见 src/app.config.ts cutPages）
const TT_SCENARIOS = ['approval_result', 'event_reminder'] as const

// 场景键 → 模板 ID 映射。env 名 = 前缀 + 场景键的 SCREAMING_SNAKE，机械可推，
// 不再逐条手写。JSON 文本经 defineConstants 按字面量内联，产物里即对象字面量。
// 缺配落空串：请求期 fail-closed 过滤掉未配置场景（src/platform/index.ts），
// **不阻断构建**——CI 与本地开发都没有真实模板 ID。
const templateIdMap = (scenarios: readonly string[], prefix: string): string =>
  JSON.stringify(
    Object.fromEntries(
      scenarios.map((scenario) => [
        scenario,
        process.env[`${prefix}${scenario.toUpperCase()}`] ?? ''
      ])
    )
  )

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
    '@': resolve(__dirname, '..', 'src'),
    // 隐私政策平台名枚举处（P0-5）：weapp/wechat 原文、xhs/D7 变体——构建期
    // 只注入一份，xhs 产物物理不含「微信」字样，零导流扫描确定性通过。
    // tt 不注册 privacy 页（本解析树不会进包），指向 wechat 无影响。
    'privacy-content$': resolve(
      __dirname,
      '..',
      'src',
      process.env.TARO_ENV === 'xhs' ? 'domain/privacy-content-xhs' : 'domain/privacy-content-wechat'
    )
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
    // 订阅消息模板 ID：单键注入整个映射（缺配为空串，请求期 fail-closed 过滤）
    __WECHAT_TEMPLATE_IDS__: templateIdMap(WECHAT_SCENARIOS, 'CGC_WECHAT_TEMPLATE_'),
    __TT_TEMPLATE_IDS__: templateIdMap(TT_SCENARIOS, 'CGC_DOUYIN_TEMPLATE_')
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
