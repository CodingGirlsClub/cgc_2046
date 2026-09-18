import type { ReactNode } from "react";

/**
 * 幂标记（R4）：关键数字沿 2 的幂标注，全站统一样式——等宽 + 玫红 + 缩小，
 * 指数走 `<sup>`，与主数字视觉分离（与小程序端 weapp.css 的 .wep-pow 同形，
 * 两端一套口径）。
 *
 * 两种用法渲染同一段 markup（样式单点，杜绝散落的手写 sup）：
 * - 结构化字段：`<Pow exponent="10" />`（hero 数字行、64 场公式卡）
 * - 文案内嵌：消息里写 `<pow>10</pow>`，交给 richTags 的 handler 渲染
 *
 * 口径纪律（R2/R4）：本页出现的幂指数只有 2⁰（启动日）/ 2³ / 2⁴ / 2⁵ / 2⁶ /
 * 2⁷ / 2¹⁰，与数字叙事体系一一对应；测试按此集合断言。
 */
export function Pow({ exponent }: { exponent: ReactNode }) {
	return (
		<span className="hs24-pow">
			2<sup>{exponent}</sup>
		</span>
	);
}

/**
 * 富文本标签表（next-intl `t.rich`）：消息里写标签，这里给样式。
 *
 * - `<pow>指数</pow>` → 幂标记（2 的指数由 Pow 组件补，消息只管指数本身）
 * - `<b>数字</b>` → 主数字加粗（与幂标记视觉分离）
 * - `<em>title</em>` → 标题里的玫红段（.hs24-title em）
 *
 * 标签集合被测试反向校验：消息里出现而这里没登记的标签会让用例红。
 */
export const richTags: Record<string, (chunks: ReactNode) => ReactNode> = {
	pow: (chunks) => <Pow exponent={chunks} />,
	b: (chunks) => <b>{chunks}</b>,
	em: (chunks) => <em>{chunks}</em>,
};
