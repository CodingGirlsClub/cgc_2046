// 订阅触点纯逻辑测试（#635）。
//
// 页面只留渲染与调起，判据/文案/时机全在 domain/subscription.ts（AGENTS.md：
// 小程序无页面渲染测试，逻辑必须下沉 domain 用 node --test 钉住）。
// 运行为 `node --experimental-strip-types --test`。

import assert from 'node:assert/strict'
import { describe, test } from 'node:test'

import type { SubscriptionScenario } from '../src/domain/models.ts'
import {
  ALL_SCENARIOS,
  MAX_TMPL_IDS_PER_REQUEST,
  acceptedScenarios,
  configuredScenarios,
  courseCardTouchpoint,
  enrollmentCardTouchpoint,
  enrollmentResultTouchpoint,
  eventCardTouchpoint,
  moderatorTouchpoint,
  paymentResultTouchpoint,
  preSubmitTouchpoint,
  refundCardTouchpoint,
  submitAfterConsent,
  subscriptionTransport,
  volunteerApplyTouchpoint,
  volunteerFollowUpTouchpoint,
  workspaceOpsTouchpoint,
  workspaceTouchpoint
} from '../src/domain/subscription.ts'

/** 全量触点的「正常态」取样（M0–M8）；payment_pending 与终态另有专门断言。 */
const allTouchpoints = () => [
  preSubmitTouchpoint('event'),
  preSubmitTouchpoint('course'),
  enrollmentResultTouchpoint('pending'),
  enrollmentResultTouchpoint('confirmed'),
  enrollmentCardTouchpoint('event'),
  enrollmentCardTouchpoint('course'),
  workspaceTouchpoint(),
  moderatorTouchpoint(),
  paymentResultTouchpoint(false),
  paymentResultTouchpoint(true),
  refundCardTouchpoint(),
  workspaceOpsTouchpoint(),
  volunteerApplyTouchpoint(),
  volunteerFollowUpTouchpoint()
]

/**
 * 确实没有触点的场景（显式缺口表，#664 审计）——后端镜像清单 =
 * `notification_worker_test.exs` 的 @scenario_gaps，逐键「谁收 / 为什么没入口 /
 * 挂哪」见那里的注释。#683 已把 6 键全部补齐触点，本表清空但**结构保留**：
 * 未来新增无入口场景必须在此登记（否则下方 uncovered 断言红），登记数写死 0
 * ——改本表/本数 = 有意识的决定。
 *
 * 纪律与后端同款：改这份列表 = 有意识承认一个缺口；补了触点必须同步删行
 * （下面「每个场景至少一个触点」守卫会红）。两个列表各自自洽：某一侧补了入口
 * 而没删行，那一侧必红。
 */
const UNCOVERED_SCENARIOS: SubscriptionScenario[] = []

describe('场景键集', () => {
  test('恰好 24 个场景，无重复', () => {
    assert.equal(ALL_SCENARIOS.length, 24)
    assert.equal(new Set(ALL_SCENARIOS).size, 24)
  })

  test('每个场景至少一个触点（缺口键走显式表，改表 = 有意识的决定）', () => {
    const covered = new Set(allTouchpoints().flatMap((t) => t?.scenarios ?? []))
    const gaps = new Set<SubscriptionScenario>(UNCOVERED_SCENARIOS)

    // 缺口数先钉死（#683 后为 0）：防「新场景被随手塞进缺口表」蒙混过关
    assert.equal(gaps.size, 0, `缺口数变了：${[...gaps].sort().join(', ')}`)

    // 缺口表不得腐烂：缺口键与场景表互补——一旦某键进入 ALL_SCENARIOS（= 补入口
    // 的第一步），必须同步从本表移除，否则这里红。
    const promoted = [...gaps].filter((scenario) => ALL_SCENARIOS.includes(scenario)).sort()
    assert.deepEqual(
      promoted,
      [],
      `这些键已进入 ALL_SCENARIOS，必须从 UNCOVERED_SCENARIOS 移除：${promoted.join(', ')}`
    )

    // 已补触点的键必须移出缺口表
    const stale = [...gaps].filter((scenario) => covered.has(scenario)).sort()
    assert.deepEqual(stale, [], `这些键已有触点，必须从 UNCOVERED_SCENARIOS 移除：${stale.join(', ')}`)

    // 本守卫的失败形态：新场景没有任何触点 → 用户永远拿不到该模板的授权
    const uncovered = ALL_SCENARIOS.filter(
      (scenario) => !covered.has(scenario) && !gaps.has(scenario)
    )
    assert.deepEqual(uncovered, [], `这些场景没有任何触点覆盖：${uncovered.join(', ')}`)
  })

  test('报名成功的课程腿（#664：课程也收 enrollment_completed，但没有核销码）', () => {
    // 课程腿单独钉住：course 报名同样会收到 enrollment_completed（后端无 kind 分支），
    // 而课程没有核销码——只把场景挂在活动触点上会漏掉课程报名。
    assert.ok(
      preSubmitTouchpoint('course').scenarios.includes('enrollment_completed'),
      '课程报名必须能订阅 enrollment_completed'
    )
    assert.ok(
      !preSubmitTouchpoint('course').scenarios.includes('enrollment_check_in_code'),
      '课程报名收不到核销码通知，不应请求其授权'
    )
  })
})

describe('M6/M7/M8（#683 新触点）', () => {
  test('M6 支付页双态：同一场景集 [payment_succeeded, event_reminder]，label 按态分派', () => {
    const pending = paymentResultTouchpoint(false)
    const paid = paymentResultTouchpoint(true)

    // 场景集双态一致（同函数分派 label，场景不许漂移）；恰 2 个（≤3 上限）
    assert.deepEqual(pending.scenarios, ['payment_succeeded', 'event_reminder'])
    assert.deepEqual(paid.scenarios, pending.scenarios)

    // pending 态文案聚焦「支付结果」（引导付款前授权），paid 态并入活动提醒
    assert.equal(pending.label, '订阅支付结果通知')
    assert.equal(paid.label, '订阅支付与活动通知')
  })

  test('M7 付费卡：退款三键恰满 3（资金类付款人腿一次问齐）', () => {
    const touchpoint = refundCardTouchpoint()
    assert.deepEqual(touchpoint.scenarios, ['refund_succeeded', 'refund_failed', 'payment_expired'])
    // 文案必须覆盖三键语义（裁决收紧 1）：label 提「退款与订单变动」，不只写「退款到账」
    assert.match(touchpoint.label, /退款与订单变动/)
  })

  test('M8 工作台第二按钮：管理者两键，与 M4 互不重叠（同页两手势各 ≤3）', () => {
    const ops = workspaceOpsTouchpoint()
    assert.deepEqual(ops.scenarios, ['enrollment_submitted', 'payment_received'])

    const m4 = workspaceTouchpoint()
    const overlap = ops.scenarios.filter((scenario) => m4.scenarios.includes(scenario))
    assert.deepEqual(overlap, [], `M4/M8 场景重叠：${overlap.join(', ')}`)
  })
})

describe('触点不变式', () => {
  test('每个时刻的场景数在 1..3（微信 tmplIds 单次上限）', () => {
    assert.equal(MAX_TMPL_IDS_PER_REQUEST, 3)

    for (const touchpoint of allTouchpoints()) {
      assert.ok(touchpoint, '正常态触点不应为 null')
      assert.ok(
        touchpoint.scenarios.length >= 1 &&
          touchpoint.scenarios.length <= MAX_TMPL_IDS_PER_REQUEST,
        `${touchpoint.page} 场景数 ${touchpoint.scenarios.length} 越界`
      )
      assert.equal(
        new Set(touchpoint.scenarios).size,
        touchpoint.scenarios.length,
        `${touchpoint.page} 场景重复`
      )
    }
  })

  test('触点引用的场景都在 ALL_SCENARIOS 内，且文案齐备', () => {
    for (const touchpoint of allTouchpoints()) {
      for (const scenario of touchpoint!.scenarios) {
        assert.ok(ALL_SCENARIOS.includes(scenario), `${touchpoint!.page} 引用未知场景 ${scenario}`)
      }
      for (const field of ['page', 'trigger', 'label', 'acceptedCopy', 'deniedCopy'] as const) {
        assert.ok(touchpoint![field], `${touchpoint!.page} 缺 ${field}`)
      }
    }
  })

  test('拒绝文案不阻断再次订阅（按钮保留，无「不可再订阅」措辞）', () => {
    for (const touchpoint of allTouchpoints()) {
      assert.ok(
        !/不可|无法|已拒绝|禁止/.test(touchpoint!.deniedCopy),
        `${touchpoint!.page} 的拒绝文案暗示不可再订阅：${touchpoint!.deniedCopy}`
      )
      assert.match(touchpoint!.deniedCopy, /再/, `${touchpoint!.page} 的拒绝文案应提示可再试`)
    }
  })
})

describe('M1 报名结果页（按报名状态分派）', () => {
  test('pending → 审批结果 + 开班/未达阈值，恰 3 个', () => {
    const touchpoint = enrollmentResultTouchpoint('pending')!
    assert.deepEqual(touchpoint.scenarios, [
      'approval_result',
      'event_qualification_confirmed',
      'event_qualification_underfilled'
    ])
  })

  test('已通过（confirmed）→ 活动提醒 + 开班/未达阈值', () => {
    const touchpoint = enrollmentResultTouchpoint('confirmed')!
    assert.deepEqual(touchpoint.scenarios, [
      'event_reminder',
      'event_qualification_confirmed',
      'event_qualification_underfilled'
    ])
    assert.match(touchpoint.label, /开班/)
  })

  test('待付款（payment_pending）→ 无触点（保持既有 !paymentPending 口径，支付页再问）', () => {
    assert.equal(
      enrollmentResultTouchpoint('payment_pending'),
      null,
      'payment_pending 应在支付成功页（order-pay）问 event_reminder，而非此处'
    )
  })

  test('已终结（rejected/expired/cancelled）→ 无触点，不再打扰', () => {
    for (const status of ['rejected', 'expired', 'cancelled'] as const) {
      assert.equal(
        enrollmentResultTouchpoint(status),
        null,
        `${status} 不应请求授权（既有实现会错配 event_reminder）`
      )
    }
  })
})

describe('M2/M3 我的报名（按条目类型分派）', () => {
  test('活动卡 → 开始提醒 + 改期提醒', () => {
    assert.deepEqual(eventCardTouchpoint().scenarios, ['event_reminder', 'event_schedule_changed'])
    assert.deepEqual(enrollmentCardTouchpoint('event').scenarios, [
      'event_reminder',
      'event_schedule_changed'
    ])
  })

  test('课程卡 → 学习停滞（不再错配 event_reminder）', () => {
    assert.deepEqual(enrollmentCardTouchpoint('course').scenarios, ['learning_stagnation'])
    assert.ok(
      !enrollmentCardTouchpoint('course').scenarios.includes('event_reminder'),
      '课程报名收不到 event_reminder，不应请求其授权'
    )
  })
})

describe('M4/M5 管理面', () => {
  test('工作台 → 审批提醒 + speaker 接受 + speaker 完成（管理者三模板，恰 3）', () => {
    assert.deepEqual(workspaceTouchpoint().scenarios, [
      'approval_reminder',
      'speaker_accepted',
      'speaker_completed'
    ])
  })

  test('活动详情（主理人）→ 主理人指派', () => {
    assert.deepEqual(moderatorTouchpoint().scenarios, ['event_moderator_assigned'])
  })
})

describe('M0 报名提交前授权（#546/#664 顺序契约）', () => {
  test('活动触点请求报名成功 + 核销码，文案两条都覆盖，拒绝文案指向「我的报名」兜底', () => {
    const touchpoint = preSubmitTouchpoint('event')
    assert.deepEqual(touchpoint.scenarios, ['enrollment_completed', 'enrollment_check_in_code'])
    assert.match(touchpoint.label, /报名结果/)
    assert.match(touchpoint.label, /核销码/)
    assert.match(touchpoint.acceptedCopy, /报名结果/)
    assert.match(touchpoint.acceptedCopy, /核销码/)
    assert.match(touchpoint.deniedCopy, /我的报名/)
  })

  test('课程触点只请求报名成功（课程恒无核销码）', () => {
    const touchpoint = preSubmitTouchpoint('course')
    assert.deepEqual(touchpoint.scenarios, ['enrollment_completed'])
    assert.match(touchpoint.label, /报名/)
    assert.match(touchpoint.acceptedCopy, /报名结果/)
    assert.match(touchpoint.deniedCopy, /我的报名/)
  })

  test('顺序契约：request（授权弹窗）→ grant（后端 +1）→ submit（可能立刻 confirmed）', async () => {
    const calls: string[] = []

    const result = await submitAfterConsent(
      preSubmitTouchpoint('event'),
      {
        request: async (scenarios) => {
          calls.push(`request:${scenarios.join(',')}`)
          return ['enrollment_completed', 'enrollment_check_in_code']
        },
        grant: async (scenario) => {
          calls.push(`grant:${scenario}`)
        }
      },
      async () => {
        calls.push('submit')
        return 'enrollment-id'
      }
    )

    assert.equal(result, 'enrollment-id')
    // 顺序即契约：一次性订阅只能覆盖 grant 之后的发送；颠倒即首次报名必然
    // consent_exhausted（discarded）。两条通知同刻触发，故同一次弹窗一次问齐。
    assert.deepEqual(calls, [
      'request:enrollment_completed,enrollment_check_in_code',
      'grant:enrollment_completed',
      'grant:enrollment_check_in_code',
      'submit'
    ])
  })

  test('部分接受：只 grant 被接受的场景，再 submit', async () => {
    const calls: string[] = []
    await submitAfterConsent(
      preSubmitTouchpoint('event'),
      {
        request: async () => [],
        grant: async (scenario) => void calls.push(`grant:${scenario}`)
      },
      async () => {
        calls.push('submit')
        return 'ok'
      }
    )

    assert.deepEqual(calls, ['submit'])
  })

  test('请求抛错（模板未配置 / 平台拒绝）→ 报名照常提交', async () => {
    const calls: string[] = []
    const result = await submitAfterConsent(
      preSubmitTouchpoint('event'),
      {
        request: async () => {
          throw new Error('缺少微信订阅消息模板 ID')
        },
        grant: async () => {}
      },
      async () => {
        calls.push('submit')
        return 'ok'
      }
    )

    assert.equal(result, 'ok')
    assert.deepEqual(calls, ['submit'])
  })

  test('grant 抛错（后端模板未配 / 网络）→ 报名照常提交', async () => {
    const calls: string[] = []
    const result = await submitAfterConsent(
      preSubmitTouchpoint('event'),
      {
        request: async () => ['enrollment_completed', 'enrollment_check_in_code'],
        grant: async () => {
          throw new Error('Consent grant failed')
        }
      },
      async () => {
        calls.push('submit')
        return 'ok'
      }
    )

    assert.equal(result, 'ok')
    assert.deepEqual(calls, ['submit'])
  })

  test('课程报名：请求仅报名成功场景，再 submit', async () => {
    const calls: string[] = []
    const result = await submitAfterConsent(
      preSubmitTouchpoint('course'),
      {
        request: async (scenarios) => {
          calls.push(`request:${scenarios.join(',')}`)
          return ['enrollment_completed']
        },
        grant: async (scenario) => void calls.push(`grant:${scenario}`)
      },
      async () => {
        calls.push('submit')
        return 'ok'
      }
    )

    assert.equal(result, 'ok')
    assert.deepEqual(calls, [
      'request:enrollment_completed',
      'grant:enrollment_completed',
      'submit'
    ])
  })

  test('submit 抛错原样上抛（授权链路不吞报名错误）', async () => {
    await assert.rejects(
      submitAfterConsent(
        preSubmitTouchpoint('event'),
        { request: async () => [], grant: async () => {} },
        async () => {
          throw new Error('容量已满')
        }
      ),
      /容量已满/
    )
  })
})

describe('调起路径优先级（mock/xhs 必须先于缺配检查）', () => {
  test('E2E mock 走 passthrough —— 即使一个模板 ID 都没配也不该抛缺配', () => {
    // 这是真实回归点：mock 构建与 CI 都没有模板 ID，若把「缺配检查」排在
    // mock 短路之前，e2e 点订阅会抛「缺少模板 ID」而不是成功。
    assert.equal(subscriptionTransport(true, 'wechat'), 'passthrough')
    assert.equal(subscriptionTransport(true, 'tt'), 'passthrough')
  })

  test('小红书走 passthrough（服务通知由平台后台下发，无 tmplIds）', () => {
    assert.equal(subscriptionTransport(false, 'xhs'), 'passthrough')
    assert.equal(subscriptionTransport(true, 'xhs'), 'passthrough')
  })

  test('微信/抖音真机走 tmplIds（此时缺配才抛可读错误）', () => {
    assert.equal(subscriptionTransport(false, 'wechat'), 'tmplIds')
    assert.equal(subscriptionTransport(false, 'tt'), 'tmplIds')
  })
})

describe('请求期 fail-closed：configuredScenarios', () => {
  test('剔除未配置（空串）场景', () => {
    const table = { approval_result: 'id-a', event_reminder: '' }
    assert.deepEqual(configuredScenarios(['approval_result', 'event_reminder'], table), [
      'approval_result'
    ])
  })

  test('表中完全缺失的场景也剔除（不是 undefined 崩溃）', () => {
    assert.deepEqual(configuredScenarios(['speaker_accepted'], {}), [])
  })

  test('全未配置 → 空（调用方据此抛可读错误，而非递空 tmplIds 给微信）', () => {
    assert.deepEqual(configuredScenarios(ALL_SCENARIOS, {}), [])
  })

  test('部分配置 → 只保留已配置的，顺序不变', () => {
    const table = { event_reminder: 'id-e', event_schedule_changed: 'id-s' }
    assert.deepEqual(
      configuredScenarios(['event_reminder', 'event_schedule_changed', 'learning_stagnation'], table),
      ['event_reminder', 'event_schedule_changed']
    )
  })
})

describe('请求期 fail-closed：acceptedScenarios 下标对齐（防静默发错模板）', () => {
  test('仅 accept 计入；reject/ban 不计', () => {
    const requested = ['a_result', 'event_reminder'] as const
    const tmplIds = ['id-a', 'id-e']
    assert.deepEqual(
      acceptedScenarios([...requested], tmplIds, { 'id-a': 'accept', 'id-e': 'reject' }),
      ['a_result']
    )
    assert.deepEqual(
      acceptedScenarios([...requested], tmplIds, { 'id-a': 'ban', 'id-e': 'accept' }),
      ['event_reminder']
    )
    assert.deepEqual(acceptedScenarios([...requested], tmplIds, {}), [])
  })

  test('部分配置剔除后仍按同序平行数组对齐（不错配到别的模板）', () => {
    // 场景顺序：A, B, C；B 未配置被剔除 → requested/tmplIds 都只含 A、C
    const table = { a_result: 'id-a', schedule_changed: 'id-c' }
    const requested = configuredScenarios(
      ['a_result', 'event_reminder', 'schedule_changed'],
      table
    )
    const tmplIds = requested.map((scenario) => table[scenario])

    assert.deepEqual(requested, ['a_result', 'schedule_changed'])
    assert.deepEqual(tmplIds, ['id-a', 'id-c'])

    // 只有 C 被接受 → 必须恰好返回 C（若下标错位会错记到 A）
    assert.deepEqual(acceptedScenarios(requested, tmplIds, { 'id-a': 'reject', 'id-c': 'accept' }), [
      'schedule_changed'
    ])
  })
})

describe('课程卡触点文案指向学习提醒', () => {
  test('文案与场景一致（不是活动提醒）', () => {
    const touchpoint = courseCardTouchpoint()
    assert.match(touchpoint.label, /学习/)
    assert.match(touchpoint.acceptedCopy, /学习/)
  })
})
