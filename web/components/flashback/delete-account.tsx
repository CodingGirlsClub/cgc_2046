"use client";

import { useEffect, useState } from "react";
import { useTranslations } from "next-intl";
import { client } from "@/lib/apollo-client";
import { FLASHBACK_DELETE, FLASHBACK_DELETE_PREVIEW } from "@/lib/graphql/flashback";

/** 与 capsule-view 同 key：删除成功后清掉 session 内 token（KTD2 失效落地） */
const TOKEN_STORAGE_KEY = "flashback.token";
const CONFIRM_WORD = "DELETE";

/**
 * 「删除我的档案」通道（U10/R30/ADR-0015）：
 * 两步确认——先拉摘要（将失去什么：寄出态/附议数），用户输入 DELETE 才提交；
 * 不可逆。删除成功后展示「数据已清除」终态并清 token。
 * 免注册（token 或登录态，链接即身份——R30「不为行使删除权设注册门槛」）。
 */
export default function DeleteAccount({ token }: { token: string | null }) {
	const t = useTranslations("flashback.delete");
	const [open, setOpen] = useState(false);
	const [preview, setPreview] = useState<{
		fullName: string;
		sentToWallAt?: string | null;
		endorsementCount: number;
	} | null>(null);
	const [confirmInput, setConfirmInput] = useState("");
	const [busy, setBusy] = useState(false);
	const [done, setDone] = useState(false);
	const [error, setError] = useState(false);

	useEffect(() => {
		if (!open || preview || done) return;
		client
			.query({ query: FLASHBACK_DELETE_PREVIEW, variables: { token }, fetchPolicy: "network-only" })
			.then(({ data }) => {
				const row = data?.flashbackDeletePreview;
				if (row) setPreview({ fullName: row.fullName, sentToWallAt: row.sentToWallAt, endorsementCount: row.endorsementCount });
			})
			.catch(() => setError(true));
	}, [open, preview, done, token]);

	const submit = async () => {
		if (busy || confirmInput !== CONFIRM_WORD) return;
		setBusy(true);
		try {
			const { data } = await client.mutate({
				mutation: FLASHBACK_DELETE,
				variables: { token, confirm: CONFIRM_WORD },
			});
			if (data?.flashbackDelete?.deleted) {
				window.sessionStorage.removeItem(TOKEN_STORAGE_KEY);
				// 胶囊查询缓存整体失效（本档案的一切读面）
				void client.cache.evict({ fieldName: "flashbackCapsule" });
				setDone(true);
			} else {
				setError(true);
			}
		} catch {
			setError(true);
		} finally {
			setBusy(false);
		}
	};

	if (done) {
		return (
			<section className="fb-delete" aria-label={t("title")} data-testid="fb-delete-done">
				<h3 className="fb-delete-title">{t("doneTitle")}</h3>
				<p className="fb-hint">{t("doneBody")}</p>
			</section>
		);
	}

	if (!open) {
		return (
			<section className="fb-delete">
				<button type="button" className="fb-delete-open" onClick={() => setOpen(true)}>
					{t("title")}
				</button>
			</section>
		);
	}

	return (
		<section className="fb-delete fb-delete-open-panel" aria-label={t("title")}>
			<h3 className="fb-delete-title">{t("title")}</h3>
			<p className="fb-hint">{t("warning")}</p>
			{error && (
				<p className="fb-hint" role="alert">
					{t("error")}
				</p>
			)}
			{preview && (
				<ul className="fb-delete-facts">
					<li>{t("factsName", { name: preview.fullName })}</li>
					<li>
						{preview.sentToWallAt
							? t("factsOnWall", { count: preview.endorsementCount })
							: t("factsOffWall", { count: preview.endorsementCount })}
					</li>
				</ul>
			)}
			<label className="fb-delete-label" htmlFor="fb-delete-confirm">
				{t("confirmLabel")}
			</label>
			<input
				id="fb-delete-confirm"
				className="fb-delete-input"
				value={confirmInput}
				onChange={(event) => setConfirmInput(event.target.value)}
				autoComplete="off"
				spellCheck={false}
				data-testid="fb-delete-confirm-input"
			/>
			<div className="fb-delete-actions">
				<button
					type="button"
					className="fb-delete-submit"
					disabled={busy || confirmInput !== CONFIRM_WORD}
					onClick={() => void submit()}
					data-testid="fb-delete-submit"
				>
					{t("submit")}
				</button>
				<button type="button" className="fb-delete-cancel" onClick={() => setOpen(false)} disabled={busy}>
					{t("cancel")}
				</button>
			</div>
		</section>
	);
}
