"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { useLocale, useTranslations } from "next-intl";
import {
	assignEventModerator,
	fetchEventModerators,
	removeEventModerator,
	type EventModerator,
} from "@/lib/graphql/moderators";
import { copyText } from "@/lib/clipboard";
import { getPathname } from "@/i18n/navigation";
import { usePaymentErrorTranslator } from "@/lib/payment-errors";
import { Icon } from "@/components/icons";

/**
 * Event 主理人管理卡（R12–R14，U7）。
 * - Owner/Admin 随时可增删（含 closed/cancelled 场次），目标用户须为本工作台
 *   成员（#558 / #542 决策 A1：非成员指派被后端拒绝，按 code 出引导文案）；
 * - 输入为三锚点精确匹配（#537）：邮箱 / CGC 编号 / 用户 ID——名录泄露的
 *   本质是可枚举，精确匹配不可枚举，任一锚未命中统一「用户不存在」；
 * - U9/KTD10：附「复制核销页链接」——核销页在工作台壳内
 *   （#559：`/[locale]/w/[slug]/events/[id]/check-in`），主理人手输 6 位码
 *   核销，组织者转发入口。
 */
export default function EventModeratorsCard({
	workspaceId,
	eventId,
	workspaceSlug,
}: {
	workspaceId: string;
	eventId: string;
	/** 工作台 slug（核销页链接的路由段；null = 壳内路由不可构造，不显示复制入口） */
	workspaceSlug?: string | null;
}) {
	const t = useTranslations("offerings");
	const tCommon = useTranslations("common");
	const translateError = usePaymentErrorTranslator();
	const locale = useLocale();
	const [rows, setRows] = useState<EventModerator[] | null>(null);
	const [userId, setUserId] = useState("");
	const [busy, setBusy] = useState(false);
	const [message, setMessage] = useState<string | null>(null);
	const [copied, setCopied] = useState(false);
	// 复制成功提示的复原计时器（ref 持有：连续点击只保留最后一次，卸载时清掉）
	const copiedTimer = useRef<number | null>(null);

	const load = useCallback(() => {
		let cancelled = false;
		void fetchEventModerators(workspaceId, eventId)
			.then((value) => {
				if (!cancelled) setRows(value);
			})
			.catch(() => {
				if (!cancelled) setMessage(t("moderatorLoadFailed"));
			});
		return () => {
			cancelled = true;
		};
	}, [workspaceId, eventId, t]);

	useEffect(() => load(), [load]);

	// 卸载清理：计时器不落到已卸载组件（也不遗留闭包引用）
	useEffect(
		() => () => {
			if (copiedTimer.current !== null) window.clearTimeout(copiedTimer.current);
			copiedTimer.current = null;
		},
		[],
	);

	async function assign() {
		const trimmed = userId.trim();
		if (!trimmed) return;
		setBusy(true);
		setMessage(null);
		const result = await assignEventModerator(workspaceId, eventId, trimmed);
		if (result.result) {
			setRows((current) => [...(current ?? []), result.result!]);
			setUserId("");
		} else {
			// 按 code 出文案（errors namespace；未知 code 落通用兜底，不透传英文原文）
			setMessage(translateError(result.errors[0]?.code, t("moderatorActionFailed")));
		}
		setBusy(false);
	}

	async function remove(moderatorId: string) {
		setBusy(true);
		setMessage(null);
		const result = await removeEventModerator(workspaceId, moderatorId);
		if (result.errors.length === 0) {
			setRows((current) => current?.filter((row) => row.id !== moderatorId) ?? null);
		} else {
			setMessage(translateError(result.errors[0]?.code, t("moderatorActionFailed")));
		}
		setBusy(false);
	}

	// 核销页在工作台壳内（#559）：/w/[slug]/events/[id]/check-in，locale 前缀由
	// 导航单源决定（zh-CN 无前缀，与 i18n routing 'as-needed' 一致）
	const checkInPath = workspaceSlug
		? getPathname({ href: `/w/${workspaceSlug}/events/${eventId}/check-in`, locale })
		: null;

	async function copyCheckInLink() {
		setMessage(null);
		if (!checkInPath) return;
		const ok = await copyText(`${window.location.origin}${checkInPath}`);
		if (ok) {
			setCopied(true);
			if (copiedTimer.current !== null) window.clearTimeout(copiedTimer.current);
			copiedTimer.current = window.setTimeout(() => {
				copiedTimer.current = null;
				setCopied(false);
			}, 2000);
			return;
		}
		// 非安全上下文/权限拒绝不静默失败：就地给出可手动复制的链接
		setMessage(`${t("moderatorsCopyFailed")} ${checkInPath}`);
	}

	return (
		<div
			className="mt-4 rounded-large border border-line bg-card p-6"
			data-testid="event-moderators-card"
		>
			<h2 className="text-sm font-medium text-ink">{t("moderatorsTitle")}</h2>
			<p className="mt-1 text-xs text-ink-3">{t("moderatorsHint")}</p>
			{checkInPath ? (
				<div className="mt-3 flex flex-wrap items-center gap-2">
					<span className="text-[13px] text-ink-3">
						{t("moderatorsCheckInLink")}
					</span>
					<button
						type="button"
						onClick={() => void copyCheckInLink()}
						className="inline-flex items-center gap-1 rounded-full border border-line px-2 py-0.5 text-[12px] text-ink-3 hover:border-line-strong"
						data-testid="copy-check-in-link"
					>
						<Icon name="invite" className="h-3.5 w-3.5" />
						{copied ? t("moderatorsLinkCopied") : t("moderatorsCopyLink")}
					</button>
					<span className="text-xs text-ink-3">{t("moderatorsCheckInHint")}</span>
				</div>
			) : null}
			{message ? (
				<p role="alert" className="mt-2 text-sm text-[var(--accent-strong)]">
					{message}
				</p>
			) : null}
			{rows === null ? (
				<p className="mt-3 text-sm text-ink-3">{tCommon("loadingAria")}</p>
			) : rows.length === 0 ? (
				<p className="mt-3 text-sm text-ink-3">{t("moderatorsEmpty")}</p>
			) : (
				<ul className="mt-3 space-y-2">
					{rows.map((row) => {
						// 回显 fallback 链（#537）：displayName → memberNumber（恒有值）；
						// UUID 降为次要信息（title + 小字）
						const name = row.userDisplayName ?? row.userMemberNumber ?? row.userId;
						const assigner = row.assignedByDisplayName ?? row.assignedByMemberNumber;
						return (
							<li key={row.id} className="flex items-center gap-3 text-sm">
								<div className="min-w-0">
									<span className="text-ink" title={row.userId}>
										{name}
									</span>
									<span className="ml-2 font-mono text-xs text-ink-3">{row.userId}</span>
										{assigner ? (
											<span className="ml-2 text-xs text-ink-3">
												{t("moderatorAssignedBy", { name: assigner })}
											</span>
										) : null}
								</div>
								<button
									type="button"
									disabled={busy}
									onClick={() => void remove(row.id)}
									className="rounded-large border border-line px-2 py-0.5 text-xs text-ink-2 hover:border-line-strong"
								>
									{t("moderatorRemove")}
								</button>
							</li>
						);
					})}
				</ul>
			)}
			<div className="mt-3 flex items-center gap-2">
				<input
					aria-label={t("moderatorUserAnchor")}
					value={userId}
					placeholder={t("moderatorUserAnchor")}
					onChange={(e) => setUserId(e.target.value)}
					className="ui-input w-full max-w-md"
				/>
				<button
					type="button"
					disabled={busy || userId.trim() === ""}
					onClick={() => void assign()}
					className="rounded-large border border-line-strong bg-card px-3 py-2 text-sm text-ink hover:border-line disabled:opacity-50"
				>
					{t("moderatorAssign")}
				</button>
			</div>
		</div>
	);
}
