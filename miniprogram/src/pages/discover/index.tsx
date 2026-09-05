import { useCallback, useMemo, useRef, useState } from 'react'
import { Button, Image, Input, ScrollView, Text, View } from '@tarojs/components'
import Taro, { useDidHide, useDidShow } from '@tarojs/taro'
import { api } from '@/api'
import { AppTabBar } from '@/components/AppTabBar'
import { PageState } from '@/components/PageState'
import type { CatalogItem } from '@/domain/models'
import { enrollmentBadgeText } from '@/domain/format'
import { debounce } from '@/domain/debounce'
import styles from './index.module.css'
import flameLogo from '@/assets/brand/cgc-flame.png'

const policyText: Record<CatalogItem['enrollmentPolicy'], string> = {
  open: '开放报名',
  request: '需审批',
  invite_only: '仅邀请'
}

export default function DiscoverPage() {
  const [items, setItems] = useState<CatalogItem[]>([])
  const [keyword, setKeyword] = useState('')
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [isVisitor, setIsVisitor] = useState(true)

  const keywordRef = useRef('')
  const requestSeq = useRef(0)

  // #355 P2-10：搜索服务端化——keyword 进 getCatalog 的 title ilike filter，
  // 不再前端过滤（Catalog first:50 封顶时第 51 条永远搜不到的契约性缺陷）。
  // requestSeq 丢弃过期响应：旧请求晚于新请求返回时不覆盖列表。
  const load = useCallback(async (kw: string) => {
    const seq = ++requestSeq.current
    setLoading(true)
    setError('')
    try {
      const [catalog, session] = await Promise.all([api.getCatalog(kw), api.getSession()])
      if (seq !== requestSeq.current) return
      setItems(catalog)
      setIsVisitor(!session.user)
    } catch (reason) {
      if (seq !== requestSeq.current) return
      setError(reason instanceof Error ? reason.message : '暂时无法加载公开内容')
    } finally {
      if (seq === requestSeq.current) setLoading(false)
    }
  }, [])

  // 击键防抖 300ms，停顿后才发服务端搜索；页面隐藏时丢弃挂起的触发
  const debouncedSearch = useMemo(() => debounce((kw: string) => { void load(kw) }, 300), [load])

  useDidShow(() => { void load(keywordRef.current) })
  useDidHide(() => debouncedSearch.cancel())

  const events = items.filter(({ kind }) => kind === 'event')
  const courses = items.filter(({ kind }) => kind === 'course')

  const openDetail = ({ id, kind }: CatalogItem) => {
    Taro.navigateTo({ url: `/pages/event-detail/index?id=${id}&kind=${kind}` })
  }

  return (
    <View className={styles.page}>
      <ScrollView className={styles.scroll} scrollY>
        <View className={styles.hero}>
          <View className={styles.brandLockup}>
            <Image className={styles.brandMark} src={flameLogo} mode='aspectFit' />
            <Text className={styles.brandName}>程序媛汇 <Text className={styles.brandYear}>2046</Text></Text>
          </View>
          <Text className={styles.title} data-testid='page-title'>发现</Text>
          <Text className={styles.subtitle}>找到下一场活动，认识一起成长的人。</Text>
          <View className={styles.searchBox}>
            <Input
              className={styles.searchInput}
              placeholder='搜索活动、课程'
              value={keyword}
              onInput={(event) => {
                const value = event.detail.value
                setKeyword(value)
                keywordRef.current = value
                debouncedSearch(value)
              }}
            />
          </View>
        </View>

        {isVisitor && !loading && (
          <View className={styles.visitor} data-testid='visitor-state'>
            <View>
              <Text className={styles.visitorTitle}>先逛逛，登录后可报名</Text>
              <Text className={styles.visitorText}>手机号一键登录，不需要设置密码。</Text>
            </View>
            <Button className={styles.loginButton} size='mini' onClick={() => Taro.navigateTo({ url: '/pages/login/index' })}>
              去登录
            </Button>
          </View>
        )}

        {loading ? (
          <PageState kind='loading' />
        ) : error ? (
          <PageState kind='error' message={error} onRetry={() => void load(keywordRef.current)} />
        ) : items.length === 0 ? (
          <PageState kind='empty' message={keyword ? '换个关键词试试' : '还没有公开活动或课程'} />
        ) : (
          <View className={styles.content}>

            <View className={styles.section}>
              <View className={styles.sectionHeader}>
                <Text className={styles.sectionTitle}>即将开始的活动</Text>
                <Text className={styles.sectionMeta}>{events.length} 场</Text>
              </View>
              {events.map((item) => (
                <View
                  key={item.id}
                  className={styles.contentCard}
                  data-testid={`event-card-${item.id}`}
                  onClick={() => openDetail(item)}
                >
                  <View className={styles.cardTop}>
                    <Text className={styles.kind}>EVENT</Text>
                    <Text className={styles.policy}>{policyText[item.enrollmentPolicy]}</Text>
                  </View>
                  <Text className={styles.cardTitle}>{item.title}</Text>
                  <Text className={styles.cardMeta}>{enrollmentBadgeText[item.enrollmentBadge]}</Text>
                  <Text className={styles.arrow}>→</Text>
                </View>
              ))}
            </View>

            <View className={styles.section}>
              <View className={styles.sectionHeader}>
                <Text className={styles.sectionTitle}>推荐 Course</Text>
                <Text className={styles.sectionMeta}>{courses.length} 门</Text>
              </View>
              {courses.map((item) => (
                <View key={item.id} className={styles.courseCard} onClick={() => openDetail(item)}>
                  <View>
                    <Text className={styles.kind}>COURSE</Text>
                    <Text className={styles.cardTitle}>{item.title}</Text>
                    <Text className={styles.cardMeta}>{policyText[item.enrollmentPolicy]}</Text>
                  </View>
                  <Text className={styles.courseArrow}>›</Text>
                </View>
              ))}
            </View>
          </View>
        )}
      </ScrollView>
      <AppTabBar selected='discover' />
    </View>
  )
}
