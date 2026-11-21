/**
 * LLM 算力微积分（microcredit, mc）精确换算与格式化工具。
 *
 * 换算口径（与后端 Cgc2046.LlmGateway 保持单源一致）：
 * - 1 CNY = 1_000_000 mc
 * - 1 分（cent）= 10_000 mc
 *
 * 全程采用 BigInt 整数运算，避免超 2^53 - 1（约 ¥90 亿微积分或长期累计大池）时的
 * IEEE 754 浮点精度丢失与舍入漂移。使用 `BigInt(...)` 构造以兼容项目 tsconfig target。
 */

const ZERO = BigInt(0);
const ONE = BigInt(1);
const TWO = BigInt(2);
const HUNDRED = BigInt(100);
const MAX_SAFE_BIGINT = BigInt(Number.MAX_SAFE_INTEGER);

export const MC_PER_CNY = BigInt(1_000_000);
export const MC_PER_CENT = BigInt(10_000);

export type McInput = bigint | number | string | null | undefined;

export interface FormatMcAsCnyOptions {
	/** 小数位数（0..6，默认 2） */
	decimals?: number;
	/** 是否带人民币符号 ¥（默认 true） */
	withSymbol?: boolean;
	/** 正数是否显式带 + 号（默认 false） */
	showSign?: boolean;
}

function pow10BigInt(exp: number): bigint {
	return BigInt(`1${"0".repeat(Math.max(0, exp))}`);
}

function groupDigits(digits: string): string {
	return digits.replace(/\B(?=(\d{3})+(?!\d))/g, ",");
}

/** 严格解析微积分值（仅接受整数 / 纯整数字符串 / BigInt）；非法值返回 null。 */
export function parseBigIntMc(value: McInput): bigint | null {
	if (typeof value === "bigint") return value;
	if (typeof value === "number") {
		return Number.isInteger(value) ? BigInt(value) : null;
	}
	if (typeof value === "string") {
		const trimmed = value.trim();
		if (/^-?\d+$/.test(trimmed)) return BigInt(trimmed);
		return null;
	}
	return null;
}

/** 安全转 BigInt 微积分；空值或非法值回退 BigInt(0)。 */
export function toBigIntMc(value: McInput): bigint {
	return parseBigIntMc(value) ?? ZERO;
}

/**
 * 将微积分（mc）无损格式化为人民币金额（如 `¥29.00`、`-¥1.25`）。
 * 采用 BigInt 半入舍入（round half-up），不经过 JS Number 浮点转换。
 */
export function formatMcAsCny(
	mc: McInput,
	options: FormatMcAsCnyOptions = {},
): string {
	const rawDecimals = options.decimals ?? 2;
	const decimals = Math.min(6, Math.max(0, Math.trunc(rawDecimals)));
	const withSymbol = options.withSymbol ?? true;
	const showSign = options.showSign ?? false;

	const raw = toBigIntMc(mc);
	const negative = raw < ZERO;
	const abs = negative ? -raw : raw;

	const divisor = pow10BigInt(6 - decimals);
	const rounded = divisor === ONE ? abs : (abs + divisor / TWO) / divisor;

	const scale = pow10BigInt(decimals);
	const whole = rounded / scale;
	const frac = rounded % scale;

	const wholeText = groupDigits(whole.toString());
	const numberText =
		decimals > 0
			? `${wholeText}.${frac.toString().padStart(decimals, "0")}`
			: wholeText;

	const sign =
		negative && rounded > ZERO
			? "-"
			: showSign && !negative && rounded > ZERO
				? "+"
				: "";
	const symbol = withSymbol ? "¥" : "";
	return `${sign}${symbol}${numberText}`;
}

/** `formatMcAsCny` 别名（便于不同调用方命名习惯）。 */
export const formatMcToCny = formatMcAsCny;

/** 将微积分或 Token 整数按千分位分组格式化，支持超过 Number.MAX_SAFE_INTEGER 的大数。 */
export function formatMcInteger(mc: McInput): string {
	const raw = toBigIntMc(mc);
	const negative = raw < ZERO;
	const digits = (negative ? -raw : raw).toString();
	return `${negative ? "-" : ""}${groupDigits(digits)}`;
}

/** Token 数量千分位格式化。 */
export function formatTokenCount(tokens: McInput): string {
	return formatMcInteger(tokens);
}

function parseCnyRawToMc(input: string): bigint | null {
	const trimmed = input.trim();
	const match = /^(\d+)(?:\.(\d{1,6}))?$/.exec(trimmed);
	if (!match) return null;
	const whole = BigInt(match[1]);
	const frac = BigInt((match[2] ?? "").padEnd(6, "0"));
	return whole * MC_PER_CNY + frac;
}

/**
 * 解析用户输入的人民币正数字符串（最多 6 位小数）为精确 BigInt 微积分。
 * 空串、非正数、非数字或超过 6 位小数返回 null。
 */
export function parseCnyInputToMc(input: string): bigint | null {
	const total = parseCnyRawToMc(input);
	return total !== null && total > ZERO ? total : null;
}

/**
 * 解析用户输入的人民币非负字符串（允许 "0"，最多 6 位小数）为精确 BigInt 微积分。
 */
export function parseNonNegativeCnyInputToMc(input: string): bigint | null {
	return parseCnyRawToMc(input);
}

/**
 * 将微积分（mc）格式化为适合表单输入回填的无逗号小数字符串（如 200000 → "0.2"）。
 */
export function formatMcToPlainCny(mc: McInput): string {
	const raw = toBigIntMc(mc);
	const negative = raw < ZERO;
	const abs = negative ? -raw : raw;
	const whole = abs / MC_PER_CNY;
	const frac = (abs % MC_PER_CNY).toString().padStart(6, "0").replace(/0+$/, "");
	const sign = negative && abs > ZERO ? "-" : "";
	return frac ? `${sign}${whole.toString()}.${frac}` : `${sign}${whole.toString()}`;
}

/**
 * 解析用户输入的人民币金额字符串（最多 2 位小数）为正整数分（cents）。
 * 空串、非正数、超过 2 位小数或超出安全整数范围返回 null。
 */
export function parseCnyInputToCents(input: string): number | null {
	const trimmed = input.trim();
	const match = /^(\d+)(?:\.(\d{1,2}))?$/.exec(trimmed);
	if (!match) return null;
	const cents =
		BigInt(match[1]) * HUNDRED + BigInt((match[2] ?? "").padEnd(2, "0"));
	if (cents <= ZERO || cents > MAX_SAFE_BIGINT) return null;
	return Number(cents);
}

/**
 * 精确百分比格式化（支持 BigInt 分子/分母，分母为 0 返回 "—"）。
 * 例如 `formatPercent(BigInt(75), BigInt(100), 1)` → `"75.0%"`。
 */
export function formatPercent(
	numerator: number | bigint,
	denominator: number | bigint,
	decimals = 1,
): string {
	const d = Math.min(4, Math.max(0, Math.trunc(decimals)));
	const numBig =
		typeof numerator === "bigint"
			? numerator
			: Number.isInteger(numerator)
				? BigInt(numerator)
				: null;
	const denBig =
		typeof denominator === "bigint"
			? denominator
			: Number.isInteger(denominator)
				? BigInt(denominator)
				: null;

	if (numBig !== null && denBig !== null) {
		if (denBig === ZERO) return "—";
		const negative = (numBig < ZERO) !== (denBig < ZERO);
		const absNum = numBig < ZERO ? -numBig : numBig;
		const absDen = denBig < ZERO ? -denBig : denBig;
		const factor = pow10BigInt(d);
		const scaled = (absNum * HUNDRED * factor + absDen / TWO) / absDen;
		const whole = scaled / factor;
		const frac = scaled % factor;
		const sign = negative && scaled > ZERO ? "-" : "";
		return d > 0
			? `${sign}${whole.toString()}.${frac.toString().padStart(d, "0")}%`
			: `${sign}${whole.toString()}%`;
	}

	const num = Number(numerator);
	const den = Number(denominator);
	if (!Number.isFinite(num) || !Number.isFinite(den) || den === 0) return "—";
	const pct = (num / den) * 100;
	const rounded = pct.toFixed(d);
	return `${rounded === `-${(0).toFixed(d)}` ? (0).toFixed(d) : rounded}%`;
}
