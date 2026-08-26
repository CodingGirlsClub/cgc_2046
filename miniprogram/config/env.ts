// 生产构建 env 装载（2026-08-26）：Taro dotenvParse 仅透传 TARO_APP_ 前缀键，
// CGC_* 构建变量不在此列——这里在 config 求值前把 .env[.mode] 合入 process.env。
// 优先级：真实环境变量 > .env.{mode}.local > .env.{mode} > .env.local > .env。
// 模板 ID 是公开标识符（随客户端分发），进 repo 的 .env.prod.example 不构成泄密。
const { parse } = require('dotenv')
const { existsSync, readFileSync } = require('node:fs')
const { resolve } = require('node:path')
const nodeEnv = process.env.NODE_ENV as string | undefined
const mode = nodeEnv === 'production' || nodeEnv === 'prod' ? 'prod' : nodeEnv || ''
const files = [
  '.env.local',
  '.env',
  ...(mode ? ['.env.local', '.env'].map((f) => `${f}.${mode}`) : [])
].reverse()

for (const name of files) {
  const path = resolve(__dirname, '..', name)
  if (!existsSync(path)) continue
  for (const [key, value] of Object.entries(parse(readFileSync(path)))) {
    if (!(key in process.env) && typeof value === 'string') process.env[key] = value
  }
}
