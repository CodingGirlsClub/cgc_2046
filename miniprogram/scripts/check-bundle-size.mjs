#!/usr/bin/env node
/**
 * 微信主包体积预算门（CI 门，见 advisor-plans/007-mp-weapp-package-budget.md）。
 *
 * 本仓库没有分包（app.config.ts 的 pages 全部进主包），微信平台对主包上传硬上限
 * 是 2 MiB（2,097,152 字节）；超限直接无法上传发版，且往往是发版当天才发现。
 * BUDGET 定在 1,900,000（留约 190KB 应急余量）——超预算就红，逼着在真正撞到
 * 平台上限之前处理，而不是等发版当天。
 *
 * 必须紧跟在 `pnpm build:weapp` 之后、`pnpm build:weapp:mock` 之前跑：
 * build:weapp:mock 会覆盖 dist/weapp（mock 构建含 mockTransport，体积不同），
 * 在它之后跑本脚本量到的就不是真实发版体积。
 *
 * 超预算时的处理顺序：先压素材（图片转 JPEG/WebP、删无用资源），再考虑分包
 * （分包改造会牵动深链路由与 e2e 锚点，见 advisor-plans/007 的 Maintenance notes）。
 * 调高 BUDGET 前要能回答：为什么素材已经无可压、为什么这次膨胀是必要的。
 */
import { readdirSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const miniprogramRoot = join(fileURLToPath(new URL(".", import.meta.url)), "..");
const distRoot = join(miniprogramRoot, "dist", "weapp");

const WECHAT_MAIN_PACKAGE_LIMIT = 2 * 1024 * 1024;
const BUDGET = 1_900_000;

function walk(dir) {
	let entries;
	try {
		entries = readdirSync(dir, { withFileTypes: true });
	} catch {
		return null;
	}
	const files = [];
	for (const entry of entries) {
		const full = join(dir, entry.name);
		if (entry.isDirectory()) files.push(...(walk(full) ?? []));
		else if (entry.isFile()) files.push({ path: full, size: statSync(full).size });
	}
	return files;
}

const files = walk(distRoot);
if (files === null) {
	console.error(`✗ dist/weapp 不存在，先执行 pnpm build:weapp`);
	process.exit(1);
}

const total = files.reduce((sum, f) => sum + f.size, 0);

if (total > BUDGET) {
	const top10 = [...files].sort((a, b) => b.size - a.size).slice(0, 10);
	console.error(`✗ 微信主包体积超预算：${total} 字节（预算 ${BUDGET}，平台上限 ${WECHAT_MAIN_PACKAGE_LIMIT}）`);
	console.error(`Top 10 最大文件：`);
	for (const f of top10) console.error(`  ${relative(distRoot, f.path)}: ${f.size} 字节`);
	process.exit(1);
}

console.log(`✓ 微信主包 ${total} 字节（预算 ${BUDGET}，平台上限 ${WECHAT_MAIN_PACKAGE_LIMIT}，余量 ${BUDGET - total}）`);
