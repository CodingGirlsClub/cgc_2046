import type { FlashbackFogSpan } from "@/lib/graphql/flashback";

/**
 * 「点句切雾」三连工具（原 send-register 内部，期间本批 today-actions 引入
 * 第二消费点：今日编辑弹层）——不抄两份，抽公共文件：
 * - toggleSpanIn：某键 spans 集合对一句 start/len 做相交切换（命中即视为雾，
 *   与 sentencesWithFogMark 的命中口径一致）
 * - normalizeSpans：把 null/undefined 规范为空数组（脏检查的相同基线）
 * - sameSpans：起止集合是否全等（元素顺序无关；起止坐标逐元对齐）
 */
export function toggleSpanIn(
	prev: Record<string, FlashbackFogSpan[]>,
	key: string,
	sentence: { start: number; len: number },
): Record<string, FlashbackFogSpan[]> {
	const current = prev[key] ?? [];
	const intersects = (span: { start: number; len: number }) =>
		span.start < sentence.start + sentence.len && sentence.start < span.start + span.len;
	const fogged = current.some(intersects);
	const rest = current.filter((span) => !intersects(span));
	return {
		...prev,
		[key]: fogged ? rest : [...rest, { start: sentence.start, len: sentence.len }],
	};
}

/** 雾区间归一（比较/落库前）：丢非法、按 start/len 排序；reason 是导入元数据，不参与比较 */
export function normalizeSpans(spans: FlashbackFogSpan[] | null | undefined): FlashbackFogSpan[] {
	return [...(spans ?? [])]
		.filter((s) => Number.isInteger(s.start) && Number.isInteger(s.len) && s.start >= 0 && s.len > 0)
		.sort((a, b) => a.start - b.start || a.len - b.len);
}

export function sameSpans(a: FlashbackFogSpan[], b: FlashbackFogSpan[]): boolean {
	return a.length === b.length && a.every((s, i) => s.start === b[i].start && s.len === b[i].len);
}

