#!/usr/bin/env node
/**
 * e2e 文档对账守卫：AGENTS.md 的 e2e 表 / 真实后端例外清单 vs e2e/ 实际脚本。
 * 纯文本核对，不执行任何 e2e（e2e 验收需要 GUI 与人工授权，不进 CI——见 AGENTS.md）。
 *
 * 三条核对（fail-closed）：
 * 1. AGENTS.md / package.json 点名的每个 e2e/ 文件必须存在（点名了却删了 → 红）
 * 2. 每个验收脚本必须可归类：含 CGC_E2E_MOCK → mock；含 127.0.0.1: / real backend /
 *    真实后端 → real；都没有或都有 → 红（新脚本必须显式归类，不许含糊）
 * 3. real 脚本的文件名必须在 AGENTS.md 点名（例外清单与实际集合单向一致）
 */
import { readdirSync, readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = fileURLToPath(new URL("../", import.meta.url)); // miniprogram/
const E2E = join(ROOT, "e2e");
const DOC = readFileSync(join(ROOT, "AGENTS.md"), "utf8");
const PKG = JSON.parse(readFileSync(join(ROOT, "package.json"), "utf8"));

// 被 import / 编排的工具文件，不是验收脚本，不参与归类
const HELPERS = new Set(["anchors.mjs", "run.mjs"]);

const problems = [];

// 核对 1：文档与入口点名的 e2e/ 文件必须存在
for (const ref of DOC.matchAll(/`e2e\/([\w./-]+)`/g)) {
	if (!existsSync(join(E2E, ref[1]))) {
		problems.push(`AGENTS.md 点名 e2e/${ref[1]} 不存在（脚本改名 / 删除后文档没跟上）`);
	}
}
for (const [name, cmd] of Object.entries(PKG.scripts)) {
	if (!name.startsWith("e2e")) continue;
	for (const m of cmd.matchAll(/e2e\/([\w./-]+)/g)) {
		if (!existsSync(join(E2E, m[1]))) {
			problems.push(`package.json 的 ${name} 引用 e2e/${m[1]} 不存在`);
		}
	}
}

// 核对 2 + 3：归类每个验收脚本；real 的必须在 AGENTS.md 点名
const real = [];
for (const f of readdirSync(E2E).sort()) {
	if (!/\.(e2e\.)?(py|mjs|sh)$/.test(f) || HELPERS.has(f)) continue;
	const text = readFileSync(join(E2E, f), "utf8");
	// 归类优先级：127.0.0.1 直连 = real 硬信号（运行时打真实 API 决定验收语义）；
	// 其次 CGC_E2E_MOCK = mock；再次文字线索 = real；全无 = 红
	const isReal = /127\.0\.0\.1:|real backend|真实后端/.test(text);
	const isMock = !isReal && text.includes("CGC_E2E_MOCK");
	if (!isReal && !isMock) {
		problems.push(`e2e/${f} 归类不了（无 CGC_E2E_MOCK 也无真实后端线索）——头注释标明其一`);
	} else if (isReal) {
		real.push(f);
		if (!DOC.includes(f)) {
			problems.push(`e2e/${f} 打真实后端，AGENTS.md 的真实后端例外清单没点名它`);
		}
	}
}

if (problems.length > 0) {
	console.error("✗ e2e 文档对账失败（AGENTS.md vs e2e/ 实际）：");
	for (const p of problems) console.error(`  - ${p}`);
	process.exit(2);
}
console.log(`✓ e2e 文档对账通过（真实后端例外：${real.join("、") || "无"}）`);
