"use client";

/**
 * 首公里邀请模态（plan 2026-08-22 first-mile-onboarding U3，R1/R2）。
 *
 * 「模态邀请，每次登录弹直到明确拒绝」（session-settled）：弹出/去重门控在概览页
 * （w/[slug]/page.tsx——KTD4 session 旗标 + KTD5 fail-closed + active 成员判定），
 * 本组件只管框内行为；模态 a11y 机制（开框聚焦、Esc 关、Tab focus trap）
 * 复用 ./modal-a11y 的 useDialogA11y（与 payment-checkout-dialog 单源），无 portal。
 *
 * 三动作：
 * - 开始接入 → /w/:slug/settings/integrations/agents（区入口页，U4），同时 onClose
 *   关框——App Router back 导航会恢复 React state，不关框 inviteClosed 留 false
 *   会同 session 重弹（违 KTD4）；
 * - 再看看 → 关闭（下次登录再弹，F3）；
 * - 暂时不用，别再弹了 → dismissOnboardingInvitation（KTD2 服务端持久拒绝）；
 *   失败不关框、内联错误 role="alert"（AE2）。
 */

import { useState } from "react";
import { Link } from "@/i18n/navigation";
import { useTranslations } from "next-intl";
import { dismissOnboardingInvitation } from "@/lib/onboarding";
import { useDialogA11y } from "./modal-a11y";

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
	const [busy, setBusy] = useState(false);
	const [error, setError] = useState<string | null>(null);

	// dismiss 在飞（busy）时 Esc/遮罩/✕ 不关框：卸载组件会吞掉迟到拒绝的
	// setError，用户显式 opt-out 丢失（「失败不关框、内联错误」AE2）
	const requestClose = () => {
		if (!busy) onClose();
	};
	const { dialogRef, handleKeyDown } = useDialogA11y(requestClose);

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

	return (
		<div
			className="modal-overlay"
			data-testid="onboarding-invite-overlay"
			onClick={requestClose}
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
						onClick={requestClose}
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
						onClick={requestClose}
					>
						{t("inviteLater")}
					</button>
					<Link
						href={`/w/${slug}/settings/integrations/agents`}
						className="join-button join-button--primary"
						data-testid="onboarding-invite-start"
						onClick={onClose}
					>
						{t("inviteStart")}
					</Link>
				</div>
			</div>
		</div>
	);
}
