import { useCallback, useEffect, useRef, useState } from 'react'
import { Button, Image, Text, View } from '@tarojs/components'
import Taro, { useDidHide, useDidShow } from '@tarojs/taro'
import { AppTabBar } from '@/components/AppTabBar'
import { getRandomVoices } from '@/api/flashback-voices'
import { api } from '@/api'
import { albumRows, type AlbumRow } from '@/domain/flashback-journey'
import { ensureWishVoterKey } from '@/domain/flashback'
import { guestVoicePreview, selectGuestVoice, type PublicVoice } from '@/domain/flashback-voices'
import { STORAGE_KEYS } from '@/state/storage'
import { recoveryView, type PublicRecovery } from '@/domain/flashback-recovery'
import { RECOVER_COPY } from '@/domain/flashback-recover'
import { FlashbackRecoverSheet } from '@/components/FlashbackRecover'
import landscape from '@/assets/flashback/mountain-map.png'
import styles from './index.module.css'

type QuoteState = { status: 'loading' | 'ready' | 'error'; voice: PublicVoice | null }
export function FlashbackGuest({ recovery, onRecover, onRetry }: { recovery: PublicRecovery; onRecover: () => void; onRetry: () => void }) {
  const [quote, setQuote] = useState<QuoteState>({ status: 'loading', voice: null })
  // #933 那些年的相册：未登录读公开统计层，已登录无档案读相册（多城市堆）；失败整段隐藏（非关键路径）
  const [albums, setAlbums] = useState<AlbumRow[]>([])
  // #932 小程序内找回：已登录没匹配到（当年用别的号码报名）→ 凭当年的号码找回、绑到当前账号
  const [recoverOpen, setRecoverOpen] = useState(false)
  useEffect(() => {
    if (recovery === 'checking') return
    let live = true
    const rows = recovery === 'unmatched'
      ? api.getFlashbackArchives().then(({ archives }) => albumRows(archives))
      : api.getFlashbackPublicStats().then((stats) => albumRows(stats.archives))
    rows.then((next) => { if (live) setAlbums(next) }).catch(() => { if (live) setAlbums([]) })
    return () => { live = false }
  }, [recovery])
  const generation = useRef(0)
  const load = useCallback(async () => {
    const seq = ++generation.current
    setQuote({ status: 'loading', voice: null })
    try {
      const voices = await getRandomVoices(ensureWishVoterKey())
      if (seq !== generation.current) return
      const previous = Taro.getStorageSync<string>(STORAGE_KEYS.flashbackLastGuestQuote) || null
      const voice = selectGuestVoice(voices, previous)
      if (voice) Taro.setStorageSync(STORAGE_KEYS.flashbackLastGuestQuote, voice.quoteId)
      else Taro.removeStorageSync(STORAGE_KEYS.flashbackLastGuestQuote)
      setQuote({ status: 'ready', voice })
    } catch {
      if (seq === generation.current) setQuote({ status: 'error', voice: null })
    }
  }, [])
  const show = () => {
    void Taro.setNavigationBarColor({ frontColor: '#000000', backgroundColor: '#f7f2e7' })
    void load()
  }
  useDidShow(show)
  useDidHide(() => { generation.current++ })
  useEffect(() => {
    show()
    return () => { generation.current++; void Taro.setNavigationBarColor({ frontColor: '#000000', backgroundColor: '#ffffff' }) }
  }, [load])
  const recoveryCopy = recoveryView(recovery)
  const preview = guestVoicePreview(quote.voice)
  const open = (url: string) => void Taro.navigateTo({ url })
  return <View className={styles.guestPage}>
    <View className={styles.content}>
      <Text className={styles.brand}>IN A FLASH</Text>
      <Text className={styles.headline}>有些话，{'\n'}过了很久还会发光。</Text>
      <Text className={styles.intro}>过去的声音，未来的相聚。</Text>
      <View className={styles.quoteCard}>
        <Image className={styles.landscape} src={landscape} mode='aspectFill' ariaLabel='山河纹理' />
        <View className={styles.tint} />
        <View className={styles.paperOutline} />
        {preview ? <Button className={styles.quoteOpen} onClick={() => open(preview.path)} ariaLabel='读这句公开金句'>
          <Text className={styles.source}>{preview.source}</Text>
          <Text className={styles.quoteText}>「{preview.text}」</Text>
          <Text className={styles.quoteCaption}>当年留下的答案，今天仍有回声。</Text>
        </Button> : <View className={styles.quoteState}>
          <Text className={styles.source}>VOICES</Text>
          <Text className={styles.stateText}>{quote.status === 'loading' ? '正在听见那些年的声音…' : quote.status === 'error' ? '声音暂时没有传来。' : '这里，等着新的声音。'}</Text>
          {quote.status === 'error'
            ? <Button className={styles.retry} onClick={() => void load()}>再听一次 ↻</Button>
            : <Text className={styles.quoteCaption}>经本人选择并授权的句子，会在这里相遇。</Text>}
        </View>}
      </View>
      <View className={styles.portals}>
        <Button className={styles.voicesPortal} onClick={() => open('/pages/flashback-voices/index')}>
          <Text className={styles.portalEnglish}>VOICES</Text><Text className={styles.portalTitle}>金句墙</Text><Text className={styles.portalHint}>听听当年的声音 ↗</Text>
        </Button>
        <Button className={styles.wishesPortal} onClick={() => open('/pages/flashback-wishes/index')}>
          <Text className={styles.portalEnglish}>WISHES</Text><Text className={styles.portalTitle}>许愿树</Text><Text className={styles.portalHint}>把期待留在这里 ↗</Text>
        </Button>
      </View>
      <View className={styles.recovery}>
        <Text className={styles.recoveryTitle}>{recoveryCopy.title}</Text>
        <Text className={styles.recoveryCopy}>{recoveryCopy.description}</Text>
        <Button className={styles.recoverButton} disabled={!recoveryCopy.action} loading={recovery === 'checking'} onClick={() => {
          if (recoveryCopy.action === 'login') onRecover()
          if (recoveryCopy.action === 'retry') onRetry()
          if (recoveryCopy.action === 'write') open('/pages/flashback-wish-write/index')
        }}>{recoveryCopy.button}</Button>
        {recovery === 'unmatched' && (
          <Text className={styles.recoverOther} onClick={() => setRecoverOpen(true)}>{RECOVER_COPY.entry}</Text>
        )}
      </View>
      {albums.length > 0 && (
        <View className={styles.albums}>
          <Text className={styles.albumsTitle}>那些年的相册</Text>
          <Text className={styles.albumsHint}>
            {recovery === 'guest' ? '登录后翻看每一场的名册。' : '回来的人亮着，还没回来的只留下一个姓。'}
          </Text>
          {albums.map((row) => (
            <View key={row.key} className={styles.albumRow} onClick={() => open(`/pages/flashback-event/index?key=${encodeURIComponent(row.key)}`)}>
              <View className={styles.albumMain}>
                <Text className={styles.albumTitle}>{row.when ? `${row.when} · ` : ''}{row.title}</Text>
                {row.meta ? <Text className={styles.albumMeta}>{row.meta}</Text> : null}
                {row.piles.length > 0 && (
                  <View className={styles.albumPiles}>
                    {row.piles.map((pile) => (
                      <Text key={pile.city} className={styles.albumPile}>
                        {pile.city} {pile.count} 位{pile.returned > 0 ? <Text className={styles.albumReturned}> · {pile.returned} 位已回来</Text> : null}
                      </Text>
                    ))}
                  </View>
                )}
              </View>
              <Text className={styles.albumArrow}>→</Text>
            </View>
          ))}
        </View>
      )}
      <Button className={styles.gathering} onClick={() => void Taro.switchTab({ url: '/pages/discover/index' })}>
        <Text className={styles.gatheringKicker}>下一次相聚</Text>
        <View className={styles.gatheringRow}><Text>发现下一场，一起做点什么</Text><Text>→</Text></View>
      </Button>
    </View>
    <AppTabBar selected='flashback' />
    {recoverOpen && (
      <FlashbackRecoverSheet onClose={() => setRecoverOpen(false)} onRecovered={() => { setRecoverOpen(false); onRetry() }} />
    )}
  </View>
}
