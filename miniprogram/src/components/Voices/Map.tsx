import { useEffect, useMemo, useRef, useState } from 'react'
import { useDidHide } from '@tarojs/taro'
import { MAP_REPLAY_MS, buildMapReplay } from '@/domain/map-replay'
import { Button, Image, Text, View } from '@tarojs/components'
import type { VoiceCity } from '@/domain/flashback-voices'
import mapImage from '@/assets/flashback/mountain-map.png'
import styles from './map.module.css'

const featured = ['北京', '上海', '杭州', '成都', '广州']
export function VoicesMap({ cities, selected, caption }: { cities: VoiceCity[]; selected: string | null; caption?: string }) {
  const plan = useMemo(() => buildMapReplay(cities, selected), [cities, selected])
  const planKey = JSON.stringify([plan.origin, plan.cities.map(c => [c.name, ...c.lngLat])])
  const [playback, setPlayback] = useState({ id: 0, playing: false })
  const playingRef = useRef(false)
  const generation = useRef(0)
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null)
  const finish = (expected?: number) => {
    if (expected !== undefined && expected !== generation.current) return
    if (timer.current) clearTimeout(timer.current)
    timer.current = null
    playingRef.current = false
    setPlayback(previous => previous.playing ? { ...previous, playing: false } : previous)
  }
  const replay = () => {
    if (playingRef.current) { finish(); return }
    const id = ++generation.current
    playingRef.current = true
    setPlayback({ id, playing: true })
    // Animation-end also covers reduced motion; fallback releases the UI if the
    // renderer drops the event. Old animation events cannot stop a later replay.
    timer.current = setTimeout(() => finish(id), MAP_REPLAY_MS + 150)
  }
  useDidHide(() => finish())
  useEffect(() => { finish() }, [planKey])
  useEffect(() => () => { if (timer.current) clearTimeout(timer.current) }, [])
  const playing = playback.playing
  return <View className={styles.map}>
    <View className={styles.scene}>
      <Image className={styles.terrain} src={mapImage} mode='aspectFit' ariaLabel='中国山河地图，金线为声音与愿望之间的连接示意' />
      {playing && <View className={styles.night} style={{ animationDuration: `${MAP_REPLAY_MS}ms` }} onAnimationEnd={() => finish(playback.id)} />}
      <View key={playback.id} className={styles.connectionLayer}>
        {plan.segments.map((segment, index) => <View key={index} className={`${styles.connection} ${playing ? styles.tracing : ''}`} style={{
          left: `${segment.left}%`, top: `${segment.top}%`, width: `${segment.width}rpx`,
          transform: `rotate(${segment.angle}deg)`, animationDelay: `${segment.delay}ms`, animationDuration: `${segment.duration}ms`
        }} />)}
      </View>
      <Text className={styles.islands}>南海诸岛</Text>
      {plan.cities.map(city => <View key={`${city.name}-${playback.id}`} className={`${styles.pin} ${city.name === selected ? styles.selected : ''}`} style={{ left: `${city.left}%`, top: `${city.top}%` }}>
        {playing && <View className={styles.cityGlow} style={{ animationDelay: `${city.arrival}ms` }} />}
        <View className={`${styles.dot} ${playing ? styles.waking : ''}`} style={{ animationDelay: `${city.arrival}ms` }} />
        {(featured.includes(city.name) || city.name === selected) && <Text className={`${styles.label} ${city.name === '杭州' ? styles.hangzhou : city.name === '上海' ? styles.shanghai : ''}`}>{city.name}</Text>}
      </View>)}
      {caption && <Text className={styles.wishTag}>{caption.slice(0, 28)}{caption.length > 28 ? '…' : ''}</Text>}
    </View>
    <View className={styles.replayRow}>
      <Button className={styles.replayButton} onClick={replay} ariaLabel={playing ? '跳过山河亮起动画' : '重看山河亮起动画'}>
        <Text className={styles.replayIcon}>{playing ? 'Ⅱ' : '↻'}</Text>
        <Text>{playing ? '正在亮起 · 跳过' : '重看山河亮起'}</Text>
      </Button>
    </View>
  </View>
}
