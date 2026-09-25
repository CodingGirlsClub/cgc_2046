import { Text, View } from '@tarojs/components'
// 构建期 alias（config/index.ts `privacy-content$`）：weapp→wechat 原文，
// xhs→D7 变体；产物只含所选一份，零导流扫描才能确定性通过。
import { PRIVACY_INTRO, PRIVACY_SECTIONS } from 'privacy-content'
import { PRIVACY_META } from '@/domain/privacy'
import styles from './index.module.css'

/**
 * 隐私政策页（#355-11，微信审核对隐私政策可查看性的硬要求；P0-5 起小红书
 * 端同页注册——开发者协议 4.3 同要求）。
 * 内容骨架单源在 `domain/privacy.ts`（web 页、源档三方同步义务见该模块头注）；
 * 平台名枚举处由 build-time alias 选定的变体文件供给（见上方 import 注释）。
 * 抖音端不注册本页（原文含「微信」过不了 check:diversion 词表，登录页协议
 * 文案保持纯文本）。
 */
export default function PrivacyPage() {
  return (
    <View className={styles.page}>
      <Text className={styles.title}>CGC 平台隐私政策</Text>
      <View className={styles.meta}>
        {PRIVACY_META.map((line) => (
          <Text key={line} className={styles.metaText}>{line}</Text>
        ))}
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
