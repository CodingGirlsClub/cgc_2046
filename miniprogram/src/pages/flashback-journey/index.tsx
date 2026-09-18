import { useCallback, useEffect, useRef, useState } from 'react'
import { Button, Text, Textarea, View } from '@tarojs/components'
import Taro, { useRouter, useShareAppMessage } from '@tarojs/taro'
import { api } from '@/api'
import { PageState } from '@/components/PageState'
import { STORAGE_KEYS } from '@/state/storage'
import {
  cardFaceAnswers,
  journeyIntroLead,
  journeyQuiz,
  quizResultText,
  revealStamp,
  SEND_OVERLAY
} from '@/domain/flashback-journey'
import type { FlashbackEnterResult, FlashbackTokenInvalidCode } from '@/domain/models'
import styles from './index.module.css'


type Phase =
  | { kind: 'boot' }
  | { kind: 'invalid'; code: FlashbackTokenInvalidCode }
  | { kind: 'error'; message: string }
  | { kind: 'intro' }
  | { kind: 'quiz' }
  | { kind: 'reveal' }

const INVALID_COPY: Record<FlashbackTokenInvalidCode, string> = {
  flashback_token_claimed: '这张卡已经被收进一个账号了。登录那个账号，或用网页端「闪念间」找回你的那一张。',
  flashback_token_revoked: '这张邀请函已经失效了。别担心——你的愿望不会消失，网页端「闪念间」凭手机号可以找回。',
  flashback_token_not_found: '没有找到这张邀请函。检查一下链接，或用网页端「闪念间」凭手机号找回。'
}

/** 卡面题干（questionKey → 中文；free 题白名单外的 key 原样显示兜底） */
function questionLabel(questionKey: string): string {
  if (questionKey === 'self_intro') return '请简单的介绍一下自己'
  if (questionKey === 'funny_thing') return '你做过的有意思的事情'
  return questionKey
}

/**
 * 首程旅程（mp 版原型 F；R1/R4-R11/R27/R29）：intro（呼吸快门）→ 场次确认
 * （R6：确认而非考察，「我不记得了」是出口）→ 显影卡翻面写今天 → 寄出浮层
 * （「微信一键收好」= 登录 + claim 绑定并作废链接；跳过 = 直接上墙）→ 长廊。
 *
 * token 从深链 query 读入后落 storage 会话持有（KTD2，不进分享 path）；
 * 登录回跳用 claim=1 标记续跑认领，token 不进 returnUrl。
 */
export default function FlashbackJourneyPage() {
  const router = useRouter()
  const [phase, setPhase] = useState<Phase>({ kind: 'boot' })
  const [entry, setEntry] = useState<FlashbackEnterResult | null>(null)
  const [choice, setChoice] = useState<string | null>(null)
  const [token, setToken] = useState('')
  // 两段式 3D 翻面（与我的卡同款：0.32s 转出 → 侧棱换面 → 0.32s 转回）
  const [flipped, setFlipped] = useState(false)
  const [flipPhase, setFlipPhase] = useState<'idle' | 'out' | 'in'>('idle')
  const flipTimers = useRef<ReturnType<typeof setTimeout>[]>([])
  useEffect(() => () => { flipTimers.current.forEach(clearTimeout) }, [])
  const [draftNow, setDraftNow] = useState('')
  const [draftWant, setDraftWant] = useState('')
  const [draftSay, setDraftSay] = useState('')
  const [sending, setSending] = useState(false)
  const [overlay, setOverlay] = useState(false)
  const [claiming, setClaiming] = useState(false)

  const quiz = entry ? journeyQuiz(entry.profile?.archive ?? null) : null

  const enter = useCallback(async (raw: string) => {
    try {
      const result = await api.flashbackEnter(raw)
      setEntry(result)
      // 回访（AE9 对齐 web journey）：已寄出 → 直达长廊不重走仪式
      if (result.progress?.today?.sentToWallAt) {
        void Taro.redirectTo({ url: '/pages/flashback-corridor/index' })
        return
      }
      const today = result.progress?.today
      setDraftNow(today?.nowStatus ?? '')
      setDraftWant(today?.want ?? '')
      setDraftSay(today?.say ?? '')
      setPhase({ kind: 'intro' })
    } catch (error) {
      const code = (error as { code?: string }).code
      if (
        code === 'flashback_token_not_found' ||
        code === 'flashback_token_claimed' ||
        code === 'flashback_token_revoked'
      ) {
        Taro.removeStorageSync(STORAGE_KEYS.flashbackToken)
        setPhase({ kind: 'invalid', code: code as FlashbackTokenInvalidCode })
        return
      }
      setPhase({ kind: 'error', message: error instanceof Error ? error.message : '进入失败，请重试' })
    }
  }, [])

  const claimAndStore = useCallback(async () => {
    if (claiming) return
    setClaiming(true)
    try {
      const result = await api.flashbackClaim(token)
      Taro.showToast({ title: result.bound ? '已收好这张卡' : '还没找到你的档案', icon: 'none' })
      void Taro.redirectTo({ url: '/pages/flashback-corridor/index' })
    } catch (error) {
      if ((error as { name?: string }).name === 'SessionExpiredError') {
        // returnUrl 不带 token（KTD2）：token 已在 storage，回跳后凭 claim=1 续跑
        void Taro.navigateTo({
          url: `/pages/login/index?returnUrl=${encodeURIComponent('/pages/flashback-journey/index?claim=1')}`
        })
      } else {
        Taro.showToast({ title: error instanceof Error ? error.message : '收好失败，请重试', icon: 'none' })
      }
    } finally {
      setClaiming(false)
    }
  }, [claiming, token])

  // 启动：深链 token（query 优先）→ storage 会话持有；claim=1 = 登录回跳续跑认领
  useEffect(() => {
    const raw = typeof router.params.token === 'string' ? router.params.token : ''
    const held = raw || Taro.getStorageSync<string>(STORAGE_KEYS.flashbackToken) || ''
    if (!held) {
      setPhase({ kind: 'invalid', code: 'flashback_token_not_found' })
      return
    }
    Taro.setStorageSync(STORAGE_KEYS.flashbackToken, held)
    setToken(held)
    void enter(held)
    // eslint-disable-next-line react-hooks/exhaustive-deps -- 进入流程一次性（回跳续跑见下方 claim effect）
  }, [])

  // 登录回跳续跑：claim=1 且 token 仍在 → 直达 intro 后自动续跑「微信一键收好」
  useEffect(() => {
    if (router.params.claim === '1' && phase.kind === 'intro' && token) void claimAndStore()
    // eslint-disable-next-line react-hooks/exhaustive-deps -- 只在进入/回到本页时触发一次
  }, [phase.kind])

  const flipCard = (next: boolean) => {
    if (flipPhase !== 'idle' || next === flipped) return
    setFlipPhase('out')
    flipTimers.current.push(
      setTimeout(() => {
        setFlipped(next)
        setFlipPhase('in')
        // 显影完成打点（四率之 revealed）：翻面即看过了正面（fire & forget）
        if (next && token) void api.flashbackMarkRevealed(token).catch(() => {})
        flipTimers.current.push(setTimeout(() => setFlipPhase('idle'), 340))
      }, 320)
    )
  }

  // 寄出（R11）：先写今天（R8）再上墙——浮层盖在显影场景上，不换页（原型 F）
  const send = async () => {
    if (sending) return
    setSending(true)
    try {
      await api.flashbackSubmitToday(
        { nowStatus: draftNow || null, want: draftWant || null, say: draftSay || null },
        token
      )
      await api.flashbackSendToWall(token)
      setOverlay(true)
    } catch (error) {
      Taro.showToast({ title: error instanceof Error ? error.message : '寄出失败，请重试', icon: 'none' })
    } finally {
      setSending(false)
    }
  }

  // R14 分享：卡片落旅程入口（朋友从这里进入闪念间）；不带本人 token（R32 边界）
  useShareAppMessage(() => ({ title: '闪念间 · 找回当年的自己', path: '/pages/flashback-journey/index' }))

  if (phase.kind === 'boot') {
    return <PageState kind="loading" title="正在打开…" />
  }

  if (phase.kind === 'invalid') {
    return (
      <View className={styles.page}>
        <View className={styles.invalidBlock}>
          <Text className={styles.invalidEyebrow}>IN A FLASH · 闪念间</Text>
          <Text className={styles.invalidText}>{INVALID_COPY[phase.code]}</Text>
          <Button
            className={styles.invalidAction}
            onClick={() => void Taro.redirectTo({ url: '/pages/flashback-corridor/index' })}
          >
            先去时间胶囊看看
          </Button>
        </View>
      </View>
    )
  }

  if (phase.kind === 'error') {
    return <PageState kind="error" message={phase.message} onRetry={() => void enter(token)} />
  }

  const profile = entry?.profile
  const faceAnswers = profile ? cardFaceAnswers(profile.answers) : []

  return (
    <View className={styles.page}>
      {phase.kind === 'intro' && profile && (
        <View className={styles.center}>
          <Text className={styles.brand}>IN A FLASH · 闪念间</Text>
          <Text className={styles.introLead}>{journeyIntroLead(profile.appliedAt)}</Text>
          <View className={styles.shutter} onClick={() => setPhase({ kind: 'quiz' })} aria-label="按下快门" />
          <Text className={styles.shutterHint}>按下快门，回到那天</Text>
        </View>
      )}

      {phase.kind === 'quiz' && quiz && (
        <View className={styles.pad}>
          <Text className={styles.quizQuestion}>{quiz.question}</Text>
          <View className={styles.quizOptions}>
            {quiz.options.map((option) => (
              <View
                key={option.id}
                className={styles.quizOption}
                onClick={() => {
                  setChoice(option.id)
                  setPhase({ kind: 'reveal' })
                }}
              >
                <Text className={styles.quizLabel}>{option.label}</Text>
                {option.hint ? <Text className={styles.quizHint}>{option.hint}</Text> : null}
              </View>
            ))}
          </View>
        </View>
      )}

      {phase.kind === 'reveal' && profile && quiz && (
        <View className={styles.center}>
          <Text className={styles.quizFeedback}>{quizResultText(choice, quiz)}</Text>
          <View className={styles.flipScene}>
            <View
              className={`${styles.cardFlip} ${flipPhase === 'out' ? styles.cardFlipOut : ''} ${flipPhase === 'in' ? styles.cardFlipIn : ''}`}
            >
              {!flipped && (
                <View className={styles.polaroid} onClick={() => flipCard(true)}>
                  <View className={styles.photo}>
                    {faceAnswers.map((answer) => (
                      <View key={answer.id} className={styles.answer}>
                        <Text className={styles.answerQ}>{questionLabel(answer.questionKey)}</Text>
                        <Text className={styles.answerA}>{answer.rawText}</Text>
                      </View>
                    ))}
                  </View>
                  <View className={styles.polaroidFoot}>
                    <Text className={styles.polaroidName}>{profile.fullName}</Text>
                    <Text className={styles.polaroidStamp}>{revealStamp(profile.appliedAt)}</Text>
                  </View>
                </View>
              )}
              {flipped && (
                <View className={styles.polaroid}>
                  <Text className={styles.backTitle}>今天的你 · 写完寄出</Text>
                  <Text className={styles.backLabel}>现在在做什么</Text>
                  <Textarea className={styles.textarea} value={draftNow} onInput={(event) => setDraftNow(event.detail.value)} maxlength={200} />
                  <Text className={styles.backLabel}>想做的事 / 想学的东西</Text>
                  <Textarea className={styles.textarea} value={draftWant} onInput={(event) => setDraftWant(event.detail.value)} maxlength={200} />
                  <Text className={styles.backLabel}>想对 CGC 说的话</Text>
                  <Textarea className={styles.textarea} value={draftSay} onInput={(event) => setDraftSay(event.detail.value)} maxlength={200} />
                  <View className={styles.polaroidFoot}>
                    <Text className={styles.backHint}>写完按下面寄出</Text>
                  </View>
                </View>
              )}
            </View>
          </View>
          {!flipped && <Text className={styles.revealHint}>点击照片翻面写字</Text>}
          <Button className={styles.cta} disabled={sending || !flipped} onClick={() => void send()}>
            {sending ? '正在寄出…' : '寄出，回到时间胶囊 →'}
          </Button>
        </View>
      )}

      {/* 寄出浮层（R27 注册引导 + R29 期望管理；文案与定稿逐字一致） */}
      {overlay && (
        <View className={styles.overlay}>
          <View className={styles.overlayCard}>
            <Text className={styles.overlayTitle}>{SEND_OVERLAY.title}</Text>
            <Text className={styles.overlayBody}>{SEND_OVERLAY.body}</Text>
            <Button className={styles.overlayPrimary} disabled={claiming} onClick={() => void claimAndStore()}>
              {claiming ? '正在收好…' : SEND_OVERLAY.primary}
            </Button>
            <Button
              className={styles.overlaySkip}
              onClick={() => void Taro.redirectTo({ url: '/pages/flashback-corridor/index' })}
            >
              {SEND_OVERLAY.skip}
            </Button>
            <View className={styles.overlayDivider} />
            <Text className={styles.overlayExpectation}>{SEND_OVERLAY.expectation}</Text>
          </View>
        </View>
      )}
    </View>
  )
}
