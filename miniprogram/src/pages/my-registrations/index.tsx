import { View, Text, ScrollView } from '@tarojs/components'
import styles from './index.module.css'

type RegistrationStatus = 'pending' | 'confirmed' | 'rejected' | 'expired' | 'cancelled'

interface Registration {
  id: string
  eventTitle: string
  clubName: string
  startAt: string
  status: RegistrationStatus
  /** pending 状态剩余审批时间（秒），mock 固定值 */
  remainingSeconds?: number
}

const statusText: Record<RegistrationStatus, string> = {
  pending: '等待审批',
  confirmed: '已通过',
  rejected: '已拒绝',
  expired: '审批超时',
  cancelled: '已取消'
}

const registrations: Registration[] = [
  { id: 'r1', eventTitle: '滨江夜骑 20km', clubName: '城市骑行社', startAt: '08-09 周六 19:00', status: 'pending', remainingSeconds: 26 * 3600 + 14 * 60 },
  { id: 'r2', eventTitle: '《人类简史》共读第三期', clubName: '周末读书会', startAt: '08-10 周日 14:00', status: 'confirmed' },
  { id: 'r3', eventTitle: '世纪公园 5km 轻松跑', clubName: '晨跑俱乐部', startAt: '08-05 周二 06:30', status: 'rejected' },
  { id: 'r4', eventTitle: '陆冲体验课', clubName: '城市骑行社', startAt: '08-02 周六 15:00', status: 'expired' },
  { id: 'r5', eventTitle: '旧书交换市集', clubName: '周末读书会', startAt: '07-26 周六 10:00', status: 'cancelled' }
]

function formatCountdown(totalSeconds: number): string {
  const hours = Math.floor(totalSeconds / 3600)
  const minutes = Math.floor((totalSeconds % 3600) / 60)
  return `剩余 ${hours} 小时 ${minutes} 分钟`
}

export default function MyRegistrationsPage() {
  return (
    <View className={styles.page}>
      <ScrollView scrollY className={styles.list}>
        {registrations.map((item) => (
          <View key={item.id} className={styles.card}>
            <View className={styles.cardHeader}>
              <Text className={styles.title}>{item.eventTitle}</Text>
              <Text className={`${styles.status} ${styles[item.status]}`}>
                {statusText[item.status]}
              </Text>
            </View>
            <Text className={styles.meta}>
              {item.clubName} · {item.startAt}
            </Text>
            {item.status === 'pending' && item.remainingSeconds != null && (
              <Text className={styles.countdown}>
                审批倒计时 {formatCountdown(item.remainingSeconds)}
              </Text>
            )}
            {(item.status === 'rejected' || item.status === 'expired') && (
              <Text className={styles.resubmit}>可重新提交</Text>
            )}
          </View>
        ))}
      </ScrollView>

      {process.env.TARO_ENV !== 'weapp' && (
        <View className={styles.platformTip}>
          审批结果将通过本端订阅消息通知你
        </View>
      )}
    </View>
  )
}
