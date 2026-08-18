"use client";

/**
 * /admin/workspaces/[id] 工作台详情（Phase 8 / R13）。
 * - 基础信息：name/slug/joinPolicy
 * - Owner 状态区（#114 pending-owner 邀请生命周期，仅无 Owner 成员时展示）：
 *   - 有 active 且 preauthorized [:owner] 的邀请 → warn badge（含有效期）
 *     + 「取消邀请」（revokeInvitation，platform_admin bypass）
 *   - 无 active Owner 邀请 → warn badge「Owner 未就位（无有效邀请）」
 *   - 「重指派 Owner」：选择已有用户（ownerUserId，直接入座）或邀请新用户
 *     （ownerEmail，原子撤销旧邀请 + 新 pending-owner 邀请 7 天有效期，
 *     ownerInvitationToken 仅展示一次）
 * - 成员列表（Owner/Admin 可见全部）
 */
import { useCallback, useEffect, useState } from "react";
import { useParams } from "next/navigation";
import { useTranslations } from "next-intl";
import { gql } from "@apollo/client";
import { client } from "@/lib/apollo-client";
import {
	JOIN_POLICY_LABEL,
	ROLE_BADGE_CLASS,
	type MembershipRoleName,
	type Workspace,
} from "@/lib/graphql/workspace";
import { fetchWorkspaceMembers, type WorkspaceMember } from "@/lib/workspaces";
import {
	fetchInvitations,
	revokeInvitation,
	type InvitationItem,
} from "@/lib/invitations";
import { fetchUsers, reassignWorkspaceOwner } from "@/lib/admin";
import type { AdminUser } from "@/lib/graphql/admin";

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

type OwnerMode = "existing" | "invite";

/** ISO 时间串 → 本地日期（无效输入回退原串） */
function formatLocalDate(iso: string): string {
	const d = new Date(iso);
	return Number.isNaN(d.getTime()) ? iso : d.toLocaleDateString("zh-CN");
}

export default function AdminWorkspaceDetailPage() {
	const t = useTranslations("admin");
	const params = useParams<{ id: string }>();
	const workspaceId = params.id;

	const [workspace, setWorkspace] = useState<Workspace | null>(null);
	const [members, setMembers] = useState<WorkspaceMember[] | null>(null);
	const [ownerInvitation, setOwnerInvitation] =
		useState<InvitationItem | null>(null);
	const [loading, setLoading] = useState(true);
	const [error, setError] = useState(false);

	// #114 Owner 状态区：取消邀请 / 重指派表单
	const [revoking, setRevoking] = useState(false);
	const [ownerMode, setOwnerMode] = useState<OwnerMode>("existing");
	const [userSearch, setUserSearch] = useState("");
	const [userResults, setUserResults] = useState<AdminUser[] | null>(null);
	const [selectedUser, setSelectedUser] = useState<AdminUser | null>(null);
	const [ownerEmail, setOwnerEmail] = useState("");
	const [searching, setSearching] = useState(false);
	const [submitting, setSubmitting] = useState(false);
	const [actionError, setActionError] = useState<string | null>(null);
	const [inviteToken, setInviteToken] = useState<string | null>(null);
	const [ownerSeated, setOwnerSeated] = useState(false);

	/** 拉取 workspace/members/invitations 并写入 state（初始加载与操作成功后复用） */
	const load = useCallback(async () => {
		const [{ data }, memberPage, invitationPage] = await Promise.all([
			client.query<WorkspaceByIdResult>({
				query: GET_WORKSPACE_BY_ID,
				variables: { id: workspaceId },
			}),
			fetchWorkspaceMembers(workspaceId),
			fetchInvitations(workspaceId),
		]);
		setWorkspace(data?.getWorkspaceById ?? null);
		setMembers(memberPage.members);
		setOwnerInvitation(
			invitationPage.items.find(
				(inv) =>
					inv.status === "active" &&
					(inv.preauthorizedRoleNames ?? []).includes("owner"),
			) ?? null,
		);
	}, [workspaceId]);

	useEffect(() => {
		let cancelled = false;
		(async () => {
			setLoading(true);
			setError(false);
			try {
				await load();
			} catch {
				if (!cancelled) setError(true);
			} finally {
				if (!cancelled) setLoading(false);
			}
		})();
		return () => {
			cancelled = true;
		};
	}, [load]);

	const handleRevokeInvitation = async () => {
		if (!ownerInvitation) return;
		setRevoking(true);
		setActionError(null);
		setInviteToken(null);
		setOwnerSeated(false);
		try {
			await revokeInvitation(ownerInvitation.id);
			await load();
		} catch {
			setActionError(t("cancelInviteFailed"));
		} finally {
			setRevoking(false);
		}
	};

	const handleSearchUser = async () => {
		setSearching(true);
		try {
			const users = await fetchUsers(userSearch, { first: 10 });
			setUserResults(users);
		} catch {
			setUserResults([]);
		} finally {
			setSearching(false);
		}
	};

	const handleReassign = async () => {
		setSubmitting(true);
		setActionError(null);
		setInviteToken(null);
		setOwnerSeated(false);
		try {
			const result = await reassignWorkspaceOwner(workspaceId, {
				...(ownerMode === "existing" && selectedUser
					? { ownerUserId: selectedUser.id }
					: {}),
				...(ownerMode === "invite" && ownerEmail ? { ownerEmail } : {}),
			});
			if (result.errors.length > 0) {
				setActionError(result.errors.map((e) => e.message).join("；"));
			} else if (result.result) {
				if (ownerMode === "invite") {
					// 新 pending-owner 邀请明文 token 仅本次返回，先展示再刷新数据
					setInviteToken(result.metadata?.ownerInvitationToken ?? null);
				} else {
					setOwnerSeated(true);
				}
				await load();
			} else {
				setActionError(t("reassignFailed"));
			}
		} catch {
			setActionError(t("networkError"));
		} finally {
			setSubmitting(false);
		}
	};

	if (loading) {
		return <p className="admin-muted">{t("loading")}</p>;
	}

	if (error || !workspace) {
		return <p className="admin-alert admin-alert--error">{t("workspaceNotFound")}</p>;
	}

	const hasOwner = (members ?? []).some((m) => m.roles.includes("owner"));

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

			{ownerSeated && (
				<p className="admin-alert admin-alert--plain">{t("ownerSeated")}</p>
			)}

			{inviteToken && (
				<div className="admin-alert admin-alert--warn admin-result-back">
					<div>
						<p>{t("ownerInviteNote")}</p>
						<code className="l-codeblock">{inviteToken}</code>
					</div>
				</div>
			)}

			{!hasOwner && (
				<>
					{ownerInvitation ? (
						<div className="admin-alert admin-alert--warn">
							<span>
								{t("pendingOwner", {
									extra: ownerInvitation.expiresAt
										? t("validUntil", {
												date: formatLocalDate(ownerInvitation.expiresAt),
											})
										: "",
								})}
							</span>
							<button
								type="button"
								onClick={handleRevokeInvitation}
								disabled={revoking}
								className="l-btn-outline"
							>
								{revoking ? t("revoking") : t("cancelInvite")}
							</button>
						</div>
					) : (
						<p className="admin-alert admin-alert--warn">
							{t("ownerNotSeated")}
						</p>
					)}

					<h2 className="admin-section-title">{t("reassignTitle")}</h2>
					<div className="admin-form">
						<fieldset className="admin-field">
							<legend className="admin-field__label">{t("ownerAssign")}</legend>
							<div className="admin-radio-row">
								<label className="admin-radio">
									<input
										type="radio"
										name="owner-mode"
										checked={ownerMode === "existing"}
										onChange={() => setOwnerMode("existing")}
									/>
									{t("chooseExisting")}
								</label>
								<label className="admin-radio">
									<input
										type="radio"
										name="owner-mode"
										checked={ownerMode === "invite"}
										onChange={() => setOwnerMode("invite")}
									/>
									{t("inviteNew")}
								</label>
							</div>

							{ownerMode === "existing" ? (
								<div>
									{!selectedUser && (
										<div className="admin-toolbar">
											<input
												value={userSearch}
												onChange={(e) => setUserSearch(e.target.value)}
												placeholder={t("searchUserPlaceholder")}
												className="l-input"
											/>
											<button
												type="button"
												onClick={handleSearchUser}
												className="l-btn-outline"
											>
												{t("search")}
											</button>
										</div>
									)}
									{searching && <p className="admin-muted">{t("searching")}</p>}
									{userResults && userResults.length === 0 && (
										<p className="admin-muted">{t("noUserMatch")}</p>
									)}
									{userResults && userResults.length > 0 && (
										<ul className="admin-pick-list">
											{userResults.map((u) => (
												<li key={u.id}>
													<button
														type="button"
														onClick={() => {
															setSelectedUser(u);
															setUserResults(null);
														}}
														className="admin-pick-list__item"
													>
														{u.displayName || u.email}（{u.email}）
													</button>
												</li>
											))}
										</ul>
									)}
									{selectedUser && (
										<p className="admin-muted">
											{t("selectedOwner", {
												user: selectedUser.displayName || selectedUser.email || "",
											})}
											{" · "}
											<button
												type="button"
												onClick={() => setSelectedUser(null)}
												className="admin-link"
											>
												{t("change")}
											</button>
										</p>
									)}
								</div>
							) : (
								<div className="admin-field">
									<label
										htmlFor="reassign-owner-email"
										className="admin-field__label"
									>
										{t("inviteEmail")}
									</label>
									<input
										id="reassign-owner-email"
										type="email"
										value={ownerEmail}
										onChange={(e) => setOwnerEmail(e.target.value)}
										placeholder="newowner@example.com"
										className="l-input"
									/>
								</div>
							)}
						</fieldset>

						{actionError && (
							<p className="admin-alert admin-alert--error">{actionError}</p>
						)}

						<div>
							<button
								type="button"
								onClick={handleReassign}
								disabled={
									submitting ||
									(ownerMode === "existing" ? !selectedUser : !ownerEmail)
								}
								className="l-btn-primary"
							>
								{t("reassignButton")}
							</button>
						</div>
					</div>
				</>
			)}

			<h2 className="admin-section-title">
				{t("membersTitle", { count: members?.length ?? 0 })}
			</h2>
			{members && members.length > 0 ? (
				<div className="admin-card admin-table-wrap">
					<table className="admin-table">
						<thead>
							<tr>
								<th>{t("thMember")}</th>
								<th>{t("thRole")}</th>
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
										{m.roles.length === 0 ? (
											<span className="members-empty-role">{t("noRoles")}</span>
										) : (
											<span className="admin-badge-row">
												{m.roles.map((r) => (
													<span
														key={r}
														className={
															ROLE_BADGE_CLASS[r as MembershipRoleName] ??
															"l-badge"
														}
													>
														{r}
													</span>
												))}
											</span>
										)}
									</td>
								</tr>
							))}
						</tbody>
					</table>
				</div>
			) : (
				<p className="admin-empty">{t("noMembers")}</p>
			)}
		</section>
	);
}
