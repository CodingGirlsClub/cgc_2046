"use client";

/**
 * #65 成员与角色管理页 /w/[slug]/members。
 *
 * 页面结构按 slice A 的 Members 设计稿落地：Workspace 管理壳（WorkspaceShell）、
 * 成员表、角色并集提示、搜索/筛选和行内角色编辑。数据经 workspaces 数据层
 * GraphQL 唯一路径（#1 能力接口：行内编辑权限消费 ws.myAbilities），
 * 页面不绕过 assignRoles 契约。
 *
 * U2：Owner 不能在此页行内授予或编辑；Owner 行只展示「专门指派」锁定入口。
 * 行内编辑选项来自 Slice A 的默认角色模板（admin/tutor/volunteer/learner），
 * 同时兼容旧 API 返回的 member 角色展示。
 *
 * #10：keyset 分页累积 + 后端搜索/角色下推 + 加载更多按钮。
 */

import { useCallback, useEffect, useMemo, useState } from "react";
import Link from "next/link";
import { useParams } from "next/navigation";
import { useAuthed } from "@/lib/use-authed";
import { formatJoinedDate } from "@/lib/format";
import { useWorkspaceBySlug } from "@/lib/use-workspace-by-slug";
import {
	assignMemberRoles,
	currentUserCanAssignRoles,
	fetchWorkspaceMembers,
	type WorkspaceMember,
} from "@/lib/workspaces";
import {
	JOIN_POLICY_LABEL,
	ROLE_BADGE_CLASS,
	ROLE_LABEL,
	type MembershipRoleName,
} from "@/lib/graphql/workspace";
import { PERMISSION_ROLE_ORDER } from "@/lib/permissions";
import WorkspaceShell from "@/components/workspace-shell";
import { Icon } from "@/components/icons";

/**
 * 行内分配控件按设计只呈现 Admin/Tutor/Volunteer/Learner（不含 owner，
 * 不含兼容输入的 member）。五行模板单源在 lib/permissions 的 PERMISSION_ROLE_ORDER
 * （由 ROLE_NAMES 过滤派生），此处直接复用，不再本地重复过滤。
 */
const INLINE_ROLE_OPTIONS = PERMISSION_ROLE_ORDER.filter(
	(role): role is Exclude<MembershipRoleName, "owner"> => role !== "owner",
);

type RoleFilter = MembershipRoleName | "all";

function roleLabel(role: MembershipRoleName) {
	return ROLE_LABEL[role] ?? role;
}

function memberName(member: WorkspaceMember) {
	return member.displayName?.trim() || member.email || member.userId;
}

function avatarLetter(member: WorkspaceMember) {
	return Array.from(memberName(member).trim())[0]?.toUpperCase() ?? "?";
}

function memberJoinedAt(member: WorkspaceMember) {
	return formatJoinedDate(member.joinedAt);
}

function MemberRoleChips({ roles }: { roles: MembershipRoleName[] }) {
	if (roles.length === 0) {
		return <span className="members-empty-role">暂无角色</span>;
	}

	return (
		<div className="members-role-chips">
			{roles.map((role) => (
				<span
					key={role}
					className={ROLE_BADGE_CLASS[role]}
					data-testid="role-badge"
				>
					{roleLabel(role)}
				</span>
			))}
		</div>
	);
}

interface RoleEditorProps {
	member: WorkspaceMember;
	roles: MembershipRoleName[];
	saving: boolean;
	onToggle: (role: MembershipRoleName) => void;
	onCancel: () => void;
	onSave: () => void;
}

function RoleEditor({
	member,
	roles,
	saving,
	onToggle,
	onCancel,
	onSave,
}: RoleEditorProps) {
	return (
		<div className="members-role-editor" data-testid="role-editor">
			<div className="members-role-editor__heading">选择角色（不含 Owner）</div>
			<div className="members-role-editor__options">
				{INLINE_ROLE_OPTIONS.map((role) => (
					<label key={role} className="members-role-option">
						<input
							type="checkbox"
							checked={roles.includes(role)}
							onChange={() => onToggle(role)}
							aria-label={`${roleLabel(role)} 角色`}
						/>
						<span>{roleLabel(role)}</span>
					</label>
				))}
			</div>
			<div className="members-role-editor__footer">
				<span>{memberName(member)}</span>
				<div>
					<button
						type="button"
						className="members-table-action members-table-action--quiet"
						onClick={onCancel}
						disabled={saving}
					>
						取消
					</button>
					<button
						type="button"
						className="members-table-action members-table-action--primary"
						onClick={onSave}
						disabled={saving}
					>
						{saving ? "保存中…" : "保存角色"}
					</button>
				</div>
			</div>
		</div>
	);
}

export default function WorkspaceMembersPage() {
	const params = useParams<{ slug: string }>();
	const slug = params?.slug ?? "";
	// 数据 effect 的认证守卫（壳管渲染/重定向；页面管「未认证不拉数据」）
	const { authed, confirmed } = useAuthed();
	const { ws, loading: wsLoading } = useWorkspaceBySlug(slug);
	const canAssign = currentUserCanAssignRoles(ws);

	const [members, setMembers] = useState<WorkspaceMember[]>([]);
	const [endKeyset, setEndKeyset] = useState<string | null>(null);
	// #10：hasMore 由「累积已加载 < count」派生（count 是 read policy 过滤后的可见总数），
	// 替代 endKeyset 启发式（Ash GraphQL 非 relay keyset 不下发 more?，末页满页时误报）。
	const [visibleCount, setVisibleCount] = useState(0);
	const [loadingMore, setLoadingMore] = useState(false);
	// #10：pageLoading 派生自 fetchKey 不匹配（见下方 effect），不在 effect 体内同步 setState
	const [loadedFetchKey, setLoadedFetchKey] = useState<string | null>(null);
	const [membersWorkspaceId, setMembersWorkspaceId] = useState<string | null>(
		null,
	);
	const [draft, setDraft] = useState<Record<string, MembershipRoleName[]>>({});
	const [editingId, setEditingId] = useState<string | null>(null);
	const [savingId, setSavingId] = useState<string | null>(null);
	const [search, setSearch] = useState("");
	const [roleFilter, setRoleFilter] = useState<RoleFilter>("all");
	const [errorMsg, setErrorMsg] = useState<string | null>(null);

	const wsId = ws?.id;

	// #10：搜索 debounce 300ms，避免每次按键都触发后端查询
	const [debouncedSearch, setDebouncedSearch] = useState("");
	useEffect(() => {
		const timer = setTimeout(() => setDebouncedSearch(search), 300);
		return () => clearTimeout(timer);
	}, [search]);

	// #10：keyset 分页查询，search/roleFilter 变化时重置从头查。
	// pageLoading 由 fetchKey 不匹配派生，不在 effect 体内同步 setState（避免级联渲染）。
	const fetchKey = `${wsId ?? ""}|${debouncedSearch}|${roleFilter}`;
	const pageLoading = loadedFetchKey !== fetchKey;
	// #10：hasMore 派生自累积已加载数 < 可见总数（count），比 endKeyset 启发式准确
	const hasMore = members.length < visibleCount;

	useEffect(() => {
		if (!confirmed || !authed) return;
		if (!wsId) return;

		let cancelled = false;
		const searchVal = debouncedSearch.trim() || undefined;
		const roleVal = roleFilter === "all" ? undefined : roleFilter;
		const key = fetchKey;

		fetchWorkspaceMembers(wsId, {
			search: searchVal,
			role: roleVal,
			first: 50,
		})
			.then((page) => {
				if (cancelled) return;
				setMembers(page.members);
				setEndKeyset(page.endKeyset);
				setVisibleCount(page.count);
				setMembersWorkspaceId(wsId);
				setLoadedFetchKey(key);
				setEditingId(null);
				setDraft(
					Object.fromEntries(
						page.members.map((member) => [
							member.membershipId,
							[...member.roles],
						]),
					),
				);
				setErrorMsg(null);
			})
			.catch((error: unknown) => {
				if (cancelled) return;
				setMembers([]);
				setEndKeyset(null);
				setVisibleCount(0);
				setMembersWorkspaceId(wsId);
				setLoadedFetchKey(key);
				setEditingId(null);
				setErrorMsg(
					error instanceof Error ? error.message : "加载成员失败",
				);
			});

		return () => {
			cancelled = true;
		};
	}, [authed, confirmed, wsId, debouncedSearch, roleFilter, fetchKey]);

	const currentMembers = membersWorkspaceId === wsId ? members : null;

	// P2-5：区分「工作区总成员数」（memberCount，物理计数）与「当前可见成员数」
	// （workspaceMembers，Ash read policy 过滤后的可见列表）。非 Owner/Admin 只能看到自己，
	// 计数以 memberCount 为主，并标注可见范围，避免两个语义不同的数字并列误导。
	const visibleMemberCount = currentMembers?.length ?? 0;
	const totalMemberCount = ws?.memberCount ?? visibleMemberCount;
	const isLimitedMemberView =
		!canAssign && totalMemberCount > visibleMemberCount;

	// #10：搜索/角色已由后端下推，members 即为应展示的全部已加载行，不再本地过滤

	const roleFilterOptions = useMemo(() => {
		const extras = (currentMembers ?? [])
			.flatMap((member) => member.roles)
			.filter(
				(role, index, roles) =>
					!PERMISSION_ROLE_ORDER.includes(role) &&
					roles.indexOf(role) === index,
			);
		return [...PERMISSION_ROLE_ORDER, ...extras];
	}, [currentMembers]);

	const toggleRole = useCallback(
		(membershipId: string, role: MembershipRoleName) => {
			setDraft((current) => {
				const roles = current[membershipId] ?? [];
				const next = roles.includes(role)
					? roles.filter((item) => item !== role)
					: [...roles, role];
				return { ...current, [membershipId]: next };
			});
		},
		[],
	);

	function beginEdit(member: WorkspaceMember) {
		if (!canAssign || member.roles.includes("owner")) return;
		setDraft((current) => ({
			...current,
			[member.membershipId]: [...member.roles],
		}));
		setErrorMsg(null);
		setEditingId(member.membershipId);
	}

	function cancelEdit(member: WorkspaceMember) {
		setDraft((current) => ({
			...current,
			[member.membershipId]: [...member.roles],
		}));
		setEditingId(null);
	}

	async function saveRoles(member: WorkspaceMember) {
		if (!ws || !canAssign || member.roles.includes("owner")) return;
		const roleNames = (draft[member.membershipId] ?? member.roles).filter(
			(role) => role !== "owner",
		);
		// #64 已知陷阱：Admin 编辑自己的行并移除 admin 会造成自杀式降权。
		// 若保存后当前用户不再持有 admin（原本持有），弹出确认；取消则不提交。
		const isSelf =
			ws.myMembershipId != null &&
			member.membershipId === ws.myMembershipId;
		const hadAdmin = member.roles.includes("admin");
		if (isSelf && hadAdmin && !roleNames.includes("admin")) {
			const ok = window.confirm(
				"移除你自己的 Admin 角色将立即失去该 Workspace 的管理权限，确认继续？",
			);
			if (!ok) return;
		}
		setSavingId(member.membershipId);
		setErrorMsg(null);
		try {
			const updated = await assignMemberRoles(
				member.membershipId,
				roleNames,
			);
			setMembers((current) =>
				current.map((item) =>
					item.membershipId === member.membershipId
						? { ...item, roles: updated.roles }
						: item,
				),
			);
			setDraft((current) => ({
				...current,
				[member.membershipId]: [...updated.roles],
			}));
			setEditingId(null);
		} catch (error: unknown) {
			setErrorMsg(
				error instanceof Error ? error.message : "保存角色失败",
			);
		} finally {
			setSavingId(null);
		}
	}

	// #10：加载更多（keyset 游标翻页）。捕获发起时的 fetchKey，await 后若筛选已变则丢弃结果。
	async function loadMore() {
		if (!wsId || !endKeyset) return;
		setLoadingMore(true);
		const searchVal = debouncedSearch.trim() || undefined;
		const roleVal = roleFilter === "all" ? undefined : roleFilter;
		const requestKey = fetchKey;
		try {
			const page = await fetchWorkspaceMembers(wsId, {
				search: searchVal,
				role: roleVal,
				after: endKeyset,
				first: 50,
			});
			if (requestKey !== fetchKey) return; // 筛选已变，结果作废
			setMembers((prev) => [...prev, ...page.members]);
			setEndKeyset(page.endKeyset);
			setVisibleCount(page.count);
			setErrorMsg(null);
		} catch (error: unknown) {
			if (requestKey !== fetchKey) return;
			setErrorMsg(
				error instanceof Error ? error.message : "加载更多成员失败",
			);
		} finally {
			setLoadingMore(false);
		}
	}

	return (
		<WorkspaceShell slug={slug}>
			<div className="ws-page-main__inner">
				<div className="ws-page-breadcrumb" aria-label="页面路径">
					<Link href={`/w/${slug}`}>工作区设置</Link>
					<span>›</span>
					<strong>成员与角色</strong>
				</div>

				<header className="ws-page-heading">
					<div>
						<h1>成员与角色</h1>
						<p>管理工作区成员与角色分配</p>
					</div>
					<div className="members-heading-summary">
						<span>
							{JOIN_POLICY_LABEL[ws?.joinPolicy ?? "open"]} Workspace
						</span>
						<strong>{ws?.name ?? slug}</strong>
					</div>
				</header>

				<nav className="members-tabs" aria-label="成员管理页签">
					<Link
						href={`/w/${slug}/members`}
						className="members-tab members-tab--selected"
						aria-current="page"
					>
						成员
					</Link>
					<Link href={`/w/${slug}/permissions`} className="members-tab">
						权限映射
					</Link>
				</nav>

				<section className="members-notice" aria-label="角色并集说明">
					<div className="members-notice__icon">
						<Icon name="info" size={22} />
					</div>
					<div>
						<strong>多角色权限取并集</strong>
						<p>
							同一成员拥有多个角色时，能力按角色权限并集合并。Owner
							不可在此处行内授予。
						</p>
					</div>
					<div className="members-notice__tenant">
						<Icon name="shield" size={22} />
						<span>租户数据仅在当前 Workspace 内可见</span>
					</div>
				</section>

				{errorMsg && (
					<div className="members-error" role="alert">
						{errorMsg}
					</div>
				)}

				<section className="members-toolbar" aria-label="成员筛选">
					<label className="members-search">
						<Icon name="search" size={20} />
						<input
							value={search}
							onChange={(event) => setSearch(event.target.value)}
							placeholder="搜索姓名或邮箱"
							aria-label="搜索姓名或邮箱"
						/>
					</label>
					<label className="members-filter">
						<select
							value={roleFilter}
							onChange={(event) =>
								setRoleFilter(event.target.value as RoleFilter)
							}
							aria-label="筛选角色"
						>
							<option value="all">全部角色</option>
							{roleFilterOptions.map((role) => (
								<option key={role} value={role}>
									{roleLabel(role)}
								</option>
							))}
						</select>
						<Icon name="chevron" size={17} />
					</label>
					<span className="members-count" data-testid="members-count">
						共 {totalMemberCount} 位成员
						{isLimitedMemberView
							? `（当前仅显示你有权查看的 ${visibleMemberCount} 位）`
							: hasMore
								? ` · 已加载 ${members.length}`
								: ""}
					</span>
				</section>

				{isLimitedMemberView && (
					<section
						className="members-visibility-note"
						aria-label="成员可见范围说明"
						data-testid="members-visibility-note"
					>
						<Icon name="info" size={16} />
						<span>
							仅显示你有权查看的成员（工作区共 {totalMemberCount} 位成员）
						</span>
					</section>
				)}

				<section className="members-table-shell" aria-label="成员列表">
					{wsLoading || pageLoading ? (
						<div
							className="members-table-loading"
							data-testid="members-loading"
						>
							{[0, 1, 2, 3].map((item) => (
								<div key={item} className="members-skeleton-row" />
							))}
						</div>
					) : members.length > 0 ? (
						<>
							<div className="members-table-scroll">
								<table className="members-table">
									<thead>
										<tr>
											<th>成员</th>
											<th>账号</th>
											<th>角色并集</th>
											<th>
												<span className="members-th-with-icon">
													<Icon name="calendar" size={16} />
													加入时间
												</span>
											</th>
											<th>操作</th>
										</tr>
									</thead>
									<tbody>
										{members.map((member) => {
											const isOwner =
												member.roles.includes("owner");
											const isEditing =
												editingId === member.membershipId;
											const currentRoles =
												draft[member.membershipId] ??
												member.roles;
											return (
												<tr
													key={member.membershipId}
													data-testid="member-row"
													className={
														isEditing
															? "members-table__row--editing"
															: undefined
													}
												>
													<td>
														<div className="members-person">
															<span
																className="members-person__avatar"
																aria-hidden="true"
															>
																{avatarLetter(member)}
															</span>
															<strong>
																{memberName(member)}
															</strong>
														</div>
													</td>
													<td>
														<span className="members-account">
															{member.email ?? member.userId}
														</span>
													</td>
													<td>
														<div className="members-role-cell">
															<MemberRoleChips
																roles={currentRoles}
															/>
															{isEditing && (
																<RoleEditor
																	member={member}
																	roles={currentRoles}
																	saving={
																		savingId ===
																		member.membershipId
																	}
																	onToggle={(role) =>
																		toggleRole(
																			member.membershipId,
																			role,
																		)
																	}
																	onCancel={() =>
																		cancelEdit(member)
																	}
																	onSave={() =>
																		saveRoles(member)
																	}
																/>
															)}
														</div>
													</td>
													<td>
														<span className="members-date">
															{memberJoinedAt(member)}
														</span>
													</td>
													<td>
														{isOwner ? (
															<button
																type="button"
																className="members-table-action members-table-action--locked"
																disabled
																title="Owner 角色只能通过专门指派流程变更"
															>
																<Icon name="lock" size={17} />
																专门指派
															</button>
														) : canAssign ? (
															<button
																type="button"
																className="members-table-action members-table-action--primary"
																aria-expanded={isEditing}
																onClick={() =>
																	isEditing
																		? cancelEdit(member)
																		: beginEdit(member)
																}
															>
																{isEditing
																	? "收起编辑"
																	: "编辑角色"}
															</button>
														) : (
															<span className="members-readonly-action">
																仅查看
															</span>
														)}
													</td>
												</tr>
											);
										})}
									</tbody>
								</table>
							</div>
							{hasMore && (
								<div className="members-load-more">
									<button
										type="button"
										data-testid="load-more"
										className="members-table-action members-table-action--primary"
										onClick={loadMore}
										disabled={loadingMore}
									>
										{loadingMore ? "加载中…" : "加载更多"}
									</button>
								</div>
							)}
						</>
					) : (
						<div className="members-empty-table">
							<Icon name="users" size={28} />
							<strong>
								{debouncedSearch.trim()
									? "没有匹配的成员"
									: "暂无成员"}
							</strong>
							<p>
								{debouncedSearch.trim()
									? "调整搜索词或角色筛选后重试。"
									: "当前 Workspace 还没有可展示的成员。"}
							</p>
						</div>
					)}
				</section>

				<footer className="members-page-footer">
					<span>成员角色按 Workspace 隔离；权限按所有角色并集合并。</span>
					{canAssign && (
						<span>
							你当前的角色：
							{(ws?.myRoleNames ?? []).map(roleLabel).join(" + ") || "无"}
						</span>
					)}
				</footer>
			</div>
		</WorkspaceShell>
	);
}
