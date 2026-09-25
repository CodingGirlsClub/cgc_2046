import { useCallback, useEffect, useRef, useState } from 'react'
import Taro, { useDidShow } from '@tarojs/taro'
import { getVoices, getVoice, getRandomVoices, likeVoice, getVoiceCities } from '@/api/flashback-voices'
import { ensureWishVoterKey } from '@/domain/flashback'
import { mergeVoices, moveVoice, selectVoice, type PublicVoice, type VoiceCity } from '@/domain/flashback-voices'

type Wall = { status: 'loading' | 'ready' | 'error' | 'gone'; rows: PublicVoice[]; id: string | null; error?: string }
export function useVoices(initialId: string | null) {
  const voter = useRef(ensureWishVoterKey())
  const sequence = useRef(0)
  const alive = useRef(true)
  const actionLock = useRef(false)
  const [wall, setWall] = useState<Wall>({ status: 'loading', rows: [], id: null })
  const [city, setCity] = useState<string | null>(null)
  const [cities, setCities] = useState<VoiceCity[]>([])
  const [busy, setBusy] = useState(false)
  const citySequence = useRef(0)
  const [citiesLoading, setCitiesLoading] = useState(true)
  const [citiesError, setCitiesError] = useState(false)
  const target = useRef(initialId)
  const cityRef = useRef<string | null>(null)

  const load = useCallback(async (nextCity: string | null, quoteId: string | null) => {
    const seq = ++sequence.current
    cityRef.current = nextCity
    target.current = quoteId
    setCity(nextCity)
    // Return-to-page and withdrawn links must never show stale public text while checking.
    setWall({ status: 'loading', rows: [], id: null })
    try {
      // A direct share is independent of top-60 membership.
      const direct = quoteId ? await getVoice(quoteId, voter.current) : undefined
      if (!alive.current || seq !== sequence.current) return
      if (direct === null) { setWall({ status: 'gone', rows: [], id: null }); return }
      const rows = await getVoices(voter.current, nextCity)
      if (!alive.current || seq !== sequence.current) return
      const merged = direct ? mergeVoices([direct], rows) : rows
      setWall({ status: 'ready', rows: merged, id: quoteId ?? merged[0]?.quoteId ?? null })
    } catch (error) {
      if (alive.current && seq === sequence.current) setWall({ status: 'error', rows: [], id: null, error: error instanceof Error ? error.message : '暂时没有连上，请重试' })
    }
  }, [])
  const retryCities = useCallback(() => {
    const seq = ++citySequence.current
    setCitiesLoading(true)
    setCitiesError(false)
    void getVoiceCities().then(result => {
      if (alive.current && seq === citySequence.current) setCities(result)
    }).catch(() => {
      if (alive.current && seq === citySequence.current) setCitiesError(true)
    }).finally(() => {
      if (alive.current && seq === citySequence.current) setCitiesLoading(false)
    })
  }, [])
  useEffect(() => () => { alive.current = false; sequence.current++; citySequence.current++ }, [])
  useDidShow(() => { retryCities(); void load(cityRef.current, target.current) })
  const current = wall.status === 'ready' ? selectVoice(wall.rows, wall.id) : null
  const step = (delta: number) => {
    if (actionLock.current) return
    const id = moveVoice(wall.rows, wall.id, delta)
    target.current = id
    setWall(previous => ({ ...previous, id }))
  }
  const toggleLike = async () => {
    if (!current || actionLock.current) return
    actionLock.current = true
    setBusy(true)
    const seq = sequence.current
    try {
      const liked = !current.likedByViewer
      const count = await likeVoice(current.quoteId, voter.current, liked)
      if (!alive.current || seq !== sequence.current) return
      // Do not reload/re-sort after liking: keep the sentence the user is reading.
      setWall(previous => ({ ...previous, rows: previous.rows.map(row => row.quoteId === current.quoteId ? { ...row, likeCount: count, likedByViewer: liked } : row) }))
      if (liked) void Taro.showToast({ title: '谢谢你，让这句话被听见', icon: 'none' })
    } catch (error) {
      if (alive.current && seq === sequence.current) void Taro.showToast({ title: error instanceof Error ? error.message : '点赞未完成，请再试一次', icon: 'none' })
    } finally {
      actionLock.current = false
      if (alive.current) setBusy(false)
    }
  }
  const random = async () => {
    if (actionLock.current) return
    actionLock.current = true
    setBusy(true)
    const seq = ++sequence.current
    try {
      const next = await getRandomVoices(voter.current)
      if (!alive.current || seq !== sequence.current) return
      const unseen = next.filter(row => !wall.rows.some(seen => seen.quoteId === row.quoteId))
      const choice = unseen[0] ?? next.find(row => row.quoteId !== wall.id) ?? next[0]
      cityRef.current = null
      setCity(null)
      const rows = mergeVoices(wall.rows, next)
      target.current = choice?.quoteId ?? wall.id
      setWall({ status: 'ready', rows, id: target.current })
      if (!choice) void Taro.showToast({ title: '暂时没有更多声音', icon: 'none' })
    } catch {
      if (alive.current && seq === sequence.current) void Taro.showToast({ title: '暂时没连上，原来的句子还在', icon: 'none' })
    } finally { actionLock.current = false; if (alive.current) setBusy(false) }
  }
  return { wall, current, cities, citiesLoading, citiesError, retryCities, city, busy, step, toggleLike, random, chooseCity: (value: string | null) => void load(value, null), retry: () => void load(cityRef.current, target.current) }
}
