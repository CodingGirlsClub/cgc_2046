import { Button, Text, View } from '@tarojs/components'
import Taro from '@tarojs/taro'
import { CAMPAIGN_BRAND_EMAIL, openCampaignEntry } from '@/domain/campaign'
import styles from './index.module.css'

/**
 * campaign 宣传页（R19，微信端专属——裁剪端页清单不登记，见 src/app.config.ts）。
 * 内容为 weapp-d 原型的浓缩版：hero（十周年 + 关键数字 + 幂标记）/ 三入口卡 /
 * 时间线 / 可查证十年。口径与 web 宣传页（U6）对齐：无厂商名、无价格，
 * 历史累计（2016-2025）与本轮计划分开标注。
 */

/** 幂标记（R4 统一样式：等宽 + 缩小 + 橙色，与主数字视觉分离） */
function Pow({ n }: { n: number }) {
  return (
    <Text className={styles.pow} data-testid={`pow-${n}`}>2<Text className={styles.powExp}>{n}</Text></Text>
  )
}

const TIMELINE = [
  { title: '2026.10.24 启动', detail: '全国首场开课，campaign 正式开始' },
  { title: '首期 64 场', detail: '首批场次集中交付' },
  { title: '批次滚动', detail: '40+ 城陆续开班，直至 1,024 场' }
]

export default function CampaignPage() {
  return (
    <View className={styles.page}>
      <View className={styles.hero}>
        <Text className={styles.brand}>程序媛汇 · <Text className={styles.brandAccent}>十周年 CAMPAIGN</Text></Text>
        <Text className={styles.title} data-testid='campaign-title'>Hacker Start 1024</Text>
        <Text className={styles.subtitle}>让普通人第一次亲手用 Agent 做出能跑的作品</Text>
        <View className={styles.numbers}>
          <Text className={styles.number}>全国 <Text className={styles.numberValue}>1,024</Text> 场（<Pow n={10} />）</Text>
          <Text className={styles.number}><Text className={styles.numberValue}>10.24</Text> 启动（<Pow n={0} />）</Text>
          <Text className={styles.number}><Text className={styles.numberValue}>16</Text> 个品牌席位（<Pow n={4} />）</Text>
        </View>
        <View className={styles.ctaRow}>
          <View className={styles.cta} data-testid='campaign-hero-join' onClick={() => openCampaignEntry(Taro, 'join')}>
            <Text className={styles.ctaText}>我要参加</Text>
          </View>
          <View className={`${styles.cta} ${styles.ctaGhost}`} data-testid='campaign-hero-volunteer' onClick={() => openCampaignEntry(Taro, 'volunteer')}>
            <Text className={styles.ctaTextGhost}>成为志愿者</Text>
          </View>
        </View>
      </View>

      <View className={styles.body}>
        <Text className={styles.sectionTitle}>参与方式<Text className={styles.sectionEn}>THREE WAYS IN</Text></Text>

        <View className={`${styles.card} ${styles.cardBorder}`} data-testid='campaign-entry-join' onClick={() => openCampaignEntry(Taro, 'join')}>
          <View className={styles.cardTop}>
            <Text className={styles.kicker}>JOIN</Text>
            <Text className={styles.arrow}>›</Text>
          </View>
          <Text className={styles.cardTitle}>我要参加一场</Text>
          <Text className={styles.cardDesc}>3 小时工作坊：15 分钟开场 · 2 小时动手 · 30 分钟 demo。8 人开班（<Pow n={3} />）、32 人满班（<Pow n={5} />），场次陆续上线。</Text>
        </View>

        <View className={`${styles.card} ${styles.cardBorder}`} data-testid='campaign-entry-volunteer' onClick={() => openCampaignEntry(Taro, 'volunteer')}>
          <View className={styles.cardTop}>
            <Text className={styles.kicker}>VOLUNTEER</Text>
            <Text className={styles.arrow}>›</Text>
          </View>
          <Text className={styles.cardTitle}>成为志愿者</Text>
          <Text className={styles.cardDesc}>三个职位：场次主理人 / 教程研究员 Tutor / 活动教练 Coach。零出资零抽成，四段流程每段都有结果通知。</Text>
        </View>

        {/* 品牌合作无页面可跳：出口 = 复制邮箱（页内按钮），故卡片本身不接点击 */}
        <View className={`${styles.card} ${styles.cardBorder}`} data-testid='campaign-entry-brand'>
          <View className={styles.cardTop}>
            <Text className={styles.kicker}>BRAND</Text>
          </View>
          <Text className={styles.cardTitle}>品牌专场合作</Text>
          <Text className={styles.cardDesc}>16 席（<Pow n={4} />）× 64 场（<Pow n={6} />）＝ 1,024 场（<Pow n={10} />）。用为你定制的课程，触达第一批普通人用户。</Text>
          <View className={styles.brandRow}>
            <Text className={styles.brandEmail} data-testid='campaign-brand-email'>{CAMPAIGN_BRAND_EMAIL}</Text>
            <Button className={styles.copyButton} size='mini' data-testid='campaign-copy-email' onClick={() => openCampaignEntry(Taro, 'brand')}>复制邮箱</Button>
          </View>
          <Text className={styles.cardNote}>48 小时内回复 · 席位按签约进度更新</Text>
        </View>

        <Text className={styles.sectionTitle}>接下来会发生什么<Text className={styles.sectionEn}>TIMELINE</Text></Text>
        <View className={styles.card}>
          {TIMELINE.map((node, index) => (
            <View key={node.title} className={styles.step} data-testid={`campaign-timeline-${index + 1}`}>
              <Text className={styles.stepIndex}>{index + 1}</Text>
              <Text className={styles.stepText}><Text className={styles.stepTitle}>{node.title}</Text> · {node.detail}</Text>
            </View>
          ))}
        </View>

        <Text className={styles.sectionTitle}>十年社区，可以被查证的十年<Text className={styles.sectionEn}>RECOGNITION</Text></Text>
        <View className={styles.card}>
          <Text className={styles.cardDesc}>程序媛汇（Coding Girls Club）· 2016 年成立 · 中国首个女性编程社区（社会企业）。</Text>
          <Text className={styles.cardDesc}>2016-2025 历史累计：10 城 · 50+ 场工作坊 · 4,000+ 学员 · 阅读 2,000 万+。</Text>
          <Text className={styles.cardDesc}>ICSE CHASE 2021（IEEE）论文收录 · 联合国开发计划署「科技与慈善」案例 · 中国日报 / 环球时报 / CGTN 报道——均可公开检索。</Text>
          <Text className={styles.lever}>本轮一个 campaign 的参与人数目标 ≈ 过去十年累计。</Text>
        </View>
      </View>
    </View>
  )
}
