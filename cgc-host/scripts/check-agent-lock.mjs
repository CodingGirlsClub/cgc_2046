#!/usr/bin/env node
// check-agent-lock.mjs — CI 门禁（期 2）：一键安装的锁仍可获取、可校验、许可合规。
// 覆盖：① 三处版本（install.ts 常量 / package.json / 锁里的条目）一致；② registry 仍提供该版本且 dist.integrity 与锁相同；
// ③ 锁里每个包（含 @openai/codex 的 6 个平台二进制包）的许可证都按规则 §2 的白名单放行（未列出/UNKNOWN 一律拒绝）——这些包不进 cgc-host 的
// package.json，pnpm check:licenses 扫不到它们；④ 六个平台包都在锁里（否则别的平台 --frozen-lockfile 会失败）；⑤ 每个条目都带 sha512。
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
const meta = await withRetry(async () => {
	const res = await fetch(`https://registry.npmjs.org/${ADAPTER}/${pinned}`, { headers: { accept: "application/json" } });
	if (!res.ok) throw new Error(`HTTP ${res.status}`);
	return res.json();
});
if (meta.dist?.integrity !== locked) fail(`registry 的 integrity 与锁不一致：${meta.dist?.integrity} ≠ ${locked}`);

// ③ 锁里每个包：许可按 §2 白名单判定（平台二进制包也在内；它们不经过 pnpm，必须在这里把关）
const nameOf = (spec) => spec.slice(0, spec.lastIndexOf("@"));
const licenseBySpec = new Map();
for (const spec of new Set(specs)) {
	const name = nameOf(spec);
	const version = spec.slice(spec.lastIndexOf("@") + 1);
	if (!name || !version) fail(`锁里的 spec 无法解析：${spec}`);
	licenseBySpec.set(
		spec,
		await withRetry(async () => {
			const res = await fetch(`https://registry.npmjs.org/${name}/${version}`, { headers: { accept: "application/json" } });
			if (!res.ok) throw new Error(`HTTP ${res.status} for ${name}@${version}`);
			return (await res.json()).license;
		}),
	);
}

const violations = [];
for (let i = 0; i < keys.length; i += 1) {
	const spec = specs[i];
	const license = licenseBySpec.get(spec);
	// 白名单（规则 §2）：未列出的许可证按 §6 不得直接引入；UNKNOWN 同样失败
	if (!licenseAllows(license, { packageName: nameOf(spec) })) {
		violations.push(`${spec}: ${typeof license === "string" ? license : JSON.stringify(license ?? null)}`);
	}
}
if (violations.length > 0) fail(`一键安装的依赖许可不合规（docs/开源合规/依赖引入规则.md）：\n  ${violations.join("\n  ")}`);

console.log(
	`agent 锁校验通过：@agentclientprotocol/codex-acp@${pinned}（${locked.slice(0, 24)}…），${keys.length} 个包的许可均合规（含 ${PLATFORMS.length} 个平台包）`,
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
