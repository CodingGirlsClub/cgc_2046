"use client";

/**
 * 缴费闭环 U11：工作台缴费管理页 /w/[slug]/settings/payments。
 *
 * 统计卡 + 订单列表 + 退款/免缴（PaymentsManagement 组件）；门控 =
 * ws.myAbilities 含 manage_members（Owner/Admin，后端 policy 兜底双保险）。
 * 页面骨架与 settings/sponsorship 同款（useWorkspaceBySlug + MembersTabs）。
 */

import { Link } from "@/i18n/navigation";
import { useParams } from "next/navigation";
import { useTranslations } from "next-intl";
import { useWorkspaceBySlug } from "@/lib/use-workspace-by-slug";
import WorkspaceShell from "@/components/workspace-shell";
import MembersTabs from "@/components/members-tabs";
import PaymentsManagement from "@/components/payments-management";

export default function WorkspacePaymentsPage() {
	const t = useTranslations("workspacePages");
	const tCommon = useTranslations("common");
	const params = useParams<{ slug: string }>();
	const slug = params?.slug ?? "";
	const { ws, readOnlyVisitor } = useWorkspaceBySlug(slug);

	// 缴费管理 = Owner/Admin（manage_members 能力；后端 policy 兜底）
	const manage = !readOnlyVisitor && (ws?.myAbilities ?? []).includes("manage_members");

	return (
		<WorkspaceShell slug={slug} requireAbility="manage_members">
			<div className="ws-page-main__inner">
				<div className="ws-page-breadcrumb" aria-label={tCommon("breadcrumbAria")}>
					<Link href="/">{t("breadcrumbHome")}</Link>
					<span>›</span>
					<Link href={`/w/${slug}`}>{ws?.name ?? slug}</Link>
					<span>›</span>
					<strong>{t("payments")}</strong>
				</div>
				{ws ? <MembersTabs slug={slug} current="payments" abilities={ws.myAbilities ?? []} /> : null}

				<div className="mt-6 grid gap-4">
					{ws ? (
						<PaymentsManagement workspaceId={ws.id} manage={manage} />
					) : (
						<div className="h-40 animate-pulse rounded-large bg-soft-2 ring-1 ring-line" />
					)}
				</div>
			</div>
		</WorkspaceShell>
	);
}
