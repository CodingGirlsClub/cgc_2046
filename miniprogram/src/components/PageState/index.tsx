import { Button, Text, View } from '@tarojs/components'
import styles from './index.module.css'

interface Props {
  kind: 'loading' | 'error' | 'empty'
  message?: string
  onRetry?: () => void
  testId?: string
}

export function PageState({ kind, message, onRetry, testId }: Props) {
  const title = kind === 'loading' ? '正在加载' : kind === 'error' ? '加载失败' : '暂无内容'
  return (
    <View className={styles.state} data-testid={testId}>
      <Text className={styles.icon}>{kind === 'error' ? '!' : kind === 'empty' ? '○' : '···'}</Text>
      <Text className={styles.title}>{title}</Text>
      {message && <Text className={styles.message}>{message}</Text>}
      {kind === 'error' && onRetry && (
        <Button className={styles.retry} size='mini' onClick={onRetry}>重新加载</Button>
      )}
    </View>
  )
}
