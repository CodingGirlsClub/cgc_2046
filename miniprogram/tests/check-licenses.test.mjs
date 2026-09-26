import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { copyFileSync, mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import test from 'node:test'

// 临时根里放一份脚本，node_modules/.pnpm 仿 pnpm 全局 virtual store 的布局：
// 只有 lock.yaml 与空的 node_modules，一个包都扫不到
test('一个包都没扫到时 fail-closed：exit 2，而不是报「全部合规」', () => {
  const root = mkdtempSync(join(tmpdir(), 'license-scan-'))
  try {
    mkdirSync(join(root, 'scripts'))
    for (const f of ['check-licenses.mjs', 'license-policy.mjs']) {
      copyFileSync(new URL(`../scripts/${f}`, import.meta.url), join(root, 'scripts', f))
    }
    mkdirSync(join(root, 'node_modules/.pnpm/node_modules'), { recursive: true })
    writeFileSync(join(root, 'node_modules/.pnpm/lock.yaml'), '')
    // license-policy.mjs 的运行时依赖；放在 .pnpm 之外，不进扫描范围
    const spdx = dirname(createRequire(import.meta.url).resolve('spdx-expression-parse/package.json'))
    symlinkSync(spdx, join(root, 'node_modules/spdx-expression-parse'))

    const r = spawnSync(process.execPath, [join(root, 'scripts/check-licenses.mjs')], { encoding: 'utf8' })
    assert.equal(r.status, 2, r.stdout + r.stderr)
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})
