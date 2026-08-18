import { describe, expect, it } from "vitest";
import { appendUserLocaleParam, stripLocalePrefix } from "./user-locale";

describe("i18n/user-locale（F0/F2b 助手）", () => {
	describe("stripLocalePrefix", () => {
		it("strips /en prefix（含根与深链，query 保留）", () => {
			expect(stripLocalePrefix("/en")).toBe("/");
			expect(stripLocalePrefix("/en/w/foo?next=/bar")).toBe(
				"/w/foo?next=/bar",
			);
			expect(stripLocalePrefix("/en/orders/123")).toBe("/orders/123");
		});

		it("keeps zh-CN path intact（默认 locale 无前缀）", () => {
			expect(stripLocalePrefix("/w/foo")).toBe("/w/foo");
			expect(stripLocalePrefix("/?tab=1")).toBe("/?tab=1");
		});

		it("does not touch /english or nested en", () => {
			expect(stripLocalePrefix("/english")).toBe("/english");
			expect(stripLocalePrefix("/w/en")).toBe("/w/en");
		});
	});

	describe("appendUserLocaleParam", () => {
		it("appends with ? when no query, & when present", () => {
			expect(appendUserLocaleParam("/en", "en")).toBe("/en?_ul=en");
			expect(appendUserLocaleParam("/w/foo?next=/bar", "zh-CN")).toBe(
				"/w/foo?next=/bar&_ul=zh-CN",
			);
		});
	});
});
