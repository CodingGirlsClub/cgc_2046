"use client";

// learning-mate.tsx — 课程页的「学习搭子」入口与抽屉（#1155 之后的 UX 重构，第一片）。
// 课程页默认只留一个「问学习搭子」按钮；点开后抽屉里才挂载对话面板——不打开就不探测 Host、不建连接。
// 首次打开后保持挂载，收起只是隐藏：重开不重建连接，正在进行的回合不会因为关抽屉被切断。
// 桌面是右侧覆盖式抽屉（不挤压正文），手机上变成底部抽屉；Esc / 点遮罩 / 关闭按钮都能收起。
// 宽屏可「固定到右侧」：固定时页面让出右栏（并排阅读），不再锁页面滚动、不显示遮罩；固定偏好按课程记在本地。
import { useEffect, useRef, useState, useSyncExternalStore } from "react";
import { useTranslations } from "next-intl";
import HostChatPanel from "./host-chat-panel";

const FOCUSABLE = 'a[href], button:not([disabled]), textarea:not([disabled]), input:not([disabled]), select:not([disabled]), [tabindex]:not([tabindex="-1"])';

/** 覆盖式抽屉是 aria-modal：Tab 只在面板内循环（固定成右栏时是非模态，不拦） */
function trapTab(event: KeyboardEvent, container: HTMLElement): void {
	const focusables = Array.from(container.querySelectorAll<HTMLElement>(FOCUSABLE)).filter((element) => element.offsetParent !== null);
	if (focusables.length === 0) {
		event.preventDefault();
		container.focus();
		return;
	}
	const first = focusables[0];
	const last = focusables[focusables.length - 1];
	const active = document.activeElement;
	if (event.shiftKey && (active === first || active === container)) {
		event.preventDefault();
		last.focus();
	} else if (!event.shiftKey && active === last) {
		event.preventDefault();
		first.focus();
	}
}

/** 与 CSS 的 @media (min-width: 1100px) 保持一致：只有宽屏才有「固定成右栏」 */
const PIN_QUERY = "(min-width: 1100px)";

function useWideLayout(): boolean {
	return useSyncExternalStore(
		(onChange) => {
			if (typeof window === "undefined" || typeof window.matchMedia !== "function") return () => {};
			const query = window.matchMedia(PIN_QUERY);
			query.addEventListener("change", onChange);
			return () => query.removeEventListener("change", onChange);
		},
		() => (typeof window !== "undefined" && typeof window.matchMedia === "function" ? window.matchMedia(PIN_QUERY).matches : false),
		() => false,
	);
}

export default function LearningMate(props: {
	courseId: string;
	userId: string;
	locale: string;
	workspaceId: string;
	courseVersion: number | null;
	unitId: string | null;
	/** 固定态变化：页面据此把阅读区切成紧凑布局，保证 ≥1100px 时正文仍可读 */
	onDockChange?(docked: boolean): void;
}) {
	const t = useTranslations("hostChat");
	const onDockChange = props.onDockChange;
	const [open, setOpen] = useState(false);
	/** 首次打开前不挂载面板（避免页面一进来就探测 Host）；之后保持挂载，收起只是隐藏 */
	const [mounted, setMounted] = useState(false);
	// 固定只对本次打开有效（不写 localStorage）：每次进入课程页都从覆盖式抽屉开始，行为可预期
	const [pinned, setPinned] = useState(false);
	const wide = useWideLayout();
	const effectivePinned = pinned && wide;
	const launcherRef = useRef<HTMLButtonElement>(null);
	const panelRef = useRef<HTMLDivElement>(null);

	const docked = open && effectivePinned;
	const show = () => {
		setMounted(true);
		setOpen(true);
	};
	const hide = () => setOpen(false);
	const togglePin = () => setPinned((value) => !value);

	useEffect(() => {
		if (mounted && !open) launcherRef.current?.focus();
	}, [mounted, open]);

	// 固定时页面让出右栏：用 body class 让课程页留出与抽屉等宽的右侧空间（只在 ≥1100px 生效）
	useEffect(() => {
		document.body.classList.toggle("learning-mate-docked", docked);
		return () => document.body.classList.remove("learning-mate-docked");
	}, [docked]);

	// 覆盖式抽屉打开时把焦点移进对话框；否则焦点留在文档上，Tab 会跑到被遮住的课程控件里
	useEffect(() => {
		if (open && !effectivePinned) panelRef.current?.focus();
	}, [open, effectivePinned]);

	// 固定时正文被右栏挤窄：通知页面切到阅读区紧凑布局（大纲收成浮层、进度栏变窄）
	useEffect(() => {
		onDockChange?.(docked);
	}, [docked, onDockChange]);

	useEffect(() => {
		if (!open) return;
		const onKey = (event: KeyboardEvent) => {
			if (event.key === "Escape") hide();
			if (event.key === "Tab" && !effectivePinned && panelRef.current) trapTab(event, panelRef.current);
		};
		document.addEventListener("keydown", onKey);
		// 覆盖式抽屉才锁页面滚动；固定成右栏时页面要能正常滚动阅读
		const previousOverflow = document.body.style.overflow;
		if (!effectivePinned) document.body.style.overflow = "hidden";
		return () => {
			document.removeEventListener("keydown", onKey);
			document.body.style.overflow = previousOverflow;
		};
	}, [open, effectivePinned]);

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
					{!effectivePinned ? <div className="learning-mate__backdrop" aria-hidden onClick={hide} /> : null}
					<div
						ref={panelRef}
						id="learning-mate"
						className="learning-mate__panel"
						role="dialog"
						aria-modal={!effectivePinned}
						aria-label={t("title")}
						tabIndex={-1}
					>
						<HostChatPanel
							{...props}
							onClose={hide}
							pinned={effectivePinned}
							onTogglePin={wide ? togglePin : undefined}
						/>
					</div>
				</div>
			) : null}
		</>
	);
}
