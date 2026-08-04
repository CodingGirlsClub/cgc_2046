"use client";

/**
 * #67 权限映射页 /w/[slug]/permissions。
 *
 * 页面按 07-rbac-permission-map-light 设计稿落地：同一 Workspace 管理壳
 * （WorkspaceShell）、五角色 × 六能力矩阵（六能力 = 后端 RBAC 真实能力，
 * 单一数据源），以及 Owner + Tutor 的角色并集 can? 判定示例。
 * 权限页只解释能力，不画 Agent / Workflow 执行 UI。
 */

import { useEffect, useMemo, useState } from "react";
import Link from "next/link";
import { useParams } from "next/navigation";
import { useAuthed } from "@/lib/use-authed";
import { useWorkspaceBySlug } from "@/lib/use-workspace-by-slug";
import {
	fetchPermissionsMatrix,
	myRolesHaveAbility,
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
import { Icon, type IconName } from "@/components/icons";

// 演示数据（角色值子集；枚举单源见 lib/graphql/workspace.ts 的 ROLE_NAMES）
const EXAMPLE_ROLES: MembershipRoleName[] = ["owner", "tutor"];

function roleLabel(role: MembershipRoleName) {
	return ROLE_LABEL[role] ?? role;
}

function roleBadgeClass(role: MembershipRoleName) {
	return ROLE_BADGE_CLASS[role] ?? "l-badge l-badge-member";
}

function PermissionCell({
	row,
	ability,
}: {
	row: PermissionMatrixRow;
	ability: PermissionAbility;
}) {
	const allowed = row.abilities[ability];
	return (
		<td
			className={`permissions-matrix__cell ${allowed ? "permissions-matrix__cell--allowed" : "permissions-matrix__cell--denied"}`}
			data-testid={`cell-${row.role}-${ability}`}
			aria-label={`${roleLabel(row.role)} ${ability}：${allowed ? "允许" : "拒绝"}`}
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

	return (
		<section className="permissions-matrix-card" aria-label="权限矩阵">
			<header className="permissions-card-heading">
				<h2>权限矩阵</h2>
				<span>Role → capability</span>
			</header>
			<div className="permissions-matrix-scroll">
				<table className="permissions-matrix">
					<thead>
						<tr>
							<th scope="col">能力</th>
							{PERMISSION_ROLE_ORDER.map((role) => (
								<th key={role} scope="col">
									<span className="permissions-role-header">
										{roleLabel(role)}
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
										<strong>{ability.label}</strong>
										{ability.id === "assign_roles" && (
											<small>
												<Icon name="info" size={14} />
												不含 Owner 角色授予
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

function ExampleCard({ matrix }: { matrix: PermissionMatrixRow[] }) {
	return (
		<aside
			className="permissions-example-card"
			aria-label="判定示例"
			data-testid="permission-example"
		>
			<h2>判定示例</h2>
			<div className="permissions-example__person">
				<span className="permissions-example__avatar">林</span>
				<div>
					<strong>林溪</strong>
					<div className="permissions-example__roles">
						{EXAMPLE_ROLES.map((role) => (
							<span key={role} className={roleBadgeClass(role)}>
								{roleLabel(role)}
							</span>
						))}
						<button
							type="button"
							className="permissions-example__add"
							aria-label="查看更多角色"
						>
							＋
						</button>
					</div>
				</div>
			</div>

			<div className="permissions-example__divider" />
			<h3>合并后能力</h3>
			<ul className="permissions-example__abilities">
				{PERMISSION_ABILITIES.map((ability) => {
					const allowed = myRolesHaveAbility(EXAMPLE_ROLES, matrix, ability.id);
					return (
						<li key={ability.id} data-testid="permission-ability-status">
							<span
								className={`permissions-example__status ${allowed ? "permissions-example__status--allowed" : "permissions-example__status--denied"}`}
							>
								{allowed ? "○" : "⊘"}
							</span>
							<span>{ability.label}</span>
							<strong
								className={
									allowed
										? "permissions-result--allowed"
										: "permissions-result--denied"
								}
							>
								{allowed ? "允许" : "拒绝"}
							</strong>
						</li>
					);
				})}
			</ul>

			<div className="permissions-example__result">
				<code>can? = true</code>
				<span>允许</span>
			</div>
			<p>权限来自当前 Workspace 的 MembershipRole 并集</p>
		</aside>
	);
}

export default function WorkspacePermissionsPage() {
	const params = useParams<{ slug: string }>();
	const slug = params?.slug ?? "";
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
					error instanceof Error ? error.message : "加载权限映射失败",
				);
			});

		return () => {
			cancelled = true;
		};
	}, [authed, confirmed, wsId]);

	const currentMatrix = matrixWorkspaceId === wsId ? matrix : null;

	return (
		<WorkspaceShell slug={slug}>
			<div className="permissions-main__inner">
				<div className="permissions-breadcrumb" aria-label="页面路径">
					<Link href={`/w/${slug}`}>工作区设置</Link>
					<span>›</span>
					<Link href={`/w/${slug}/members`}>成员与角色</Link>
					<span>›</span>
					<strong>权限映射</strong>
				</div>

				<header className="permissions-heading">
					<h1>查看角色到能力的映射与 can? 判定</h1>
				</header>

				<nav className="permissions-tabs" aria-label="成员管理页签">
					<Link href={`/w/${slug}/members`} className="permissions-tab">
						成员
					</Link>
					<Link
						href={`/w/${slug}/permissions`}
						className="permissions-tab permissions-tab--selected"
						aria-current="page"
					>
						权限映射
					</Link>
				</nav>

				<section className="permissions-notices" aria-label="权限规则说明">
					<NoticeCard
						icon="users"
						tone="green"
						title="多角色取并集"
						detail="任一角色允许，即可执行"
					/>
					<NoticeCard
						icon="shield"
						tone="cyan"
						title="租户边界优先"
						detail="跨 Workspace 一律拒绝"
					/>
					<NoticeCard
						icon="owner"
						tone="blue"
						title="Owner 专门指派"
						detail="不可通过行内角色编辑授予"
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
						<ExampleCard matrix={currentMatrix} />
					</div>
				) : (
					<div className="permissions-empty-table">
						<Icon name="shield" size={30} />
						<strong>暂无权限映射</strong>
						<p>当前 Workspace 还没有可展示的角色能力矩阵。</p>
					</div>
				)}

				<footer className="permissions-footer">
					<span>
						角色权限按当前 Workspace 隔离；跨 Workspace 资源默认拒绝。
					</span>
				</footer>
			</div>
		</WorkspaceShell>
	);
}
