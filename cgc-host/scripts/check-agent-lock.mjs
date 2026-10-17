#!/usr/bin/env bun
// check-agent-lock.mjs — CI 门禁（期 2）：锁里的适配器版本与 integrity 仍与 npm 上一致。
// 覆盖：① 三处版本（install.ts 常量 / package.json / 锁里的条目）一致；② registry 仍提供该版本且 dist.integrity 与锁相同。
// 整棵依赖树的校验发生在学员机器上（bun install --frozen-lockfile 按锁里的 sha512 逐个校验），CI 不下载 337MB。
const read = (p) => Bun.file(p).text();

const pkg = JSON.parse(await read("src/agents/codex-acp.package.json"));
const pinned = pkg.dependencies?.["@agentclientprotocol/codex-acp"];
const src = await read("src/agents/install.ts");
const constant = src.match(/export const CODEX_ACP_VERSION = "([^"]+)";/)?.[1];
if (!pinned || !constant) fail(`版本缺失：package.json=${pinned} install.ts=${constant}`);
if (pinned !== constant) fail(`版本不一致：package.json=${pinned} install.ts=${constant}`);

const lock = await read("src/agents/codex-acp.lock");
const line = lock.split("\n").find((l) => l.includes(`"@agentclientprotocol/codex-acp": ["@agentclientprotocol/codex-acp@${pinned}"`));
if (!line) fail(`锁里没有 @agentclientprotocol/codex-acp@${pinned}`);
const locked = line.match(/sha512-[A-Za-z0-9+/=]+/)?.[0];
if (!locked) fail("锁里的适配器条目没有 sha512");

const url = `https://registry.npmjs.org/@agentclientprotocol/codex-acp/${pinned}`;
const meta = await withRetry(async () => {
  const res = await fetch(url, { headers: { accept: "application/json" } });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return res.json();
});
if (meta.dist?.integrity !== locked) fail(`registry 的 integrity 与锁不一致：${meta.dist?.integrity} ≠ ${locked}`);

console.log(`agent 锁校验通过：@agentclientprotocol/codex-acp@${pinned}（${locked.slice(0, 24)}…）`);

function fail(message) {
  console.error(`::error::${message}`);
  process.exit(1);
}

async function withRetry(fn, attempts = 3) {
  let last;
  for (let i = 0; i < attempts; i += 1) {
    try {
      return await fn();
    } catch (e) {
      last = e;
      await Bun.sleep(500 * (i + 1));
    }
  }
  throw last;
}
