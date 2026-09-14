"use client";

/**
 * 常驻接入卡（plan 2026-08-22 first-mile-onboarding U3，R8）。
 *
 * 挂概览页 w/[slug] 的 ws 块内（现有卡网格旁）；渲染门控在概览页
 * （KTD5 fail-closed + active 成员 + 非 readOnlyVisitor + 未接入或未通联），
 * 本组件按 hasActiveCredential 分两态（R 权威读法）：
 * - 无活跃凭证 → 邀请态：CTA 同模态主 CTA 跳区入口页。
 *   R1 把凭证全撤销/过期的回归成员视同未接入——即使其历史 connected
 *   （某 revoked token 有 lastUsedAt），只要当前无活跃凭证，仍呈邀请态；
 * - 有活跃凭证但未通联 → 「等待你的 Agent 第一次连接」提醒态（AE5 前半）；
 * - connected（hasActiveCredential && connected）→ 概览页不挂本卡（AE5 后半）。
 *
 * U5/KTD3：hasActiveCredential = 活跃连接 token 或活跃 OAuth 授权——两类凭证
 * 对用户是同一件事（已接入），卡态不分凭证类型。
 *
 * dismissed 不影响卡（per R2：常驻卡是拒绝模态后的常驻入口）。
 */

import { Link } from "@/i18n/navigation";
import { useTranslations } from "next-intl";

export interface OnboardingConnectCardProps {
	/** 工作区 slug（CTA 拼区入口页路径用） */
	slug: string;
	/** 有活跃凭证（token 或 OAuth 授权）→ 等待首联态；无 → 邀请态 */
	hasActiveCredential: boolean;
}

export default function OnboardingConnectCard({
	slug,
	hasActiveCredential,
}: OnboardingConnectCardProps) {
	const t = useTranslations("onboarding");

	return (
		<div
			className="connect-step-card"
			data-testid="onboarding-connect-card"
			data-variant={hasActiveCredential ? "waiting" : "invite"}
		>
			<h2>
				{hasActiveCredential ? t("cardWaitingTitle") : t("cardInviteTitle")}
			</h2>
			<p className="connect-step-card__desc">
				{hasActiveCredential ? t("cardWaitingDesc") : t("cardInviteDesc")}
			</p>
			<div className="connect-step-card__actions">
				<Link
					href={`/w/${slug}/settings/integrations/agents`}
					className={
						hasActiveCredential
							? "join-button join-button--outline"
							: "join-button join-button--primary"
					}
					data-testid="onboarding-connect-card-cta"
				>
					{hasActiveCredential ? t("cardWaitingCta") : t("inviteStart")}
				</Link>
			</div>
		</div>
	);
}
