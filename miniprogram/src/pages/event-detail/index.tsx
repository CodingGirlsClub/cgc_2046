import { useCallback, useEffect, useState } from 'react'
import { Button, ScrollView, Text, View } from '@tarojs/components'
import Taro, { useRouter } from '@tarojs/taro'
import { api } from '@/api'
import { PageState } from '@/components/PageState'
import type { CatalogItem, ContentKind } from '@/domain/models'
import { formatAmount } from '@/domain/payment'
import styles from './index.module.css'

const policyText: Record<CatalogItem['enrollmentPolicy'], string> = {
  open: '提交后立即确认',
  request: '提交后等待审批',
  invite_only: '需要有效批次码'
}

export default function EventDetailPage() {
  const router = useRouter()
  const id = router.params.id ?? ''
  const kind = (router.params.kind === 'course' ? 'course' : 'event') as ContentKind
  const [item, setItem] = useState<CatalogItem | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')

  const load = useCallback(async () => {
    setLoading(true)
    setError('')
    try {
      setItem(await api.getContent(kind, id))
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : '详情加载失败')
    } finally {
      setLoading(false)
    }
  }, [id, kind])

  useEffect(() => { void load() }, [load])

  const register = async () => {
    if (!item) return
    const target = `/pages/register-form/index?id=${item.id}&kind=${item.kind}`
    try {
      const session = await api.getSession()
      if (!session.user) {
        await Taro.navigateTo({ url: `/pages/login/index?returnUrl=${encodeURIComponent(target)}` })
        return
      }
      await Taro.navigateTo({ url: target })
    } catch (reason) {
      Taro.showToast({ title: reason instanceof Error ? reason.message : '暂时无法报名', icon: 'none' })
    }
  }

  if (loading) return <PageState kind='loading' />
  if (error) return <PageState kind='error' message={error} onRetry={load} />
  if (!item) return <PageState kind='empty' message='内容不存在' />

  return (
    <View className={styles.page}>
      <ScrollView scrollY className={styles.scroll}>
        <View className={styles.header}>
          <Text className={styles.kind}>{item.kind === 'event' ? 'EVENT' : 'COURSE'}</Text>
          <Text className={styles.title} data-testid='detail-title'>{item.title}</Text>
          <Text className={styles.club}>{item.workspaceName}</Text>
        </View>

        <View className={styles.metrics}>
          <View className={styles.metric}>
            <Text className={styles.metricValue}>{item.confirmedCount}</Text>
            <Text className={styles.metricLabel}>已确认</Text>
          </View>
          <View className={styles.metric}>
            <Text className={styles.metricValue}>{item.capacity ?? '∞'}</Text>
            <Text className={styles.metricLabel}>名额</Text>
          </View>
          <View className={styles.metric}>
            <Text className={styles.metricValue}>{item.enrollmentPolicy === 'request' ? '审批' : '即时'}</Text>
            <Text className={styles.metricLabel}>报名方式</Text>
          </View>
        </View>

        <View className={styles.block}>
          <Text className={styles.blockTitle}>活动信息</Text>
          {item.schemaFields.length === 0 ? (
            <PageState kind='empty' message='组织者还没有补充详细信息' />
          ) : item.schemaFields.map((field) => (
            <View key={field.key} className={styles.row} data-testid={`schema-field-${field.key}`}>
              <Text className={styles.label}>{field.label}</Text>
              <Text className={styles.value}>{field.value}</Text>
            </View>
          ))}
        </View>

        {item.pricingEnabled && (
          <View className={styles.block} data-testid='price-tiers'>
            <Text className={styles.blockTitle}>价格档位</Text>
            {item.priceTiers.length === 0 ? (
              <Text className={styles.value}>当前无可售档位，请联系组织者。</Text>
            ) : item.priceTiers.map((tier) => (
              <View key={tier.id} className={styles.row} data-testid={`price-tier-${tier.id}`}>
                <Text className={styles.label}>{tier.name}</Text>
                <Text className={styles.value}>¥{formatAmount(tier.amountCents)}</Text>
              </View>
            ))}
          </View>
        )}

        <View className={styles.policyBlock}>
          <Text className={styles.policyTitle}>报名说明</Text>
          <Text className={styles.policyText}>{policyText[item.enrollmentPolicy]}</Text>
          {item.pricingEnabled && (
            <Text className={styles.policyText}>收费活动：提交报名后请在限定时间内完成支付。</Text>
          )}
          {item.registrationDeadline && (
            <Text className={styles.deadline}>截止：{new Date(item.registrationDeadline).toLocaleString()}</Text>
          )}
        </View>
      </ScrollView>

      <View className={styles.footer}>
        <Button className={styles.primaryButton} data-testid='register-action' onClick={register}>
          立即报名
        </Button>
      </View>
    </View>
  )
}
