import { applyFogSpans, type FlashbackFogSpan } from "@/lib/graphql/flashback";

/**
 * 雾面文本渲染（R16/KTD4）单源组件（U4 显影卡 / U5 名册与卡共用）。
 *
 * - `selfView`：本人视图——原文永远完整，雾面区间加 fb-fog-span 视觉标记
 *   （可读、可选择），旁注提示哪些句对外是雾；
 * - 对外视图（墙/分享卡）：fog 段渲染为占位句「这里有一段当年写的话」，
 *   原文字符不进 DOM（零泄露，KTD3）。
 */
export function FogText({
	text,
	spans,
	selfView,
	placeholder,
}: {
	text: string;
	spans: FlashbackFogSpan[] | null | undefined;
	selfView: boolean;
	placeholder: string;
}) {
	const segments = applyFogSpans(text, spans);

	if (selfView) {
		return (
			<>
				{segments.map((segment, index) =>
					segment.fog ? (
						<span key={index} className="fb-fog-span" title={placeholder}>
							{segment.text}
						</span>
					) : (
						<span key={index}>{segment.text}</span>
					),
				)}
			</>
		);
	}

	return (
		<>
			{segments.map((segment, index) =>
				segment.fog ? (
					<span key={index} className="fb-fog-span" aria-label={placeholder}>
						{placeholder}
					</span>
				) : (
					<span key={index}>{segment.text}</span>
				),
			)}
		</>
	);
}
