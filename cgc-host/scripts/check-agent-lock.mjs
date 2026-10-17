#!/usr/bin/env bun
// check-agent-lock.mjs — CI 门禁（期 2）：一键安装的锁仍可获取、可校验、许可合规。
// 覆盖：① 三处版本（install.ts 常量 / package.json / 锁里的条目）一致；② registry 仍提供该版本且 dist.integrity 与锁相同；
// ③ 锁里每个包（含 @openai/codex 的 6 个平台二进制包）的许可证都按规则 §2 的白名单放行（未列出/UNKNOWN 一律拒绝）——这些包不进 cgc-host 的
// package.json，pnpm check:licenses 扫不到它们；④ 六个平台包都在锁里（否则别的平台 --frozen-lockfile 会失败）。
// 整棵依赖树的 integrity 校验发生在学员机器上（bun install --frozen-lockfile 逐个按 sha512 校验），CI 不下载 337MB。
import { licenseAllows } from "../../web/scripts/license-rule.mjs";
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

// 锁里的每个包：版本 + 许可（平台二进制包也在内；它们不经过 pnpm，必须在这里把关）
const packages = [...new Set([...lock.matchAll(/^\s*"[^"]+": \["([^"]+)",/gm)].map(([, spec]) => spec))];
if (packages.length === 0) fail("锁里没解析出任何包（格式变了？）");

const PLATFORMS = ["darwin-arm64", "darwin-x64", "linux-arm64", "linux-x64", "win32-arm64", "win32-x64"];
const missing = PLATFORMS.filter((p) => !packages.some((spec) => spec.endsWith(`-${p}`)));
if (missing.length > 0) fail(`锁里缺少平台包：${missing.join(", ")}（用 --os='*' --cpu='*' 重算锁）`);

const violations = [];
for (const spec of packages) {
	const at = spec.lastIndexOf("@");
	const name = spec.slice(0, at);
	const version = spec.slice(at + 1);
	const license = await withRetry(async () => {
		const res = await fetch(`https://registry.npmjs.org/${name}/${version}`, { headers: { accept: "application/json" } });
		if (!res.ok) throw new Error(`HTTP ${res.status} for ${name}@${version}`);
		return (await res.json()).license;
	});
	// 白名单（规则 §2）：未列出的许可证按 §6 不得直接引入；UNKNOWN 同样失败
	if (!licenseAllows(license)) {
		violations.push(`${name}@${version}: ${typeof license === "string" ? license : JSON.stringify(license ?? null)}`);
	}
}
if (violations.length > 0) fail(`一键安装的依赖许可不合规（docs/开源合规/依赖引入规则.md）：\n  ${violations.join("\n  ")}`);

console.log(
	`agent 锁校验通过：@agentclientprotocol/codex-acp@${pinned}（${locked.slice(0, 24)}…），${packages.length} 个包的许可均合规（含 ${PLATFORMS.length} 个平台包）`,
);

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
