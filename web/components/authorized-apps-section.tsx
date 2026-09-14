"use client";

/**
 * 「已授权应用」区块（U5/KTD3；唯一实现）。
 *
 * 消费方（两处，同一 DOM 与两步确认语义）：
 * - 工作台集成页 `/w/[slug]/settings/integrations/agents/mcp`（与连接 token 同界面）
 * - 用户级账号设置 `/settings/account/connections`（无工作台成员资格也可达；
 *   U4 同意页「可随时在 CGC 账号设置中撤销此授权」的落点）
 *
 * 纯展示 + 行内两步确认态：数据与撤销请求由消费方持有。撤销成功后消费方把该行
 * 从列表移除——web 撤销会撤回同意行，该 client 不再处于「已授权」状态；宿主
 * 自撤销（RFC 7009）的行保留为「已撤销」审计行（无操作按钮）。
 */

import { useState } from "react";
import { useTranslations } from "next-intl";
import type { OauthAuthorizationItem } from "@/lib/mcp";
import { formatDateTime } from "@/lib/format";

/** 状态 → 徽章类名（与连接 token 列表同色系：绿=有效、琥珀=可恢复的失效、红=已撤销） */
function badgeClass(status: OauthAuthorizationItem["status"]): string {
	if (status === "active") return "l-badge l-badge-volunteer";
	if (status === "revoked") return "l-badge l-badge-danger";
	if (status === "idle_expired") return "l-badge l-badge-pending";
	return "l-badge";
}

export default function AuthorizedAppsSection({
	items,
	revokingClientId,
	onRevoke,
}: {
	items: OauthAuthorizationItem[];
	/** 撤销进行中的 clientId（禁用该行确认按钮） */
	revokingClientId: string | null;
	/** 确认撤销（消费方负责请求与列表更新；失败由消费方内联报错；resolve 后收起确认态） */
	onRevoke: (clientId: string) => Promise<void>;
}) {
	const t = useTranslations("oauthAuthorizations");
	// 撤销两步确认（确认态的选中行）
	const [confirmClientId, setConfirmClientId] = useState<string | null>(null);

	const statusLabel = (status: OauthAuthorizationItem["status"]) => {
		if (status === "active") return t("statusActive");
		if (status === "revoked") return t("statusRevoked");
		if (status === "idle_expired") return t("statusIdleExpired");
		return t("statusPending");
	};

	return (
		<div className="invitations-list" data-testid="authorized-apps">
			{items.map((item) => (
				<div className="invitation-card" key={item.clientId}>
					<div className="invitation-card__header">
						<div className="invitation-card__info">
							<strong>
								{item.clientName || t("unknownClient", { id: item.clientId })}
							</strong>
							<div className="invitation-card__expires">
								{item.grantedAt
									? `${t("grantedAt", { time: formatDateTime(item.grantedAt) })} · `
									: ""}
								{t("lastUsed", { time: formatDateTime(item.lastUsedAt) })}
							</div>
						</div>
						<div className="invitation-card__actions">
							<span className={badgeClass(item.status)}>
								{statusLabel(item.status)}
							</span>
							{item.status !== "revoked" &&
								(confirmClientId === item.clientId ? (
									<>
										<button
											type="button"
											className="join-button join-button--primary"
											disabled={revokingClientId === item.clientId}
											onClick={async () => {
												try {
													await onRevoke(item.clientId);
												} catch {
													// 消费方已内联报错（本组件不重复展示）
												} finally {
													setConfirmClientId(null);
												}
											}}
										>
											{revokingClientId === item.clientId
												? t("revoking")
												: t("confirmRevoke")}
										</button>
										<button
											type="button"
											className="join-button join-button--ghost"
											disabled={revokingClientId === item.clientId}
											onClick={() => setConfirmClientId(null)}
										>
											{t("cancel")}
										</button>
									</>
								) : (
									<button
										type="button"
										className="join-button join-button--outline"
										onClick={() => setConfirmClientId(item.clientId)}
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
