#!/usr/bin/env node
/**
 * agent 文档引用完整性守卫：各 AGENTS.md / docs/agents/*.md 反引号引用的仓库内
 * 路径必须存在。指令文档由 agent 当事实消费，路径失效 = agent 按错误地图干活。
 * 纯文本核对，不执行任何被引用内容。
 *
 * 归类不了的 token 一律红（fail-closed）；确实是文档写错的，改文档而不是加白名单。
 */
import { readFileSync, existsSync } from "node:fs";
import { join, dirname, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = fileURLToPath(new URL("../", import.meta.url)); // 仓库根
const DOCS = [
	"AGENTS.md",
	"backend/AGENTS.md",
	"web/AGENTS.md",
	"miniprogram/AGENTS.md",
	"omp-plugin/AGENTS.md",
	"openclacky-ext/AGENTS.md",
	...["domain", "issue-tracker", "loopx-workflow", "triage-labels"].map((n) => `docs/agents/${n}.md`),
].map((f) => ({ rel: f, abs: join(ROOT, f), dir: dirname(join(ROOT, f)) }));

// 首词是命令的 inline code（如 `bash scripts/x.sh`）剥掉命令取路径
const CMD = /^(bash|sh|node|ruby|python3?|npx|pnpm|mix|gh-axi|gh|git|loopx|psql|createdb|mise)\s+/;

// 非仓库路径的合法引用（allowlist，注明理由）——新增前先确认不是文档写错
const ALLOW = new Set([
	"dependencies/blocked_by", // issue-tracker.md：GitHub issue dependencies API 路径，非仓库文件
]);

// 首段为忽略 / 生成物 / 外部目录的引用，存在性不代表仓库状态
const IGNORED_FIRST = /^(dist|node_modules|\.loopx|\.codex|\.worktrees|\.worktrees|tmp|deps|_build|origin|evidence|logs)\//;

const EXT = /\.(md|ex|exs|ts|tsx|mts|mjs|cjs|js|sh|rb|yml|yaml|json|lock|graphql|puml|txt)$/;

const problems = [];

function looksLikePath(token) {
	if (ALLOW.has(token)) return false;
	if (token.startsWith("~") || token.startsWith("@") || /^(https?|file):/.test(token)) return false;
	if (token.includes("node_modules") || /(^|\/)dist(\/|$)/.test(token)) return false; // 产物 / 依赖目录
	if (token.endsWith(".env")) return false; // gitignored，存在性因机器而异
	if (/^[A-Z][^/]*\/[a-zA-Z0-9_.-]+$/.test(token) && !EXT.test(token)) return false; // GitHub owner/repo
	if (token.startsWith("/") || IGNORED_FIRST.test(token)) return false;
	if (token.includes("..") || token.includes("=") || /\s/.test(token)) return false;
	const segs = token.replace(/\/\*\*$/, "").replace(/\*[^/]*$/, "").split("/").filter(Boolean);
	if (segs.length < 2) return false; // 单段泛指（src/ 之类）不核对
	if (/\/[0-9]+$/.test(token) && !EXT.test(token)) return false; // Elixir 函数签名 M.f/2
	const t = token.replace(/:\d+$/, "");
	return Boolean(t) && (t.includes("/") || EXT.test(t));
}

function existsSomewhere(token, docDir) {
	let t = token.replace(/:\d+$/, "");
	// brace 展开 src/api/generated/{schema,graphql}.ts → 两个候选都必须存在
	const brace = t.match(/\{([^}]+)\}/);
	if (brace) {
		return brace[1].split(",").every((alt) => existsSomewhere(t.replace(brace[0], alt), docDir));
	}
	// 通配：取 * 前的目录段核对目录存在
	t = t.replace(/\*[^/]*$/, "");
	if (t.endsWith("/")) {
		const dir = t.slice(0, -1);
		return [ROOT, docDir, join(docDir, "cgc-2046"), join(docDir, "src"), resolve(docDir, "..")].some((b) =>
			existsSync(resolve(b, dir)),
		);
	}
	const bases = [ROOT, docDir, join(docDir, "cgc-2046"), join(docDir, "src"), join(docDir, "lib"), resolve(docDir, "..")];
	return bases.some((b) => existsSync(resolve(b, t)));
}

for (const doc of DOCS) {
	if (!existsSync(doc.abs)) {
		problems.push(`守卫清单里的 ${doc.rel} 不存在（文件改名后本清单没跟上）`);
		continue;
	}
	const text = readFileSync(doc.abs, "utf8");
	for (const m of text.matchAll(/`([^`\n]+)`/g)) {
		let token = m[1].replace(CMD, "").trim();
		if (token.startsWith("../")) token = resolve(doc.dir, token).split(sep).join("/");
		if (!looksLikePath(token)) continue;
		if (!existsSomewhere(token, doc.dir)) {
			problems.push(`${doc.rel}: 引用 \`${m[1]}\` 不存在`);
		}
	}
}

if (problems.length > 0) {
	console.error("✗ agent 文档引用完整性对账失败：");
	for (const p of problems) console.error(`  - ${p}`);
	process.exit(2);
}
console.log(`✓ agent 文档引用完整性通过（${DOCS.length} 个文档，全部引用可解析）`);
