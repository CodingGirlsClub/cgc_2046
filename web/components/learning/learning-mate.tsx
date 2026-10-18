"use client";

// learning-mate.tsx — 课程页的「学习搭子」入口与抽屉（#1155 之后的 UX 重构，第一片）。
// 课程页默认只留一个「问学习搭子」按钮；点开后抽屉里才挂载对话面板——不打开就不探测 Host、不建连接。
// 首次打开后保持挂载，收起只是隐藏：重开不重建连接，正在进行的回合不会因为关抽屉被切断。
// 桌面是右侧覆盖式抽屉（不挤压正文），手机上变成底部抽屉；Esc / 点遮罩 / 关闭按钮都能收起。
// 宽屏可「固定到右侧」：固定时页面让出右栏（并排阅读），不再锁页面滚动、不显示遮罩；固定偏好按课程记在本地。
import { useEffect, useRef, useState } from "react";
import { useTranslations } from "next-intl";
import HostChatPanel from "./host-chat-panel";

/** 固定到右侧的偏好按课程记忆；只记偏好，不记「是否打开」（每次进来仍默认收起） */
const pinnedKey = (courseId: string) => `cgc-learning-mate-pinned:${courseId}`;

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
	// 记住的是「固定」偏好，不是打开状态：每次进入课程页仍然默认收起。
	// 用惰性初始化读 localStorage（不在 effect 里 setState）：SSR 时为 false，客户端首屏读到偏好；
	// 未打开抽屉时两种值渲染结果相同，不产生 hydration 差异。
	const [pinned, setPinned] = useState(() => {
		if (typeof window === "undefined") return false;
		try {
			return window.localStorage.getItem(pinnedKey(props.courseId)) === "1";
		} catch {
			return false; // 隐私窗口读不到就按未固定处理
		}
	});
	const launcherRef = useRef<HTMLButtonElement>(null);

	const docked = open && pinned;
	const show = () => {
		setMounted(true);
		setOpen(true);
	};
	const hide = () => setOpen(false);
	const togglePin = () => {
		setPinned((value) => {
			const next = !value;
			try {
				window.localStorage.setItem(pinnedKey(props.courseId), next ? "1" : "0");
			} catch {
				// 写不进去只影响下次记忆，不影响本次
			}
			return next;
		});
	};

	useEffect(() => {
		if (mounted && !open) launcherRef.current?.focus();
	}, [mounted, open]);

	// 固定时页面让出右栏：用 body class 让课程页留出与抽屉等宽的右侧空间（只在 ≥1100px 生效）
	useEffect(() => {
		document.body.classList.toggle("learning-mate-docked", docked);
		return () => document.body.classList.remove("learning-mate-docked");
	}, [docked]);

	useEffect(() => {
		if (!open) return;
		const onKey = (event: KeyboardEvent) => {
			if (event.key === "Escape") hide();
		};
		document.addEventListener("keydown", onKey);
		// 覆盖式抽屉才锁页面滚动；固定成右栏时页面要能正常滚动阅读
		const previousOverflow = document.body.style.overflow;
		if (!pinned) document.body.style.overflow = "hidden";
		return () => {
			document.removeEventListener("keydown", onKey);
			document.body.style.overflow = previousOverflow;
		};
	}, [open, pinned]);

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
				<div className={`learning-mate${docked ? " learning-mate--pinned" : ""}`} hidden={!open}>
					{!pinned ? <div className="learning-mate__backdrop" aria-hidden onClick={hide} /> : null}
					<div id="learning-mate" className="learning-mate__panel" role="dialog" aria-modal={!pinned} aria-label={t("title")}>
						<HostChatPanel {...props} onClose={hide} pinned={pinned} onTogglePin={togglePin} />
					</div>
				</div>
			) : null}
		</>
	);
}
