import { useRef, useState } from 'react'
import { Button, Input, Text, Textarea, View } from '@tarojs/components'
import Taro, { useDidShow, useRouter } from '@tarojs/taro'
import { api } from '@/api'
import { getAuthToken, graphqlRequest } from '@/api/client'
import { getMyWishes } from '@/api/wishes'
import { FlashbackCitiesQueryDocument } from '@/api/operations'
import type { FlashbackCitiesQuery, FlashbackCitiesQueryVariables } from '@/api/generated/graphql'
import { cityCandidates, type CityOption } from '@/domain/flashback'
import { editWishDraft, emptyWishDraft, wishValidation, wishWriteReturnUrl, type WishDraft } from '@/domain/wish-writing'
import { getActiveAccountId } from '@/state/accountState'
import { clearWishDraft, newWishRequestId, prepareWishLogin, receiveWishDraft, saveWishDraft } from '@/state/wishDraft'
import styles from './index.module.css'

const currentOwner = () => getAuthToken() ? getActiveAccountId() : null
export default function WishWritePage() {
  const router = useRouter()
  const [draft, setDraft] = useState(() => emptyWishDraft(newWishRequestId()))
  const [owner, setOwner] = useState<string | null>(null)
  const [quota, setQuota] = useState<number | null>(null)
  const [cities, setCities] = useState<CityOption[]>([])
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)
  const inFlight = useRef(false)
  const generation = useRef(0)

  useDidShow(() => {
    const seq = ++generation.current
    const active = currentOwner()
    setOwner(active)
    setDraft(receiveWishDraft(active, router.params.transfer))
    setQuota(null)
    setError('')
    if (active) void getMyWishes().then(data => {
      if (seq === generation.current && currentOwner() === active) setQuota(data.quotaRemaining)
    }).catch(() => { /* Quota is enforced again by create; drafts remain writable offline. */ })
    if (!cities.length) void graphqlRequest<FlashbackCitiesQuery, FlashbackCitiesQueryVariables>(FlashbackCitiesQueryDocument, {})
      .then(data => setCities((data.flashbackCities ?? []).map(c => ({ name: c.name, pinyin: c.pinyin }))))
      .catch(() => { /* City text remains usable; authoritative validation is on submit. */ })
  })

  const edit = (patch: Partial<Omit<WishDraft, 'requestId'>>) => {
    if (inFlight.current || currentOwner() !== owner) return
    const next = editWishDraft(draft, patch, newWishRequestId())
    setDraft(next)
    saveWishDraft(owner, next)
    setError('')
  }
  const submit = async () => {
    if (inFlight.current) return
    const invalid = wishValidation(draft, quota)
    if (invalid) { setError(invalid); return }
    if (!getAuthToken()) {
      prepareWishLogin(owner, draft)
      await Taro.navigateTo({ url: `/pages/login/index?returnUrl=${encodeURIComponent(wishWriteReturnUrl(draft.requestId))}` })
      return
    }
    if (currentOwner() !== owner) { setError('账号已变化，请重新打开本页。草稿仍保存在原账号下。'); return }
    inFlight.current = true
    setBusy(true)
    setError('')
    saveWishDraft(owner, draft)
    try {
      const result = await api.flashbackCreateWish(draft.content.trim(), draft.visibility, null, {
        signatureChoice: draft.signatureChoice, expectedCity: draft.city.trim(),
        publicListingConsent: draft.visibility === 'public', requestId: draft.requestId
      })
      clearWishDraft(owner)
      if (currentOwner() !== owner) return
      await Taro.redirectTo({ url: `/pages/flashback-my-wishes/index?created=${encodeURIComponent(result.id)}` })
        .catch(() => setError('愿望已保存。请点击下方“我的愿望”查看。'))
    } catch (reason) {
      if (currentOwner() !== owner) { setError('登录已失效，草稿已保留，请重新登录后继续。'); return }
      setError(reason instanceof Error ? reason.message : '提交失败，草稿已保留，请重试。')
      void getMyWishes().then(data => { if (currentOwner() === owner) setQuota(data.quotaRemaining) }).catch(() => {})
    } finally { inFlight.current = false; setBusy(false) }
  }
  return <View className={styles.page}>
    <Text className={styles.eyebrow}>闪念间 · 写给未来</Text>
    <Text className={styles.title}>写下我的愿望</Text>
    <Text className={styles.intro}>想学什么、想遇见谁、想一起做些什么？{owner ? '' : '没有历史档案，也可以许愿。'}</Text>
    <Text className={styles.label}>我的愿望</Text>
    <Textarea className={styles.contentInput} value={draft.content} maxlength={500} disabled={busy} onInput={e => edit({ content: e.detail.value })} placeholder='写下你想和 CGC 一起实现的事…' />
    <Text className={styles.count}>{Array.from(draft.content).length} / 500</Text>
    <Text className={styles.label}>期待相聚的城市</Text>
    <Input className={styles.cityInput} value={draft.city} maxlength={16} disabled={busy} onInput={e => edit({ city: e.detail.value })} placeholder='例如：成都' />
    <View className={styles.candidates}>{cityCandidates(draft.city, cities).map(name => <Button key={name} className={styles.candidate} disabled={busy} onClick={() => edit({ city: name })}>{name}</Button>)}</View>
    <Text className={styles.label}>怎样署名</Text>
    <View className={styles.choices}>
      <Button className={`${styles.option} ${draft.signatureChoice === 'anonymous' ? styles.selected : ''}`} disabled={busy} onClick={() => edit({ signatureChoice: 'anonymous' })}>匿名</Button>
      <Button className={`${styles.option} ${draft.signatureChoice === 'display_name' ? styles.selected : ''}`} disabled={busy} onClick={() => edit({ signatureChoice: 'display_name' })}>使用展示名</Button>
    </View>
    <Text className={styles.label}>谁能看到</Text>
    <Button className={`${styles.publicChoice} ${draft.visibility === 'public' ? styles.selected : ''}`} disabled={busy} onClick={() => edit({ visibility: 'public' })}>公开愿望 · 任何人可见</Button>
    <Button className={`${styles.privateChoice} ${draft.visibility === 'private' ? styles.selected : ''}`} disabled={busy} onClick={() => edit({ visibility: 'private' })}>说给主办方听 · 仅自己和平台可见</Button>
    <Text className={styles.hint}>{draft.visibility === 'public' ? '提交即同意公开展示，大家可以期待它发生，也可以出力。' : '我们会认真看，可能会联系你，一起聊聊如何实现。'}</Text>
    <Text className={styles.quota}>{quota === null ? '每年可许 3 个愿望；删除不退还额度。' : `今年还可以许 ${quota} 个愿望；删除不退还额度。`}</Text>
    {error && <Text className={styles.error}>{error}</Text>}
    <Button className={styles.submit} loading={busy} disabled={busy || quota === 0} onClick={() => void submit()}>{busy ? '正在保存…' : owner ? '许下这个愿' : '登录并继续许愿'}</Button>
    <Text className={styles.saved}>{owner ? '草稿已保存在当前设备。' : '登录或取消登录，都不会丢失这份草稿。'}</Text>
    <Button className={styles.myWishesLink} onClick={() => Taro.navigateTo({ url: '/pages/flashback-my-wishes/index' })}>我的愿望 →</Button>
  </View>
}
