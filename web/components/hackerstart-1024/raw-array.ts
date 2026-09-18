/**
 * `t.raw` 取数组时的收口。
 *
 * messages 与组件失配（整段命名空间缺失、值为字符串）时，next-intl 回落成 key
 * 路径字符串，直接 `.map` 会把整页渲染炸掉（真机上表现为白屏）。这里统一回落
 * 空数组：页面骨架与其余区块照常渲染，坏消息只影响它自己那段——与 sitemap
 * 「上游坏了也恒 200」同一口径。
 */
export function rawArray<T>(value: unknown): T[] {
	return Array.isArray(value) ? (value as T[]) : [];
}
