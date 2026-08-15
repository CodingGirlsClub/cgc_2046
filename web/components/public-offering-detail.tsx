"use client";

/**
 * E-5 #50 公开宿主页 /events/[id] 与 /courses/[id]（游客可看详情，报名需登录）。
 *
 * - 详情：匿名读（open + public）；workspace 活动 / 非 open → 404 语义
 *   （读策略过滤 → get 返回 null）；
 * - 报名表单（J-Visitor → J-Learner）：
 *   - 未登录：引导 /login（登录后回到本页）；
 *   - open：直接提交 → confirmed；
 *   - request：提交 → 「申请审批中」中间态；
 *   - invite_only：邀请码输入（可空则后端报 invite_code_required）。
 */

import Link from "next/link";
import { useParams, useRouter } from "next/navigation";
import { useEffect, useState } from "react";
import { useAuthed } from "@/lib/use-authed";
import {
	fetchPublicOffering,
	parseSponsorshipTiers,
	submitEnrollment,
} from "@/lib/public-offerings";
import SponsorshipIntentForm from "@/components/sponsorship-intent-form";
import type { OfferingKind, PublicOfferingItem } from "@/lib/graphql/events";
import {
	ENROLLMENT_POLICY_LABEL,
	OFFERING_LABEL,
	VISIBILITY_LABEL,
} from "@/lib/graphql/events";
import EventStatusTag from "@/components/event-status-tag";
import { formatDeadline } from "@/lib/events";

interface DetailState {
	id: string;
	row: PublicOfferingItem | null;
	error: string | null;
}

export default function PublicOfferingDetailPage({ kind }: { kind: OfferingKind }) {
	const params = useParams<{ slug: string }>();
	const slug = params?.slug ?? "";
	const router = useRouter();
	const { authed, userId } = useAuthed();

	const [state, setState] = useState<DetailState>({ id: "", row: null, error: null });
	const [inviteCode, setInviteCode] = useState("");
	const [busy, setBusy] = useState(false);
	const [submitState, setSubmitState] = useState<{
		kind: "idle" | "confirmed" | "pending" | "error";
		message: string | null;
	}>({ kind: "idle", message: null });

	useEffect(() => {
		if (!slug) return;
		let cancelled = false;

		fetchPublicOffering(slug, kind)
			.then((row) => {
				if (!cancelled) setState({ id: slug, row, error: null });
			})
			.catch((e: unknown) => {
				if (!cancelled) {
					setState({
						id: slug,
						row: null,
						error: e instanceof Error ? e.message : "加载失败",
					});
				}
			});

		return () => {
			cancelled = true;
		};
	}, [slug, kind]);

	const stale = state.id !== slug;
	const offering = stale ? null : state.row;
	const loadError = stale ? null : state.error;
	const label = OFFERING_LABEL[kind];
	const listHref = kind === "event" ? "/events" : "/courses";

	// E-3 #48 赞助入口（仅 event；enabled + tiers 已配才显示，对齐 E-5 readiness ②）
	const sponsorshipTiers = offering
		? parseSponsorshipTiers(offering.sponsorshipTiers)
		: [];
	const sponsorshipOpen =
		kind === "event" &&
		offering !== null &&
		offering.sponsorshipEnabled === true &&
		sponsorshipTiers.length > 0;

	async function submit() {
		if (!offering || !authed || !userId) return;
		setBusy(true);
		setSubmitState({ kind: "idle", message: null });
		try {
			const res = await submitEnrollment({
				eventId: kind === "event" ? offering.id : undefined,
				courseId: kind === "course" ? offering.id : undefined,
				userId,
				inviteCode: inviteCode === "" ? null : inviteCode,
			});
			if (res.result) {
				const pending = res.result.status === "pending";
				setSubmitState({
					kind: pending ? "pending" : "confirmed",
					message: pending ? "申请已提交，等待审批" : "报名成功",
				});
				if (!pending) router.refresh();
			} else {
				setSubmitState({
					kind: "error",
					message: res.errors[0]?.message ?? "提交失败",
				});
			}
		} catch (e: unknown) {
			setSubmitState({
				kind: "error",
				message: e instanceof Error ? e.message : "提交失败",
			});
		} finally {
			setBusy(false);
		}
	}

	return (
		<main className="mx-auto w-full max-w-3xl px-4 py-10">
			<header className="mb-6">
				<p className="text-[13px] text-ink-3">
					<Link href="/" className="hover:text-ink">
						工作台
					</Link>
					{" › "}
					<Link href={listHref} className="hover:text-ink">
						{label}
					</Link>
					{" › "}
					<strong>{offering?.title ?? "详情"}</strong>
				</p>
			</header>

			{loadError ? (
				<div className="join-card" role="alert">
					加载失败：{loadError}
				</div>
			) : stale ? (
				<div className="h-56 animate-pulse rounded-large bg-soft-2 ring-1 ring-line" />
			) : offering === null ? (
				<div className="join-card text-center">
					<h1 className="text-lg font-medium">该{label}不可访问</h1>
					<p className="mt-2 text-sm text-ink-3">
						仅工作台内部可见，或已结束。请登录后从工作台内访问。
					</p>
				</div>
			) : (
				<>
					<div className="join-card !p-8">
						<p className="flex items-center gap-2">
							<EventStatusTag status={offering.status} />
							<span className="text-[13px] text-ink-3">
								{VISIBILITY_LABEL[offering.visibility]}
							</span>
						</p>
						<h1 className="mt-3 text-2xl font-semibold">{offering.title}</h1>
						<div className="mt-4 grid gap-2 text-sm text-ink-3">
							<span>报名策略：{ENROLLMENT_POLICY_LABEL[offering.enrollmentPolicy]}</span>
							<span>报名截止：{formatDeadline(offering.registrationDeadline)}</span>
							{offering.description ? (
								<p className="mt-3 whitespace-pre-wrap text-sm text-ink-3">
									{offering.description}
								</p>
							) : null}
						</div>

						<div className="mt-6 border-t border-line pt-5">
							{!authed ? (
								<div className="text-sm">
									<Link
										href={`/login?next=${encodeURIComponent(`/${kind === "event" ? "events" : "courses"}/${offering.slug}`)}`}
										className="join-button join-button--primary inline-block"
									>
										登录后报名
									</Link>
									<p className="mt-2 text-[13px] text-ink-3">
										报名免费，登录或注册后提交（J-Visitor → J-Learner）。
									</p>
								</div>
							) : submitState.kind === "confirmed" ||
							  submitState.kind === "pending" ? (
								<div className="text-sm" role="status">
									<p className="font-medium">
										{submitState.kind === "confirmed" ? "✓ 报名成功" : "✓ 申请已提交"}
									</p>
									<p className="mt-1 text-[13px] text-ink-3">{submitState.message}</p>
									<Link href="/participations" className="mt-3 inline-block text-[13px] text-accent hover:underline">
										在「我的参与」查看报名状态
									</Link>
								</div>
							) : (
								<div className="grid gap-3">
									{offering.enrollmentPolicy === "invite_only" ? (
										<label className="block">
											<span className="block text-[13px] text-ink-3">
												邀请码（必填）
											</span>
											<input
												value={inviteCode}
												onChange={(e) => setInviteCode(e.target.value)}
												className="mt-1 w-full rounded-large border border-line bg-soft-2 px-3 py-2 text-sm"
											/>
										</label>
									) : null}
									{offering.enrollmentPolicy === "request" ? (
										<p className="text-[13px] text-ink-3">
											提交后需 Owner/Admin 审批，通过后确认名额。
										</p>
									) : null}
									{submitState.kind === "error" ? (
										<p className="text-[13px] text-ink-3" role="alert">
											{submitState.message}
										</p>
									) : null}
									<button
										type="button"
										disabled={busy}
										onClick={() => void submit()}
										className="join-button join-button--primary justify-self-start"
									>
										{busy ? "提交中…" : "提交报名"}
									</button>
								</div>
							)}
						</div>
					</div>

					{sponsorshipOpen ? (
						<div className="join-card !p-8">
							<h2 className="text-lg font-semibold">赞助本场</h2>
							<p className="mt-1 text-[13px] text-ink-3">
								提交赞助意向，审批通过后权益生效（意向登记，不收款）。
							</p>
							<div className="mt-4 grid gap-2">
								{sponsorshipTiers.map((tier) => (
									<div
										key={tier.id}
										className="rounded-large border border-line bg-soft-2 p-3 text-sm"
									>
										<p className="flex items-center gap-2 font-medium">
											{tier.name}
											{tier.exclusive ? (
												<span className="rounded-full bg-amber-100 px-2 py-0.5 text-[11px] text-amber-800">
													独占位
												</span>
											) : null}
										</p>
										{tier.amountSuggestion ? (
											<p className="mt-0.5 text-[13px] text-ink-3">
												建议金额 ¥{tier.amountSuggestion}
											</p>
										) : null}
										{tier.benefits.length > 0 ? (
											<p className="mt-0.5 text-[13px] text-ink-3">
												权益：{tier.benefits.join(" / ")}
											</p>
										) : null}
									</div>
								))}
							</div>
							<div className="mt-5 border-t border-line pt-5">
								{!authed ? (
									<div className="text-sm">
										<Link
											href={`/login?next=${encodeURIComponent(`/events/${offering.slug}`)}`}
											className="join-button join-button--primary inline-block"
										>
											登录后赞助
										</Link>
										<p className="mt-2 text-[13px] text-ink-3">
											赞助需登录全局账号（不自动成为工作台成员）。
										</p>
									</div>
								) : userId ? (
									<SponsorshipIntentForm
										eventId={offering.id}
										sponsorUserId={userId}
										tiers={sponsorshipTiers}
									/>
								) : null}
							</div>
						</div>
					) : null}
				</>
			)}
		</main>
	);
}
