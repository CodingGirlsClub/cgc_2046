"use client";

/**
 * 缴费闭环 follow-up U2-R1：定价配置页 /w/[slug]/settings/pricing。
 *
 * 收费 Event/Course 的 pricingEnabled 开关 + PriceTier 档位编辑
 * （PricingManagement 组件）；门控 = canManageEvents（Owner/Admin，后端
 * policy 兜底）。页面骨架与 settings/sponsorship 同款。
 */

import { Link } from "@/i18n/navigation";
import { useParams } from "next/navigation";
import { useTranslations } from "next-intl";
import { useWorkspaceBySlug } from "@/lib/use-workspace-by-slug";
import { canManageEvents } from "@/lib/events";
import WorkspaceShell from "@/components/workspace-shell";
import MembersTabs from "@/components/members-tabs";
import PricingManagement from "@/components/pricing-management";

export default function WorkspacePricingPage() {
	const t = useTranslations("workspacePages");
	const tCommon = useTranslations("common");
	const params = useParams<{ slug: string }>();
	const slug = params?.slug ?? "";
	const { ws } = useWorkspaceBySlug(slug);
	const manage = canManageEvents(ws?.myRoleNames ?? []);

	return (
		<WorkspaceShell slug={slug}>
			<div className="ws-page-main__inner">
				<div className="ws-page-breadcrumb" aria-label={tCommon("breadcrumbAria")}>
					<Link href="/">{t("breadcrumbHome")}</Link>
					<span>›</span>
					<Link href={`/w/${slug}`}>{ws?.name ?? slug}</Link>
					<span>›</span>
					<strong>{t("pricing")}</strong>
				</div>
				{ws ? <MembersTabs slug={slug} current="pricing" abilities={ws.myAbilities ?? []} /> : null}

				<div className="mt-6 grid gap-4">
					{ws ? (
						<PricingManagement workspaceId={ws.id} manage={manage} />
					) : (
						<div className="h-40 animate-pulse rounded-large bg-soft-2 ring-1 ring-line" />
					)}
				</div>
			</div>
		</WorkspaceShell>
	);
}
