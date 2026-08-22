"use client";

/**
 * 首公里邀请模态（plan 2026-08-22 first-mile-onboarding U3，R1/R2）。
 *
 * 「模态邀请，每次登录弹直到明确拒绝」（session-settled）：弹出/去重门控在概览页
 * （w/[slug]/page.tsx——KTD4 session 旗标 + KTD5 fail-closed + active 成员判定），
 * 本组件只管框内行为，仿 payment-checkout-dialog：
 * role="dialog"、开框 dialogRef.focus()、Esc 关、Tab focus trap（FOCUSABLE_SELECTOR）、
 * 无 portal。
 *
 * 三动作：
 * - 开始接入 → /w/:slug/settings/integrations/agents（区入口页，U4）；
 * - 再看看 → 关闭（下次登录再弹，F3）；
 * - 暂时不用，别再弹了 → dismissOnboardingInvitation（KTD2 服务端持久拒绝）；
 *   失败不关框、内联错误 role="alert"（AE2）。
 */

import { useEffect, useRef, useState } from "react";
import { Link } from "@/i18n/navigation";
import { useTranslations } from "next-intl";
import { dismissOnboardingInvitation } from "@/lib/onboarding";

const FOCUSABLE_SELECTOR =
	'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';

export interface OnboardingInviteModalProps {
	/** 工作区 slug（主 CTA 拼区入口页路径用） */
	slug: string;
	onClose: () => void;
}

export default function OnboardingInviteModal({
	slug,
	onClose,
}: OnboardingInviteModalProps) {
	const t = useTranslations("onboarding");
	const dialogRef = useRef<HTMLDivElement>(null);
	const [busy, setBusy] = useState(false);
	const [error, setError] = useState<string | null>(null);

	// 开框聚焦对话框本体（Esc/Tab trap 的焦点锚点）
	useEffect(() => {
		dialogRef.current?.focus();
	}, []);

	// 「暂时不用，别再弹了」：服务端持久拒绝（KTD2）；失败不关框 + 内联错误（AE2）
	async function handleDismiss() {
		if (busy) return;
		setBusy(true);
		setError(null);
		try {
			await dismissOnboardingInvitation();
			onClose();
		} catch {
			setError(t("inviteDismissError"));
		} finally {
			setBusy(false);
		}
	}

	// Esc 关闭 + Tab focus trap（对话框内循环）
	function handleKeyDown(e: React.KeyboardEvent<HTMLDivElement>) {
		if (e.key === "Escape") {
			e.stopPropagation();
			onClose();
			return;
		}
		if (e.key !== "Tab") return;
		const el = dialogRef.current;
		if (!el) return;
		const focusables = Array.from(
			el.querySelectorAll<HTMLElement>(FOCUSABLE_SELECTOR),
		);
		if (focusables.length === 0) return;
		const first = focusables[0];
		const last = focusables[focusables.length - 1];
		const active = document.activeElement;
		if (e.shiftKey && (active === first || active === el)) {
			e.preventDefault();
			last.focus();
		} else if (!e.shiftKey && active === last) {
			e.preventDefault();
			first.focus();
		}
	}

	return (
		<div
			className="modal-overlay"
			data-testid="onboarding-invite-overlay"
			onClick={onClose}
			onKeyDown={handleKeyDown}
		>
			<div
				ref={dialogRef}
				role="dialog"
				aria-modal="true"
				aria-label={t("inviteAria")}
				tabIndex={-1}
				className="modal-content"
				data-testid="onboarding-invite-modal"
				onClick={(e) => e.stopPropagation()}
			>
				<div className="flex items-start justify-between gap-3">
					<h2>{t("inviteTitle")}</h2>
					<button
						type="button"
						aria-label={t("inviteCloseAria")}
						data-testid="onboarding-invite-close"
						onClick={onClose}
						className="rounded-large border border-line px-2 py-1 text-sm text-ink-3 hover:border-line-strong hover:text-ink"
					>
						✕
					</button>
				</div>

				<p>{t("inviteDesc")}</p>

				{error ? (
					<p
						role="alert"
						className="text-[13px] text-red-300"
						data-testid="onboarding-invite-error"
					>
						{error}
					</p>
				) : null}

				<div className="connect-step-card__actions">
					<button
						type="button"
						className="join-button join-button--ghost"
						data-testid="onboarding-invite-dismiss"
						disabled={busy}
						onClick={() => void handleDismiss()}
					>
						{t("inviteDismiss")}
					</button>
					<button
						type="button"
						className="join-button join-button--outline"
						data-testid="onboarding-invite-later"
						onClick={onClose}
					>
						{t("inviteLater")}
					</button>
					<Link
						href={`/w/${slug}/settings/integrations/agents`}
						className="join-button join-button--primary"
						data-testid="onboarding-invite-start"
					>
						{t("inviteStart")}
					</Link>
				</div>
			</div>
		</div>
	);
}
