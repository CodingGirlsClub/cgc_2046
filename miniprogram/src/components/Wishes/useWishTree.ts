import { useCallback, useEffect, useReducer, useRef, useState } from 'react'
import Taro, { useDidHide, useDidShow } from '@tarojs/taro'
import { api } from '@/api'
import { getWishTree, getPublicWish, getWishCities } from '@/api/wish-tree'
import { ensureWishVoterKey } from '@/domain/flashback'
import { initialTree, treeReducer } from '@/domain/wish-tree'
import type { VoiceCity } from '@/domain/flashback-voices'

const PAGE_SIZE = 24
export function useWishTree(initialId: string | null, initialCity: string | null) {
  const [tree, dispatch] = useReducer(treeReducer, undefined, initialTree)
  const [city, setCity] = useState(initialCity)
  const [echoesOnly, setEchoesOnly] = useState(false)
  const [cities, setCities] = useState<VoiceCity[]>([])
  const [citiesLoading, setCitiesLoading] = useState(true)
  const [citiesError, setCitiesError] = useState(false)
  const [expecting, setExpecting] = useState(false)
  const voter = useRef(ensureWishVoterKey())
  const generation = useRef(0)
  const cityGeneration = useRef(0)
  const active = useRef(true)
  const lock = useRef(false)
  const filters = useRef({ city: initialCity, withEchoes: false, seed: `${Date.now()}` })
  const target = useRef(initialId)
  const state = useRef(tree)
  state.current = tree

  const load = useCallback(async (append = false, next = false) => {
    const seq = ++generation.current
    const previous = state.current
    const offset = append ? previous.offset : 0
    const input = { ...filters.current }
    const wishId = append ? null : target.current
    dispatch({ type: 'load', generation: seq, append })
    try {
      const direct = wishId ? await getPublicWish(wishId, voter.current) : undefined
      if (!active.current || seq !== generation.current) return
      if (direct === null) { dispatch({ type: 'gone', generation: seq }); return }
      const rows = await getWishTree({ ...input, offset, limit: PAGE_SIZE, voterKey: voter.current })
      if (!active.current || seq !== generation.current) return
      const matches = direct && (!input.city || !direct.city || direct.city === input.city) && (!input.withEchoes || direct.echoCount > 0)
      const merged = matches ? [direct, ...rows] : rows
      const selectedId = next ? rows.find(row => !previous.rows.some(old => old.id === row.id))?.id ?? previous.id : append ? previous.id : matches ? direct.id : null
      dispatch({ type: 'ready', generation: seq, rows: merged, selectedId, offset: offset + rows.length, more: rows.length === PAGE_SIZE })
      target.current = selectedId ?? merged[0]?.id ?? null
    } catch (reason) {
      if (active.current && seq === generation.current) dispatch({ type: 'error', generation: seq, error: reason instanceof Error ? reason.message : '愿望暂时未能加载，请重试。' })
    }
  }, [])
  const retryCities = useCallback(() => {
    const seq = ++cityGeneration.current
    setCitiesLoading(true); setCitiesError(false)
    void getWishCities().then(rows => { if (active.current && seq === cityGeneration.current) setCities(rows) })
      .catch(() => { if (active.current && seq === cityGeneration.current) setCitiesError(true) })
      .finally(() => { if (active.current && seq === cityGeneration.current) setCitiesLoading(false) })
  }, [])
  useEffect(() => () => { active.current = false; generation.current++; cityGeneration.current++ }, [])
  useDidHide(() => { active.current = false; generation.current++; cityGeneration.current++ })
  useDidShow(() => { active.current = true; setExpecting(false); retryCities(); void load() })

  const chooseCity = (value: string | null) => {
    filters.current.city = value; target.current = null; setCity(value); void load()
  }
  const chooseEchoes = (value: boolean) => {
    filters.current.withEchoes = value; target.current = null; setEchoesOnly(value); void load()
  }
  const shuffle = () => {
    filters.current.seed = `${Date.now()}-${Math.random()}`; target.current = null; void load()
  }
  const step = (delta: number) => {
    const current = state.current
    if (current.status !== 'ready' || current.appending || !current.rows.length) return
    const index = current.rows.findIndex(row => row.id === current.id)
    if (delta > 0 && index === current.rows.length - 1 && current.more) { void load(true, true); return }
    const id = current.rows[(index + delta + current.rows.length) % current.rows.length].id
    target.current = id; dispatch({ type: 'select', id })
  }
  const current = tree.status === 'ready' ? tree.rows.find(row => row.id === tree.id) ?? null : null
  const toggleExpect = async () => {
    if (!current || lock.current) return
    lock.current = true; setExpecting(true)
    const seq = generation.current
    try {
      const expected = !current.expectedByViewer
      const count = await api.flashbackExpectWish(current.id, expected, voter.current)
      if (active.current && seq === generation.current) dispatch({ type: 'expect', generation: seq, id: current.id, expected, count })
    } catch (reason) {
      if (active.current && seq === generation.current) void Taro.showToast({ title: reason instanceof Error ? reason.message : '期待未保存，请重试。', icon: 'none' })
    } finally { lock.current = false; if (active.current) setExpecting(false) }
  }
  return { tree, current, city, echoesOnly, cities, citiesLoading, citiesError, retryCities, chooseCity, chooseEchoes, shuffle, step, expecting, toggleExpect, retry: () => void load(tree.rows.length > 0), reload: () => void load(), all: () => { filters.current.withEchoes = false; setEchoesOnly(false); chooseCity(null) } }
}
