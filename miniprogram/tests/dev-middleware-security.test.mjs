import test from 'node:test'
import assert from 'node:assert/strict'
import { createRequire } from 'node:module'
import { mkdtemp, writeFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import http from 'node:http'

const require = createRequire(new URL('../package.json', import.meta.url))
const taroRequire = createRequire(require.resolve('@tarojs/taro/package.json'))
const WebpackDevServer = taroRequire('webpack-dev-server')
const webpack = require('webpack')

function get(port, path) {
  return new Promise((resolve, reject) => {
    const req = http.get({ host: '127.0.0.1', port, path }, (res) => {
      let body = ''
      res.setEncoding('utf8')
      res.on('data', (chunk) => { body += chunk })
      res.on('end', () => resolve({ status: res.statusCode, body }))
      res.on('error', reject)
    })
    req.setTimeout(5000, () => req.destroy(new Error('HTTP test timeout')))
    req.on('error', reject)
  })
}

test('Taro dev server serves bundles but cannot escape a publicPath without trailing slash', { timeout: 30000 }, async (t) => {
  const root = await mkdtemp(join(tmpdir(), 'cgc-dev-middleware-'))
  await writeFile(join(root, 'entry.cjs'), 'module.exports = "bundle-ready"')
  const compiler = webpack({
    mode: 'development', devtool: false, entry: join(root, 'entry.cjs'),
    output: { path: join(root, 'dist'), filename: 'bundle.js', publicPath: '/assets' },
    infrastructureLogging: { level: 'none' }
  })
  const server = new WebpackDevServer({
    host: '127.0.0.1', port: 0, static: false, client: false,
    webSocketServer: false, hot: false, liveReload: false,
    devMiddleware: { publicPath: '/assets', stats: 'errors-only' }
  }, compiler)
  t.after(async () => {
    await server.stop()
    await new Promise((resolve, reject) => compiler.close((err) => err ? reject(err) : resolve()))
    await rm(root, { recursive: true, force: true })
  })
  await server.start()
  await new Promise((resolve) => server.middleware.waitUntilValid(resolve))
  const port = server.server.address().port
  const normal = await get(port, '/assets/bundle.js')
  assert.equal(normal.status, 200)
  assert.match(normal.body, /bundle-ready/)

  // Only synthetic data in the compiler's in-memory FS; never probe real host files.
  compiler.outputFileSystem.writeFileSync(join(root, 'private.txt'), 'outside-output-marker')
  const traversal = await get(port, '/assets../private.txt')
  assert.ok([403, 404].includes(traversal.status), `expected rejection, received ${traversal.status}`)
  assert.ok(!traversal.body.includes('outside-output-marker'))
})
