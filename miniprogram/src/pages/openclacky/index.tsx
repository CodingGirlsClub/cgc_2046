import { Button, Text, View } from '@tarojs/components'
import Taro from '@tarojs/taro'
import styles from './index.module.css'

// 官方地址与 web 端接入引导同源（web/components/agent-connect-sections.tsx
// OpenclackyInstallCard iframe + web/proxy.ts CSP frame-src），不在本页另造 URL。
// 小程序无 web-view 业务域名配置，出口 = 复制到剪贴板，由用户在电脑浏览器打开
// （weapp setClipboardData 成功后平台自带「内容已复制」toast）。
const OPENCLACKY_SITE_URL = 'https://www.openclacky.com'
const OPENCLACKY_CGC_INSTALL_URL = 'https://www.openclacky.com/claw/cgc'

const copyUrl = (url: string) => {
  void Taro.setClipboardData({ data: url }).catch(() => {
    Taro.showToast({ title: '复制失败，请手动记录', icon: 'none' })
  })
}

export default function OpenClackyPage() {
  return (
    <View className={styles.page}>
      <Text className={styles.eyebrow}>CONTINUE IN OPENCLACKY</Text>
      <Text className={styles.title}>把深度协作留给你的本地环境</Text>
      <Text className={styles.description}>小程序负责发现、报名、审批与通知。课程学习、材料创作和完整协作在你自己的 OpenClacky 中进行。</Text>
      <View className={styles.steps}>
        <View className={styles.step}><Text className={styles.number}>01</Text><Text className={styles.stepText}>在电脑上安装 OpenClacky</Text></View>
        <View className={styles.step}><Text className={styles.number}>02</Text><Text className={styles.stepText}>安装官方 cgc-2046 连接器扩展</Text></View>
        <View className={styles.step}><Text className={styles.number}>03</Text><Text className={styles.stepText}>由扩展自动完成 CGC MCP 连接配置</Text></View>
      </View>
      <View className={styles.notice}>
        <Text className={styles.noticeTitle}>为什么不直接在小程序里完成？</Text>
        <Text className={styles.noticeText}>CGC 遵循 BYO 架构：模型与执行留在你的设备，平台只提供业务数据、鉴权和审计。</Text>
      </View>
      <View className={styles.actions}>
        <Button className={styles.copyButton} onClick={() => copyUrl(OPENCLACKY_SITE_URL)}>复制官网地址</Button>
        <Text className={styles.installHint} onClick={() => copyUrl(OPENCLACKY_CGC_INSTALL_URL)}>
          安装引导页：{OPENCLACKY_CGC_INSTALL_URL}（点按复制，在电脑浏览器打开）
        </Text>
      </View>
    </View>
  )
}
