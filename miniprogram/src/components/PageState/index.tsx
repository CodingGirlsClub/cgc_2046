import { Button, Text, View } from '@tarojs/components'
import styles from './index.module.css'

interface Props {
  kind: 'loading' | 'error' | 'empty'
  /** 覆盖默认标题（loading/error/empty 三态默认：正在加载/加载失败/暂无内容） */
  title?: string
  message?: string
  onRetry?: () => void
  /** 非重试类动作按钮（如空态「去登录」）；与 onRetry 互不冲突 */
  action?: { label: string; onClick: () => void }
  testId?: string
}

export function PageState({ kind, title, message, onRetry, action, testId }: Props) {
  const defaultTitle = kind === 'loading' ? '正在加载' : kind === 'error' ? '加载失败' : '暂无内容'
  return (
    <View className={styles.state} data-testid={testId}>
      <Text className={styles.icon}>{kind === 'error' ? '!' : kind === 'empty' ? '○' : '···'}</Text>
      <Text className={styles.title}>{title ?? defaultTitle}</Text>
      {message && <Text className={styles.message}>{message}</Text>}
      {kind === 'error' && onRetry && (
        <Button className={styles.retry} size='mini' onClick={onRetry}>重新加载</Button>
      )}
      {action && (
        <Button className={styles.retry} size='mini' onClick={action.onClick}>{action.label}</Button>
      )}
    </View>
  )
}
