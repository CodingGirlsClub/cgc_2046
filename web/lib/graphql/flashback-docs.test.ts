import { describe, it, expect } from "vitest";
import {
	FLASHBACK_SUBMIT_TODAY,
	FLASHBACK_ADJUST_FOG,
	FLASHBACK_ADJUST_TODAY_FOG,
	FLASHBACK_SET_QUOTE_LICENSE,
	FLASHBACK_SEND_TO_WALL,
	FLASHBACK_RETRACT,
	FLASHBACK_MARK_REVEALED,
	FLASHBACK_ENTER,
} from "./flashback";

/**
 * U9 双入口声明对齐守卫（视觉审计 2026-09 D1）：
 *
 * 后端 schema 在 U9 起给「编辑/回访类」动作开放了 token 可空腿（token 省略时
 * 按登录账号绑定档案）：submitToday / adjustFog / setQuoteLicense 的变量均是
 * `String` 可空。Web 文档若仍声明 `$token: String!`，那么 `token: null` 会在
 * 请求到达 resolver 之前按请求文档自身声明被变量验证拦下——这曾是
 * 胶囊「编辑今天的你」对已绑定/未带 token 用户必失败的根因。
 *
 * 本测试把「哪些文档必须可空、哪些必须保持非空」钉成契约：
 * - 编辑/回访类 + 寄出/撤下（#931 起后端双入口：绑定账号不带 token 也能寄出、
 *   撤下）：token 变量不得是 NonNullType；
 * - 首程旅程类（进入 / 标记已显影）：保持 NonNullType——只有链接才有这一步
 *   （与后端双入口的边界一致）。
 */
function tokenVarIsRequired(doc: unknown, opName: string): boolean {
	const def = (doc as { definitions?: unknown[] }).definitions?.find(
		(d): d is { kind: string; name?: { value: string } } =>
			typeof d === "object" &&
			d !== null &&
			(d as { kind?: string }).kind === "OperationDefinition",
	);
	if (!def || (def as { name?: { value: string } }).name?.value !== opName) {
		throw new Error(`operation ${opName} not found in document`);
	}
	const type = (def as {
		variableDefinitions?: Array<{
			variable: { name: { value: string } };
			type: { kind: string; type?: { kind: string } };
		}>;
	}).variableDefinitions?.find((v) => v.variable.name.value === "token")?.type;
	if (!type) throw new Error(`variable $token not declared on ${opName}`);
	return type.kind === "NonNullType";
}

describe("flashback 文档 token 声明与 schema U9 双入口对齐", () => {
	it("编辑/回访类与寄出/撤下允许 token 可空（登录会话腿；寄出/撤下自 #931 起）", () => {
		expect(tokenVarIsRequired(FLASHBACK_SUBMIT_TODAY, "FlashbackSubmitToday")).toBe(false);
		expect(tokenVarIsRequired(FLASHBACK_ADJUST_FOG, "FlashbackAdjustFog")).toBe(false);
		expect(
			tokenVarIsRequired(FLASHBACK_ADJUST_TODAY_FOG, "FlashbackAdjustTodayFog"),
		).toBe(false);
		expect(tokenVarIsRequired(FLASHBACK_SET_QUOTE_LICENSE, "FlashbackSetQuoteLicense")).toBe(false);
		expect(tokenVarIsRequired(FLASHBACK_SEND_TO_WALL, "FlashbackSendToWall")).toBe(false);
		expect(tokenVarIsRequired(FLASHBACK_RETRACT, "FlashbackRetract")).toBe(false);
	});

	it("首程旅程类操作保持 token 非空（不放宽）", () => {
		expect(tokenVarIsRequired(FLASHBACK_MARK_REVEALED, "FlashbackMarkRevealed")).toBe(true);
		expect(tokenVarIsRequired(FLASHBACK_ENTER, "FlashbackEnter")).toBe(true);
	});
});
