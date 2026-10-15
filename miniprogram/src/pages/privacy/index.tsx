import { Text, View } from '@tarojs/components'
// 构建期 alias（config/index.ts `privacy-content$`）：weapp→wechat 原文，
// xhs→D7 变体（小红书），tt→D7 变体（抖音，#1079）；产物只含所选一份，
// 零导流扫描才能确定性通过。
import { PRIVACY_INTRO, PRIVACY_SECTIONS } from 'privacy-content'
import { PRIVACY_META } from '@/domain/privacy'
import { filingNumber } from '@/domain/filing'
import styles from './index.module.css'

/**
 * 隐私政策页（#355-11，微信审核对隐私政策可查看性的硬要求；P0-5 起小红书
 * 端同页注册——开发者协议 4.3 同要求）。
 * 内容骨架单源在 `domain/privacy.ts`（web 页、源档三方同步义务见该模块头注）；
 * 平台名枚举处由 build-time alias 选定的变体文件供给（见上方 import 注释）。
 * 抖音端 #1079 起注册本页（D7 变体 alias → privacy-content-tt），登录页协议文案可点开。
 */
export default function PrivacyPage() {
  // ICP 备案号行（#1077 §B「游客也可查看隐私说明，显示本应用的备案信息」）——
  // 本行先只在 tt 挂：weapp / xhs 隐私正文为已定稿文本（weapp 原文、xhs D7），
  // 追加行属审查面外且有重审成本；tt 由 #1079 新注册、尚未定稿法务口径，成本最低。
  const filing = process.env.TARO_ENV === 'tt' ? filingNumber('tt') : null
  return (
    <View className={styles.page}>
      <Text className={styles.title}>CGC 平台隐私政策</Text>
      <View className={styles.meta}>
        {PRIVACY_META.map((line) => (
          <Text key={line} className={styles.metaText}>{line}</Text>
        ))}
        {filing ? <Text className={styles.metaText}>备案信息：{filing}</Text> : null}
      </View>
      <Text className={styles.intro}>{PRIVACY_INTRO}</Text>
      {PRIVACY_SECTIONS.map((section) => (
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
