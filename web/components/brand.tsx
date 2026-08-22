"use client";

import { useTranslations } from "next-intl";

/**
 * 品牌标识：官方火焰圆标（取自 2016 横排版 logo AI 源文件，标准橙 #EA5504）
 * + 双语文字（zh「程序媛汇 2046」/ en「Coding Girls Club 2046」）。
 * 火焰标为固定品牌色，不随主题变色；尺寸由 CSS 按场景定（导航/auth 品牌面板/页脚）。
 */

export function BrandMark({
	size = 22,
	className,
}: {
	size?: number;
	className?: string;
}) {
	return (
		<svg
			width={size}
			height={size}
			viewBox="3.6 5.8 17.4 17.4"
			aria-hidden
			className={className}
		>
			<path
				fill="#EA5504"
				d="M12.3,23.2c4.8,0,8.7-3.9,8.7-8.7c0-4.8-3.9-8.7-8.7-8.7s-8.7,3.9-8.7,8.7C3.6,19.3,7.5,23.2,12.3,23.2"
			/>
			<path
				fill="#FFFFFF"
				d="M9.9,14.9c0.4-1.3-0.3-2.5-0.3-2.5S6.8,13.2,6.4,16c-0.4,3.1,2.5,4.4,2.5,4.4c-0.1-0.1-0.2-0.1-0.3-0.2C8.3,19.9,8,19.5,8,18.9c-0.1-0.4,0-0.8,0.1-1.2C8.6,16.5,9.6,16.2,9.9,14.9"
			/>
			<path
				fill="#FFFFFF"
				d="M14.8,16.6c0.5-2.3-0.3-3.7-0.8-4.7c-0.1-0.4-0.3-0.8-0.5-1.3c-0.5-1.6-0.2-2.8-0.2-2.8s-3.8,1.7-3.1,5.7c0.5,3,1.5,4,1.4,5.4c0,0,0,0.1,0,0.1c0,0.1,0,0.2-0.1,0.3c0,0,0,0,0,0c0,0.1-0.1,0.2-0.1,0.3c0,0,0,0,0,0c-0.1,0.3-0.3,0.5-0.6,0.7c0,0,0,0,0,0c-0.1,0-0.1,0.1-0.2,0.1c0,0-0.1,0-0.1,0.1c0,0-0.1,0-0.1,0.1c0,0-0.1,0-0.1,0c-0.1,0-0.1,0-0.2,0l0,0c-0.2,0-0.3,0-0.3,0s0,0,0.1,0C12.3,20.5,14.3,18.8,14.8,16.6"
			/>
			<path
				fill="#FFFFFF"
				d="M17.2,20.2L17.2,20.2c0.1,0.1-0.3-0.4-0.6-1.2c-0.3-0.7-0.1-1.9,0.5-3.2c0.8-1.6-0.1-2.8-0.1-2.8l0,0c-1.1,0.8-1.8,2.1-1.8,3.5C15.3,18.1,16,19.4,17.2,20.2"
			/>
		</svg>
	);
}

export function BrandLockup({ className }: { className?: string }) {
	const t = useTranslations("brand");
	return (
		<span className={`brand-lockup${className ? ` ${className}` : ""}`}>
			<BrandMark className="brand-lockup__mark" />
			<span className="brand-lockup__name">
				{t("name")}
				<span className="brand-lockup__year">2046</span>
			</span>
		</span>
	);
}
