// @vitest-environment node
// license-rule.test.ts — 依赖许可判定：§2 白名单 + SPDX 表达式（AND/OR/括号），未列出与 UNKNOWN 一律拒绝
import { describe, expect, it } from "vitest";
import { licenseAllows } from "./license-rule.mjs";

describe("licenseAllows（规则 §2 白名单）", () => {
	it("宽松与弱 copyleft 白名单放行", () => {
		for (const id of ["MIT", "Apache-2.0", "BSD-3-Clause", "ISC", "0BSD", "MPL-2.0", "LGPL-3.0-or-later", "EPL-2.0", "Zlib"]) {
			expect(licenseAllows(id), id).toBe(true);
		}
	});

	it("未列出的许可证与 UNKNOWN 一律拒绝（§6：先开 issue）", () => {
		for (const id of ["WTFPL", "CC-BY-SA-4.0", "EPL-1.0", "GPL-3.0-only", "AGPL-3.0-only", "UNLICENSED"]) {
			expect(licenseAllows(id), id).toBe(false);
		}
		expect(licenseAllows(undefined)).toBe(false);
		expect(licenseAllows({})).toBe(false);
		expect(licenseAllows("Apache-2.0 WITH LLVM-exception")).toBe(false); // 例外条款未在白名单：fail-closed
	});

	it("SPDX 表达式：OR 任一放行、AND 必须全部放行、括号按分组", () => {
		expect(licenseAllows("MIT OR Apache-2.0")).toBe(true);
		expect(licenseAllows("MIT AND Zlib")).toBe(true);
		expect(licenseAllows("GPL-2.0-only AND MIT")).toBe(false); // 必须全部遵守，含禁用项
		expect(licenseAllows("(BSD-3-Clause OR GPL-2.0-only)")).toBe(true); // 多选可避开
		expect(licenseAllows("(GPL-2.0-only OR GPL-3.0-only)")).toBe(false);
		expect(licenseAllows("BSD-3-Clause / ISC / BSD-4-Clause")).toBe(true); // 规则里的多选写法：任选其一
	});

	it("数组与 {type} 形态按同一规则判定", () => {
		expect(licenseAllows([{ type: "MIT" }, { type: "GPL-2.0-only" }])).toBe(true);
		expect(licenseAllows([{ type: "GPL-2.0-only" }])).toBe(false);
	});
});
