"use client";

import { useEffect, useMemo, useState } from "react";
import { useTranslations } from "next-intl";
import { useMutation } from "@apollo/client/react";
import { Link } from "@/i18n/navigation";
import { client } from "@/lib/apollo-client";
import { graphqlErrorDetails } from "@/lib/graphql/auth";
import { usePaymentErrorTranslator } from "@/lib/payment-errors";
import type { FlashbackFutureFrame, FlashbackWish } from "@/lib/graphql/flashback";
import {
	FLASHBACK_CITIES,
	FLASHBACK_CREATE_WISH,
	FLASHBACK_ENDORSE_WISH,
	FLASHBACK_ADD_WISH_COMMENT,
	FLASHBACK_DELETE_WISH,
} from "@/lib/graphql/flashback";
/**
 * 许愿卡与模态（U7/版 D 定稿）：纸白卡（附议 +1 / 留言 / 已附议态）；
 * 点卡开模态——许愿全文 + 留言流 + 附议按钮 + 本人删除（R14）；「+ 许个愿」
 * 开表单模态（私有/公开二选一，R6）。报名型模态在 WishEventCard 内联。
 * 群星显影（KTD7）由 corridor 传入 --fb-d。
 */

type WishFormKind = { kind: "closed" } | { kind: "form" } | { kind: "wish"; wishId: string };

export function WishFrames({
	publicWishes,
	myPrivateWishes,
	myWishQuotaRemaining,
	token,
	onChanged,
}: {
	publicWishes: FlashbackWish[];
	myPrivateWishes: FlashbackWish[];
	/** 本人今年剩余许愿条数（未登录为 null，表单模态不显示额度行） */
	myWishQuotaRemaining: number | null;
	token: string | null;
	onChanged: () => void;
}) {
	const t = useTranslations("flashback.wish");
	const [modal, setModal] = useState<WishFormKind>({ kind: "closed" });
	const [busy, setBusy] = useState(false);

	const [endorse] = useMutation(FLASHBACK_ENDORSE_WISH);
	const [comment] = useMutation(FLASHBACK_ADD_WISH_COMMENT);
	const [deleteWish] = useMutation(FLASHBACK_DELETE_WISH);

	const run = async (fn: () => Promise<unknown>) => {
		if (busy) return;
		setBusy(true);
		try {
			await fn();
			onChanged();
		} catch {
			// 失败静默：下一帧 reload 校正
		} finally {
			setBusy(false);
		}
	};

	// 模态持有 id 而非快照：附议/留言触发 reload 后，每次渲染从最新 props 解析——
	// 留言立刻上墙、附议立刻翻「已附议」态
	const resolveWish = (wishId: string): FlashbackWish | null =>
		publicWishes.find((w) => w.id === wishId) ??
		myPrivateWishes.find((w) => w.id === wishId) ??
		null;

	return (
		<>
			<article className="fb-corridor-frame fb-future-frame">
				<h3 className="fb-corridor-when fb-corridor-when--future">
					{t("publicTitle")}
					<span className="fb-corridor-flabel">{t("publicLabel")}</span>
				</h3>
				<ul className="fb-wish-list">
					{publicWishes.length === 0 && (
						<li className="fb-wish-empty">
							<span className="fb-wish-blank-card" onClick={() => setModal({ kind: "form" })}>
								{t("empty")}
							</span>
						</li>
					)}
					{publicWishes.map((wish, i) => (
						<li key={wish.id}>
							<div
								className="fb-wish-card fb-develop-soft"
								style={{ "--fb-d": `${(i % 5) * 0.3}s` } as React.CSSProperties}
								onClick={() => setModal({ kind: "wish", wishId: wish.id })}
							>
								<p className="fb-wish-content">{wish.content}</p>
								<p className="fb-wish-meta">
									{wish.wisherMasked} · {t("endorsed", { count: wish.endorsementCount })}
								</p>
								{wish.endorsedByMe ? (
									<span className="fb-wish-endorsed">{t("endorsedByMe")}</span>
								) : (
									<button
										type="button"
										className="fb-wish-endorse-btn"
										disabled={busy}
										onClick={(e) => {
											e.stopPropagation();
											void run(() => endorse({ variables: { token, wishId: wish.id } }));
										}}
									>
										{t("endorse")}
									</button>
								)}
							</div>
						</li>
					))}
				</ul>
				<button type="button" className="fb-wish-add" onClick={() => setModal({ kind: "form" })}>
					+ {t("makeWish")}
				</button>
			</article>

			{myPrivateWishes.length > 0 && (
				<article className="fb-corridor-frame fb-future-frame fb-private-frame">
					<h3 className="fb-corridor-when fb-corridor-when--future">
						{t("privateTitle")}
						<span className="fb-corridor-flabel">{t("privateLabel")}</span>
					</h3>
					<ul className="fb-wish-list">
											{myPrivateWishes.map((wish) => (
						<li key={wish.id}>
							<div
								className="fb-wish-card fb-wish-card--private"
								onClick={() => setModal({ kind: "wish", wishId: wish.id })}
							>
									<p className="fb-wish-content">{wish.content}</p>
									<p className="fb-wish-meta">{t("privateMark")}</p>
								</div>
							</li>
						))}
					</ul>
					<button type="button" className="fb-wish-add" onClick={() => setModal({ kind: "form" })}>
						+ {t("makeWish")}
					</button>
				</article>
			)}

			{modal.kind === "form" && (
				<WishFormModal
					token={token}
					busy={busy}
					myWishQuotaRemaining={myWishQuotaRemaining}
					onClose={() => setModal({ kind: "closed" })}
					onDone={() => onChanged()}
				/>
			)}
			{modal.kind === "wish" &&
				resolveWish(modal.wishId) && (
					<WishModal
						wish={resolveWish(modal.wishId) as FlashbackWish}
						token={token}
						busy={busy}
						onClose={() => setModal({ kind: "closed" })}
						onEndorse={(wishId) => run(() => endorse({ variables: { token, wishId } }))}
						onComment={(wishId, content) => run(() => comment({ variables: { token, wishId, content } }))}
						onDelete={(wishId) => run(() => deleteWish({ variables: { token, wishId } }))}
					/>
				)}
		</>
	);
}

/** 提交结果三态（R18）：listed=挂树 / pending_review=信用待审 / private=说给主办方听 */
export interface WishSubmitOutcome {
	wishId: string;
	status: "listed" | "pending_review" | "private";
	city: string | null;
}
export function WishFormModal({
	token,
	busy,
	myWishQuotaRemaining,
	onClose,
	onDone,
}: {
	token: string | null;
	busy: boolean;
	myWishQuotaRemaining: number | null;
	onClose: () => void;
	/** 提交成功（含三态）与额度被拒（refetch）都会触发；outcome 为 null 表示仅 refetch */
	onDone: (outcome: WishSubmitOutcome | null) => void;
}) {
	const t = useTranslations("flashback.wish");
	const tErrors = useTranslations("errors");
	const errorT = usePaymentErrorTranslator();
	const [content, setContent] = useState("");
	// wish2 U8：默认公开档（R6 定稿——公开是主路径）；公开档选中即授权挂树
	const [visibility, setVisibility] = useState<"private" | "public">("public");
	const [signatureChoice, setSignatureChoice] = useState<"anonymous" | "display_name">("anonymous");
	const [expectedCity, setExpectedCity] = useState("");
	const [error, setError] = useState<string | null>(null);
	const [outcome, setOutcome] = useState<WishSubmitOutcome | null>(null);
	const [withdrawn, setWithdrawn] = useState(false);
	const [cities, setCities] = useState<string[]>([]);
	const [createWish, { loading }] = useMutation(FLASHBACK_CREATE_WISH);
	const [deleteWish] = useMutation(FLASHBACK_DELETE_WISH);

	const quotaExhausted = myWishQuotaRemaining === 0;

	// 期望地候选名单（KTD11 真源 flashbackCities；modal 打开拉一次）
	useEffect(() => {
		client
			.query({ query: FLASHBACK_CITIES, fetchPolicy: "cache-first" })
			.then(({ data }) => setCities((data?.flashbackCities ?? []).map((c) => c.name)))
			.catch(() => setCities([]));
	}, []);

	// 前缀/包含匹配的候选（≤6；空输入不提示）
	const cityCandidates = useMemo(() => {
		const query = expectedCity.trim();
		if (!query || cities.length === 0) return [];
		return cities.filter((name) => name.includes(query) && name !== query).slice(0, 6);
	}, [expectedCity, cities]);

	const submit = async () => {
		const trimmed = content.trim();
		if (!trimmed || loading || busy || quotaExhausted) return;
		setError(null);
		try {
			const { data } = await createWish({
				variables: {
					token,
					content: trimmed,
					visibility,
					signatureChoice,
					expectedCity: expectedCity.trim() || null,
					// 公开档选中即授权（R6）：private 档恒 false
					publicListingConsent: visibility === "public",
				},
			});
			const result = data?.flashbackCreateWish;
			const status = result?.status;
			if (!result?.id || (status !== "listed" && status !== "pending_review" && status !== "private")) {
				throw new Error("unexpected response");
			}
			const done: WishSubmitOutcome = {
				wishId: result.id,
				status,
				city: expectedCity.trim() || null,
			};
			setOutcome(done);
			onDone(done);
		} catch (e) {
			// 业务错误（quota_exceeded / content_rejected / city_unknown）按 code 映射
			// errors 文案；无 code / 未知 code 兜底 database_error（错误文案纪律）
			const detail = graphqlErrorDetails(e);
			setError(errorT(detail?.code, tErrors("database_error")));
			// 额度被拒即触发胶囊 refetch（F2）：refetch 完成后 prop 变 0 → 额度行变
			// 用完文案 + 提交禁用；模态保持打开
			if (detail?.code === "flashback_wish_quota_exceeded") onDone(null);
		}
	};

	// 撤回（R18）：提交反馈处即可收回——公开面（含 item 直达）立即不可见
	const withdraw = async () => {
		if (!outcome || withdrawn) return;
		try {
			await deleteWish({ variables: { token, wishId: outcome.wishId } });
			setWithdrawn(true);
			onDone(null);
		} catch (e) {
			setError(errorT(graphqlErrorDetails(e)?.code, tErrors("database_error")));
		}
	};

	// 三态反馈视图（R18）：不关闭模态——反馈 + 「我的愿望」指引 + 撤回入口
	if (outcome) {
		return (
			<div className="fb-wish-modal-layer" onClick={onClose} role="presentation">
				<div className="fb-wish-modal" onClick={(e) => e.stopPropagation()} role="dialog" aria-label={t("makeWish")}>
					{withdrawn ? (
						<>
							<h4 className="fb-wish-modal-title">{t("withdrawnToast")}</h4>
							<p className="fb-wish-modal-quota">{t("myWishHint")}</p>
						</>
					) : outcome.status === "listed" ? (
						<>
							<h4 className="fb-wish-modal-title">{t("feedbackListedTitle")}</h4>
							<p className="fb-wish-modal-quota">{t("feedbackListedBody")}</p>
						</>
					) : outcome.status === "pending_review" ? (
						<>
							<h4 className="fb-wish-modal-title">{t("feedbackPendingTitle")}</h4>
							<p className="fb-wish-modal-quota">{t("feedbackPendingBody")}</p>
						</>
					) : (
						<>
							<h4 className="fb-wish-modal-title">{t("feedbackPrivateTitle")}</h4>
							<p className="fb-wish-modal-quota">{t("feedbackPrivateBody")}</p>
						</>
					)}
					{!withdrawn && (
						<p className="fb-wish-modal-quota">
							{t("myWishHint")}
							{outcome.status === "listed" && (
								<>
									{" "}
									<Link href={`/flashback/wishes?item=${outcome.wishId}`}>{t("viewOnTree")}</Link>
								</>
							)}
						</p>
					)}
					<div className="fb-wish-modal-actions">
						{!withdrawn && (
							<button type="button" className="fb-wish-modal-cancel" onClick={() => void withdraw()}>
								{t("withdraw")}
							</button>
						)}
						<button type="button" className="fb-wish-modal-submit" onClick={onClose}>
							{t("close")}
						</button>
					</div>
				</div>
			</div>
		);
	}

	return (
		<div className="fb-wish-modal-layer" onClick={onClose} role="presentation">
			<div className="fb-wish-modal" onClick={(e) => e.stopPropagation()} role="dialog" aria-label={t("makeWish")}>
				<h4 className="fb-wish-modal-title">{t("makeWish")}</h4>
				{myWishQuotaRemaining !== null && (
					<p className="fb-wish-modal-quota">
						{quotaExhausted ? t("quotaExhausted") : t("quotaRemaining", { count: myWishQuotaRemaining })}
					</p>
				)}
				<textarea
					className="fb-wish-modal-textarea"
					value={content}
					maxLength={500}
					placeholder={t("formPlaceholder")}
					onChange={(e) => setContent(e.target.value)}
				/>
				<div className="fb-wish-modal-radios" role="radiogroup" aria-label={t("signatureLabel")}>
					<label>
						<input
							type="radio"
							name="wish-signature"
							checked={signatureChoice === "anonymous"}
							onChange={() => setSignatureChoice("anonymous")}
						/>{" "}
						{t("signatureAnonymous")}
					</label>
					<label>
						<input
							type="radio"
							name="wish-signature"
							checked={signatureChoice === "display_name"}
							onChange={() => setSignatureChoice("display_name")}
						/>{" "}
						{t("signatureDisplay")}
					</label>
				</div>
				<label className="fb-wish-city-field">
					<span className="fb-wish-city-label">{t("expectedCityLabel")}</span>
					<input
						type="text"
						value={expectedCity}
						maxLength={16}
						placeholder={t("expectedCityPlaceholder")}
						onChange={(e) => setExpectedCity(e.target.value)}
					/>
					{cityCandidates.length > 0 && (
						<p className="fb-wish-city-candidates">
							{t("cityCandidatesHint")}{" "}
							{cityCandidates.map((name, i) => (
								<span key={name}>
									{i > 0 && " · "}
									<button type="button" className="fb-wish-city-candidate" onClick={() => setExpectedCity(name)}>
										{name}
									</button>
								</span>
							))}
						</p>
					)}
				</label>
				<div className="fb-wish-modal-radios fb-wish-visibility" role="radiogroup" aria-label={t("visibilityLabel")}>
					<label className="fb-wish-visibility-option">
						<input
							type="radio"
							name="wish-visibility"
							checked={visibility === "public"}
							onChange={() => setVisibility("public")}
						/>{" "}
						<strong>{t("visibilityPublicBold")}</strong>
						<span className="fb-wish-visibility-hint">{t("visibilityPublicHint")}</span>
					</label>
					<label className="fb-wish-visibility-option">
						<input
							type="radio"
							name="wish-visibility"
							checked={visibility === "private"}
							onChange={() => setVisibility("private")}
						/>{" "}
						{t("visibilityPrivate")}
						<span className="fb-wish-visibility-hint">{t("visibilityPrivateHint")}</span>
					</label>
				</div>
				{error && (
					<p role="alert" className="fb-hint">
						{error}
					</p>
				)}
				<div className="fb-wish-modal-actions">
					<button
						type="button"
						className="fb-wish-modal-submit"
						disabled={loading || busy || quotaExhausted}
						onClick={() => void submit()}
					>
						{t("submit")}
					</button>
					<button type="button" className="fb-wish-modal-cancel" onClick={onClose}>
						{t("cancel")}
					</button>
				</div>
			</div>
		</div>
	);
}

function WishModal({
	wish,
	token,
	busy,
	onClose,
	onEndorse,
	onComment,
	onDelete,
}: {
	wish: FlashbackWish;
	token: string | null;
	busy: boolean;
	onClose: () => void;
	onEndorse: (wishId: string) => void;
	onComment: (wishId: string, content: string) => void;
	onDelete: (wishId: string) => void;
}) {
	const t = useTranslations("flashback.wish");
	const [draft, setDraft] = useState("");
	const [confirmingDelete, setConfirmingDelete] = useState(false);

	return (
		<div className="fb-wish-modal-layer" onClick={onClose} role="presentation">
			<div className="fb-wish-modal" onClick={(e) => e.stopPropagation()} role="dialog" aria-label={wish.content}>
				<button
					type="button"
					className="fb-wish-modal-close"
					aria-label={t("close")}
					onClick={onClose}
				>
					✕
				</button>
				<h4 className="fb-wish-modal-title">{wish.content}</h4>
				<p className="fb-wish-modal-meta">
					{wish.wisherMasked} · {t("endorsed", { count: wish.endorsementCount })}
				</p>
				<ul className="fb-wish-modal-comments">
					{wish.comments.map((c) => (
						<li key={c.id}>
							<span className="fb-wish-modal-commenter">{c.commenterMasked}</span>
							<span>{c.content}</span>
						</li>
					))}
				</ul>
				<textarea
					className="fb-wish-modal-textarea"
					value={draft}
					maxLength={500}
					placeholder={t("commentPlaceholder")}
					onChange={(e) => setDraft(e.target.value)}
				/>
				<div className="fb-wish-modal-actions">
					{wish.endorsedByMe ? (
						<span className="fb-wish-endorsed">{t("endorsedByMe")}</span>
					) : (
						<button
							type="button"
							className="fb-wish-endorse-btn"
							disabled={busy}
							onClick={() => onEndorse(wish.id)}
						>
							{t("endorse")}
						</button>
					)}
					<button
						type="button"
						className="fb-wish-modal-submit"
						disabled={busy || !draft.trim()}
						onClick={() => {
							onComment(wish.id, draft.trim());
							setDraft("");
						}}
					>
						{t("comment")}
					</button>
					{confirmingDelete ? (
						<>
							<span className="fb-wish-modal-confirm-text">{t("deleteConfirm")}</span>
							<button
								type="button"
								className="fb-wish-modal-delete"
								disabled={busy}
								onClick={() => {
									onDelete(wish.id);
									onClose();
								}}
							>
								{t("deleteYes")}
							</button>
							<button
								type="button"
								className="fb-wish-modal-cancel"
								onClick={() => setConfirmingDelete(false)}
							>
								{t("deleteNo")}
							</button>
						</>
					) : wish.mine ? (
						<button
							type="button"
							className="fb-wish-modal-delete"
							disabled={busy}
							onClick={() => setConfirmingDelete(true)}
						>
							{t("delete")}
						</button>
					) : null}
				</div>
			</div>
		</div>
	);
}

/** 场次帧（U7）：亮金可报名卡（满员/截止不出现 CTA，R2）+ 帧头 Initiative 直链（R1） */
export function FutureEventFrames({
	frames,
	hiddenWhenFiltered,
}: {
	frames: FlashbackFutureFrame[];
	hiddenWhenFiltered: boolean;
}) {
	const t = useTranslations("flashback.wish");

	return (
		<>
			{frames.map((frame, i) => {
				if (hiddenWhenFiltered && frame.events.length === 0) return null;
				return (
					<article key={frame.initiativeSlug} className="fb-corridor-frame fb-future-frame">
						<h3 className="fb-corridor-when fb-corridor-when--future">
							<Link href={`/initiatives/${frame.initiativeSlug}`} className="fb-future-initiative">
								{frame.initiativeName}
							</Link>
							<span className="fb-corridor-flabel">{t("futureLabel")}</span>
						</h3>
						<ul className="fb-future-list">
							{frame.events.map((event, j) => {
								const full = event.capacity !== null && event.confirmedCount >= event.capacity;
								const closed = event.registrationDeadline !== null && new Date(event.registrationDeadline) < new Date();
								const joinable = !full && !closed;
								return (
									<li key={event.id}>
										<div
											className={`fb-event-card${joinable ? " fb-event-card--lit" : ""} fb-develop-soft`}
											style={{ "--fb-d": `${((i + j) % 5) * 0.3}s` } as React.CSSProperties}
										>
											<p className="fb-event-title">{event.title}</p>
											<p className="fb-event-meta">
												{event.city} · {t("enrolled", { count: event.confirmedCount })}
												{event.startsAt ? ` · ${new Date(event.startsAt).toLocaleDateString()}` : ""}
											</p>
											{joinable ? (
												<Link href={`/events/${event.slug}`} className="fb-event-cta">
													{t("join")}
												</Link>
											) : (
												<span className="fb-event-note">{full ? t("full") : t("closed")}</span>
											)}
										</div>
									</li>
								);
							})}
						</ul>
					</article>
				);
			})}
		</>
	);
}
