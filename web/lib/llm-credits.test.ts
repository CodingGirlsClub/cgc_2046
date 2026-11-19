import { describe, expect, it } from "vitest";
import {
	MC_PER_CENT,
	MC_PER_CNY,
	formatMcAsCny,
	formatMcInteger,
	formatMcToCny,
	formatPercent,
	formatTokenCount,
	parseBigIntMc,
	parseCnyInputToCents,
	parseCnyInputToMc,
	toBigIntMc,
} from "./llm-credits";

describe("llm-credits BigInt / CNY helpers", () => {
	it("exposes canonical microcredit constants", () => {
		expect(MC_PER_CNY).toBe(BigInt(1_000_000));
		expect(MC_PER_CENT).toBe(BigInt(10_000));
		expect(formatMcToCny).toBe(formatMcAsCny);
	});

	it("parses valid integers, numeric strings, and BigInts safely", () => {
		expect(parseBigIntMc(42)).toBe(BigInt(42));
		expect(parseBigIntMc("-5000000")).toBe(BigInt(-5_000_000));
		expect(parseBigIntMc(BigInt("9007199254740993"))).toBe(
			BigInt("9007199254740993"),
		);
		expect(parseBigIntMc("99999999999999999999")).toBe(
			BigInt("99999999999999999999"),
		);
		expect(parseBigIntMc(1.5)).toBeNull();
		expect(parseBigIntMc("abc")).toBeNull();
		expect(parseBigIntMc(null)).toBeNull();
		expect(toBigIntMc(undefined)).toBe(BigInt(0));
		expect(toBigIntMc("invalid")).toBe(BigInt(0));
	});

	it("formats microcredits to CNY accurately without floating-point overflow", () => {
		expect(formatMcAsCny(0)).toBe("¥0.00");
		expect(formatMcAsCny(1_000_000)).toBe("¥1.00");
		expect(formatMcAsCny(29_000_000)).toBe("¥29.00");
		expect(formatMcAsCny("1234567890000")).toBe("¥1,234,567.89");
		// Round half-up at 2 decimals: 1.005 CNY -> ¥1.01
		expect(formatMcAsCny(1_005_000)).toBe("¥1.01");
		expect(formatMcAsCny(1_004_999)).toBe("¥1.00");
		// Tiny values at 4 and 6 decimals
		expect(formatMcAsCny(250, { decimals: 4 })).toBe("¥0.0003");
		expect(formatMcAsCny(1, { decimals: 6 })).toBe("¥0.000001");
		// Huge BigInt well above Number.MAX_SAFE_INTEGER (9_007_199_254_740_991)
		expect(formatMcAsCny("123456789012345678901234", { decimals: 2 })).toBe(
			"¥123,456,789,012,345,678.90",
		);
		// Negative values and avoiding -¥0.00
		expect(formatMcAsCny(-12_340_000)).toBe("-¥12.34");
		expect(formatMcAsCny(-1)).toBe("¥0.00");
		// Options: no symbol & explicit sign
		expect(
			formatMcAsCny(5_500_000, { withSymbol: false, showSign: true }),
		).toBe("+5.50");
	});

	it("formats raw microcredits and tokens with grouping", () => {
		expect(formatMcInteger("1234567890123456789")).toBe(
			"1,234,567,890,123,456,789",
		);
		expect(formatMcInteger(-9876543)).toBe("-9,876,543");
		expect(formatTokenCount(1_250_000)).toBe("1,250,000");
	});

	it("parses CNY decimal inputs to exact microcredits and cents", () => {
		expect(parseCnyInputToMc("10")).toBe(BigInt(10_000_000));
		expect(parseCnyInputToMc("19.99")).toBe(BigInt(19_990_000));
		expect(parseCnyInputToMc("0.000001")).toBe(BigInt(1));
		expect(parseCnyInputToMc("0")).toBeNull();
		expect(parseCnyInputToMc("-5")).toBeNull();
		expect(parseCnyInputToMc("1.1234567")).toBeNull();
		expect(parseCnyInputToMc("abc")).toBeNull();

		expect(parseCnyInputToCents("100")).toBe(10_000);
		expect(parseCnyInputToCents("29.5")).toBe(2_950);
		expect(parseCnyInputToCents("29.99")).toBe(2_999);
		expect(parseCnyInputToCents("0")).toBeNull();
		expect(parseCnyInputToCents("1.999")).toBeNull();
	});

	it("formats percentages safely for BigInt and zero denominators", () => {
		expect(formatPercent(BigInt(0), BigInt(0))).toBe("—");
		expect(
			formatPercent(
				BigInt("333333333333333333"),
				BigInt("1000000000000000000"),
				1,
			),
		).toBe("33.3%");
		expect(formatPercent(BigInt(-250_000), BigInt(1_000_000), 1)).toBe("-25.0%");
		expect(formatPercent(3, 4, 2)).toBe("75.00%");
	});
});
