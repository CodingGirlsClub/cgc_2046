"use client";

import { useCallback, useEffect, useState } from "react";
import { useTranslations } from "next-intl";
import {
	assignEventModerator,
	fetchEventModerators,
	removeEventModerator,
	type EventModerator,
} from "@/lib/graphql/moderators";

/**
 * Event 主理人管理卡（R12–R14，U7）。
 * - Owner/Admin 随时可增删（含 closed/cancelled 场次），目标用户只需是平台 User；
 * - 输入为用户 ID（计划口径：不按邮箱检索，避免泄露全站用户名录）。
 */
export default function EventModeratorsCard({
	workspaceId,
	eventId,
}: {
	workspaceId: string;
	eventId: string;
}) {
	const t = useTranslations("offerings");
	const tCommon = useTranslations("common");
	const [rows, setRows] = useState<EventModerator[] | null>(null);
	const [userId, setUserId] = useState("");
	const [busy, setBusy] = useState(false);
	const [message, setMessage] = useState<string | null>(null);

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
			setMessage(result.errors[0]?.message ?? t("moderatorActionFailed"));
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
			setMessage(result.errors[0]?.message ?? t("moderatorActionFailed"));
		}
		setBusy(false);
	}

	return (
		<div
			className="mt-4 rounded-large border border-line bg-card p-6"
			data-testid="event-moderators-card"
		>
			<h2 className="text-sm font-medium text-ink">{t("moderatorsTitle")}</h2>
			<p className="mt-1 text-xs text-ink-3">{t("moderatorsHint")}</p>
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
					{rows.map((row) => (
						<li key={row.id} className="flex items-center gap-3 text-sm">
							<span className="font-mono text-ink">{row.userId}</span>
							<button
								type="button"
								disabled={busy}
								onClick={() => void remove(row.id)}
								className="rounded-large border border-line px-2 py-0.5 text-xs text-ink-2 hover:border-line-strong"
							>
								{t("moderatorRemove")}
							</button>
						</li>
					))}
				</ul>
			)}
			<div className="mt-3 flex items-center gap-2">
				<input
					aria-label={t("moderatorUserId")}
					value={userId}
					placeholder={t("moderatorUserId")}
					onChange={(e) => setUserId(e.target.value)}
					className="w-full max-w-md rounded-large border border-line bg-soft-2 px-3 py-2 text-sm text-ink"
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
