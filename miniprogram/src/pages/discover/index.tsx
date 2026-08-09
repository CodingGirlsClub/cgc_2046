import { useCallback, useState } from 'react'
import { Button, Input, ScrollView, Text, View } from '@tarojs/components'
import Taro, { useDidShow } from '@tarojs/taro'
import { api } from '@/api'
import { AppTabBar } from '@/components/AppTabBar'
import { PageState } from '@/components/PageState'
import type { CatalogItem } from '@/domain/models'
import styles from './index.module.css'

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

  const load = useCallback(async () => {
    setLoading(true)
    setError('')
    try {
      const [catalog, session] = await Promise.all([api.getCatalog(), api.getSession()])
      setItems(catalog)
      setIsVisitor(!session.user)
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : '暂时无法加载公开内容')
    } finally {
      setLoading(false)
    }
  }, [])

  useDidShow(() => { void load() })

  const normalized = keyword.trim().toLowerCase()
  const filtered = items.filter((item) => !normalized || [
    item.title,
    item.workspaceName,
    ...item.schemaFields.map(({ value }) => value)
  ].some((value) => value.toLowerCase().includes(normalized)))
  const events = filtered.filter(({ kind }) => kind === 'event')
  const courses = filtered.filter(({ kind }) => kind === 'course')
  const clubs = Array.from(new Map(filtered.map((item) => [item.workspaceId, item.workspaceName])).entries())

  const openDetail = ({ id, kind }: CatalogItem) => {
    Taro.navigateTo({ url: `/pages/event-detail/index?id=${id}&kind=${kind}` })
  }

  return (
    <View className={styles.page}>
      <ScrollView className={styles.scroll} scrollY>
        <View className={styles.hero}>
          <Text className={styles.eyebrow}>CODING GIRLS CLUB</Text>
          <Text className={styles.title} data-testid='page-title'>发现</Text>
          <Text className={styles.subtitle}>找到下一场活动，认识一起成长的人。</Text>
          <View className={styles.searchBox}>
            <Text className={styles.searchIcon}>⌕</Text>
            <Input
              className={styles.searchInput}
              placeholder='搜索活动、课程、地点'
              value={keyword}
              onInput={(event) => setKeyword(event.detail.value)}
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
          <PageState kind='error' message={error} onRetry={load} />
        ) : filtered.length === 0 ? (
          <PageState kind='empty' message={keyword ? '换个关键词试试' : '还没有公开活动或课程'} />
        ) : (
          <View className={styles.content}>
            <View className={styles.section}>
              <View className={styles.sectionHeader}>
                <Text className={styles.sectionTitle}>推荐 Club</Text>
                <Text className={styles.sectionMeta}>{clubs.length} 个公开社区</Text>
              </View>
              <ScrollView scrollX className={styles.clubRail}>
                <View className={styles.clubRow}>
                  {clubs.map(([id, name], index) => (
                    <View key={id} className={styles.clubCard}>
                      <Text className={styles.clubIndex}>0{index + 1}</Text>
                      <Text className={styles.clubName}>{name}</Text>
                      <Text className={styles.clubCaption}>公开工作台</Text>
                    </View>
                  ))}
                </View>
              </ScrollView>
            </View>

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
                  <Text className={styles.cardMeta}>{item.workspaceName} · {item.confirmedCount}/{item.capacity ?? '∞'} 人</Text>
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
                    <Text className={styles.cardMeta}>{item.workspaceName} · {policyText[item.enrollmentPolicy]}</Text>
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
