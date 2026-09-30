import { useEffect, useReducer, useRef, useState } from 'react'
import { Button, Image, Text, View } from '@tarojs/components'
import Taro, { useDidShow, useRouter } from '@tarojs/taro'
import { api } from '@/api'
import { getWebLoginRequest, confirmWebLogin } from '@/api/web-login'
import { webLoginEntry, WEB_LOGIN_PATH, canConfirmWebLogin, transitionWebLoginPage, webLoginPageView, type WebLoginRequest } from '@/domain/web-login'
import type { UserSummary } from '@/domain/models'
import { currentPlatform } from '@/platform'
import flameLogo from '@/assets/brand/cgc-flame.png'
import styles from './index.module.css'

export default function WebLoginPage() {
  const router = useRouter()
  const id = webLoginEntry(WEB_LOGIN_PATH, router.params, currentPlatform())
  const [request, setRequest] = useState<WebLoginRequest | null>(null)
  const [user, setUser] = useState<UserSummary | null>(null)
  const [busy, setBusy] = useState(false)
  const [pageState, dispatch] = useReducer(transitionWebLoginPage, 'active')
  const [error, setError] = useState('')
  const [now, setNow] = useState(Date.now)
  const generation = useRef(0)
  const view = webLoginPageView(request, pageState, now, error)
  useEffect(() => {
    const timer = setInterval(() => setNow(Date.now()), 1000)
    return () => { clearInterval(timer); generation.current++ }
  }, [])

  const refresh = async () => {
    const version = ++generation.current
    if (!id) { setError('登录链接无效，请从原网页重新打开。'); return }
    setBusy(true); setError('')
    try {
      const result = await getWebLoginRequest(id)
      if (version !== generation.current) return
      setRequest(result)
      if (canConfirmWebLogin(result, true, Date.now())) {
        const session = await api.getSession()
        if (version === generation.current) setUser(session.user)
      }
    } catch { if (version === generation.current) setError('暂时无法检查登录请求，请重试。') }
    finally { if (version === generation.current) setBusy(false) }
  }
  useDidShow(() => { if (view.refreshable) void refresh() })

  const login = async (switchAccount = false) => {
    if (!id || busy) return
    setBusy(true); setError('')
    try {
      if (switchAccount) { await api.signOut(); setUser(null) }
      const target = `/${WEB_LOGIN_PATH}?requestId=${id}`
      await Taro.navigateTo({ url: `/pages/login/index?returnUrl=${encodeURIComponent(target)}` })
    } catch { setError('暂时无法打开登录页，请重试。') }
    finally { setBusy(false) }
  }
  const confirm = async () => {
    if (!id || busy || !user || !webLoginPageView(request, pageState, Date.now()).active) return
    dispatch({ type: 'confirm_started' })
    setBusy(true); setError('')
    try {
      const result = await confirmWebLogin(id)
      setRequest(result)
      dispatch({ type: 'confirm_received', status: result.status })
      if (result.status !== 'APPROVED') setError('登录请求已失效，请从网页重新发起。')
    } catch { setError('确认结果暂时未知，请返回原网页查看，或重试检查。') }
    finally { setBusy(false) }
  }
  return (
    <View className={styles.page}>
      <Image className={styles.mark} src={flameLogo} mode='aspectFit' />
      <Text className={styles.brand}>程序媛汇 2046</Text>
      <Text className={styles.title}>{view.title}</Text>
      <Text className={styles.description}>{view.description}</Text>
      {view.active && user && <View className={styles.account}><Text className={styles.label}>当前账号</Text><Text className={styles.name}>{user.displayName || user.memberNumber || '程序媛汇用户'}</Text></View>}
      {error && <Text className={styles.error}>{error}</Text>}
      {view.active && (user ? <Button className={styles.primary} disabled={busy} loading={busy} onClick={() => void confirm()}>确认登录</Button> : <Button className={styles.primary} disabled={busy} loading={busy} onClick={() => void login()}>手机号快捷登录</Button>)}
      {view.active && user && <Button className={styles.secondary} disabled={busy} onClick={() => void login(true)}>切换账号</Button>}
      {error && view.refreshable && <Button className={styles.secondary} disabled={busy} onClick={() => void refresh()}>重试</Button>}
      {view.refreshable && <Button className={`${styles.secondary} ${styles.cancel}`} disabled={busy} onClick={() => { generation.current++; dispatch({ type: 'exit' }) }}>取消</Button>}
      <Text className={styles.footer}>仅授权本次网页登录，不改变账号数据。</Text>
    </View>
  )
}
