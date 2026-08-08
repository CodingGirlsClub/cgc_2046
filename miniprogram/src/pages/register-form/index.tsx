import { useState } from 'react'
import { View, Text, Input, Textarea, Button } from '@tarojs/components'
import Taro, { useRouter } from '@tarojs/taro'
import styles from './index.module.css'

export default function RegisterFormPage() {
  const router = useRouter()
  const eventId = router.params.id ?? 'unknown'

  const [name, setName] = useState('')
  const [phone, setPhone] = useState('')
  const [note, setNote] = useState('')

  const submit = () => {
    if (!name.trim() || !phone.trim()) {
      Taro.showToast({ title: '请填写姓名和手机号', icon: 'none' })
      return
    }
    // spike 阶段不落库：仅演示交互链路
    console.log('mock submit registration', { eventId, name, phone, note })
    Taro.showToast({ title: '已提交（mock）', icon: 'success' })
    setTimeout(() => Taro.navigateBack(), 600)
  }

  return (
    <View className={styles.page}>
      <View className={styles.block}>
        <Text className={styles.blockTitle}>报名信息</Text>

        <View className={styles.field}>
          <Text className={styles.label}>姓名</Text>
          <Input
            className={styles.input}
            placeholder='请输入姓名'
            value={name}
            onInput={(e) => setName(e.detail.value)}
          />
        </View>

        <View className={styles.field}>
          <Text className={styles.label}>手机号</Text>
          <Input
            className={styles.input}
            type='number'
            maxlength={11}
            placeholder='用于审批结果联系'
            value={phone}
            onInput={(e) => setPhone(e.detail.value)}
          />
        </View>

        <View className={styles.field}>
          <Text className={styles.label}>备注</Text>
          <Textarea
            className={styles.textarea}
            placeholder='想对组织者说的话（选填）'
            value={note}
            onInput={(e) => setNote(e.detail.value)}
          />
        </View>
      </View>

      <Button className={styles.primaryButton} onClick={submit}>
        提交报名
      </Button>

      <Text className={styles.hint}>提交后需等待组织者审批，结果将通过订阅消息通知你。</Text>
    </View>
  )
}
