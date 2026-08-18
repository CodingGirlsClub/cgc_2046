"use client";

/**
 * E-4 #49 Speaker 着陆页 /events/[slug]/speaker-invite/[token]。
 *
 * - 邀请卡片：token 公开校验（speakerInvitationCard）——Event 公开信息 +
 *   邀请主题/时间；无效/过期/已用 token 统一错误态（不做防枚举时序攻击，
 *   错误信息统一即可）；
 * - 决策：登录/注册后接受/婉拒（token 一次性，接受/婉拒后失效）；
 * - 已决策后展示终态（accepted 提示材料产出后完成 / declined 提示已婉拒）。
 */

import Link from "next/link";
import { useParams } from "next/navigation";
import { useEffect, useState } from "react";
import { useTranslations } from "next-intl";
import { useAuthed } from "@/lib/auth-provider";
import {
	acceptSpeakerInvitation,
	declineSpeakerInvitation,
	fetchSpeakerInvitationCard,
} from "@/lib/speaker-invitations";
import type { SpeakerInvitationCard } from "@/lib/graphql/speaker-invitation";

type DecisionState =
	| { kind: "idle" }
	| { kind: "busy" }
	| { kind: "accepted" }
	| { kind: "declined" }
	| { kind: "error"; message: string };

function formatScheduledAt(datetime: string | null, undecided: string): string {
	if (!datetime) return undecided;
	const d = new Date(datetime);
	if (Number.isNaN(d.getTime())) return undecided;
	return d.toLocaleString("zh-CN", {
		year: "numeric",
		month: "2-digit",
		day: "2-digit",
		hour: "2-digit",
		minute: "2-digit",
	});
}

export default function Page() {
	const t = useTranslations("speakerInvite");
	const params = useParams<{ slug: string; token: string }>();
	const slug = params?.slug ?? "";
	const token = params?.token ?? "";
	const { authed } = useAuthed();

	const [cardState, setCardState] = useState<{
		id: string;
		status: "loading" | "ok" | "error";
		card: SpeakerInvitationCard | null;
	}>({ id: "", status: "loading", card: null });
	const [decision, setDecision] = useState<DecisionState>({ kind: "idle" });

	useEffect(() => {
		if (!token) return;
		let cancelled = false;

		fetchSpeakerInvitationCard(token)
			.then((card) => {
				if (!cancelled) {
					setCardState({
						id: token,
						status: card === null ? "error" : "ok",
						card,
					});
				}
			})
			.catch(() => {
				if (!cancelled) {
					setCardState({ id: token, status: "error", card: null });
				}
			});

		return () => {
			cancelled = true;
		};
	}, [token]);

	const stale = cardState.id !== token;
	const card = stale ? null : cardState.card;
	const loadError = stale ? false : cardState.status === "error";

	async function decide(next: "accepted" | "declined") {
		setDecision({ kind: "busy" });
		try {
			const res =
				next === "accepted"
					? await acceptSpeakerInvitation(token)
					: await declineSpeakerInvitation(token);

			if (res.result) {
				setDecision({ kind: next });
			} else {
				setDecision({
					kind: "error",
					message: res.errors[0]?.message ?? t("actionFailed"),
				});
			}
		} catch (e: unknown) {
			setDecision({
				kind: "error",
				message: e instanceof Error ? e.message : t("actionFailedShort"),
			});
		}
	}

	const returnHref = card?.event?.slug ? `/events/${card.event.slug}` : "/events";
	const invitePath = `/events/${slug}/speaker-invite/${token}`;

	return (
		<main className="mx-auto w-full max-w-3xl px-4 py-10">
			<header className="mb-6">
				<p className="text-[13px] text-ink-3">
					<Link href="/" className="hover:text-ink">
						{t("breadcrumbHome")}
					</Link>
					{" › "}
					<Link href="/events" className="hover:text-ink">
						{t("breadcrumbEvents")}
					</Link>
					{" › "}
					<strong>{t("title")}</strong>
				</p>
			</header>

			{loadError ? (
				<div className="join-card text-center" role="alert">
					<h1 className="text-lg font-medium">{t("invalidTitle")}</h1>
					<p className="mt-2 text-sm text-ink-3">
						{t("invalidDesc")}
					</p>
					<Link
						href="/events"
						className="join-button join-button--primary mt-6 inline-block"
					>
						{t("browseEvents")}
					</Link>
				</div>
			) : stale || card === null ? (
				<div className="h-56 animate-pulse rounded-large bg-soft-2 ring-1 ring-line" />
			) : (
				<div className="join-card !p-8">
					<p className="text-[13px] text-ink-3">
						{t("invited")}
					</p>
					<h1 className="mt-3 text-2xl font-semibold">{card.event.title}</h1>
					{card.event.description ? (
						<p className="mt-3 whitespace-pre-wrap text-sm text-ink-3">
							{card.event.description}
						</p>
					) : null}

					<div className="mt-4 grid gap-2 rounded-large border border-line bg-soft-2 p-4 text-sm">
						<span className="text-ink">
							{t("topic")}<strong>{card.topic ?? t("topicEmpty")}</strong>
						</span>
						<span className="text-ink">
							{t("time")}<strong>{formatScheduledAt(card.scheduledAt, t("undecided"))}</strong>
						</span>
					</div>

					<div className="mt-6 border-t border-line pt-5">
						{decision.kind === "accepted" ? (
							<div className="text-sm" role="status">
								<p className="font-medium text-accent">{t("accepted")}</p>
								<p className="mt-1 text-[13px] text-ink-3">
									{t("acceptedDesc")}
								</p>
								<Link
									href={returnHref}
									className="mt-4 inline-block text-[13px] text-accent hover:underline"
								>
									{t("backToEvent")}
								</Link>
							</div>
						) : decision.kind === "declined" ? (
							<div className="text-sm" role="status">
								<p className="font-medium text-ink">{t("declined")}</p>
								<p className="mt-1 text-[13px] text-ink-3">
									{t("declinedDesc")}
								</p>
							</div>
						) : !authed ? (
							<div className="text-sm">
								<Link
									href={`/login?next=${encodeURIComponent(invitePath)}`}
									className="join-button join-button--primary inline-block"
								>
									{t("loginToAccept")}
								</Link>
								<p className="mt-2 text-[13px] text-ink-3">
									{t("noAccount")}{" "}
									<Link
										href={`/register?next=${encodeURIComponent(invitePath)}`}
										className="text-accent hover:underline"
									>
										{t("registerAccount")}
									</Link>
									{t("loginHint")}
								</p>
							</div>
						) : (
							<div>
								<div className="flex flex-wrap gap-2">
									<button
										type="button"
										disabled={decision.kind === "busy"}
										onClick={() => void decide("accepted")}
										className="join-button join-button--primary"
									>
										{decision.kind === "busy" ? t("processing") : t("accept")}
									</button>
									<button
										type="button"
										disabled={decision.kind === "busy"}
										onClick={() => void decide("declined")}
										className="join-button"
									>
										{t("decline")}
									</button>
								</div>
								{decision.kind === "error" ? (
									<p className="mt-3 text-[13px] text-ink-3" role="alert">
										{decision.message}
									</p>
								) : null}
								<p className="mt-2 text-[13px] text-ink-3">
									{t("decisionHint")}
								</p>
							</div>
						)}
					</div>
				</div>
			)}
		</main>
	);
}
