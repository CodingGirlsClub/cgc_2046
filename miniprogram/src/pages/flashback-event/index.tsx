import { useCallback, useRef, useState } from 'react'
import { Button, ScrollView, Text, View } from '@tarojs/components'
import Taro, { useDidShow, useRouter } from '@tarojs/taro'
import { api } from '@/api'
import { PageState } from '@/components/PageState'
import { eventFogLine, eventStats } from '@/domain/flashback-journey'
import { futureEventCards } from '@/domain/flashback'
import { STORAGE_KEYS } from '@/state/storage'
import { setFlashbackEntry } from '@/state/flashbackEntry'
import type { FlashbackFutureFrame } from '@/domain/models'
import type {
  FlashbackCapsuleArchive,
  FlashbackClaimResult,
  FlashbackPublicStats,
  FlashbackRosterEntry
} from '@/domain/models'
import { FlashbackNotBoundError, FlashbackTokenInvalidError } from '@/domain/models'
import styles from './index.module.css'


type Mode =
  | { kind: 'loading' }
  | { kind: 'error'; message: string }
  | { kind: 'member'; archive: FlashbackCapsuleArchive }
  /** 路人态（R32）：只有统计行（缺数不显示），无任何名册内容 */
  | { kind: 'viewer'; stats: FlashbackPublicStats | null; guide: 'login' | 'recover' | null }

/** 回长廊（现为 tabBar 页面）：switchTab 是 Tab 页唯一合法入口。
 *  「看看未来」的 future 语义走一次性 intent（switchTab 不接受 query）。 */
function enterCorridor(): void {
  void Taro.switchTab({ url: '/pages/flashback-corridor/index' })
}

/**
 * 场次页（E 的 event 步 / R12）：长廊点某一格 → 这一场——统计行（报名/走进
 * 教室/已回来，缺数不显示不编造 0）+「这一场的人」3 列拍立得网格
 * （已寄出 = 显影卡带名字 / 未回来 = 雾卡「王** · 城市 · 职业 · 答案还在等她」）
 * + 找回 CTA（三级视角②：没回来的人从这里认领自己那张）。
 *
 * 名册仅当年实际参与者（后端已滤 not_selected，R12）；路人只有统计层（R32）。
 */
export default function FlashbackEventPage() {
  const router = useRouter()
  const eventKey = typeof router.params.key === 'string' ? router.params.key : ''
  const [mode, setMode] = useState<Mode>({ kind: 'loading' })
  // U6 回环数据:capsule 邻近未来场次(「下一场」出口)
  const [futureFrames, setFutureFrames] = useState<FlashbackFutureFrame[]>([])
  // U6 看别人的卡:点已寄出名册卡 → 覆盖层迎面翻开(雾面版当年+她的今天只读)
  const [viewPerson, setViewPerson] = useState<FlashbackRosterEntry | null>(null)
  const [viewOpen, setViewOpen] = useState(false)
  const viewOpenedAt = useRef(0)

  const loadStats = useCallback(async (): Promise<FlashbackPublicStats | null> => {
    try {
      return await api.getFlashbackPublicStats()
    } catch {
      return null
    }
  }, [])

  const load = useCallback(async () => {
    const token = Taro.getStorageSync<string>(STORAGE_KEYS.flashbackToken) || null
    try {
      const capsule = await api.getFlashbackCapsule(null, token)
      const archive = capsule.archives.find((item) => item.key === eventKey)
      if (archive) {
        setMode({ kind: 'member', archive })
        setFutureFrames(capsule.futureEvents)
        return
      }
      setMode({ kind: 'viewer', stats: await loadStats(), guide: null })
    } catch (error) {
      if (error instanceof FlashbackTokenInvalidError) {
        Taro.removeStorageSync(STORAGE_KEYS.flashbackToken)
        void load()
        return
      }
      if (error instanceof FlashbackNotBoundError) {
        let claimed: FlashbackClaimResult | null = null
        try {
          claimed = await api.flashbackClaim(null)
        } catch {
          claimed = null
        }
        if (claimed?.bound) {
          // 认领成功即重拉；服务端仍报未绑定（数据不一致）时落找回引导，
          // 绝不再递归认领（防死循环）
          const capsule = await api.getFlashbackCapsule(null, null).catch(() => null)
          const archive = capsule?.archives.find((item) => item.key === eventKey)
          setMode(
            archive
              ? { kind: 'member', archive }
              : { kind: 'viewer', stats: await loadStats(), guide: 'recover' }
          )
          return
        }
        setMode({ kind: 'viewer', stats: await loadStats(), guide: 'login' })
        return
      }
      setMode({ kind: 'error', message: error instanceof Error ? error.message : '加载失败' })
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps -- eventKey 是路由参数，进页即定
  }, [eventKey, loadStats])

  useDidShow(() => {
    if (eventKey) void load()
  })

  const goLogin = () => {
    void Taro.navigateTo({
      url: `/pages/login/index?returnUrl=${encodeURIComponent(`/pages/flashback-event/index?key=${encodeURIComponent(eventKey)}`)}`
    })
  }

  const back = () => {
    // 长廊是唯一上游（深链直达时栈可能只有本页）——栈底退长廊；
    // 长廊现为 tabBar 页面，栈空时只能 switchTab（redirectTo 跳 Tab 页会失败）
    if (Taro.getCurrentPages().length > 1) void Taro.navigateBack()
    else enterCorridor()
  }

  if (mode.kind === 'loading') {
    return <PageState kind="loading" title="正在显影…" />
  }

  if (mode.kind === 'error') {
    return <PageState kind="error" message={mode.message} onRetry={() => void load()} />
  }

  const viewerStats =
    mode.kind === 'viewer' ? mode.stats?.archives.find((item) => item.key === eventKey) ?? null : null
  const when =
    mode.kind === 'member'
      ? mode.archive.occurredOn?.slice(0, 10).replace(/-/g, '.') ?? mode.archive.key
      : viewerStats?.occurredOn?.slice(0, 10).replace(/-/g, '.') ?? eventKey
  const name = mode.kind === 'member' ? mode.archive.name ?? '' : viewerStats?.name ?? ''
  const stats = mode.kind === 'member' ? eventStats(mode.archive) : null

  return (
    <View className={styles.page}>
      <ScrollView scrollY className={styles.board} style={{ height: '100vh' }}>
        <Text className={styles.back} onClick={back}>
          ‹ 时间长廊
        </Text>
        <View className={styles.header}>
          <Text className={styles.title}>
            {when}
            {name ? ` · ${name}` : ''}
          </Text>
          {/* 统计行（缺数不显示——导入未带该列就不编造 0；教练数本场无数据同理） */}
          <View className={styles.statsRow}>
            {stats?.applied ? <Text className={styles.stat}>{stats.applied} 位报名</Text> : null}
            {stats?.attended ? <Text className={styles.stat}>{stats.attended} 位走进教室</Text> : null}
            {!stats && viewerStats?.attendedCount ? (
              <Text className={styles.stat}>{viewerStats.attendedCount} 位走进教室</Text>
            ) : null}
            {stats ? <Text className={`${styles.stat} ${styles.statReturned}`}>{stats.returned} 位已回来</Text> : null}
          </View>
        </View>

        {mode.kind === 'member' && (
          <View className={styles.section}>
            <Text className={styles.peopleHint}>这一场的人 · 显影的是寄出了的，雾着的是还没回来的</Text>
            <View className={styles.grid}>
              {mode.archive.roster.map((entry) => (
                <View key={entry.id} className={styles.rosterCellWrap} style={{ animationDelay: `${mode.archive.roster.indexOf(entry) * 0.12}s` }} onClick={() => {
                  if (!entry.sentToWallAt) {
                    Taro.showToast({ title: 'ta 还没回来——点击下方找回你的那一张', icon: 'none' })
                    return
                  }
                  setViewPerson(entry)
                  setViewOpen(false)
                  viewOpenedAt.current = Date.now()
                  setTimeout(() => setViewOpen(true), 260)
                }}>
                  <RosterCell entry={entry} />
                </View>
              ))}
            </View>
          </View>
        )}

        {mode.kind === 'viewer' && (
          <View className={styles.guideBlock}>
            <Text className={styles.guideText}>
              {mode.guide === 'login'
                ? '你也在这一场吗？登录后我们帮你找你的那一张。'
                : '我们还没找到你的档案——收到过我们的链接就从链接打开完成首程，或用网页端「闪念间」凭手机号找回。'}
            </Text>
            {mode.guide === 'login' && (
              <Button className={styles.cta} onClick={goLogin}>
                微信一键登录，找回你的那一张 →
              </Button>
            )}
          </View>
        )}

        {/* 三级视角②：没回来的人从这里认领自己那张（参与态里 = 回长廊） */}
        {mode.kind === 'member' && (
          <View className={styles.findBlock}>
            <Button className={styles.cta} onClick={enterCorridor}>
              你也在这一场？找回你的那一张 →
            </Button>
          </View>
        )}

        {/* U6/R10 场次页回环(修断裂 3):下一场/回到今天/看看未来 三出口 */}
        {mode.kind === 'member' && (
          <View className={styles.loopBlock}>
            {(() => {
              const cards = futureEventCards(futureFrames)
              const next = cards.find((card) => card.status === 'open')
              return (
                <>
                  {next && (
                    <Button className={styles.loopBtn} onClick={() => void Taro.navigateTo({ url: `/pages/event-detail/index?id=${next.id}&kind=event` })}>
                      下一场:{next.title} →
                    </Button>
                  )}
                  <Button className={styles.loopBtn} onClick={back}>
                    回到今天
                  </Button>
                  <Button
                    className={styles.loopBtn}
                    onClick={() => {
                      setFlashbackEntry('future')
                      enterCorridor()
                    }}
                  >
                    看看未来
                  </Button>
                </>
              )
            })()}
          </View>
        )}
      </ScrollView>

      {/* U6 看别人的卡:封面(她的名字)→0.9s 翻开——当年(雾面句遮蔽)+她的今天(只读) */}
      {viewPerson && (
        <View
          className={styles.layerMask}
          onClick={() => {
            if (Date.now() - viewOpenedAt.current < 500) return
            setViewOpen(false)
            setTimeout(() => setViewPerson(null), 920)
          }}
        >
          <View className={styles.layerCard}>
            <View className={styles.viewFlip} style={{ transform: viewOpen ? 'rotateY(180deg)' : 'rotateY(0deg)' }}>
              <View className={styles.viewFace}>
                <View className={styles.viewCover}>
                  <Text className={styles.viewCoverName}>{viewPerson.fullName ?? viewPerson.surnameMasked}</Text>
                  <Text className={styles.viewCoverHint}>点按任意处合上</Text>
                </View>
              </View>
              <View className={styles.viewFaceBack}>
                <View className={styles.viewPolaroid}>
                  <View className={styles.viewPhoto}>
                    {viewPerson.answers.map((answer) => (
                      <View key={answer.questionKey}>
                        <Text className={styles.viewSegments}>
                          {answer.segments.map((seg, i) =>
                            seg.fog ? (
                              <Text key={i} className={styles.viewFog}>{seg.text}</Text>
                            ) : (
                              <Text key={i}>{seg.text}</Text>
                            ),
                          )}
                        </Text>
                      </View>
                    ))}
                    <View style={{ marginTop: 12 }}>
                      {viewPerson.today?.nowStatus ? (
                        <Text className={styles.viewToday}>现在在做什么:{viewPerson.today.nowStatus}</Text>
                      ) : null}
                      {viewPerson.today?.want ? (
                        <Text className={styles.viewToday}>想做的事:{viewPerson.today.want}</Text>
                      ) : null}
                    </View>
                  </View>
                  <Text className={styles.viewFoot}>她雾住的句子,只有她自己能看到 · 点任意处合上</Text>
                </View>
              </View>
            </View>
          </View>
        </View>
      )}
    </View>
  )
}

/** 网格格子：已寄出 = 显影卡带名字；未回来 = 雾卡（姓氏隐名 + 结构化小字，R12） */
function RosterCell({ entry }: { entry: FlashbackRosterEntry }) {
  return (
    <View className={styles.cell}>
      {entry.sentToWallAt ? (
        <View className={styles.cardLit}>
          <View className={styles.cardWindow}>
            <Text className={styles.cardName}>{entry.fullName ?? entry.surnameMasked}</Text>
          </View>
          <Text className={styles.cardFoot}>已寄出</Text>
        </View>
      ) : (
        <View className={styles.cardFog}>
          <View className={styles.cardWindowFog}>
            <Text className={styles.cardNameFog}>{entry.surnameMasked}</Text>
          </View>
          <Text className={styles.cardFootFog}>{eventFogLine(entry)}</Text>
        </View>
      )}
    </View>
  )
}
