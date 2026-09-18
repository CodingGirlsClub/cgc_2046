// 订阅场景键集一致性守卫（#635）。
//
// 单一 JSON blob 注入（config/index.ts 的 __WECHAT_TEMPLATE_IDS__）换掉了
// 「一场景一条 defineConstants」，代价是失去「少写一条 define 就 tsc 报错」的天然
// 保护——本文件把这份保护补回来，并且补得更宽：同时钉住**四处**名单。
//
// 与 #606 的关系：#606 的根因就是多处平行名单漂移（runtime.exs 17 键 vs
// deploy.yml 10 键 vs .env.example 另一套 10 键），后端侧由
// backend/test/cgc_2046/notifications/template_allowlist_test.exs 兜住；
// 本文件是小程序侧的同类守卫。
//
// 纯文件扫描，**不依赖任何真实模板 ID** ⇒ CI 与本地无 ID 环境同样全绿。

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join, relative } from 'node:path'

const root = join(dirname(fileURLToPath(import.meta.url)), '..')

const read = (relPath) => readFileSync(join(root, relPath), 'utf8')

/** 期望场景数：改这个数必须是有意识的决定（防「四处一起被删空」也能通过相等断言）。 */
const EXPECTED_SCENARIO_COUNT = 20

/** 去掉行注释：注释里出现的示例字面量不得计入名单（守卫只认真实条目）。 */
const stripLineComments = (source) => source.replace(/\/\/[^\n]*/g, '')

/** 从 `const NAME = [...] as const` 里取字符串字面量。 */
function constList(source, name, file) {
  const match = source.match(new RegExp(`const ${name} = \\[([\\s\\S]*?)\\] as const`))
  assert.ok(match, `${file} 里找不到 const ${name} = [...] as const`)
  return [...stripLineComments(match[1]).matchAll(/'([a-z0-9_]+)'/g)].map((m) => m[1])
}

/** 从 models.ts 的 `export type SubscriptionScenario = ...` 联合里取成员。 */
function scenarioUnion(source, file) {
  const start = source.indexOf('export type SubscriptionScenario =')
  assert.ok(start !== -1, `${file} 里找不到 SubscriptionScenario 联合声明`)
  // 联合声明是单一段落（空行即结束），可安全按空行截断
  const block = stripLineComments(source.slice(start).split(/\n\s*\n/)[0])
  return [...block.matchAll(/'([a-z0-9_]+)'/g)].map((m) => m[1])
}

/** 从 env 文件取 `CGC_WECHAT_TEMPLATE_<KEY>=` 的 <key>（转小写场景键）。 */
function envScenarioKeys(source, file) {
  const keys = [...source.matchAll(/^CGC_WECHAT_TEMPLATE_([A-Z0-9_]+)=/gm)].map((m) =>
    m[1].toLowerCase()
  )
  assert.ok(keys.length > 0, `${file} 里找不到任何 CGC_WECHAT_TEMPLATE_* 键`)
  return keys
}

const sorted = (list) => [...new Set(list)].sort()

test('订阅场景键集四处双射：config 列表 ↔ models 联合 ↔ domain 列表 ↔ env 模板', () => {
  const configSrc = read('config/index.ts')
  const modelsSrc = read('src/domain/models.ts')
  const domainSrc = read('src/domain/subscription.ts')
  const envExample = read('.env.example')
  const envProdExample = read('.env.prod.example')

  const sources = {
    'config/index.ts 的 WECHAT_SCENARIOS': constList(configSrc, 'WECHAT_SCENARIOS', 'config/index.ts'),
    'src/domain/models.ts 的 SubscriptionScenario 联合': scenarioUnion(modelsSrc, 'src/domain/models.ts'),
    'src/domain/subscription.ts 的 ALL_SCENARIOS': constList(domainSrc, 'ALL_SCENARIOS', 'src/domain/subscription.ts'),
    '.env.example 的键': envScenarioKeys(envExample, '.env.example'),
    '.env.prod.example 的键': envScenarioKeys(envProdExample, '.env.prod.example')
  }

  // 数量先钉死：四处「一起被删空」不能靠相等断言蒙混过关
  for (const [label, list] of Object.entries(sources)) {
    assert.equal(
      sorted(list).length,
      EXPECTED_SCENARIO_COUNT,
      `${label} 有 ${sorted(list).length} 个场景，期望 ${EXPECTED_SCENARIO_COUNT}：${JSON.stringify(sorted(list))}`
    )
  }

  const [referenceLabel, reference] = Object.entries(sources)[0]
  const referenceSet = sorted(reference)

  for (const [label, list] of Object.entries(sources)) {
    const set = sorted(list)
    assert.deepEqual(
      set,
      referenceSet,
      `${label} 与 ${referenceLabel} 不一致\n  仅 ${label} 有：${JSON.stringify(set.filter((k) => !referenceSet.includes(k)))}\n  仅 ${referenceLabel} 有：${JSON.stringify(referenceSet.filter((k) => !set.includes(k)))}`
    )
  }
})

test('仓库内不出现真实模板 ID（#635 红线）', () => {
  // 真实微信模板 ID 恰 43 字符。gitleaks 默认规则**不认**这种形态（3 个真实 ID
  // 曾长期在仓内且 CI 全绿），所以必须自己守。
  //
  // 判定收紧成两类，避免把长标识符 / env 键名误判：
  //   ① env 文件里任何 *TEMPLATE* 键的**值**非空 → 违规（模板 ID 只来自构建期 env）；
  //   ② 源码里的**带引号字面量**且形如模板 ID（40..48 位 [A-Za-z0-9_-]，同时含
  //      大写、小写、数字）→ 违规。标识符不带引号，env 键名是大写+下划线且无小写，
  //      两者天然出局。
  const files = [
    '.env.example',
    '.env.prod.example',
    'config/index.ts',
    'config/env.ts',
    'types/global.d.ts',
    ...collectSourceFiles('src')
  ]

  const TEMPLATE_ID_SHAPE = /^[A-Za-z0-9_-]{40,48}$/
  const looksLikeTemplateId = (token) =>
    TEMPLATE_ID_SHAPE.test(token) &&
    /[A-Z]/.test(token) &&
    /[a-z]/.test(token) &&
    /[0-9]/.test(token)

  const offenders = []
  for (const relPath of files) {
    const isEnvFile = relPath.endsWith('.env.example') || relPath.endsWith('.env.prod.example')
    read(relPath)
      .split('\n')
      .forEach((line, index) => {
        const location = `${relPath}:${index + 1}`

        // ① env 值侧：模板键必须留空
        if (isEnvFile) {
          const assignment = line.match(/^([A-Z0-9_]*TEMPLATE[A-Z0-9_]*)=(.*)$/)
          if (assignment && assignment[2].trim() !== '') {
            offenders.push(`${location} ${assignment[1]} 的值非空：${assignment[2]}`)
          }
          return
        }

        // ② 源码引号字面量侧
        for (const match of line.matchAll(/['"`]([A-Za-z0-9_-]{40,48})['"`]/g)) {
          if (looksLikeTemplateId(match[1])) {
            offenders.push(`${location} ${match[1]}`)
          }
        }
      })
  }

  assert.deepEqual(
    offenders,
    [],
    `以下位置疑似真实模板 ID（#635 红线：模板 ID 只来自构建期 env）：\n${offenders.join('\n')}`
  )
})

/** 递归收集某目录下的源码文件（跳过 codegen 产物）。 */
function collectSourceFiles(dir) {
  const out = []
  for (const entry of readdirSync(join(root, dir))) {
    const relPath = `${dir}/${entry}`
    if (statSync(join(root, relPath)).isDirectory()) {
      out.push(...collectSourceFiles(relPath))
    } else if (/\.(ts|tsx|mjs|js|json)$/.test(entry)) {
      out.push(relative(root, join(root, relPath)))
    }
  }
  return out
}
