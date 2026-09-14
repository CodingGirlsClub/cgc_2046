"use client";

/**
 * 连接 token 列表（U5 从 agents/mcp 页抽出，唯一实现）。
 *
 * 消费方（两处，同一 DOM 与两步确认语义）：
 * - 工作台集成页 `/w/[slug]/settings/integrations/agents/mcp`（含签发行）
 * - 用户级账号设置 `/settings/account/connections`（无工作台成员资格也可达的
 *   管理面；见 U5/KTD3）
 *
 * 纯展示 + 行内两步确认态：数据与撤销请求由消费方持有（fetch/错误/重试一处收口），
 * 本组件只负责「撤销 → 确认撤销」的确认门与徽章映射。
 */

import { useState } from "react";
import { useTranslations } from "next-intl";
import type { McpTokenItem } from "@/lib/mcp";
import { formatDateTime } from "@/lib/format";

export default function McpTokenList({
	tokens,
	revokingId,
	onRevoke,
}: {
	tokens: McpTokenItem[];
	/** 撤销进行中的 token id（禁用该行确认按钮） */
	revokingId: string | null;
	/** 确认撤销（消费方负责请求与列表更新；失败由消费方内联报错；resolve 后收起确认态） */
	onRevoke: (id: string) => Promise<void>;
}) {
	const t = useTranslations("workspaceMcp");
	// 撤销两步确认（确认态的选中行）
	const [confirmRevokeId, setConfirmRevokeId] = useState<string | null>(null);

	return (
		<div className="invitations-list" data-testid="mcp-token-list">
			{tokens.map((token) => (
				<div className="invitation-card" key={token.id}>
					<div className="invitation-card__header">
						<div className="invitation-card__info">
							<strong>{token.name}</strong>
							<div className="invitation-card__expires">
								{t("issuedAt", {
									time: formatDateTime(token.insertedAt),
									used: formatDateTime(token.lastUsedAt),
								})}
							</div>
						</div>
						<div className="invitation-card__actions">
							<span
								className={`l-badge ${
									token.status === "active"
										? "l-badge-volunteer"
										: token.status === "idle_expired"
											? "l-badge-pending"
											: "l-badge-danger"
								}`}
							>
								{token.status === "active"
									? t("active")
									: token.status === "idle_expired"
										? t("idleExpired")
										: t("revoked")}
							</span>
							{token.status !== "revoked" &&
								(confirmRevokeId === token.id ? (
									<>
										<button
											type="button"
											className="join-button join-button--primary"
											disabled={revokingId === token.id}
											onClick={async () => {
												try {
													await onRevoke(token.id);
												} catch {
													// 消费方已内联报错（本组件不重复展示）
												} finally {
													setConfirmRevokeId(null);
												}
											}}
										>
											{revokingId === token.id
												? t("revoking")
												: t("confirmRevoke")}
										</button>
										<button
											type="button"
											className="join-button join-button--ghost"
											disabled={revokingId === token.id}
											onClick={() => setConfirmRevokeId(null)}
										>
											{t("cancel")}
										</button>
									</>
								) : (
									<button
										type="button"
										className="join-button join-button--outline"
										onClick={() => setConfirmRevokeId(token.id)}
									>
										{t("revoke")}
									</button>
								))}
						</div>
					</div>
				</div>
			))}
		</div>
	);
}
