// chat-icons.tsx — 学习搭子头部的小图标（行内 SVG，不引第三方图标库；颜色跟随 currentColor）。
import type { SVGProps } from "react";

const base: SVGProps<SVGSVGElement> = {
	width: 14,
	height: 14,
	viewBox: "0 0 24 24",
	fill: "none",
	stroke: "currentColor",
	strokeWidth: 1.8,
	strokeLinecap: "round",
	strokeLinejoin: "round",
	"aria-hidden": true,
	focusable: false,
};

export function ClockIcon() {
	return (
		<svg {...base}>
			<circle cx="12" cy="12" r="8.5" />
			<path d="M12 7.5v5l3.2 1.9" />
		</svg>
	);
}

export function PlusIcon() {
	return (
		<svg {...base}>
			<path d="M12 5v14M5 12h14" />
		</svg>
	);
}

export function PinIcon({ filled = false }: { filled?: boolean }) {
	return (
		<svg {...base} fill={filled ? "currentColor" : "none"}>
			<path d="M9 3.5h6l-1 5 3.5 3.5v1.5H6.5V12L10 8.5l-1-5Z" />
			<path d="M12 13.5V21" />
		</svg>
	);
}

export function CloseIcon() {
	return (
		<svg {...base}>
			<path d="M6 6l12 12M18 6 6 18" />
		</svg>
	);
}
