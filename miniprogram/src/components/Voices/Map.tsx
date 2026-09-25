import { Image, Text, View } from '@tarojs/components'
import { voiceMapPoint, type VoiceCity } from '@/domain/flashback-voices'
import mapImage from '@/assets/flashback/voices-map.png'
import styles from './map.module.css'

const featured = ['北京', '上海', '杭州', '成都', '广州']
export function VoicesMap({ cities, selected }: { cities: VoiceCity[]; selected: string | null }) {
  // Nearby pins are decorative anchors; full-size city buttons below the map are
  // the equivalent accessible interaction (Shanghai/Hangzhou must not overlap).
  const visible = cities.filter(city => featured.includes(city.name) || city.name === selected)
  return <View className={styles.map}>
    <View className={styles.scene}>
    <Image className={styles.terrain} src={mapImage} mode='aspectFit' ariaLabel='中国山河地图，金线为声音之间的连接示意' />
    <Text className={styles.islands}>南海诸岛</Text>
    {visible.map(city => {
      const point = voiceMapPoint(city)
      if (!point) return null
      return <View key={city.name} className={`${styles.pin} ${city.name === selected ? styles.selected : ''}`} style={{ left: `${point.left}%`, top: `${point.top}%` }}>
        <View className={styles.dot} />
        <Text className={`${styles.label} ${city.name === '杭州' ? styles.hangzhou : city.name === '上海' ? styles.shanghai : ''}`}>{city.name}</Text>
      </View>
    })}
    </View>
  </View>
}
