import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

/**
 * 错误码 golden-file 契约守卫（#241 四清单机械联动，同 RBAC 模式）。
 *
 * 断言 messages errors namespace 里的业务 code 键（snake_case，含 "_"）
 * ⊆ backend/priv/error_codes_contract.json（由 domain 单源经
 * `mix cgc2046.gen_error_codes_contract` 生成，后端测试守卫工件新鲜度）。
 *
 * 漂移语义：后端改名/删除 code → 工件变化 → 本测试红灯 → 同步文案键；
 * 前端拼错键 → 直接红灯。camelCase 键（approveRequestFailed 等前端本地
 * 错误）不参与契约。en.json 键集由 check:i18n 与 zh-CN 对齐，此处只查 zh。
 */

const HERE = dirname(fileURLToPath(import.meta.url));
const CONTRACT_PATH = resolve(HERE, "../../backend/priv/error_codes_contract.json");
const MESSAGES_PATH = resolve(HERE, "../messages/zh-CN.json");

describe("errors namespace 错误码契约", () => {
	const { codes } = JSON.parse(readFileSync(CONTRACT_PATH, "utf8")) as {
		codes: string[];
	};
	const codeSet = new Set(codes);
	const errors = (
		JSON.parse(readFileSync(MESSAGES_PATH, "utf8")) as {
			errors: Record<string, string>;
		}
	).errors;

	it("业务 code 键全部存在于后端契约工件", () => {
		const businessKeys = Object.keys(errors).filter((k) => k.includes("_"));
		expect(businessKeys.length).toBeGreaterThan(0);
		for (const key of businessKeys) {
			expect(
				codeSet.has(key),
				`errors.${key} 不在后端契约中（键拼错，或后端已改名/删除该 code）`,
			).toBe(true);
		}
	});

	it("database_error 有文案（#241 F4 回归钉：DB 故障不得英文直出）", () => {
		expect(errors.database_error).toBeTruthy();
	});
});
