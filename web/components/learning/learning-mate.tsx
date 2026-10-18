"use client";

// learning-mate.tsx — 课程页的「学习搭子」入口与抽屉（#1155 之后的 UX 重构，第一片）。
// 课程页默认只留一个「问学习搭子」按钮；点开后抽屉里才挂载对话面板——不打开就不探测 Host、不建连接。
// 首次打开后保持挂载，收起只是隐藏：重开不重建连接，正在进行的回合不会因为关抽屉被切断。
// 桌面是右侧覆盖式抽屉（不挤压正文），手机上变成底部抽屉；Esc / 点遮罩 / 关闭按钮都能收起。
import { useEffect, useRef, useState } from "react";
import { useTranslations } from "next-intl";
import HostChatPanel from "./host-chat-panel";

export default function LearningMate(props: {
	courseId: string;
	userId: string;
	locale: string;
	workspaceId: string;
	courseVersion: number | null;
	unitId: string | null;
}) {
	const t = useTranslations("hostChat");
	const [open, setOpen] = useState(false);
	/** 首次打开前不挂载面板（避免页面一进来就探测 Host）；之后保持挂载，收起只是隐藏 */
	const [mounted, setMounted] = useState(false);
	const launcherRef = useRef<HTMLButtonElement>(null);

	const show = () => {
		setMounted(true);
		setOpen(true);
	};
	const hide = () => setOpen(false);

	useEffect(() => {
		if (mounted && !open) launcherRef.current?.focus();
	}, [mounted, open]);

	useEffect(() => {
		if (!open) return;
		const onKey = (event: KeyboardEvent) => {
			if (event.key === "Escape") hide();
		};
		document.addEventListener("keydown", onKey);
		const previousOverflow = document.body.style.overflow;
		document.body.style.overflow = "hidden"; // 抽屉打开时锁住页面滚动，焦点留在对话里
		return () => {
			document.removeEventListener("keydown", onKey);
			document.body.style.overflow = previousOverflow;
		};
	}, [open]);

	return (
		<>
			{!open ? (
				<button
					ref={launcherRef}
					type="button"
					className="learning-mate__launcher"
					aria-expanded={false}
					aria-controls="learning-mate"
					onClick={show}
				>
					<span className="learning-mate__launcher-dot" aria-hidden />
					{t("mateOpen")}
				</button>
			) : null}
			{mounted ? (
				<div className="learning-mate" hidden={!open}>
					<div className="learning-mate__backdrop" aria-hidden onClick={hide} />
					<div id="learning-mate" className="learning-mate__panel" role="dialog" aria-modal="true" aria-label={t("title")}>
						<HostChatPanel {...props} onClose={hide} />
					</div>
				</div>
			) : null}
		</>
	);
}
