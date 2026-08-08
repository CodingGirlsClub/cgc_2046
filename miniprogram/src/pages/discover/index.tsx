import { View, Text, ScrollView } from '@tarojs/components'
import Taro from '@tarojs/taro'
import styles from './index.module.css'

interface ClubItem {
  id: string
  name: string
  memberCount: number
  tag: string
}

interface EventItem {
  id: string
  title: string
  clubName: string
  startAt: string
  location: string
}

interface CourseItem {
  id: string
  title: string
  tutor: string
  lessonCount: number
}

const clubs: ClubItem[] = [
  { id: 'c1', name: '城市骑行社', memberCount: 128, tag: '户外' },
  { id: 'c2', name: '周末读书会', memberCount: 86, tag: '文化' },
  { id: 'c3', name: '晨跑俱乐部', memberCount: 203, tag: '运动' }
]

const events: EventItem[] = [
  { id: 'e1', title: '滨江夜骑 20km', clubName: '城市骑行社', startAt: '08-09 周六 19:00', location: '浦东滨江大道' },
  { id: 'e2', title: '《人类简史》共读第三期', clubName: '周末读书会', startAt: '08-10 周日 14:00', location: '衡山路咖啡馆' },
  { id: 'e3', title: '世纪公园 5km 轻松跑', clubName: '晨跑俱乐部', startAt: '08-12 周二 06:30', location: '世纪公园 3 号门' }
]

const courses: CourseItem[] = [
  { id: 'k1', title: '新手骑行安全入门', tutor: '老周', lessonCount: 6 },
  { id: 'k2', title: '如何做一场读书会领读', tutor: '阿黎', lessonCount: 4 }
]

export default function DiscoverPage() {
  const openEvent = (id: string) => {
    Taro.navigateTo({ url: `/pages/event-detail/index?id=${id}` })
  }

  return (
    <ScrollView className={styles.page} scrollY>
      <View className={styles.section}>
        <Text className={styles.sectionTitle}>推荐 Club</Text>
        {clubs.map((club) => (
          <View key={club.id} className={styles.card}>
            <View className={styles.cardMain}>
              <Text className={styles.cardTitle}>{club.name}</Text>
              <Text className={styles.cardMeta}>{club.memberCount} 名成员</Text>
            </View>
            <Text className={styles.tag}>{club.tag}</Text>
          </View>
        ))}
      </View>

      <View className={styles.section}>
        <Text className={styles.sectionTitle}>即将开始的活动</Text>
        {events.map((event) => (
          <View
            key={event.id}
            className={styles.card}
            hoverClass={styles.cardHover}
            onClick={() => openEvent(event.id)}
          >
            <View className={styles.cardMain}>
              <Text className={styles.cardTitle}>{event.title}</Text>
              <Text className={styles.cardMeta}>
                {event.clubName} · {event.startAt}
              </Text>
              <Text className={styles.cardMeta}>{event.location}</Text>
            </View>
            <Text className={styles.arrow}>›</Text>
          </View>
        ))}
      </View>

      <View className={styles.section}>
        <Text className={styles.sectionTitle}>推荐 Course</Text>
        {courses.map((course) => (
          <View key={course.id} className={styles.card}>
            <View className={styles.cardMain}>
              <Text className={styles.cardTitle}>{course.title}</Text>
              <Text className={styles.cardMeta}>
                {course.tutor} · {course.lessonCount} 节
              </Text>
            </View>
          </View>
        ))}
      </View>
    </ScrollView>
  )
}
