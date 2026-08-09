import { spawnSync } from 'node:child_process'

function run(command, args, env = process.env) {
  return spawnSync(command, args, { env, stdio: 'inherit' }).status ?? 1
}

let status = run('pnpm', ['build:weapp'], { ...process.env, CGC_E2E_MOCK: 'true' })
if (status === 0) status = run(process.execPath, ['e2e/journey.e2e.mjs'])

const restoreStatus = run('pnpm', ['build:weapp'])
process.exit(status === 0 ? restoreStatus : status)
