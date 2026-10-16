"use client";

/**
 * 对话栏的「已配对的电脑」（R5、R30）：本账号有效的学习凭证，一台电脑一枚；终端 token 与已失效的不列。
 * 按 Host 上报的凭证记录 id（status.tokenId）标出本机这台；撤销两步确认（同 MCP 设置页），
 * 撤销本机这台之后交给 useHostPairing 的 forget 回到未配对。
 */

import { useEffect, useId, useState } from "react";
import { useTranslations } from "next-intl";
import { formatDateTime } from "@/lib/format";
import { fetchMyMcpTokens, revokeMcpToken, type McpTokenItem } from "@/lib/mcp";

const SECONDARY_BUTTON =
	"rounded-large border border-line px-3 py-1.5 text-sm text-ink-2 hover:bg-soft-2 disabled:opacity-60";

export default function HostPairingList({
	currentTokenId,
	onRevokeCurrent,
}: {
	/** status.tokenId：本机 Host 所持学习凭证的记录 id；没连上 Host 或本机未配对时为 null */
	currentTokenId: string | null;
	/** 撤销的正是本机这台时调用（useHostPairing().forget） */
	onRevokeCurrent: () => void;
}) {
	const t = useTranslations("hostPairing");
	const titleId = useId();
	/** null = 加载中 */
	const [computers, setComputers] = useState<McpTokenItem[] | null>(null);
	const [loadFailed, setLoadFailed] = useState(false);
	const [reloads, setReloads] = useState(0);
	const [confirmId, setConfirmId] = useState<string | null>(null);
	const [revokingId, setRevokingId] = useState<string | null>(null);
	const [feedback, setFeedback] = useState<string | null>(null);

	// 本机的配对一变（配对完成、被撤销）就重拉：新签发的那枚要出现，本机这台的标记要跟上
	useEffect(() => {
		let cancelled = false;
		fetchMyMcpTokens()
			.then((tokens) => {
				if (cancelled) return;
				setComputers(tokens.filter((token) => token.kind === "LEARNING_HOST" && token.status === "active"));
				setLoadFailed(false);
			})
			.catch(() => {
				if (!cancelled) setLoadFailed(true);
			});
		return () => {
			cancelled = true;
		};
	}, [currentTokenId, reloads]);

	function retry() {
		setLoadFailed(false);
		setComputers(null);
		setReloads((n) => n + 1);
	}

	async function revoke(computer: McpTokenItem) {
		setRevokingId(computer.id);
		setFeedback(null);
		try {
			await revokeMcpToken(computer.id);
			setComputers((list) => list?.filter((c) => c.id !== computer.id) ?? null);
			setFeedback(t("revoked", { name: computer.name }));
			if (computer.id === currentTokenId) onRevokeCurrent();
		} catch {
			setFeedback(t("revokeFailed"));
		} finally {
			setRevokingId(null);
			setConfirmId(null);
		}
	}

	return (
		<section aria-labelledby={titleId} className="grid gap-2">
			<h3 id={titleId} className="text-sm font-medium text-ink-2">
				{t("title")}
			</h3>

			{loadFailed ? (
				<div className="flex flex-wrap items-center gap-2">
					<p role="alert" className="text-sm text-ink-3">
						{t("loadFailed")}
					</p>
					<button type="button" onClick={retry} className={SECONDARY_BUTTON}>
						{t("retry")}
					</button>
				</div>
			) : computers === null ? (
				<p className="text-[13px] text-ink-3">{t("loading")}</p>
			) : computers.length === 0 ? (
				<p className="text-[13px] text-ink-3">{t("empty")}</p>
			) : (
				<ul className="overflow-hidden rounded-large border border-line">
					{computers.map((computer) => {
						const revoking = revokingId === computer.id;
						return (
							<li
								key={computer.id}
								className="flex flex-wrap items-center justify-between gap-2 border-b border-line px-3 py-2 last:border-b-0"
							>
								<div className="min-w-0">
									<p className="flex flex-wrap items-center gap-2 text-sm text-ink">
										<span>{computer.name}</span>
										{computer.id === currentTokenId ? (
											<span className="rounded-full border border-line-strong px-2 py-0.5 text-[11px] text-ink-2">
												{t("thisComputer")}
											</span>
										) : null}
									</p>
									<p className="text-[12px] text-ink-3">
										{t("lastUsed", { time: formatDateTime(computer.lastUsedAt) })}
									</p>
								</div>
								{confirmId === computer.id ? (
									<div className="flex gap-2">
										{/* 确认按钮出现即取得焦点：键盘回车就能完成这一步 */}
										<button
											type="button"
											autoFocus
											disabled={revoking}
											aria-label={t("confirmRevokeLabel", { name: computer.name })}
											onClick={() => void revoke(computer)}
											className="join-button join-button--primary"
										>
											{revoking ? t("revoking") : t("confirmRevoke")}
										</button>
										<button
											type="button"
											disabled={revoking}
											onClick={() => setConfirmId(null)}
											className={SECONDARY_BUTTON}
										>
											{t("cancel")}
										</button>
									</div>
								) : (
									<button
										type="button"
										aria-label={t("revokeLabel", { name: computer.name })}
										onClick={() => setConfirmId(computer.id)}
										className={SECONDARY_BUTTON}
									>
										{t("revoke")}
									</button>
								)}
							</li>
						);
					})}
				</ul>
			)}

			<p role="status" className="text-[13px] text-ink-3">
				{feedback}
			</p>
		</section>
	);
}
