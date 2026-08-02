"use client";

/**
 * #65 成员与角色管理页 /w/[slug]/members。
 *
 * 页面结构按 slice A 的 Members 设计稿落地：Workspace 管理壳、成员表、
 * 角色并集提示、搜索/筛选和行内角色编辑。数据仍由 workspaces 数据层负责
 * mock/GraphQL 切换，页面不绕过 assignRoles 契约。
 *
 * U2：Owner 不能在此页行内授予或编辑；Owner 行只展示「专门指派」锁定入口。
 * 行内编辑选项来自 Slice A 的默认角色模板（admin/tutor/volunteer/learner），
 * 同时兼容旧 API 返回的 member 角色展示。
 */

import { useCallback, useEffect, useMemo, useState } from "react";
import Link from "next/link";
import { useParams, useRouter } from "next/navigation";
import { clearAuthToken } from "@/lib/auth";
import { useAuthed } from "@/lib/use-authed";
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
import ProfileEntry from "@/components/profile-entry";

/**
 * 设计稿里的默认角色模板。旧 API 返回的 `member` 仍可显示和筛选，
 * 但正式页面的行内分配控件按设计只呈现 Admin/Tutor/Volunteer/Learner。
 */
const DESIGN_ROLE_OPTIONS: MembershipRoleName[] = ["owner", "admin", "tutor", "volunteer", "learner"];
const INLINE_ROLE_OPTIONS = DESIGN_ROLE_OPTIONS.filter(
  (role): role is Exclude<MembershipRoleName, "owner"> => role !== "owner",
);

type RoleFilter = MembershipRoleName | "all";

function Icon({ name, size = 20 }: { name: "grid" | "users" | "settings" | "user" | "search" | "chevron" | "lock" | "info" | "shield" | "calendar"; size?: number }) {
  const common = {
    width: size,
    height: size,
    viewBox: "0 0 24 24",
    fill: "none",
    stroke: "currentColor",
    strokeWidth: 1.7,
    strokeLinecap: "round" as const,
    strokeLinejoin: "round" as const,
    "aria-hidden": true,
  };

  switch (name) {
    case "grid":
      return (
        <svg {...common}>
          <rect x="3" y="3" width="7" height="7" rx="1" />
          <rect x="14" y="3" width="7" height="7" rx="1" />
          <rect x="3" y="14" width="7" height="7" rx="1" />
          <rect x="14" y="14" width="7" height="7" rx="1" />
        </svg>
      );
    case "users":
      return (
        <svg {...common}>
          <path d="M16 21v-1.6a4.4 4.4 0 0 0-4.4-4.4H7.4A4.4 4.4 0 0 0 3 19.4V21" />
          <circle cx="9.5" cy="7.5" r="3.5" />
          <path d="M21 21v-1.5a4.3 4.3 0 0 0-3.2-4.15M16.7 4.1a3.5 3.5 0 0 1 0 6.8" />
        </svg>
      );
    case "settings":
      return (
        <svg {...common}>
          <circle cx="12" cy="12" r="3" />
          <path d="M19.4 15a1.7 1.7 0 0 0 .34 1.88l.06.06-1.7 1.7-.06-.06a1.7 1.7 0 0 0-1.88-.34 1.7 1.7 0 0 0-1.03 1.56V21h-2.4v-.2a1.7 1.7 0 0 0-1.03-1.56 1.7 1.7 0 0 0-1.88.34l-.06.06-1.7-1.7.06-.06A1.7 1.7 0 0 0 8.46 15a1.7 1.7 0 0 0-1.56-1.03H6.7v-2.4h.2A1.7 1.7 0 0 0 8.46 10a1.7 1.7 0 0 0-.34-1.88l-.06-.06 1.7-1.7.06.06a1.7 1.7 0 0 0 1.88.34 1.7 1.7 0 0 0 1.03-1.56V5h2.4v.2a1.7 1.7 0 0 0 1.03 1.56 1.7 1.7 0 0 0 1.88-.34l.06-.06 1.7 1.7-.06.06A1.7 1.7 0 0 0 19.4 10a1.7 1.7 0 0 0 1.56 1.03h.2v2.4h-.2A1.7 1.7 0 0 0 19.4 15Z" />
        </svg>
      );
    case "user":
      return (
        <svg {...common}>
          <circle cx="12" cy="8" r="3.5" />
          <path d="M4 21a8 8 0 0 1 16 0" />
        </svg>
      );
    case "search":
      return (
        <svg {...common}>
          <circle cx="10.8" cy="10.8" r="6.4" />
          <path d="m16 16 4.5 4.5" />
        </svg>
      );
    case "chevron":
      return (
        <svg {...common}>
          <path d="m8 10 4 4 4-4" />
        </svg>
      );
    case "lock":
      return (
        <svg {...common}>
          <rect x="5" y="10" width="14" height="10" rx="2" />
          <path d="M8 10V7a4 4 0 0 1 8 0v3M12 14v2" />
        </svg>
      );
    case "info":
      return (
        <svg {...common}>
          <circle cx="12" cy="12" r="9" />
          <path d="M12 10.5v5M12 7.5h.01" />
        </svg>
      );
    case "shield":
      return (
        <svg {...common}>
          <path d="M12 3 19 6v5c0 4.7-2.9 8.1-7 10-4.1-1.9-7-5.3-7-10V6l7-3Z" />
          <path d="m9.3 12 1.8 1.8 3.7-4" />
        </svg>
      );
    case "calendar":
      return (
        <svg {...common}>
          <rect x="4" y="5" width="16" height="15" rx="2" />
          <path d="M8 3v4M16 3v4M4 10h16" />
        </svg>
      );
  }
}

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
  return member.joinedAt ?? "—";
}

function MemberRoleChips({ roles }: { roles: MembershipRoleName[] }) {
  if (roles.length === 0) {
    return <span className="members-empty-role">暂无角色</span>;
  }

  return (
    <div className="members-role-chips">
      {roles.map((role) => (
        <span key={role} className={ROLE_BADGE_CLASS[role]} data-testid="role-badge">
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

function RoleEditor({ member, roles, saving, onToggle, onCancel, onSave }: RoleEditorProps) {
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
          <button type="button" className="members-table-action members-table-action--quiet" onClick={onCancel} disabled={saving}>
            取消
          </button>
          <button type="button" className="members-table-action members-table-action--primary" onClick={onSave} disabled={saving}>
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
  const router = useRouter();
  const { authed, confirmed } = useAuthed();
  const { ws, loading: wsLoading } = useWorkspaceBySlug(slug);
  const canAssign = currentUserCanAssignRoles(ws);

  const [members, setMembers] = useState<WorkspaceMember[] | null>(null);
  const [membersWorkspaceId, setMembersWorkspaceId] = useState<string | null>(null);
  const [draft, setDraft] = useState<Record<string, MembershipRoleName[]>>({});
  const [editingId, setEditingId] = useState<string | null>(null);
  const [savingId, setSavingId] = useState<string | null>(null);
  const [search, setSearch] = useState("");
  const [roleFilter, setRoleFilter] = useState<RoleFilter>("all");
  const [errorMsg, setErrorMsg] = useState<string | null>(null);

  const wsId = ws?.id;

  useEffect(() => {
    if (!confirmed) return;
    if (!authed) {
      router.replace("/login");
      return;
    }
    if (!wsId) return;

    let cancelled = false;
    fetchWorkspaceMembers(wsId)
      .then((list) => {
        if (cancelled) return;
        setMembers(list);
        setMembersWorkspaceId(wsId);
        setEditingId(null);
        setDraft(Object.fromEntries(list.map((member) => [member.membershipId, [...member.roles]])));
        setErrorMsg(null);
      })
      .catch((error: unknown) => {
        if (cancelled) return;
        setMembers([]);
        setMembersWorkspaceId(wsId);
        setEditingId(null);
        setErrorMsg(error instanceof Error ? error.message : "加载成员失败");
      });

    return () => {
      cancelled = true;
    };
  }, [authed, confirmed, router, wsId]);

  const currentMembers = membersWorkspaceId === wsId ? members : null;

  const visibleMembers = useMemo(() => {
    if (!currentMembers) return [];
    const needle = search.trim().toLowerCase();
    return currentMembers.filter((member) => {
      const matchesSearch = !needle || [memberName(member), member.email, member.userId]
        .filter(Boolean)
        .some((value) => value!.toLowerCase().includes(needle));
      const matchesRole = roleFilter === "all" || member.roles.includes(roleFilter);
      return matchesSearch && matchesRole;
    });
  }, [currentMembers, roleFilter, search]);

  const roleFilterOptions = useMemo(() => {
    const extras = (currentMembers ?? [])
      .flatMap((member) => member.roles)
      .filter((role, index, roles) => !DESIGN_ROLE_OPTIONS.includes(role) && roles.indexOf(role) === index);
    return [...DESIGN_ROLE_OPTIONS, ...extras];
  }, [currentMembers]);

  const toggleRole = useCallback((membershipId: string, role: MembershipRoleName) => {
    setDraft((current) => {
      const roles = current[membershipId] ?? [];
      const next = roles.includes(role) ? roles.filter((item) => item !== role) : [...roles, role];
      return { ...current, [membershipId]: next };
    });
  }, []);

  function beginEdit(member: WorkspaceMember) {
    if (!canAssign || member.roles.includes("owner")) return;
    setDraft((current) => ({ ...current, [member.membershipId]: [...member.roles] }));
    setErrorMsg(null);
    setEditingId(member.membershipId);
  }

  function cancelEdit(member: WorkspaceMember) {
    setDraft((current) => ({ ...current, [member.membershipId]: [...member.roles] }));
    setEditingId(null);
  }

  async function saveRoles(member: WorkspaceMember) {
    if (!ws || !canAssign || member.roles.includes("owner")) return;
    const roleNames = (draft[member.membershipId] ?? member.roles).filter((role) => role !== "owner");
    // #64 已知陷阱：Admin 编辑自己的行并移除 admin 会造成自杀式降权。
    // 若保存后当前用户不再持有 admin（原本持有），弹出确认；取消则不提交。
    const isSelf = ws.myMembershipId != null && member.membershipId === ws.myMembershipId;
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
      const updated = await assignMemberRoles(ws.id, member.membershipId, roleNames);
      setMembers((current) => current?.map((item) => item.membershipId === member.membershipId ? { ...item, roles: updated.roles } : item) ?? current);
      setDraft((current) => ({ ...current, [member.membershipId]: [...updated.roles] }));
      setEditingId(null);
    } catch (error: unknown) {
      setErrorMsg(error instanceof Error ? error.message : "保存角色失败");
    } finally {
      setSavingId(null);
    }
  }

  function handleSignOut() {
    clearAuthToken();
    router.push("/login");
  }

  if (!authed) {
    return (
      <main className="members-loading">
        <span>正在确认登录状态…</span>
      </main>
    );
  }

  if (!ws && !wsLoading) {
    return (
      <main className="members-page">
        <div className="members-empty-page">
          <h1>工作区不可访问</h1>
          <p>工作区「{slug}」不存在或你没有访问权限。</p>
          <Link href="/" className="members-primary-link">返回工作台</Link>
        </div>
      </main>
    );
  }

  return (
    <div className="members-page">
      <aside className="members-sidebar">
        <div className="members-brand">
          <span className="members-brand__mark">CGC</span>
          <span>上海 Coding Girls Club</span>
          <span className="members-brand__chevron">⌄</span>
        </div>

        <div className="members-workspace-context">
          <span>当前 Workspace</span>
          <strong>{ws?.name ?? slug}</strong>
          <code>{ws?.slug ?? slug}</code>
        </div>

        <div className="members-sidebar__heading">Workspace 设置</div>
        <nav className="members-sidebar__nav" aria-label="Workspace 设置">
          <Link href={`/w/${slug}`} className="members-sidebar__item">
            <Icon name="grid" />
            <span>概览</span>
          </Link>
          <Link href={`/w/${slug}/members`} className="members-sidebar__item members-sidebar__item--selected" aria-current="page">
            <Icon name="users" />
            <span>成员与角色</span>
          </Link>
          <button type="button" className="members-sidebar__item members-sidebar__item--disabled" disabled title="Workspace 设置将在后续版本开放">
            <Icon name="settings" />
            <span>工作区设置</span>
          </button>
          <Link href="/profile" className="members-sidebar__item">
            <Icon name="user" />
            <span>个人资料</span>
          </Link>
        </nav>

        <div className="members-sidebar__footer">
          <ProfileEntry />
          <button type="button" className="members-signout" onClick={handleSignOut}>退出登录</button>
        </div>
      </aside>

      <main className="members-main">
        <div className="members-main__inner">
          <div className="members-breadcrumb" aria-label="页面路径">
            <Link href={`/w/${slug}`}>Workspace 设置</Link>
            <span>›</span>
            <strong>成员与角色</strong>
          </div>

          <header className="members-heading">
            <div>
              <h1>成员与角色</h1>
              <p>管理工作区成员与角色分配</p>
            </div>
            <div className="members-heading__workspace">
              <span>{JOIN_POLICY_LABEL[ws?.joinPolicy ?? "open"]} Workspace</span>
              <strong>{ws?.name ?? slug}</strong>
            </div>
          </header>

          <nav className="members-tabs" aria-label="成员管理页签">
            <Link href={`/w/${slug}/members`} className="members-tab members-tab--selected" aria-current="page">成员</Link>
            <Link href={`/w/${slug}/permissions`} className="members-tab">权限映射</Link>
          </nav>

          <section className="members-notice" aria-label="角色并集说明">
            <div className="members-notice__icon"><Icon name="info" size={22} /></div>
            <div>
              <strong>多角色权限取并集</strong>
              <p>同一成员拥有多个角色时，能力按角色权限并集合并。Owner 不可在此处行内授予。</p>
            </div>
            <div className="members-notice__tenant"><Icon name="shield" size={22} /><span>租户数据仅在当前 Workspace 内可见</span></div>
          </section>

          {errorMsg && <div className="members-error" role="alert">{errorMsg}</div>}

          <section className="members-toolbar" aria-label="成员筛选">
            <label className="members-search">
              <Icon name="search" size={20} />
              <input value={search} onChange={(event) => setSearch(event.target.value)} placeholder="搜索姓名或邮箱" aria-label="搜索姓名或邮箱" />
            </label>
            <label className="members-filter">
              <select value={roleFilter} onChange={(event) => setRoleFilter(event.target.value as RoleFilter)} aria-label="筛选角色">
                <option value="all">全部角色</option>
                {roleFilterOptions.map((role) => <option key={role} value={role}>{roleLabel(role)}</option>)}
              </select>
              <Icon name="chevron" size={17} />
            </label>
            <span className="members-count">共 {currentMembers?.length ?? 0} 位成员{visibleMembers.length !== (currentMembers?.length ?? 0) ? ` · 显示 ${visibleMembers.length}` : ""}</span>
          </section>

          <section className="members-table-shell" aria-label="成员列表">
            {wsLoading || currentMembers === null ? (
              <div className="members-table-loading" data-testid="members-loading">
                {[0, 1, 2, 3].map((item) => <div key={item} className="members-skeleton-row" />)}
              </div>
            ) : visibleMembers.length > 0 ? (
              <div className="members-table-scroll">
                <table className="members-table">
                  <thead>
                    <tr>
                      <th>成员</th>
                      <th>账号</th>
                      <th>角色并集</th>
                      <th><span className="members-th-with-icon"><Icon name="calendar" size={16} />加入时间</span></th>
                      <th>操作</th>
                    </tr>
                  </thead>
                  <tbody>
                    {visibleMembers.map((member) => {
                      const isOwner = member.roles.includes("owner");
                      const isEditing = editingId === member.membershipId;
                      const currentRoles = draft[member.membershipId] ?? member.roles;
                      return (
                        <tr key={member.membershipId} data-testid="member-row" className={isEditing ? "members-table__row--editing" : undefined}>
                          <td>
                            <div className="members-person">
                              <span className="members-person__avatar" aria-hidden="true">{avatarLetter(member)}</span>
                              <strong>{memberName(member)}</strong>
                            </div>
                          </td>
                          <td><span className="members-account">{member.email ?? member.userId}</span></td>
                          <td>
                            <div className="members-role-cell">
                              <MemberRoleChips roles={currentRoles} />
                              {isEditing && <RoleEditor member={member} roles={currentRoles} saving={savingId === member.membershipId} onToggle={(role) => toggleRole(member.membershipId, role)} onCancel={() => cancelEdit(member)} onSave={() => saveRoles(member)} />}
                            </div>
                          </td>
                          <td><span className="members-date">{memberJoinedAt(member)}</span></td>
                          <td>
                            {isOwner ? (
                              <button type="button" className="members-table-action members-table-action--locked" disabled title="Owner 角色只能通过专门指派流程变更">
                                <Icon name="lock" size={17} />专门指派
                              </button>
                            ) : canAssign ? (
                              <button type="button" className="members-table-action members-table-action--primary" aria-expanded={isEditing} onClick={() => isEditing ? cancelEdit(member) : beginEdit(member)}>
                                {isEditing ? "收起编辑" : "编辑角色"}
                              </button>
                            ) : (
                              <span className="members-readonly-action">仅查看</span>
                            )}
                          </td>
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>
            ) : (
              <div className="members-empty-table">
                <Icon name="users" size={28} />
                <strong>{currentMembers.length > 0 ? "没有匹配的成员" : "暂无成员"}</strong>
                <p>{currentMembers.length > 0 ? "调整搜索词或角色筛选后重试。" : "当前 Workspace 还没有可展示的成员。"}</p>
              </div>
            )}
          </section>

          <footer className="members-page-footer">
            <span>成员角色按 Workspace 隔离；权限按所有角色并集合并。</span>
            {canAssign && <span>你当前的角色：{(ws?.myRoleNames ?? []).map(roleLabel).join(" + ") || "无"}</span>}
          </footer>
        </div>
      </main>
    </div>
  );
}
