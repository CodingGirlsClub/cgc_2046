import { useCallback, useEffect, useReducer, useRef } from 'react'
import Taro, { useDidHide } from '@tarojs/taro'
import { api } from '@/api'
import { FlashbackNotBoundError, FlashbackTokenInvalidError } from '@/domain/models'
import { initialRecovery, recoveryReducer } from '@/domain/flashback-recovery'
import { STORAGE_KEYS } from '@/state/storage'

export function useRecovery() {
  const [mode, dispatch] = useReducer(recoveryReducer, undefined, initialRecovery)
  const generation = useRef(0)
  const state = useRef(mode)
  state.current = mode
  const invalidate = () => dispatch({ type: 'start', generation: ++generation.current })
  useDidHide(invalidate)
  useEffect(() => () => { generation.current++ }, [])

  const load = useCallback(async (city: string | null = null) => {
    const seq = ++generation.current
    const current = () => seq === generation.current
    dispatch({ type: 'start', generation: seq })
    let token = Taro.getStorageSync<string>(STORAGE_KEYS.flashbackToken) || null
    const read = async () => {
      try { return await api.getFlashbackCapsule(city, token) }
      catch (reason) {
        if (!(reason instanceof FlashbackTokenInvalidError) || !token || !current()) throw reason
        Taro.removeStorageSync(STORAGE_KEYS.flashbackToken)
        token = null
        return api.getFlashbackCapsule(city, null)
      }
    }
    try {
      const capsule = await read()
      if (current()) dispatch({ type: 'member', generation: seq, capsule, token })
    } catch (reason) {
      if (!current()) return
      try {
        if (!(reason instanceof FlashbackNotBoundError)) throw reason
        const claim = await api.flashbackClaim(null)
        if (!current()) return
        if (!claim.bound) { dispatch({ type: 'unmatched', generation: seq }); return }
        // A successful claim still needs a readable capsule. Failure here is not
        // evidence that the account has no archive, and must remain retryable.
        const capsule = await api.getFlashbackCapsule(city, null)
        if (!current()) return
        dispatch({ type: 'member', generation: seq, capsule, token: null })
        void Taro.showToast({ title: '找到了，已为你收好', icon: 'none' })
      } catch (error) {
        if (!current()) return
        const expired = (error as { name?: string })?.name === 'SessionExpiredError'
        if (!expired) console.warn('Flashback archive lookup failed', { name: error instanceof Error ? error.name : 'UnknownError' })
        dispatch({ type: expired ? 'guest' : 'error', generation: seq })
      }
    }
  }, [])

  const reloadMember = async (city: string | null) => {
    const previous = state.current
    if (previous.kind !== 'member') return null
    const seq = generation.current
    const capsule = await api.getFlashbackCapsule(city, previous.token).catch(() => null)
    if (!capsule || seq !== generation.current) return null
    dispatch({ type: 'member', generation: seq, capsule, token: previous.token })
    return capsule
  }
  return { mode, load, reloadMember }
}
