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

function formatScheduledAt(datetime: string | null): string {
	if (!datetime) return "未定";
	const d = new Date(datetime);
	if (Number.isNaN(d.getTime())) return "未定";
	return d.toLocaleString("zh-CN", {
		year: "numeric",
		month: "2-digit",
		day: "2-digit",
		hour: "2-digit",
		minute: "2-digit",
	});
}

export default function Page() {
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
					message: res.errors[0]?.message ?? "操作失败，邀请链接可能已失效",
				});
			}
		} catch (e: unknown) {
			setDecision({
				kind: "error",
				message: e instanceof Error ? e.message : "操作失败",
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
						工作台
					</Link>
					{" › "}
					<Link href="/events" className="hover:text-ink">
						活动
					</Link>
					{" › "}
					<strong>嘉宾邀请</strong>
				</p>
			</header>

			{loadError ? (
				<div className="join-card text-center" role="alert">
					<h1 className="text-lg font-medium">邀请链接无效或已失效</h1>
					<p className="mt-2 text-sm text-ink-3">
						链接可能已过期、已被使用，或并非有效的嘉宾邀请。请联系活动主办方确认。
					</p>
					<Link
						href="/events"
						className="join-button join-button--primary mt-6 inline-block"
					>
						浏览公开活动
					</Link>
				</div>
			) : stale || card === null ? (
				<div className="h-56 animate-pulse rounded-large bg-soft-2 ring-1 ring-line" />
			) : (
				<div className="join-card !p-8">
					<p className="text-[13px] text-ink-3">
						你被邀请为以下活动的分享嘉宾
					</p>
					<h1 className="mt-3 text-2xl font-semibold">{card.event.title}</h1>
					{card.event.description ? (
						<p className="mt-3 whitespace-pre-wrap text-sm text-ink-3">
							{card.event.description}
						</p>
					) : null}

					<div className="mt-4 grid gap-2 rounded-large border border-line bg-soft-2 p-4 text-sm">
						<span className="text-ink">
							分享主题：<strong>{card.topic ?? "未填"}</strong>
						</span>
						<span className="text-ink">
							分享时间：<strong>{formatScheduledAt(card.scheduledAt)}</strong>
						</span>
					</div>

					<div className="mt-6 border-t border-line pt-5">
						{decision.kind === "accepted" ? (
							<div className="text-sm" role="status">
								<p className="font-medium text-accent">✓ 已接受邀请</p>
								<p className="mt-1 text-[13px] text-ink-3">
									期待你的分享！产出分享材料后，本次邀请将标记完成。
								</p>
								<Link
									href={returnHref}
									className="mt-4 inline-block text-[13px] text-accent hover:underline"
								>
									返回活动页
								</Link>
							</div>
						) : decision.kind === "declined" ? (
							<div className="text-sm" role="status">
								<p className="font-medium text-ink">已婉拒邀请</p>
								<p className="mt-1 text-[13px] text-ink-3">
									已告知主办方。如情况有变，请联系主办方重新发送邀请。
								</p>
							</div>
						) : !authed ? (
							<div className="text-sm">
								<Link
									href={`/login?next=${encodeURIComponent(invitePath)}`}
									className="join-button join-button--primary inline-block"
								>
									登录后接受邀请
								</Link>
								<p className="mt-2 text-[13px] text-ink-3">
									无账号？{" "}
									<Link
										href={`/register?next=${encodeURIComponent(invitePath)}`}
										className="text-accent hover:underline"
									>
										注册一个全局账号
									</Link>
									（接受邀请需要登录，账号不会加入该工作台）。
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
										{decision.kind === "busy" ? "处理中…" : "接受邀请"}
									</button>
									<button
										type="button"
										disabled={decision.kind === "busy"}
										onClick={() => void decide("declined")}
										className="join-button"
									>
										婉拒
									</button>
								</div>
								{decision.kind === "error" ? (
									<p className="mt-3 text-[13px] text-ink-3" role="alert">
										{decision.message}
									</p>
								) : null}
								<p className="mt-2 text-[13px] text-ink-3">
									接受后请产出分享材料；婉拒即结束，链接一次性生效。
								</p>
							</div>
						)}
					</div>
				</div>
			)}
		</main>
	);
}
