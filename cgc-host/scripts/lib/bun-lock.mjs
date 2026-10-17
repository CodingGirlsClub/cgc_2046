#!/usr/bin/env bun
// scripts/lib/bun-lock.mjs — 解析随包发布的 bun.lock（JSONC：Bun 会写尾逗号）。
// 供 CI 门禁与单测共用：按 packages 的**键**取条目，并断言每个键都有可用的 spec 与 sha512——正则按行匹配会随排版静默漏查。

/** @returns {{ keys: string[], specs: string[], integrities: (string|null)[] }} */
export function parseBunLock(text) {
	const parsed = JSON.parse(stripTrailingCommas(text));
	const packages = parsed.packages;
	if (!packages || typeof packages !== "object" || Array.isArray(packages)) throw new Error("bun.lock 缺少 packages 对象");
	const keys = Object.keys(packages);
	const specs = keys.map((key) => {
		const entry = packages[key];
		if (!Array.isArray(entry) || typeof entry[0] !== "string" || entry[0].length === 0) {
			throw new Error(`bun.lock 的 packages["${key}"] 形状不认识`);
		}
		return entry[0];
	});
	// 覆盖度自证：每个键都必须解析出 spec，数量必须相等（只兜住「全漏」是不够的）
	if (specs.length !== keys.length) throw new Error("bun.lock 解析条目数与 keys 不一致");
	for (const spec of specs) if (!spec.includes("@", 1)) throw new Error(`bun.lock 的 spec 没有版本：${spec}`);
	const integrities = keys.map((key) => {
		const entry = packages[key];
		return entry.find((value) => typeof value === "string" && value.startsWith("sha512-")) ?? null;
	});
	return { keys, specs, integrities };
}

/** 去掉 JSON 对象/数组末尾的逗号（Bun 的 text lock 用 JSONC 写法，标准 JSON.parse 不接受） */
function stripTrailingCommas(text) {
	let out = "";
	let inString = false;
	let escaped = false;
	for (let i = 0; i < text.length; i += 1) {
		const ch = text[i];
		if (inString) {
			out += ch;
			if (escaped) escaped = false;
			else if (ch === "\\") escaped = true;
			else if (ch === '"') inString = false;
			continue;
		}
		if (ch === '"') {
			inString = true;
			out += ch;
			continue;
		}
		if (ch === ",") {
			// 往后看第一个非空白字符：若是 } 或 ]，这个逗号是尾逗号
			let j = i + 1;
			while (j < text.length && /\s/.test(text[j])) j += 1;
			if (text[j] === "}" || text[j] === "]") continue;
		}
		out += ch;
	}
	return out;
}
