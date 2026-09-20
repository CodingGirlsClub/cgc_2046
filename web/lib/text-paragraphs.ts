/** 纯文本描述 → 段落数组：按空行（\n\s*\n）切分，去掉空白段；null/空串 → [] */
export function toParagraphs(text: string | null | undefined): string[] {
	if (!text) return [];
	return text
		.split(/\n\s*\n/)
		.map((p) => p.trim())
		.filter((p) => p.length > 0);
}
