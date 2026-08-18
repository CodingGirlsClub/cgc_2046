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
 * 行内编辑选项来自默认角色模板（admin/tutor/volunteer/learner）。
 * 空标签显示「暂无角色」。
 *
 * #10：keyset 分页累积 + 后端搜索/角色下推 + 加载更多按钮。
 */

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import Link from "next/link";
import { useParams } from "next/navigation";
import { useLocale, useTranslations } from "next-intl";
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
	ROLE_BADGE_CLASS,
	ROLE_LABEL,
	type MembershipRoleName,
} from "@/lib/graphql/workspace";
import { PERMISSION_ROLE_ORDER } from "@/lib/permissions";
import WorkspaceShell from "@/components/workspace-shell";
import MembersTabs from "@/components/members-tabs";
import { Icon } from "@/components/icons";

/**
 * 行内分配控件按设计只呈现 Admin/Tutor/Volunteer/Learner（不含 owner）。
 * 五行模板单源在 lib/permissions 的 PERMISSION_ROLE_ORDER
 * （由 ROLE_NAMES 派生），此处直接复用，不再本地重复过滤。
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

function memberJoinedAt(member: WorkspaceMember, locale: string) {
	return formatJoinedDate(member.joinedAt, locale);
}

function MemberRoleChips({ roles }: { roles: MembershipRoleName[] }) {
	const t = useTranslations("workspaceMembers");
	const labelsT = useTranslations();
	if (roles.length === 0) {
		return <span className="members-empty-role">{t("noRoles")}</span>;
	}

	return (
		<div className="members-role-chips">
			{roles.map((role) => (
				<span
					key={role}
					className={ROLE_BADGE_CLASS[role]}
					data-testid="role-badge"
				>
					{labelsT(roleLabel(role))}
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
	const t = useTranslations("workspaceMembers");
	const labelsT = useTranslations();
	return (
		<div className="members-role-editor" data-testid="role-editor">
			<div className="members-role-editor__heading">{t("editHeading")}</div>
			<div className="members-role-editor__options">
				{INLINE_ROLE_OPTIONS.map((role) => (
					<label key={role} className="members-role-option">
						<input
							type="checkbox"
							checked={roles.includes(role)}
							onChange={() => onToggle(role)}
							aria-label={t("roleAria", { role: labelsT(roleLabel(role)) })}
						/>
						<span>{labelsT(roleLabel(role))}</span>
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
						{t("cancel")}
					</button>
					<button
						type="button"
						className="members-table-action members-table-action--primary"
						onClick={onSave}
						disabled={saving}
					>
						{saving ? t("saving") : t("saveRoles")}
					</button>
				</div>
			</div>
		</div>
	);
}

export default function WorkspaceMembersPage() {
	const locale = useLocale();
	const t = useTranslations("workspaceMembers");
	const commonT = useTranslations("common");
	const labelsT = useTranslations();
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
	// loadMore stale guard 需要读取「最新已提交筛选 key」：闭包捕获的 loadedFetchKey 在
	// await 返回后仍是发起时的旧值（与 requestKey 恒等，guard 永不生效），因此用 ref 镜像，
	// 主查询 effect 完成时同步，loadMore 据此丢弃过期页。
	const loadedFetchKeyRef = useRef<string | null>(null);
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
				loadedFetchKeyRef.current = key;
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
				loadedFetchKeyRef.current = key;
				setLoadedFetchKey(key);
				setEditingId(null);
				setErrorMsg(
					error instanceof Error ? error.message : t("loadFailed"),
				);
			});

		return () => {
			cancelled = true;
		};
	}, [authed, confirmed, wsId, debouncedSearch, roleFilter, fetchKey, t]);

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
			const ok = window.confirm(t("removeAdminConfirm"));
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
				error instanceof Error ? error.message : t("saveFailed"),
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
			if (requestKey !== loadedFetchKeyRef.current) return; // 主查询已切新筛选 —— 丢弃过期页
			setMembers((prev) => [...prev, ...page.members]);
			setEndKeyset(page.endKeyset);
			setVisibleCount(page.count);
			setErrorMsg(null);
		} catch (error: unknown) {
			if (requestKey !== loadedFetchKeyRef.current) return;
			setErrorMsg(
				error instanceof Error ? error.message : t("loadMoreFailed"),
			);
		} finally {
			setLoadingMore(false);
		}
	}

	return (
		<WorkspaceShell slug={slug}>
			<div className="ws-page-main__inner">
				<div
					className="ws-page-breadcrumb"
					aria-label={commonT("breadcrumbAria")}
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
						current="members"
						abilities={ws.myAbilities ?? []}
					/>
				)}

				<section
					className="members-notice"
					aria-label={t("noticeAria")}
				>
					<div className="members-notice__icon">
						<Icon name="info" size={22} />
					</div>
					<div>
						<strong>{t("unionNoticeTitle")}</strong>
						<p>{t("unionNoticeDesc")}</p>
					</div>
					<div className="members-notice__tenant">
						<Icon name="shield" size={22} />
						<span>{t("tenantNotice")}</span>
					</div>
				</section>

				{errorMsg && (
					<div className="members-error" role="alert">
						{errorMsg}
					</div>
				)}

				<section className="members-toolbar" aria-label={t("filterAria")}>
					<label className="members-search">
						<Icon name="search" size={20} />
						<input
							value={search}
							onChange={(event) => setSearch(event.target.value)}
							placeholder={t("searchPlaceholder")}
							aria-label={t("searchAria")}
						/>
					</label>
					<label className="members-filter">
						<select
							value={roleFilter}
							onChange={(event) =>
								setRoleFilter(event.target.value as RoleFilter)
							}
							aria-label={t("filterRoleAria")}
						>
							<option value="all">{t("allRoles")}</option>
							{roleFilterOptions.map((role) => (
								<option key={role} value={role}>
									{labelsT(roleLabel(role))}
								</option>
							))}
						</select>
						<Icon name="chevron" size={17} />
					</label>
					<span className="members-count" data-testid="members-count">
						{t("memberCount", { count: totalMemberCount })}
						{isLimitedMemberView
							? t("limitedView", { count: visibleMemberCount })
							: hasMore
								? t("loadedCount", { count: members.length })
								: ""}
					</span>
				</section>

				{isLimitedMemberView && (
					<section
						className="members-visibility-note"
						aria-label={t("visibilityAria")}
						data-testid="members-visibility-note"
					>
						<Icon name="info" size={16} />
						<span>
							{t("visibilityNote", { count: totalMemberCount })}
						</span>
					</section>
				)}

				<section
					className="members-table-shell"
					aria-label={t("listAria")}
				>
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
											<th>{t("thMember")}</th>
											<th>{t("thAccount")}</th>
											<th>{t("thRoles")}</th>
											<th>
												<span className="members-th-with-icon">
													<Icon name="calendar" size={16} />
													{t("thJoinedAt")}
												</span>
											</th>
											<th>{t("thActions")}</th>
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
															{memberJoinedAt(member, locale)}
														</span>
													</td>
													<td>
														{isOwner ? (
															<button
																type="button"
																className="members-table-action members-table-action--locked"
																disabled
																title={t("ownerTitle")}
															>
																<Icon name="lock" size={17} />
																{t("ownerSpecialAssign")}
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
																	? t("collapseEdit")
																	: t("editRoles")}
															</button>
														) : (
															<span className="members-readonly-action">
																{t("readonlyView")}
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
										{loadingMore ? t("loadingMore") : t("loadMore")}
									</button>
								</div>
							)}
						</>
					) : (
						<div className="members-empty-table">
							<Icon name="users" size={28} />
							<strong>
								{debouncedSearch.trim()
									? t("noMatch")
									: t("noMembers")}
							</strong>
							<p>
								{debouncedSearch.trim()
									? t("noMatchHint")
									: t("noMembersHint")}
							</p>
						</div>
					)}
				</section>

				<footer className="members-page-footer">
					<span>{t("footer")}</span>
					{canAssign && (
						<span>
							{t("yourRoles")}
							{(ws?.myRoleNames ?? [])
								.map((role) => labelsT(roleLabel(role)))
								.join(" + ") || t("noRoleValue")}
						</span>
					)}
				</footer>
			</div>
		</WorkspaceShell>
	);
}
