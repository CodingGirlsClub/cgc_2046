import { View, Text, Button } from '@tarojs/components'
import Taro, { useRouter } from '@tarojs/taro'
import styles from './index.module.css'

const mockDetail = {
  title: '滨江夜骑 20km',
  clubName: '城市骑行社',
  startAt: '2026-08-09 周六 19:00',
  endAt: '2026-08-09 周六 21:30',
  location: '浦东滨江大道（陆家嘴南段集合）',
  joinPolicy: '审批制',
  quota: 30,
  joined: 17,
  description:
    '沿滨江大道夜骑往返 20km，配速 15-18km/h。请自备头盔与车灯，新手友好。集合点 19:00 准时出发，过时不候。'
}

export default function EventDetailPage() {
  const router = useRouter()
  const eventId = router.params.id ?? 'unknown'

  const goRegister = () => {
    Taro.navigateTo({ url: `/pages/register-form/index?id=${eventId}` })
  }

  return (
    <View className={styles.page}>
      <View className={styles.header}>
        <Text className={styles.title}>{mockDetail.title}</Text>
        <Text className={styles.club}>{mockDetail.clubName}</Text>
      </View>

      <View className={styles.block}>
        <View className={styles.row}>
          <Text className={styles.label}>时间</Text>
          <Text className={styles.value}>
            {mockDetail.startAt} ~ {mockDetail.endAt}
          </Text>
        </View>
        <View className={styles.row}>
          <Text className={styles.label}>地点</Text>
          <Text className={styles.value}>{mockDetail.location}</Text>
        </View>
        <View className={styles.row}>
          <Text className={styles.label}>报名</Text>
          <Text className={styles.value}>
            {mockDetail.joinPolicy} · {mockDetail.joined}/{mockDetail.quota} 人
          </Text>
        </View>
      </View>

      <View className={styles.block}>
        <Text className={styles.label}>活动详情</Text>
        <Text className={styles.description}>{mockDetail.description}</Text>
      </View>

      <View className={styles.footer}>
        <Button className={styles.primaryButton} onClick={goRegister}>
          立即报名
        </Button>
      </View>
    </View>
  )
}
