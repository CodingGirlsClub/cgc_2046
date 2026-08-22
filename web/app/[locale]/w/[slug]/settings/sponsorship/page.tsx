"use client";

/**
 * E-3 #48 工作台级赞助管理页 /w/[slug]/settings/sponsorship。
 *
 * - 档位配置：Workspace.sponsorshipTiers（Workspace 级长期赞助档位），
 *   Owner/Admin 可保存（updateWorkspace sponsorshipTiers；后端 policy 兜底）；
 * - 赞助列表 + 履约账本：LIST_WORKSPACE_SPONSORSHIPS（含 Event 级与
 *   Workspace 级全部赞助行，Event 级经 event_id 区分）+ 交付行核销
 *   （Workspace 级审批仍仅 Owner——审批动作在 /approvals 控制台，不在本页）。
 */

import { Link } from "@/i18n/navigation";
import { useParams } from "next/navigation";
import { useTranslations } from "next-intl";
import { useWorkspaceBySlug } from "@/lib/use-workspace-by-slug";
import { canManageEvents } from "@/lib/events";
import { parseSponsorshipTiers } from "@/lib/public-offerings";
import { updateWorkspaceSponsorshipTiers } from "@/lib/workspaces";
import WorkspaceShell from "@/components/workspace-shell";
import MembersTabs from "@/components/members-tabs";
import SponsorshipManagement from "@/components/sponsorship-management";

export default function WorkspaceSponsorshipPage() {
	const t = useTranslations("workspacePages");
	const tCommon = useTranslations("common");
	const params = useParams<{ slug: string }>();
	const slug = params?.slug ?? "";
	const { ws } = useWorkspaceBySlug(slug);
	const manage = canManageEvents(ws?.myAbilities ?? []);

	return (
		<WorkspaceShell slug={slug} requireAbility="manage_events">
			<div className="ws-page-main__inner">
				<div className="ws-page-breadcrumb" aria-label={tCommon("breadcrumbAria")}>
					<Link href="/">{t("breadcrumbHome")}</Link>
					<span>›</span>
					<Link href={`/w/${slug}`}>{ws?.name ?? slug}</Link>
					<span>›</span>
					<strong>{t("sponsorship")}</strong>
				</div>
				{ws && (
					<MembersTabs
						slug={slug}
						current="sponsorship"
						abilities={ws.myAbilities ?? []}
					/>
				)}

				<div className="mt-6 grid gap-4">
					<SponsorshipManagement
						target={ws ? { kind: "workspace", id: ws.id } : { kind: "workspace", id: "" }}
						tiers={parseSponsorshipTiers(ws?.sponsorshipTiers)}
						manage={manage}
						onSaveTiers={async (tiers) => {
							if (!ws) return false;
							try {
								await updateWorkspaceSponsorshipTiers(
									ws.id,
									tiers.map((t) => JSON.stringify(t)),
								);
								return true;
							} catch {
								return false;
							}
						}}
					/>
				</div>
			</div>
		</WorkspaceShell>
	);
}
