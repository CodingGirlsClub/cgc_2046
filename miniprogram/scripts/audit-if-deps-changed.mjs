#!/usr/bin/env node
// pnpm audit --prod 的依赖变更门卫（#376）。
//
// 为什么：audit 必须实时调 npm 审计 API（registry.npmjs.org/-/npm/v1/
// security/audits/quick），该服务故障时所有 PR（含纯 backend/docs 改动）
// 被 required check 阻塞——2026-09-04 全天间歇故障实证阻塞 4 次。
//
// 语义（fail-closed：宁可多跑，不可漏检）：
// - PR 事件（GITHUB_REF + GH_TOKEN 在场）：经 compare API 判定本 PR
//   是否变更依赖解析指纹（pnpm-lock.yaml / pnpm-workspace.yaml——overrides
//   真源）。lock 是依赖树的完备指纹：任何依赖变更必改 lock（CI
//   --frozen-lockfile 强制同步）；改 package.json 而不改 lock = scripts/
//   metadata 改动，audit 结果不变。未变更 → skip（exit 0）。
// - push 事件 / 本地开发（无上述 env）→ 恒跑 audit（无 API 可窄化）。
// - rename：compare 返回的 previous_filename 一并命中（deploy.yml changes
//   job 同款纪律）。
// - 任何 API/解析异常 → 恒跑 audit（检测失败不等于安全）。
//
// 跳过只针对网络依赖：本地 pnpm check:ci 与 CI 走同一脚本，清单无第二份。

import { execFileSync } from 'node:child_process'

const DEP_FILES = ['miniprogram/pnpm-lock.yaml', 'miniprogram/pnpm-workspace.yaml']


const token = process.env.GH_TOKEN
const repo = process.env.GITHUB_REPOSITORY
const sha = process.env.GITHUB_SHA

function runAudit() {
  const argv = process.argv.slice(2).filter((a) => a !== '--')
  const [cmd, ...args] = argv
  if (!cmd) {
    console.error('audit-if-deps-changed: 需要 audit 命令参数（如 -- --prod --audit-level high）')
    process.exit(2)
  }
  console.log(`[audit-gate] 依赖解析面变更（或无法证明未变更）——执行 ${cmd} ${args.join(' ')}`)
  execFileSync(cmd, args, { stdio: 'inherit' })
}

function shouldSkip() {
  // 仅 PR 场景可窄化；push/本地恒跑。PR 号取自 GITHUB_REF（pull_request 事件
  // 为 refs/pull/N/merge；push 事件为 refs/heads/... 不匹配 → 恒跑）。
  const prMatch = /^refs\/pull\/(\d+)\/merge$/.exec(process.env.GITHUB_REF || '')
  const prNumber = prMatch && prMatch[1]
  if (!prNumber || !token || !repo) return false
  const timeout = { timeout: 15000 }

  const base = execFileSync(
    'gh', ['api', `repos/${repo}/pulls/${prNumber}`, '--jq', '.base.sha'],
    { encoding: 'utf8', env: { ...process.env, GH_TOKEN: token }, ...timeout }
  ).trim()
  if (!/^[0-9a-f]{40}$/.test(base)) return false

  const compareJson = execFileSync(
    'gh', ['api', `repos/${repo}/compare/${base}...${sha}`, '--jq', '.files[] | .filename, (.previous_filename // empty)'],
    { encoding: 'utf8', env: { ...process.env, GH_TOKEN: token }, ...timeout }
  )
  const touched = compareJson.split('\n').map((s) => s.trim()).filter(Boolean)
  if (touched.length === 0) return false // compare 异常形状：fail-closed

  const hit = touched.filter((f) => DEP_FILES.includes(f))
  if (hit.length > 0) {
    console.log(`[audit-gate] 依赖文件变更：${hit.join(', ')}`)
    return false
  }
  console.log(`[audit-gate] 本 PR 未变更依赖三件套（${touched.length} 个文件全部无关）——跳过联网 audit`)
  return true
}

// fail-closed：检测链路任何异常（API 5xx/限流/网络）→ 恒跑 audit——
// 检测失败不等于安全。
let skip = false
try {
  skip = shouldSkip()
} catch (err) {
  console.warn(`[audit-gate] 变更检测失败（${err && err.message ? err.message.split('\n')[0] : err}）——fail-closed 执行 audit`)
}
if (skip) process.exit(0)
runAudit()
