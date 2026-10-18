"use client";

// chat-tooltip.tsx — 图标按钮的 Tooltip（#1155 UX 修复）：鼠标悬停 / 键盘聚焦时在按钮下方显示文字。
// 用 portal 挂到 body：对话面板有 overflow: hidden，放在按钮内部会被裁掉。
import { useCallback, useEffect, useId, useRef, useState, type ButtonHTMLAttributes, type ReactNode } from "react";
import { createPortal } from "react-dom";

interface TooltipButtonProps extends Omit<ButtonHTMLAttributes<HTMLButtonElement>, "aria-label" | "title"> {
	/** 按钮的可访问名称，同时作为 Tooltip 文案 */
	label: string;
	children: ReactNode;
}

export default function TooltipButton({ label, children, className, onMouseEnter, onMouseLeave, onFocus, onBlur, ...rest }: TooltipButtonProps) {
	const ref = useRef<HTMLButtonElement>(null);
	const id = useId();
	const [position, setPosition] = useState<{ top: number; left: number } | null>(null);

	const show = useCallback(() => {
		const rect = ref.current?.getBoundingClientRect();
		if (!rect) return;
		setPosition({
			top: rect.bottom + 8,
			left: Math.min(Math.max(rect.left + rect.width / 2, 56), window.innerWidth - 56),
		});
	}, []);
	const hide = useCallback(() => setPosition(null), []);

	// 滚动/改窗口大小时按钮会动：直接收起，避免 Tooltip 停在不正确的位置
	useEffect(() => {
		if (!position) return;
		const onScroll = () => setPosition(null);
		window.addEventListener("scroll", onScroll, true);
		window.addEventListener("resize", onScroll);
		return () => {
			window.removeEventListener("scroll", onScroll, true);
			window.removeEventListener("resize", onScroll);
		};
	}, [position]);

	return (
		<>
			<button
				{...rest}
				ref={ref}
				type="button"
				aria-label={label}
				aria-describedby={position ? id : undefined}
				className={className}
				onMouseEnter={(event) => {
					show();
					onMouseEnter?.(event);
				}}
				onMouseLeave={(event) => {
					hide();
					onMouseLeave?.(event);
				}}
				onFocus={(event) => {
					show();
					onFocus?.(event);
				}}
				onBlur={(event) => {
					hide();
					onBlur?.(event);
				}}
			>
				{children}
			</button>
			{position
				? createPortal(
						<span id={id} role="tooltip" className="learning-chat__tooltip" style={{ top: position.top, left: position.left }}>
							{label}
						</span>,
						document.body,
					)
				: null}
		</>
	);
}
