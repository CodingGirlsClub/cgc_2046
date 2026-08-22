"use client";

/**
 * #67 权限映射页 /w/[slug]/permissions。
 *
 * 页面按 07-rbac-permission-map-light 设计稿落地：同一 Workspace 管理壳
 * （WorkspaceShell）、五角色 × 六能力矩阵（六能力 = 后端 RBAC 真实能力，
 * 单一数据源），以及「我的能力」示例卡。
 * 「我的能力」只消费 ws.myAbilities（后端 Rbac 下发的权威能力列表），
 * 不在前端用角色名 × 矩阵复写权限语义（platform admin 无成员角色时
 * 本地自算会误显「拒绝」）。
 * 权限页只解释能力，不画 Agent / Workflow 执行 UI。
 */

import { useEffect, useMemo, useState } from "react";
import { Link } from "@/i18n/navigation";
import { useParams } from "next/navigation";
import { useTranslations } from "next-intl";
import { useAuthed } from "@/lib/use-authed";
import { useWorkspaceBySlug } from "@/lib/use-workspace-by-slug";
import {
	fetchPermissionsMatrix,
	PERMISSION_ABILITIES,
	PERMISSION_ROLE_ORDER,
	type PermissionAbility,
	type PermissionMatrixRow,
} from "@/lib/permissions";
import {
	ROLE_BADGE_CLASS,
	ROLE_LABEL,
	type MembershipRoleName,
} from "@/lib/graphql/workspace";
import WorkspaceShell from "@/components/workspace-shell";
import MembersTabs from "@/components/members-tabs";
import { Icon, type IconName } from "@/components/icons";

function roleLabel(role: MembershipRoleName) {
	return ROLE_LABEL[role] ?? role;
}

function roleBadgeClass(role: MembershipRoleName) {
	return ROLE_BADGE_CLASS[role] ?? "l-badge";
}

function PermissionCell({
	row,
	ability,
}: {
	row: PermissionMatrixRow;
	ability: PermissionAbility;
}) {
	const t = useTranslations("workspacePermissions");
	const labelsT = useTranslations();
	const allowed = row.abilities[ability];
	return (
		<td
			className={`permissions-matrix__cell ${allowed ? "permissions-matrix__cell--allowed" : "permissions-matrix__cell--denied"}`}
			data-testid={`cell-${row.role}-${ability}`}
			aria-label={t("cellAria", {
				role: labelsT(roleLabel(row.role)),
				ability,
				state: allowed ? t("allowed") : t("denied"),
			})}
		>
			{allowed ? "✓" : "—"}
		</td>
	);
}

function NoticeCard({
	icon,
	tone,
	title,
	detail,
}: {
	icon: IconName;
	tone: string;
	title: string;
	detail: string;
}) {
	return (
		<article className={`permissions-notice permissions-notice--${tone}`}>
			<span className="permissions-notice__icon">
				<Icon name={icon} size={23} />
			</span>
			<div>
				<strong>{title}</strong>
				<span>{detail}</span>
			</div>
		</article>
	);
}

function MatrixCard({ matrix }: { matrix: PermissionMatrixRow[] }) {
	const rowsByRole = useMemo(
		() => new Map(matrix.map((row) => [row.role, row])),
		[matrix],
	);
	const orderedRows = PERMISSION_ROLE_ORDER.map((role) =>
		rowsByRole.get(role),
	).filter((row): row is PermissionMatrixRow => Boolean(row));
	const t = useTranslations("workspacePermissions");
	const labelsT = useTranslations();

	return (
		<section className="permissions-matrix-card" aria-label={t("matrixTitle")}>
			<header className="permissions-card-heading">
				<h2>{t("matrixTitle")}</h2>
				<span>{t("matrixSubtitle")}</span>
			</header>
			<div className="permissions-matrix-scroll">
				<table className="permissions-matrix">
					<thead>
						<tr>
							<th scope="col">{t("thAbility")}</th>
							{PERMISSION_ROLE_ORDER.map((role) => (
								<th key={role} scope="col">
									<span className="permissions-role-header">
										{labelsT(roleLabel(role))}
									</span>
								</th>
							))}
						</tr>
					</thead>
					<tbody>
						{PERMISSION_ABILITIES.map((ability) => {
							return (
								<tr
									key={ability.id}
									data-testid={`permission-row-${ability.id}`}
								>
									<th scope="row" className="permissions-ability-label">
										<strong>{labelsT(ability.label)}</strong>
										{ability.id === "assign_roles" && (
											<small>
												<Icon name="info" size={14} />
												{t("noOwnerInline")}
											</small>
										)}
									</th>
									{orderedRows.map((row) => (
										<PermissionCell
											key={`${row.role}-${ability.id}`}
											row={row}
											ability={ability.id}
										/>
									))}
								</tr>
							);
						})}
					</tbody>
				</table>
			</div>
		</section>
	);
}

function ExampleCard({
	myAbilities,
	myRoles,
}: {
	myAbilities: string[];
	myRoles: MembershipRoleName[];
}) {
	const t = useTranslations("workspacePermissions");
	const labelsT = useTranslations();
	return (
		<aside
			className="permissions-example-card"
			aria-label={t("myAbilitiesTitle")}
			data-testid="permission-example"
		>
			<h2>{t("myAbilitiesTitle")}</h2>
			<div className="permissions-example__person">
				<span className="permissions-example__avatar">{t("me")}</span>
				<div>
					<strong>{t("currentRoles")}</strong>
					<div className="permissions-example__roles">
						{myRoles.length > 0 ? (
							myRoles.map((role) => (
								<span key={role} className={roleBadgeClass(role)}>
									{labelsT(roleLabel(role))}
								</span>
							))
						) : (
							<span className="permissions-example__no-roles">
								{t("noRoles")}
							</span>
						)}
					</div>
				</div>
			</div>

			<div className="permissions-example__divider" />
			<h3>{t("abilitiesLabel")}</h3>
			<ul className="permissions-example__abilities">
				{PERMISSION_ABILITIES.map((ability) => {
					const allowed = myAbilities.includes(ability.id);
					return (
						<li key={ability.id} data-testid="permission-ability-status">
							<span
								className={`permissions-example__status ${allowed ? "permissions-example__status--allowed" : "permissions-example__status--denied"}`}
							>
								{allowed ? "○" : "⊘"}
							</span>
							<span>{labelsT(ability.label)}</span>
							<strong
								className={
									allowed
										? "permissions-result--allowed"
										: "permissions-result--denied"
								}
							>
								{allowed ? t("allowed") : t("denied")}
							</strong>
						</li>
					);
				})}
			</ul>
			<p>{t("abilitiesHint")}</p>
		</aside>
	);
}

export default function WorkspacePermissionsPage() {
	const params = useParams<{ slug: string }>();
	const slug = params?.slug ?? "";
	const t = useTranslations("workspacePermissions");
	const tCommon = useTranslations("common");
	// 数据 effect 的认证守卫（壳管渲染/重定向；页面管「未认证不拉数据」）
	const { authed, confirmed } = useAuthed();
	const { ws, loading: wsLoading } = useWorkspaceBySlug(slug);
	const wsId = ws?.id;

	const [matrix, setMatrix] = useState<PermissionMatrixRow[] | null>(null);
	const [matrixWorkspaceId, setMatrixWorkspaceId] = useState<string | null>(
		null,
	);
	const [errorMsg, setErrorMsg] = useState<string | null>(null);

	useEffect(() => {
		if (!confirmed || !authed) return;
		if (!wsId) return;

		let cancelled = false;
		fetchPermissionsMatrix()
			.then((rows) => {
				if (cancelled) return;
				setMatrix(rows);
				setMatrixWorkspaceId(wsId);
				setErrorMsg(null);
			})
			.catch((error: unknown) => {
				if (cancelled) return;
				setMatrix([]);
				setMatrixWorkspaceId(wsId);
				setErrorMsg(
					error instanceof Error ? error.message : t("loadFailed"),
				);
			});

		return () => {
			cancelled = true;
		};
	}, [authed, confirmed, wsId, t]);

	const currentMatrix = matrixWorkspaceId === wsId ? matrix : null;

	return (
		<WorkspaceShell slug={slug} requireAbility="list_members">
			<div className="ws-page-main__inner">
				<div
					className="ws-page-breadcrumb"
					aria-label={tCommon("breadcrumbAria")}
				>
					<Link href="/">{t("breadcrumbHome")}</Link>
					<span>›</span>
					<Link href={`/w/${slug}`}>{ws?.name ?? slug}</Link>
					<span>›</span>
					<Link href={`/w/${slug}/settings/join-policy`}>
						{t("breadcrumbSettings")}
					</Link>
					<span>›</span>
					<strong>{t("breadcrumbTitle")}</strong>
				</div>

				<header className="ws-page-heading">
					<div>
						<h1>{t("title")}</h1>
						<p>{t("subtitle")}</p>
					</div>
				</header>

				{ws && (
					<MembersTabs
						slug={slug}
						current="permissions"
						abilities={ws.myAbilities ?? []}
					/>
				)}

				<section
					className="permissions-notices"
					aria-label={t("rulesAria")}
				>
					<article
						className="permissions-notice permissions-notice--green"
						data-testid="permissions-baseline-row"
					>
						<span className="permissions-notice__icon">
							<Icon name="users" size={23} />
						</span>
						<div>
							<strong>{t("memberNoticeTitle")}</strong>
							<span>{t("memberNoticeDesc")}</span>
						</div>
					</article>
					<article
						className="permissions-notice permissions-notice--cyan"
						data-testid="permissions-diff-tags-row"
					>
						<span className="permissions-notice__icon">
							<Icon name="shield" size={23} />
						</span>
						<div>
							<strong>{t("diffNoticeTitle")}</strong>
							<span>{t("diffNoticeDesc")}</span>
						</div>
					</article>
					<NoticeCard
						icon="owner"
						tone="blue"
						title={t("ownerTitle")}
						detail={t("ownerDetail")}
					/>
				</section>

				{errorMsg && (
					<div className="permissions-error" role="alert">
						{errorMsg}
					</div>
				)}

				{wsLoading || currentMatrix === null ? (
					<div
						className="permissions-loading-card"
						data-testid="permissions-loading"
					/>
				) : currentMatrix.length > 0 ? (
					<div className="permissions-content-grid">
						<MatrixCard matrix={currentMatrix} />
						<ExampleCard
							myAbilities={ws?.myAbilities ?? []}
							myRoles={ws?.myRoleNames ?? []}
						/>
					</div>
				) : (
					<div className="permissions-empty-table">
						<Icon name="shield" size={30} />
						<strong>{t("emptyTitle")}</strong>
						<p>{t("emptyDesc")}</p>
					</div>
				)}

				<footer className="permissions-footer">
					<span>{t("footer")}</span>
				</footer>
			</div>
		</WorkspaceShell>
	);
}
