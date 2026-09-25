import { useEffect, useRef, useState } from 'react'
import { Button, ScrollView, Text, View } from '@tarojs/components'
import Taro, { useDidHide } from '@tarojs/taro'
import type { VoiceCity } from '@/domain/flashback-voices'
import styles from './city-filter.module.css'

type Props = {
  cities: VoiceCity[]
  selected: string | null
  loading: boolean
  error: boolean
  retry: () => void
  onChange: (city: string | null) => void
}

export function VoiceCityFilter({ cities, selected, loading, error, retry, onChange }: Props) {
  const [open, setOpen] = useState(false)
  const [scrollLeft, setScrollLeft] = useState(0)
  const position = useRef(0)
  // Server supplies a stable pinyin order, independently of popularity/current quote.
  const names = [null, ...cities.map(city => city.name)]
  const index = Math.max(0, names.indexOf(selected))
  useEffect(() => {
    if (open) { setScrollLeft(position.current); return }
    let active = true
    // Native scroll-into-view does not resolve targets through Taro's nested templates.
    // Measure the actual row to center selections, including long city names.
    Taro.nextTick(() => {
      const query = Taro.createSelectorQuery()
      query.select('#voice-city-strip').fields({ rect: true, size: true, scrollOffset: true })
      query.select(`#voice-city-${index}`).boundingClientRect()
      query.exec(result => {
        if (!active || !result[0] || !result[1]) return
        const [strip, chip] = result
        setScrollLeft(Math.max(0, strip.scrollLeft + chip.left - strip.left - (strip.width - chip.width) / 2))
      })
    })
    return () => { active = false }
  }, [index, open, cities.length])
  useDidHide(() => setOpen(false))
  const choose = (city: string | null) => {
    setOpen(false)
    onChange(city)
  }
  return <>
    <View className={styles.cityBar}>
      <ScrollView id='voice-city-strip' className={styles.cityStrip} scrollX showScrollbar={false} scrollLeft={scrollLeft} onScroll={event => { position.current = event.detail.scrollLeft }} scrollWithAnimation>
        {names.map((name, i) => <View key={name ?? 'all'} id={`voice-city-${i}`} className={styles.cityItem}>
          <Button
            className={`${styles.cityChip} ${selected === name ? styles.activeChip : ''}`}
            ariaLabel={`${name ?? '全部城市'}${selected === name ? '，已选中' : ''}`} onClick={() => choose(name)}>{name ?? '全部'}</Button>
        </View>)}
      </ScrollView>
      <Button className={styles.allCitiesButton} onClick={() => setOpen(true)}>全部城市 ▾</Button>
    </View>
    {open && <View className={styles.cityMask} catchMove onClick={() => setOpen(false)}>
      <View className={styles.citySheet} onClick={event => event.stopPropagation()}>
        <View className={styles.sheetHeading}>
          <View><Text className={styles.sheetTitle}>选择城市</Text><Text className={styles.sheetHint}>有公开金句的城市 · 按拼音排列</Text></View>
          <Button className={styles.closeCities} ariaLabel='关闭城市选择' onClick={() => setOpen(false)}>关闭</Button>
        </View>
        {loading ? <Text className={styles.cityState}>正在加载城市…</Text> : error ? <View className={styles.cityState}>
          <Text>城市暂时未能加载</Text><Button className={styles.retryCities} onClick={retry}>重新加载</Button>
        </View> : <>
          {cities.length === 0 && <Text className={styles.cityState}>还没有公开金句的城市</Text>}
          <ScrollView className={styles.cityGridScroll} scrollY showScrollbar={false} scrollIntoView={`voice-grid-${index}`}
            style={{ height: `${Math.ceil(names.length / 4) * 104}rpx` }}>
            <View className={styles.cityGrid}>
              {names.map((name, i) => <Button key={name ?? 'all'} id={`voice-grid-${i}`}
                className={`${styles.gridCity} ${selected === name ? styles.activeGridCity : ''}`}
                ariaLabel={`${name ?? '全部城市'}${selected === name ? '，已选中' : ''}`} onClick={() => choose(name)}>{name ?? '全部'}</Button>)}
            </View>
          </ScrollView>
        </>}
      </View>
    </View>}
  </>
}
