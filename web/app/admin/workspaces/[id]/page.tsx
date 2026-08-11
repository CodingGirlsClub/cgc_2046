"use client";

/**
 * /admin/workspaces/[id] 工作台详情（Phase 8 / R13）。
 * - 基础信息：name/slug/joinPolicy/创建时间
 * - pending-owner 状态：有 active 且 preauthorized [:owner] 的 Invitation
 *   （复用 Invitation 生命周期，OQ6 选项 3）
 * - 成员列表（Owner/Admin 可见全部）
 */
import { useEffect, useState } from "react";
import { useParams } from "next/navigation";
import { gql } from "@apollo/client";
import { client } from "@/lib/apollo-client";
import {
	JOIN_POLICY_LABEL,
	type Workspace,
} from "@/lib/graphql/workspace";
import { fetchWorkspaceMembers, type WorkspaceMember } from "@/lib/workspaces";
import { fetchInvitations } from "@/lib/invitations";

const GET_WORKSPACE_BY_ID = gql`
  query GetWorkspaceById($id: ID!) {
    getWorkspaceById(id: $id) {
      id
      slug
      name
      joinPolicy
      sponsorshipEnabled
    }
  }
`;

interface WorkspaceByIdResult {
	getWorkspaceById: Workspace | null;
}

export default function AdminWorkspaceDetailPage() {
	const params = useParams<{ id: string }>();
	const workspaceId = params.id;

	const [workspace, setWorkspace] = useState<Workspace | null>(null);
	const [members, setMembers] = useState<WorkspaceMember[] | null>(null);
	const [pendingOwner, setPendingOwner] = useState(false);
	const [loading, setLoading] = useState(true);
	const [error, setError] = useState(false);

	useEffect(() => {
		let cancelled = false;
		(async () => {
			setLoading(true);
			setError(false);
			try {
				const [{ data }, memberPage, invitations] = await Promise.all([
					client.query<WorkspaceByIdResult>({
						query: GET_WORKSPACE_BY_ID,
						variables: { id: workspaceId },
					}),
					fetchWorkspaceMembers(workspaceId),
					fetchInvitations(workspaceId),
				]);
				if (cancelled) return;
				setWorkspace(data?.getWorkspaceById ?? null);
				setMembers(memberPage.members);
				setPendingOwner(
					invitations.items.some(
						(inv) =>
							inv.status === "active" &&
							(inv.preauthorizedRoleNames ?? []).includes("owner"),
					),
				);
			} catch {
				if (!cancelled) setError(true);
			} finally {
				if (!cancelled) setLoading(false);
			}
		})();
		return () => {
			cancelled = true;
		};
	}, [workspaceId]);

	if (loading) {
		return <p className="admin-muted">加载中…</p>;
	}

	if (error || !workspace) {
		return <p className="admin-alert admin-alert--error">加载失败，工作台不存在或无权查看。</p>;
	}

	return (
		<section>
			<div className="admin-page__head">
				<div>
					<h1>{workspace.name}</h1>
					<p className="admin-page__desc">
						{workspace.slug} · {JOIN_POLICY_LABEL[workspace.joinPolicy]}
					</p>
				</div>
			</div>

			{pendingOwner && (
				<p className="admin-alert admin-alert--warn">
					待指定 Owner（有 active Owner 邀请）
				</p>
			)}

			<h2 className="admin-section-title">成员（{members?.length ?? 0}）</h2>
			{members && members.length > 0 ? (
				<div className="admin-card admin-table-wrap">
					<table className="admin-table">
						<thead>
							<tr>
								<th>成员</th>
								<th>角色</th>
							</tr>
						</thead>
						<tbody>
							{members.map((m) => (
								<tr key={m.membershipId}>
									<td>
										<span className="admin-table__primary">
											{m.displayName || m.email || m.userId}
										</span>
										{m.email && (
											<span className="admin-table__sub">{m.email}</span>
										)}
									</td>
									<td>
										<span className="admin-badge-row">
											{m.roles.map((r) => (
												<span key={r} className="l-badge l-badge-member">
													{r}
												</span>
											))}
										</span>
									</td>
								</tr>
							))}
						</tbody>
					</table>
				</div>
			) : (
				<p className="admin-empty">暂无成员。</p>
			)}
		</section>
	);
}
