#!/usr/bin/env node
// check-agent-lock.mjs — CI 门禁（期 2）：一键安装的锁仍可获取、可校验、许可合规。
// 覆盖：① 三处版本（install.ts 常量 / package.json / 锁里的条目）一致；② registry 仍提供该版本且 dist.integrity 与锁相同；
// ③ 锁里每个包（含 @openai/codex 的 6 个平台二进制包）的许可证都按规则 §2 的白名单放行（未列出/UNKNOWN 一律拒绝）——这些包不进 cgc-host 的
// package.json，pnpm check:licenses 扫不到它们；④ 六个平台包都在锁里（否则别的平台 --frozen-lockfile 会失败）；⑤ 每个条目都带 sha512；
// ⑥ 每个 registry 条目的 integrity 都与 registry 现价一致（改坏任一传递依赖也会红）；
// ⑦ 复用变体锁（#1154）只装适配器、@openai/codex 被本地 stub 顶掉，其余包与全量锁一致。
// 锁按 JSONC 解析、按 packages 的键逐条走，不按行正则——排版变化（多空格、多行数组）不能让条目被静默漏查。
// 整棵依赖树的 integrity 校验发生在学员机器上（bun install --frozen-lockfile 逐个按 sha512 校验），CI 不下载 337MB。
import { licenseAllows } from "../../web/scripts/license-rule.mjs";
import { parseBunLock } from "./lib/bun-lock.mjs";
import { readFile } from "node:fs/promises";

const read = (p) => readFile(p, "utf8");
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const pkg = JSON.parse(await read("src/agents/codex-acp.package.json"));
const pinned = pkg.dependencies?.["@agentclientprotocol/codex-acp"];
const src = await read("src/agents/install.ts");
const constant = src.match(/export const CODEX_ACP_VERSION = "([^"]+)";/)?.[1];
if (!pinned || !constant) fail(`版本缺失：package.json=${pinned} install.ts=${constant}`);
if (pinned !== constant) fail(`版本不一致：package.json=${pinned} install.ts=${constant}`);

let parsedLock;
try {
	parsedLock = parseBunLock(await read("src/agents/codex-acp.lock"));
} catch (e) {
	fail(`bun.lock 解析失败：${e.message}`);
}
const { keys, specs, integrities } = parsedLock;

// ① 适配器那条：版本 + sha512（从解析后的条目取，不按行匹配）
const ADAPTER = "@agentclientprotocol/codex-acp";
const at = keys.indexOf(ADAPTER);
if (at < 0) fail(`锁里没有 ${ADAPTER}`);
if (specs[at] !== `${ADAPTER}@${pinned}`) fail(`锁里的适配器不是钉住版本：${specs[at]} ≠ ${ADAPTER}@${pinned}`);
const locked = integrities[at];
if (!locked) fail(`锁里 ${ADAPTER} 的条目没有 sha512`);

// ⑤ 每个条目都必须带 sha512：缺了就是「没被校验的包」，不能静默放行
const missingIntegrity = keys.filter((key, index) => !integrities[index]);
if (missingIntegrity.length > 0) fail(`锁里这些条目没有 sha512（integrity 校验会失效）：${missingIntegrity.join(", ")}`);

// ④ 平台包：键与 spec 都要对上（只按 spec 后缀判断会漏掉「键被改名」的锁）
const PLATFORMS = ["darwin-arm64", "darwin-x64", "linux-arm64", "linux-x64", "win32-arm64", "win32-x64"];
const missingPlatforms = PLATFORMS.filter(
	(platform) => !keys.includes(`@openai/codex-${platform}`) || !specs.some((spec) => spec.endsWith(`-${platform}`)),
);
if (missingPlatforms.length > 0) fail(`锁里缺少平台包：${missingPlatforms.join(", ")}（用 --os='*' --cpu='*' 重算锁）`);

// ② registry 仍提供钉住版本，且 integrity 与锁一致
const meta = await fetchMeta(ADAPTER, pinned, `${ADAPTER}@${pinned}`);
if (meta.dist?.integrity !== locked) fail(`registry 的 integrity 与锁不一致：${meta.dist?.integrity} ≠ ${locked}`);

// ⑦ 复用变体锁（#1154）：只装适配器，`@openai/codex` 被本地 stub 顶掉；其余包必须与全量锁完全一致
const reusePkg = JSON.parse(await read("src/agents/codex-acp-reuse.package.json"));
if (reusePkg.overrides?.["@openai/codex"] !== "file:./stub") fail("复用变体的 package.json 没有把 @openai/codex 指到本地 stub");
let reuseLock;
try {
	reuseLock = parseBunLock(await read("src/agents/codex-acp-reuse.lock"));
} catch (e) {
	fail(`复用变体锁解析失败：${e.message}`);
}
const reuseAt = reuseLock.keys.indexOf(ADAPTER);
if (reuseAt < 0) fail(`复用变体锁里没有 ${ADAPTER}`);
if (reuseLock.specs[reuseAt] !== `${ADAPTER}@${pinned}`) fail(`复用变体锁里的适配器不是钉住版本：${reuseLock.specs[reuseAt]}`);
if (reuseLock.integrities[reuseAt] !== locked) fail("复用变体锁里的适配器 integrity 与全量锁不一致");
const STUB_SPEC = "@openai/codex@file:./stub";
const stubEntries = reuseLock.specs.filter((spec) => spec === STUB_SPEC);
if (stubEntries.length !== 1) fail(`复用变体锁里应恰好有一条 ${STUB_SPEC}，实际 ${stubEntries.length}`);
const leftoverCodex = reuseLock.keys.filter((key, index) => reuseLock.specs[index] !== STUB_SPEC && (key === "@openai/codex" || key.startsWith("@openai/codex-")));
if (leftoverCodex.length > 0) fail(`复用变体锁里仍有 Codex 本体条目：${leftoverCodex.join(", ")}`);
const missingReuseIntegrity = reuseLock.keys.filter((key, index) => !reuseLock.integrities[index] && reuseLock.specs[index] !== STUB_SPEC);
if (missingReuseIntegrity.length > 0) fail(`复用变体锁里这些条目没有 sha512：${missingReuseIntegrity.join(", ")}`);
const fullSpecs = new Set(specs);
const unexpected = reuseLock.specs.filter((spec) => spec !== STUB_SPEC && !fullSpecs.has(spec));
if (unexpected.length > 0) fail(`复用变体锁里出现了全量锁没有的包：${unexpected.join(", ")}`);
// 每个非 stub 条目的 integrity 都必须与全量锁一致：只比 spec/适配器会漏掉传递依赖 sha512 被改坏，
// 那样 CI 绿、学员机器上 frozen-lock 安装失败，最后还会静默回退 337MB 全量包。
const fullIntegrityBySpec = new Map(specs.map((spec, index) => [spec, integrities[index]]));
const reuseIntegrityMismatch = reuseLock.specs
	.map((spec, index) => ({ spec, integrity: reuseLock.integrities[index] }))
	.filter(({ spec, integrity }) => spec !== STUB_SPEC && fullIntegrityBySpec.get(spec) !== integrity);
if (reuseIntegrityMismatch.length > 0) fail(`复用变体锁这些条目的 integrity 与全量锁不一致：${reuseIntegrityMismatch.map(({ spec }) => spec).join(", ")}`);

// ③ 锁里每个包：许可按 §2 白名单判定（平台二进制包也在内；它们不经过 pnpm，必须在这里把关）
const nameOf = (spec) => spec.slice(0, spec.lastIndexOf("@"));
const metaBySpec = new Map();
for (const spec of new Set(specs)) {
	const name = nameOf(spec);
	const version = spec.slice(spec.lastIndexOf("@") + 1);
	if (!name || !version) fail(`锁里的 spec 无法解析：${spec}`);
	metaBySpec.set(spec, await fetchMeta(name, version, spec));
}

const violations = [];
for (let i = 0; i < keys.length; i += 1) {
	const spec = specs[i];
	const license = metaBySpec.get(spec)?.license;
	// 白名单（规则 §2）：未列出的许可证按 §6 不得直接引入；UNKNOWN 同样失败
	if (!licenseAllows(license, { packageName: nameOf(spec) })) {
		violations.push(`${spec}: ${typeof license === "string" ? license : JSON.stringify(license ?? null)}`);
	}
}
if (violations.length > 0) fail(`一键安装的依赖许可不合规（docs/开源合规/依赖引入规则.md）：\n  ${violations.join("\n  ")}`);

// ⑥ 每个条目的 integrity 都要与 registry 一致：只查适配器那条时，改坏传递依赖的 sha512 会漏过
const integrityMismatch = [];
for (let i = 0; i < keys.length; i += 1) {
	const actual = metaBySpec.get(specs[i])?.dist?.integrity;
	if (actual !== integrities[i]) integrityMismatch.push(`${specs[i]}: 锁=${integrities[i] ?? "无"} registry=${actual ?? "无"}`);
}
if (integrityMismatch.length > 0) fail(`锁里的 integrity 与 registry 不一致（锁被改坏或版本被重新发布）：\n  ${integrityMismatch.join("\n  ")}`);

console.log(
	`agent 锁校验通过：@agentclientprotocol/codex-acp@${pinned}（${locked.slice(0, 24)}…），${keys.length} 个包的许可均合规（含 ${PLATFORMS.length} 个平台包）`,
);

function fail(message) {
	console.error(`::error::${message}`);
	process.exit(1);
}

/** 取 registry 元数据：15 秒超时 + 3 次重试（网络挂起时不让 CI 干等 job 超时） */
function fetchMeta(name, version, what) {
	return withRetry(async () => {
		const res = await fetch(`https://registry.npmjs.org/${name}/${version}`, {
			headers: { accept: "application/json" },
			signal: AbortSignal.timeout(15_000),
		});
		if (!res.ok) throw new Error(`HTTP ${res.status} for ${what}`);
		return res.json();
	});
}

async function withRetry(fn, attempts = 3) {
	let last;
	for (let i = 0; i < attempts; i += 1) {
		try {
			return await fn();
		} catch (e) {
			last = e;
			await sleep(500 * (i + 1));
		}
	}
	throw last;
}
