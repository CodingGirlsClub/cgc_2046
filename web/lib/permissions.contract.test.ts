import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { ROLE_NAMES } from "./graphql/workspace";
import { PERMISSION_ABILITIES, PERMISSION_ROLE_ORDER } from "./permissions";

/**
 * golden-file 契约守卫（#1 能力接口收敛）。
 *
 * 断言前端静态展示词汇 ⊆ 后端契约工件 backend/priv/rbac_contract.json
 * （由后端 Rbac/Role 单源经 `mix cgc2046.gen_rbac_contract` 生成，后端
 * rbac_contract_test.exs 守卫工件新鲜度）。
 *
 * 漂移语义：后端新增角色/能力 → 工件变化 → 本测试红灯 → 开发者同步
 * ROLE_NAMES / PERMISSION_ABILITIES 标签（展示词汇），同步后绿。
 * 矩阵数据本身运行时直接消费后端 permissionMatrix / myAbilities，不受本测试影响。
 */

const CONTRACT_PATH = resolve(
	dirname(fileURLToPath(import.meta.url)),
	"../../backend/priv/rbac_contract.json",
);

function loadContract(): {
	roles: string[];
	abilities: string[];
	matrix: Array<{ role: string; abilities: Record<string, boolean> }>;
} {
	let raw: string;
	try {
		raw = readFileSync(CONTRACT_PATH, "utf8");
		return JSON.parse(raw) as {
			roles: string[];
			abilities: string[];
			matrix: Array<{ role: string; abilities: Record<string, boolean> }>;
		};
	} catch (error) {
		if (error instanceof SyntaxError) {
			throw new Error(`契约工件解析失败：${CONTRACT_PATH} —— 请检查文件内容`);
		}
		throw new Error(
			`契约工件缺失：${CONTRACT_PATH} —— 请在 backend 运行 mix cgc2046.gen_rbac_contract 再生成`,
		);
	}
}

describe("跨语言 RBAC 契约守卫（backend/priv/rbac_contract.json）", () => {
	const contract = loadContract();

	it("契约工件存在且包含 roles/abilities/matrix", () => {
		expect(contract.roles.length).toBeGreaterThan(0);
		expect(contract.abilities.length).toBeGreaterThan(0);
		expect(contract.matrix.length).toBeGreaterThan(0);
	});

	it("ROLE_NAMES 展示词汇与后端角色枚举完全一致（双向，防止任一侧静默滞后）", () => {
		for (const role of ROLE_NAMES) {
			expect(contract.roles, `角色 ${role} 未出现在后端契约中`).toContain(role);
		}
		// 反向：后端新增角色而未同步前端 ROLE_NAMES → 红灯
		// （否则徽章/筛选会静默缺少新角色的展示词汇）
		for (const role of contract.roles) {
			expect(
				ROLE_NAMES,
				`后端新增角色 ${role} 未同步到前端 ROLE_NAMES`,
			).toContain(role);
		}
	});

	it("PERMISSION_ROLE_ORDER 五行模板 ⊆ 后端角色枚举（展示模板，有意为子集）", () => {
		for (const role of PERMISSION_ROLE_ORDER) {
			expect(contract.roles, `展示角色 ${role} 未出现在后端契约中`).toContain(
				role,
			);
		}
	});

	it("PERMISSION_ABILITIES 标签键与后端能力枚举完全一致（双向）", () => {
		const ids = PERMISSION_ABILITIES.map((ability) => ability.id);
		for (const ability of PERMISSION_ABILITIES) {
			expect(
				contract.abilities,
				`能力 ${ability.id} 未出现在后端契约中`,
			).toContain(ability.id);
		}
		// 反向：后端新增能力而未同步前端标签 → 红灯
		// （否则权限页矩阵会静默不渲染新能力列）
		for (const ability of contract.abilities) {
			expect(
				ids,
				`后端新增能力 ${ability} 未同步到前端 PERMISSION_ABILITIES`,
			).toContain(ability);
		}
	});

	it("矩阵每行角色 ∈ 角色枚举、能力键 ∈ 能力枚举（契约自洽）", () => {
		for (const row of contract.matrix) {
			expect(contract.roles).toContain(row.role);
			for (const name of Object.keys(row.abilities)) {
				expect(contract.abilities).toContain(name);
			}
		}
	});

	it("owner/admin 为管理角色：管理类能力为 true（与展示层 ROLE_NOTES 语义一致）", () => {
		for (const row of contract.matrix) {
			if (row.role === "owner" || row.role === "admin") {
				expect(row.abilities.list_members).toBe(true);
				expect(row.abilities.manage_members).toBe(true);
				expect(row.abilities.assign_roles).toBe(true);
			}
		}
	});
});
