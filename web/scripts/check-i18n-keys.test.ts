import { describe, expect, it } from "vitest";
import zhCN from "../messages/zh-CN.json";
import en from "../messages/en.json";
import { checkKeysEqual, flattenKeys } from "./check-i18n-keys.mjs";

describe("check-i18n-keys", () => {
	describe("flattenKeys", () => {
		it("expands nested objects to dot paths", () => {
			expect(
				flattenKeys({ a: { b: { c: 1 } }, d: "x" }),
			).toEqual(["a.b.c", "d"]);
		});

		it("treats arrays and null as leaf values", () => {
			expect(flattenKeys({ a: [1, 2], b: null })).toEqual(["a", "b"]);
		});
	});

	describe("checkKeysEqual", () => {
		it("returns empty list when key sets are equal", () => {
			expect(checkKeysEqual({ a: { b: 1 } }, { a: { b: "1" } })).toEqual([]);
		});

		it("reports keys missing from the pivot locale", () => {
			expect(checkKeysEqual({ a: { b: 1, c: 2 }, d: 3 }, { a: { b: "1" } })).toEqual([
				"a.c",
				"d",
			]);
		});

		it("passes for the shipped messages files", () => {
			expect(checkKeysEqual(zhCN, en)).toEqual([]);
		});
	});
});
