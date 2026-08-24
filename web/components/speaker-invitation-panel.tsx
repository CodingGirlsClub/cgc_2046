"use client";

import { useCallback, useEffect, useState } from "react";
import { useTranslations } from "next-intl";
import { copyText } from "@/lib/clipboard";
import {
	createSpeakerInvitation,
	fetchSpeakerInvitations,
	resendSpeakerInvitation,
} from "@/lib/speaker-invitations";
import {
	SPEAKER_INVITATION_STATUS_LABEL,
	SPEAKER_INVITATION_STATUS_TONE,
	type SpeakerInvitationItem,
	type SpeakerInvitationStatus,
} from "@/lib/graphql/speaker-invitation";
import { Icon } from "@/components/icons";

/**
 * E-4 #49 Owner 入口：Event 详情页「邀请 Speaker」表单 + 该 Event 邀请列表。
 *
 * - 表单：speakerName 必填；speakerEmail/topic/scheduledAt/note 可选；
 * - 创建成功返回一次性 plainToken（库中只存哈希）——仅本次会话可复制链接，
 *   刷新后不再可重建（明文只出现一次的设计约束）；
 * - 列表：状态徽章 + 复制邀请链接（仅新创建的 invited 行持有 token；
 *   不做成可导航超链接，避免组织者点进着陆页把自己变成 Speaker）。
 */

const STATUS_TONE_CLASS: Record<"neutral" | "positive" | "negative", string> = {
	neutral: "border-line text-ink-3",
	positive: "border-accent text-accent",
	negative: "border-danger text-danger",
};

interface InviteDraft {
	speakerName: string;
	speakerEmail: string;
	topic: string;
	scheduledAt: string;
	note: string;
}

const EMPTY_DRAFT: InviteDraft = {
	speakerName: "",
	speakerEmail: "",
	topic: "",
	scheduledAt: "",
	note: "",
};

function fromLocalInput(value: string): string | null {
	if (!value) return null;
	const d = new Date(value);
	return Number.isNaN(d.getTime()) ? null : d.toISOString();
}

function formatScheduledAt(datetime: string | null, undecidedLabel: string): string {
	if (!datetime) return undecidedLabel;
	const d = new Date(datetime);
	if (Number.isNaN(d.getTime())) return undecidedLabel;
	return d.toLocaleString("zh-CN", {
		year: "numeric",
		month: "2-digit",
		day: "2-digit",
		hour: "2-digit",
		minute: "2-digit",
	});
}

export default function SpeakerInvitationPanel({
	eventId,
	eventSlug,
	workspaceId,
}: {
	eventId: string;
	eventSlug: string | null;
	workspaceId: string;
}) {
	const t = useTranslations("speakerInvitePanel");
	const [draft, setDraft] = useState<InviteDraft>(EMPTY_DRAFT);
	const [busy, setBusy] = useState(false);
	const [message, setMessage] = useState<string | null>(null);
	const [items, setItems] = useState<SpeakerInvitationItem[]>([]);
	const [listState, setListState] = useState<{
		id: string;
		status: "loading" | "ok" | "error";
	}>({ id: "", status: "loading" });
	// 明文 token 仅本次会话持有（创建/重发响应一次性返回；刷新后不可重建）
	const [tokenByInvitation, setTokenByInvitation] = useState<Record<string, string>>({});
	// 重发防误触（R10）：请求 in-flight disabled + 成功后 30s per-row 冷却
	const [resendingId, setResendingId] = useState<string | null>(null);
	const [cooldown, setCooldown] = useState<Record<string, boolean>>({});

	useEffect(() => {
		if (!eventId) return;
		let cancelled = false;

		fetchSpeakerInvitations(eventId)
			.then((rows) => {
				if (!cancelled) {
					setItems(rows);
					setListState({ id: eventId, status: "ok" });
				}
			})
			.catch(() => {
				// 失败 ≠ 空：不得把未知数据误报为「无邀请」（同待审批计数纪律）
				if (!cancelled) setListState({ id: eventId, status: "error" });
			});

		return () => {
			cancelled = true;
		};
	}, [eventId]);

	const setField = useCallback(
		(field: keyof InviteDraft) =>
			(e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement>) => {
				setDraft((prev) => ({ ...prev, [field]: e.target.value }));
				setMessage(null);
			},
		[],
	);

	async function submit() {
		if (!workspaceId || draft.speakerName.trim() === "") return;
		setBusy(true);
		setMessage(null);
		try {
			const res = await createSpeakerInvitation({
				workspaceId,
				eventId,
				speakerName: draft.speakerName.trim(),
				speakerEmail: draft.speakerEmail.trim() === "" ? null : draft.speakerEmail.trim(),
				topic: draft.topic.trim() === "" ? null : draft.topic.trim(),
				scheduledAt: fromLocalInput(draft.scheduledAt),
				note: draft.note.trim() === "" ? null : draft.note.trim(),
			});

			if (res.result && res.plainToken) {
				setItems((prev) => [res.result as SpeakerInvitationItem, ...prev]);
				setTokenByInvitation((prev) => ({ ...prev, [res.result!.id]: res.plainToken! }));
				setDraft(EMPTY_DRAFT);
				setListState({ id: eventId, status: "ok" });
				setMessage(t("created"));
			} else {
				setMessage(res.errors[0]?.message ?? t("createFailed"));
			}
		} catch (e: unknown) {
			setMessage(e instanceof Error ? e.message : t("createFailed"));
		} finally {
			setBusy(false);
		}
	}

	async function resend(item: SpeakerInvitationItem) {
		if (resendingId || cooldown[item.id]) return;
		setResendingId(item.id);
		setMessage(null);
		try {
			const res = await resendSpeakerInvitation(item.id);

			if (res.result && res.plainToken) {
				// 旧链接已作废：行内替换为新记录 + 新 token 立即可复制（R8）
				setItems((prev) =>
					prev.map((it) => (it.id === item.id ? (res.result as SpeakerInvitationItem) : it)),
				);
				setTokenByInvitation((prev) => ({ ...prev, [item.id]: res.plainToken! }));
				setMessage(t("resendSuccess"));
				setCooldown((prev) => ({ ...prev, [item.id]: true }));
				window.setTimeout(() => {
					setCooldown((prev) => {
						const next = { ...prev };
						delete next[item.id];
						return next;
					});
				}, 30_000);
			} else {
				setMessage(res.errors[0]?.message ?? t("resendFailed"));
			}
		} catch (e: unknown) {
			setMessage(e instanceof Error ? e.message : t("resendFailed"));
		} finally {
			setResendingId(null);
		}
	}


	const stale = listState.id !== eventId;
	const loadError = stale ? false : listState.status === "error";

	const inviteHref = (token: string) =>
		eventSlug ? `/events/${eventSlug}/speaker-invite/${token}` : null;

	return (
		<div className="mt-4 rounded-large border border-line bg-card p-6">
			<h2 className="text-sm font-medium text-ink">{t("title")}</h2>
			<p className="mt-1 text-[13px] text-ink-3">
				{t("desc")}
			</p>

			<div className="mt-4 grid gap-3 sm:grid-cols-2">
				<label className="block">
					<span className="block text-[13px] text-ink-3">{t("speakerName")}</span>
					<input
						value={draft.speakerName}
						onChange={setField("speakerName")}
						placeholder={t("speakerNamePlaceholder")}
						className="mt-1 w-full rounded-large border border-line bg-soft-2 px-3 py-2 text-sm text-ink"
					/>
				</label>

				<label className="block">
					<span className="block text-[13px] text-ink-3">
						{t("speakerEmail")}
					</span>
					<input
						type="email"
						value={draft.speakerEmail}
						onChange={setField("speakerEmail")}
						placeholder="speaker@example.com"
						className="mt-1 w-full rounded-large border border-line bg-soft-2 px-3 py-2 text-sm text-ink"
					/>
				</label>

				<label className="block">
					<span className="block text-[13px] text-ink-3">{t("topic")}</span>
					<input
						value={draft.topic}
						onChange={setField("topic")}
						placeholder={t("topicPlaceholder")}
						className="mt-1 w-full rounded-large border border-line bg-soft-2 px-3 py-2 text-sm text-ink"
					/>
				</label>

				<label className="block">
					<span className="block text-[13px] text-ink-3">{t("scheduledAt")}</span>
					<input
						type="datetime-local"
						value={draft.scheduledAt}
						onChange={setField("scheduledAt")}
						className="mt-1 w-full rounded-large border border-line bg-soft-2 px-3 py-2 text-sm text-ink"
					/>
				</label>

				<label className="block sm:col-span-2">
					<span className="block text-[13px] text-ink-3">{t("notes")}</span>
					<textarea
						value={draft.note}
						onChange={setField("note")}
						rows={2}
						className="mt-1 w-full rounded-large border border-line bg-soft-2 px-3 py-2 text-sm text-ink"
					/>
				</label>
			</div>

			<div className="mt-3 flex items-center gap-3">
				<button
					type="button"
					disabled={busy || draft.speakerName.trim() === ""}
					onClick={() => void submit()}
					className="rounded-large border border-line-strong bg-card px-4 py-2 text-sm font-medium text-ink hover:border-line disabled:opacity-50"
				>
					{busy ? t("creating") : t("create")}
				</button>
				{message ? <span className="text-[13px] text-ink-3">{message}</span> : null}
			</div>

			<div className="mt-5">
				<h3 className="text-[13px] font-medium text-ink">{t("listTitle")}</h3>
				{loadError ? (
					<p className="mt-2 text-[13px] text-ink-3">{t("loadFailed")}</p>
				) : stale || listState.status === "loading" ? (
					<p className="mt-2 text-[13px] text-ink-3">{t("loading")}</p>
				) : items.length === 0 ? (
					<p className="mt-2 text-[13px] text-ink-3">{t("empty")}</p>
				) : (
					<ul className="mt-2 divide-y divide-line rounded-large border border-line">
						{items.map((item) => {
							const token = tokenByInvitation[item.id];
							return (
								<li
									key={item.id}
									className="flex flex-wrap items-center gap-x-4 gap-y-2 px-4 py-3"
								>
									<div className="min-w-0 flex-1">
										<p className="truncate text-sm text-ink">
											{item.speakerName}
											{item.speakerEmail ? (
												<span className="ml-2 text-[12px] text-ink-3">
													{item.speakerEmail}
												</span>
											) : null}
										</p>
										<p className="mt-0.5 truncate text-[13px] text-ink-3">
											{item.topic ? t("topicLabel", { topic: item.topic }) : t("noTopic")}
											<span className="mx-1.5">·</span>
											{formatScheduledAt(item.scheduledAt, t("undecided"))}
										</p>
									</div>
									<SpeakerStatusTag status={item.status} />
									{token ? (
										<CopyInviteLink token={token} href={inviteHref(token)} />
									) : null}
									{item.status === "invited" ? (
										<button
											type="button"
											disabled={resendingId !== null || Boolean(cooldown[item.id])}
											onClick={() => void resend(item)}
											className="inline-flex items-center gap-1 rounded-full border border-line px-2 py-0.5 text-[12px] text-ink-3 hover:border-line-strong disabled:opacity-50"
										>
											{cooldown[item.id]
												? t("resent")
												: item.speakerEmail
													? t("resend")
													: t("regenerate")}
										</button>
									) : null}
								</li>
							);
						})}
					</ul>
				)}
			</div>
		</div>
	);
}

function SpeakerStatusTag({ status }: { status: SpeakerInvitationStatus }) {
	const tone = SPEAKER_INVITATION_STATUS_TONE[status];
	const labelsT = useTranslations();
	return (
		<span
			className={`inline-flex items-center rounded-full border px-2 py-0.5 text-[12px] leading-4 ${STATUS_TONE_CLASS[tone]}`}
		>
			{labelsT(SPEAKER_INVITATION_STATUS_LABEL[status])}
		</span>
	);
}

function CopyInviteLink({ token, href }: { token: string; href: string | null }) {
	const t = useTranslations("speakerInvitePanel");
	const [copied, setCopied] = useState(false);

	async function copy() {
		const url = href ? `${window.location.origin}${href}` : token;
		if (await copyText(url)) {
			setCopied(true);
			window.setTimeout(() => setCopied(false), 2000);
		}
	}

	return (
		<span className="inline-flex items-center gap-2">
			<span className="text-[13px] text-ink-3">{t("inviteLink")}</span>
			<button
				type="button"
				onClick={() => void copy()}
				className="inline-flex items-center gap-1 rounded-full border border-line px-2 py-0.5 text-[12px] text-ink-3 hover:border-line-strong"
			>
				<Icon name="invite" className="h-3.5 w-3.5" />
				{copied ? t("copied") : t("copy")}
			</button>
		</span>
	);
}
