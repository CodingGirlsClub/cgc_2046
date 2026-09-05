import { Text, View } from '@tarojs/components'
import styles from './index.module.css'

/**
 * 隐私政策页（#355-11，微信审核对隐私政策可查看性的硬要求）。
 * 内容转写自两份源档（与 web 端 /privacy 页同组成）：
 * - docs/合规上架/隐私政策.md（第 1-9 节）
 * - docs/合规上架/个人信息处理规则.md（末节附录——PIPL 要求处理规则
 *   公开即可，与隐私政策同页呈现，同 web 页设计决策）
 * 表格展平为条目、语句保持原文；法务文本变更时必须同步更新源档、web 页
 * 与本页（三方同步义务，同 web/app/[locale]/privacy/page.tsx 头注）。
 * 仅注册于全量端（app.config.ts fullPages）：政策原文含「微信」等词，
 * 受 CI check:diversion 裁剪端词表约束（仅扫 dist/tt、dist/xhs）——
 * tt/xhs 不注册本页，登录页协议文案在裁剪端保持纯文本（见 login/
 * index.tsx isCut 分支）。
 */

const META = [
  '生效日期 2026-09-01 ｜ 版本 v1.0（2026-08-20）',
  '运营者：CodingGirlsClub（「我们」）',
  '法律文本以中文版本为准'
]

const INTRO =
  '欢迎使用 CGC 平台（codingirlsclub.com，含微信/抖音/小红书小程序端，以下合称「本平台」）。本政策说明我们收集哪些个人信息、如何使用与保护、您拥有哪些权利。使用本平台即表示您已阅读并同意本政策。'

/** 有序内容块：段落或（可选小标题的）条目组，保序渲染 */
type Block = { kind: 'p'; text: string; title?: string } | { kind: 'items'; title?: string; items: string[] }

interface PolicySection {
  title: string
  blocks: Block[]
}

const SECTIONS: PolicySection[] = [
  {
    title: '1. 我们收集的信息',
    blocks: [
      {
        kind: 'items',
        title: '1.1 您主动提供的信息',
        items: [
          '电子邮箱地址：注册、登录（邮箱+密码）、找回密码（网站端注册必填）',
          '密码：邮箱+密码登录，仅存储加密哈希，我们不存储明文密码（该登录方式必填）',
          '手机号码：短信验证码登录；微信/抖音/小红书小程序手机号快捷登录（经平台授权组件，我们仅收到授权结果中的号码；使用对应登录方式时必填）',
          '姓名/昵称（display_name）：个人资料展示（选填）',
          '报名理由、提交材料：报名活动/课程、申请赞助或讲者（对应业务必填）',
          '学习记录、作业产出：参与课程学习（业务过程产生）'
        ]
      },
      {
        kind: 'items',
        title: '1.2 登录与身份关联信息',
        items: [
          '第三方平台身份标识（openid/unionid）：您经微信（含扫码与小程序）、抖音、小红书登录时，平台返回的匿名标识，用于识别同一账号。',
          '同一手机号在不同平台登录会归一到同一账号（跨平台归一）。',
          '平台会话密钥（session_key）仅在我们的服务端调用栈内使用，不进日志、不进数据库、不向任何端返回。'
        ]
      },
      {
        kind: 'items',
        title: '1.3 自动收集的信息',
        items: [
          '登录凭证与令牌（用于维持登录态；网站登录态存于加密 Cookie，Agent 连接令牌可由您自主生成与撤销）。',
          '操作日志：平台记录必要的账户与操作事件（如报名提交、审批操作、工具调用审计），用于安全与争议追溯。',
          '网络信息：处理请求所必需的 IP 地址（用于安全防护与限流，如登录失败次数限制）。'
        ]
      }
    ]
  },
  {
    title: '2. 我们如何使用信息',
    blocks: [
      {
        kind: 'items',
        title: '目的与涉及信息',
        items: [
          '账号创建与身份验证：邮箱、手机号、密码哈希、平台身份标识',
          '报名与审批处理：报名表单内容、账号身份',
          '通知送达：手机号（经平台订阅消息/短信）、邮箱（交易类邮件，如密码重置）——每次小程序订阅消息均需您主动授权，无授权不发送',
          '订单与支付：订单信息；支付由微信支付/支付宝处理，我们仅收到支付结果与必要对账信息（详见第 5 节）',
          '课程学习服务：学习记录、作业产出',
          '安全与反滥用：操作日志、IP（限流与异常行为防护）'
        ]
      },
      { kind: 'p', text: '我们不做什么：不向其他用户公开您的手机号（审批人可见姓名/邮箱，不含手机号）；不用于营销推送；不出售个人信息；不做用户画像。' }
    ]
  },
  {
    title: '3. 存储与保护',
    blocks: [
      {
        kind: 'items',
        items: [
          '密码仅存储不可逆加密哈希；登录令牌可撤销、有数量上限。',
          '手机号标记为敏感字段：不进入 API 响应、不进入日志——包括您本人在内的任何用户都无法通过接口读取手机号。',
          '全站强制 HTTPS 传输。',
          '手机号当前以可识别形态存储于数据库（用于跨平台账号归一），该方案已经过内部安全评审；后续版本将增加敏感操作二次校验。'
        ]
      }
    ]
  },
  {
    title: '4. 存储期限',
    blocks: [
      {
        kind: 'items',
        items: [
          '账号信息：存续于账号有效期内。',
          '操作与审计日志：保留合理期限用于安全与合规追溯。',
          '注销：当前版本可退出登录停止使用；账号注销与数据删除入口将在后续版本提供（届时可通过客服渠道提交人工注销申请）。'
        ]
      }
    ]
  },
  {
    title: '5. 第三方服务',
    blocks: [
      { kind: 'p', text: '本平台依赖以下第三方处理必要业务，各自受其隐私政策约束：' },
      {
        kind: 'items',
        items: [
          '腾讯云（境内）：服务器与数据库托管——业务数据存储',
          '微信开放平台/微信支付：登录、订阅消息、支付——openid、订单与支付要素',
          '支付宝：支付——订单与支付要素',
          '抖音/小红书开放平台：小程序登录与订阅消息——openid',
          'SendCloud：交易类邮件（密码重置等）与短信验证码——收件邮箱/手机号、验证码内容'
        ]
      },
      { kind: 'p', text: '我们不会向上述之外的主体提供您的个人信息，法律法规要求的除外。' }
    ]
  },
  {
    title: '6. 您的权利',
    blocks: [
      {
        kind: 'items',
        items: [
          '查询与更正：个人资料页可查看/修改姓名、昵称、语言偏好。',
          '撤回授权：小程序订阅消息按次授权，拒绝授权不影响业务本身（如报名）。',
          '退出登录：「我的」页/账户菜单可退出登录，服务端撤销当前登录态。',
          '撤销 Agent 连接令牌：MCP 页可随时撤销已生成的连接令牌。',
          '删除：如需删除账号或特定个人信息，可发送邮件至 info@codingirlsclub.com 联系我们，我们将在核实身份后 15 个工作日内处理。'
        ]
      }
    ]
  },
  {
    title: '7. 未成年人',
    blocks: [
      { kind: 'p', text: '本平台面向技术社区教育与协作，不面向不满 14 周岁的儿童收集个人信息。如您是未成年人，请在监护人指导下使用本平台。' }
    ]
  },
  {
    title: '8. 政策变更',
    blocks: [{ kind: 'p', text: '政策重大变更时我们将通过站内公告或登录通知告知。继续使用即视为接受变更后的政策。' }]
  },
  {
    title: '9. 联系我们',
    blocks: [
      { kind: 'items', items: ['网站端：页脚「联系我们」', '个人信息安全问题：info@codingirlsclub.com'] }
    ]
  },
  {
    title: '附录：CGC 平台个人信息处理规则',
    blocks: [
      { kind: 'p', text: '依据《个人信息保护法》（PIPL）第十七条编制，与本平台《隐私政策》配套公开。版本 v1.0（2026-08-20）' },
      {
        kind: 'items',
        title: '处理者信息',
        items: ['处理者名称：CodingGirlsClub（运营者）', '网站域名：codingirlsclub.com（含小程序端）']
      },
      {
        kind: 'items',
        title: '处理目的、方式、种类一览',
        items: [
          '电子邮箱：账号注册、登录、密码重置通知（方式：存储、验证、发送交易邮件；期限：账号存续期）',
          '密码（哈希）：身份验证（方式：单向加密存储、比对；期限：账号存续期）',
          '手机号码：短信登录、跨平台账号归一、订阅消息送达（方式：存储——敏感字段管控，不出 API/日志；期限：账号存续期）',
          '姓名/昵称：个人资料展示、报名身份呈现（方式：存储、授权范围内展示；期限：账号存续期）',
          '第三方平台标识（openid/unionid）：第三方登录身份关联（方式：存储、验证；期限：账号存续期）',
          '报名/申请表单内容：活动报名、赞助与讲者申请的审批处理（方式：存储、授权范围内展示；期限：业务必要期限）',
          '学习记录与作业产出：课程学习服务与进度展示（方式：存储；期限：账号存续期）',
          '订单与支付结果信息：订单管理、对账、退款（方式：存储——支付要素由支付机构处理；期限：法定与对账必要期限）',
          '操作与审计日志：安全防护、限流、争议追溯（方式：自动记录；期限：安全必要期限）',
          'IP 地址：安全限流（如登录失败限制）（方式：瞬时处理、日志留存；期限：安全必要期限）'
        ]
      },
      {
        kind: 'items',
        title: '敏感个人信息说明',
        items: [
          '手机号：用于登录与账号归一。授权入口即告知：登录页明示「登录即表示你同意隐私授权说明」；小程序端经平台授权组件主动授权后我们方获得号码。手机号字段实施了不出接口、不出日志的技术管控。',
          '本平台不收集生物识别、宗教信仰、医疗健康、金融账户、行踪轨迹、不满十四周岁未成年人信息等其它敏感个人信息。'
        ]
      },
      {
        kind: 'items',
        title: '委托处理与对外提供',
        items: [
          '见《隐私政策》第 5 节第三方服务表（腾讯云/微信/支付宝/抖音/小红书/SendCloud），均为履行服务所必需。',
          '除上述及法律法规要求外，我们不向任何第三方提供个人信息；不出售个人信息。'
        ]
      },
      { kind: 'p', title: '自动化决策', text: '本平台不进行基于个人信息的自动化决策（不含定向推送、差异化定价）。' },
      { kind: 'p', title: '个人信息跨境', text: '本平台服务器位于中华人民共和国境内，不进行跨境传输。' },
      { kind: 'p', title: '个人权利响应', text: '查询、复制、更正、删除、撤回同意、注销账号：可通过站内「联系我们」或 info@codingirlsclub.com 提出，我们将在 15 个工作日内核实身份并响应。' },
      { kind: 'p', title: '安全事件响应', text: '发生个人信息泄露等安全事件时，我们将依法采取补救措施，按规定告知监管部门与受影响用户。' }
    ]
  }
]

export default function PrivacyPage() {
  return (
    <View className={styles.page}>
      <Text className={styles.title}>CGC 平台隐私政策</Text>
      <View className={styles.meta}>
        {META.map((line) => (
          <Text key={line} className={styles.metaText}>{line}</Text>
        ))}
      </View>
      <Text className={styles.intro}>{INTRO}</Text>
      {SECTIONS.map((section) => (
        <View key={section.title} className={styles.section}>
          <Text className={styles.sectionTitle}>{section.title}</Text>
          {section.blocks.map((block, index) =>
            block.kind === 'p' ? (
              <View key={index}>
                {block.title ? <Text className={styles.subTitle}>{block.title}</Text> : null}
                <Text className={styles.paragraph}>{block.text}</Text>
              </View>
            ) : (
              <View key={index} className={styles.subsection}>
                {block.title ? <Text className={styles.subTitle}>{block.title}</Text> : null}
                {block.items.map((item) => (
                  <Text key={item} className={styles.item}>· {item}</Text>
                ))}
              </View>
            )
          )}
        </View>
      ))}
    </View>
  )
}
