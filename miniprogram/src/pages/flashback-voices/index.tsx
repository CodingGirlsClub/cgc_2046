import { useEffect } from 'react'
import { Button, Text, View } from '@tarojs/components'
import Taro, { useRouter, useShareAppMessage, useShareTimeline } from '@tarojs/taro'
import { PageState } from '@/components/PageState'
import { VoiceCityFilter } from '@/components/Voices/CityFilter'
import { VoicesMap } from '@/components/Voices/Map'
import { useVoices } from '@/components/Voices/useVoices'
import { voiceShare } from '@/domain/flashback-voices'
import shareImage from '@/assets/flashback/voices-map.png'
import styles from './index.module.css'

export default function FlashbackVoicesPage() {
  const router = useRouter()
  const initialId = typeof router.params.quoteId === 'string' ? router.params.quoteId.trim() || null : null
  const { wall, current, city, cities, citiesLoading, citiesError, retryCities, busy, step, toggleLike, random, chooseCity, retry } = useVoices(initialId)
  useShareAppMessage(event => ({
    ...voiceShare(event.from === 'button' && (event.target as { dataset?: { scope?: string } } | undefined)?.dataset?.scope === 'quote' ? current : null),
    imageUrl: shareImage
  }))
  useShareTimeline(() => ({ ...voiceShare(current), imageUrl: shareImage }))
  useEffect(() => {
    // Menu shares the wall; a withdrawn sentence never remains a share payload.
    void Taro.showShareMenu({ showShareItems: ['shareAppMessage', 'shareTimeline'] })
  }, [])
  const corridor = () => {
    void Taro.switchTab({ url: '/pages/flashback-corridor/index' })
  }
  return <View className={styles.page}>
    <View className={styles.header}>
      <View><Text className={styles.title}>金句墙</Text><Text className={styles.english}>VOICES</Text></View>
      <Button className={styles.shareWall} openType='share' data-scope='wall'>分享整墙 ↗</Button>
    </View>
    <VoicesMap cities={cities} selected={current?.city ?? city} />
    <View className={styles.filters}>
      <Text className={styles.legend}>青绿 · 山河来处　　金线 · 句长成树</Text>
    </View>
    <VoiceCityFilter cities={cities} selected={city} loading={citiesLoading} error={citiesError} retry={retryCities} onChange={chooseCity} />
    <View className={styles.reader}>
      {wall.status === 'loading' && <PageState kind='loading' title='正在听见那些年的声音…' />}
      {wall.status === 'error' && <PageState kind='error' message={wall.error} onRetry={retry} />}
      {wall.status === 'gone' && <View className={styles.gone}>
        <Text className={styles.stateTitle}>这句话，已经收回了。</Text>
        <Text className={styles.stateCopy}>她的选择值得被尊重。你可以继续听听其他声音。</Text>
        <Button className={styles.primary} onClick={() => chooseCity(null)}>去看看整面墙 →</Button>
      </View>}
      {wall.status === 'ready' && !current && <View className={styles.empty}>
        <Text className={styles.stateTitle}>{city ? `${city}的声音，还在路上。` : '这里，等着新的声音。'}</Text>
        <Text className={styles.stateCopy}>公开墙只展示本人选择并授权的句子。</Text>
        {city && <Button className={styles.primary} onClick={() => chooseCity(null)}>听听其他城市 →</Button>}
      </View>}
      {current && <>
        <Text className={styles.eyebrow}>那年，她这样写　—</Text>
        <Text className={styles.quote}>{current.text}</Text>
        <View className={styles.meta}>
          <Text className={styles.attribution}>{current.attribution}</Text>
          <Button className={styles.shareQuote} openType='share' data-scope='quote' ariaLabel='分享这句话'>分享 ↗</Button>
        </View>
        <View className={styles.actions}>
          <Button className={`${styles.likeButton} ${current.likedByViewer ? styles.liked : ''}`} disabled={busy} onClick={() => void toggleLike()} ariaLabel={current.likedByViewer ? '取消点赞' : '赞这句话'}>
            {current.likedByViewer ? '♥' : '♡'}　{current.likeCount}
          </Button>
          <Button className={styles.random} disabled={busy} onClick={() => void random()}>随便听一听 ↝</Button>
        </View>
        <View className={styles.pager}>
          <Button className={styles.previous} disabled={busy || wall.rows.length < 2} onClick={() => step(-1)}>← 上一句</Button>
          <Text className={styles.position}>{String(wall.rows.findIndex(row => row.quoteId === current.quoteId) + 1).padStart(2, '0')} / {String(wall.rows.length).padStart(2, '0')}</Text>
          <Button className={styles.next} disabled={busy || wall.rows.length < 2} onClick={() => step(1)}>下一句 →</Button>
        </View>
        <Text className={styles.consent}>经本人选择并授权公开，赞是一份共鸣，无需登录。</Text>
      </>}
      <View className={styles.footer}>
        <Button className={styles.recover} onClick={() => corridor()}>找回你的那一张 ↗</Button>
        <Button className={styles.future} onClick={() => Taro.navigateTo({ url: "/pages/flashback-wish-write/index" })}>去许愿，写下未来 →</Button>
      </View>
    </View>
  </View>
}
