"use client";

import { useEffect, useState } from "react";
import type { TypedDocumentNode } from "@apollo/client";
import { useTranslations } from "next-intl";
import { Link } from "@/i18n/navigation";
import { useAuthed } from "@/lib/auth-provider";
import { client } from "@/lib/apollo-client";
import FlashbackNav from "@/components/flashback/flashback-nav";
import { useDialogA11y } from "@/components/modal-a11y";
import {
	FLASHBACK_DELETE_WISH,
	FLASHBACK_MY_WISHES,
	type FlashbackOwnedWish,
} from "@/lib/graphql/flashback";

const STATUS_KEYS: Record<string, string> = {
	listed: "statusListed",
	pending_review: "statusPendingReview",
	private: "statusPrivate",
};

/**
 * 我的愿望（M11，对齐小程序 flashback-my-wishes）：登录即可、无历史档案也可用。
 * 状态、年度剩余名额（删除不退还）、删除二次确认；listed 可回公开树看。
 */
export default function MyWishesView() {
	const t = useTranslations("flashback.myWishes");
	const { authed } = useAuthed();

	if (!authed) {
		return (
			<main className="fb-stage fb-stage-pad" data-testid="fb-my-wishes-login">
				<p className="fb-lead">{t("login")}</p>
				<p className="fb-quotes-wall-cta">
					<Link href="/login?next=%2Fflashback%2Fwishes%2Fmine">{t("login")}</Link>
				</p>
				<p className="fb-hint">
					<Link href="/flashback/wishes">{t("backToWall")}</Link>
				</p>
			</main>
		);
	}
	return <MyWishes />;
}

function MyWishes() {
	const t = useTranslations("flashback.myWishes");
	const [data, setData] = useState<{ quotaRemaining: number; wishes: FlashbackOwnedWish[] } | null>(null);
	const [loadState, setLoadState] = useState<"loading" | "ready" | "failed">("loading");
	const [confirmFor, setConfirmFor] = useState<FlashbackOwnedWish | null>(null);
	const [notice, setNotice] = useState("");

	const load = async () => {
		try {
			const { data: result } = await client.query({
				query: FLASHBACK_MY_WISHES,
				fetchPolicy: "network-only",
			});
			setData(result?.flashbackMyWishes ?? { quotaRemaining: 0, wishes: [] });
			setLoadState("ready");
		} catch {
			setLoadState("failed");
		}
	};

	useEffect(() => {
		// microtask 包裹避开 effect 内同步 setState（react-hooks/set-state-in-effect），同 capsule-view 先例
		Promise.resolve().then(() => void load());
	}, []);

	const onDeleted = () => {
		setConfirmFor(null);
		setNotice(t("deleted"));
		void load();
	};

	return (
		<>
			<FlashbackNav active="wishes" />
			<main className="fb-stage fb-stage-pad" data-testid="fb-my-wishes">
				<h1 className="fb-stage-title">{t("title")}</h1>
				{loadState === "loading" && <p role="status">{t("loading")}</p>}
				{loadState === "failed" && (
					<p role="alert" className="fb-hint">
						{t("error")}{" "}
						<button type="button" onClick={() => void load()}>
							{t("retry")}
						</button>
					</p>
				)}
				{loadState === "ready" && data && (
					<>
						<p className="fb-hint" data-testid="fb-my-wishes-quota">
							{t("quota", { count: data.quotaRemaining })}
						</p>
						{notice && (
							<p role="status" className="fb-hint">
								{notice}
							</p>
						)}
						{data.wishes.length === 0 ? (
							<p className="fb-lead">
								{t("empty")}{" "}
								<Link href="/flashback/wishes">
									{t("writeWish")}
								</Link>
							</p>
						) : (
							<ul className="fb-my-wishes">
								{data.wishes.map((wish) => (
									<li key={wish.id} data-wish-id={wish.id}>
										<p className="fb-lead">{wish.content}</p>
										<p className="fb-hint">
											{wish.signature}
											{wish.city ? ` · ${wish.city}` : ""}
										</p>
										<p className="fb-hint">
											<span data-testid="fb-my-wish-status">{t(STATUS_KEYS[wish.status] ?? "statusPendingReview")}</span>
											{wish.status === "listed" && (
												<>
													{" · "}
													<Link href={`/flashback/wishes?item=${encodeURIComponent(wish.id)}`}>{t("viewOnTree")}</Link>
												</>
											)}
										</p>
										<button type="button" className="fb-cta" onClick={() => setConfirmFor(wish)}>
											{t("delete")}
										</button>
									</li>
								))}
							</ul>
						)}
					</>
				)}
				{confirmFor && (
					<DeleteConfirm
						wish={confirmFor}
						onClose={() => setConfirmFor(null)}
						onDeleted={onDeleted}
					/>
				)}
			</main>
		</>
	);
}

function DeleteConfirm({
	wish,
	onClose,
	onDeleted,
}: {
	wish: FlashbackOwnedWish;
	onClose: () => void;
	onDeleted: () => void;
}) {
	const t = useTranslations("flashback.myWishes");
	const { dialogRef, handleKeyDown } = useDialogA11y(onClose);
	const [busy, setBusy] = useState(false);
	const [error, setError] = useState(false);

	const del = async () => {
		if (busy) return;
		setBusy(true);
		setError(false);
		try {
			const { data } = await client.mutate({
				// FLASHBACK_DELETE_WISH 文档未带 TypedDocumentNode 泛型，这里显式窄化
				mutation: FLASHBACK_DELETE_WISH as TypedDocumentNode<{ flashbackDeleteWish: boolean }, { wishId: string }>,
				variables: { wishId: wish.id },
			});
			if (data?.flashbackDeleteWish) onDeleted();
			else setError(true);
		} catch {
			setError(true);
		} finally {
			setBusy(false);
		}
	};

	return (
		<div className="fb-send-overlay" onKeyDown={handleKeyDown}>
			<div
				role="dialog"
				aria-modal="true"
				aria-labelledby="fb-my-wish-delete-title"
				tabIndex={-1}
				ref={dialogRef}
				data-testid="fb-my-wish-delete-dialog"
				className="fb-send-step fb-today-dialog"
			>
				<h3 id="fb-my-wish-delete-title" className="fb-send-title">
					{t("deleteTitle")}
				</h3>
				<p className="fb-lead">{wish.content}</p>
				<p className="fb-hint">{t("deleteBody")}</p>
				{error && (
					<p role="alert" className="fb-hint">
						{t("error")}
					</p>
				)}
				<button type="button" className="fb-cta fb-cta-primary" disabled={busy} onClick={() => void del()}>
					{t("confirmDelete")}
				</button>
				<button type="button" className="fb-cta" disabled={busy} onClick={onClose}>
					{t("cancel")}
				</button>
			</div>
		</div>
	);
}
