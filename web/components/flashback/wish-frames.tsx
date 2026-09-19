"use client";

import { useState } from "react";
import { useTranslations } from "next-intl";
import { useMutation } from "@apollo/client/react";
import { Link } from "@/i18n/navigation";
import type { FlashbackFutureFrame, FlashbackWish } from "@/lib/graphql/flashback";
import {
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
	token,
	onChanged,
}: {
	publicWishes: FlashbackWish[];
	myPrivateWishes: FlashbackWish[];
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
	// 留言立刻上墙、附议立刻翻「已附议」态（用户 UAT 反馈 ②③）
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
				<WishFormModal token={token} busy={busy} onClose={() => setModal({ kind: "closed" })} onDone={onChanged} />
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

function WishFormModal({
	token,
	busy,
	onClose,
	onDone,
}: {
	token: string | null;
	busy: boolean;
	onClose: () => void;
	onDone: () => void;
}) {
	const t = useTranslations("flashback.wish");
	const [content, setContent] = useState("");
	const [visibility, setVisibility] = useState<"private" | "public">("public");
	const [createWish, { loading }] = useMutation(FLASHBACK_CREATE_WISH);

	const submit = async () => {
		const trimmed = content.trim();
		if (!trimmed || loading || busy) return;
		try {
			await createWish({ variables: { token, content: trimmed, visibility } });
			onDone();
			onClose();
		} catch {
			// 静默
		}
	};

	return (
		<div className="fb-wish-modal-layer" onClick={onClose} role="presentation">
			<div className="fb-wish-modal" onClick={(e) => e.stopPropagation()} role="dialog" aria-label={t("makeWish")}>
				<h4 className="fb-wish-modal-title">{t("makeWish")}</h4>
				<textarea
					className="fb-wish-modal-textarea"
					value={content}
					maxLength={500}
					placeholder={t("formPlaceholder")}
					onChange={(e) => setContent(e.target.value)}
				/>
				<div className="fb-wish-modal-radios" role="radiogroup" aria-label={t("visibilityLabel")}>
					<label>
						<input
							type="radio"
							name="wish-visibility"
							checked={visibility === "private"}
							onChange={() => setVisibility("private")}
						/>{" "}
						{t("visibilityPrivate")}
					</label>
					<label>
						<input
							type="radio"
							name="wish-visibility"
							checked={visibility === "public"}
							onChange={() => setVisibility("public")}
						/>{" "}
						{t("visibilityPublic")}
					</label>
				</div>
				<div className="fb-wish-modal-actions">
					<button type="button" className="fb-wish-modal-submit" disabled={loading || busy} onClick={() => void submit()}>
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
