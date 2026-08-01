"use client";

/**
 * #65 成员角色管理页 /w/[slug]/members。
 *
 * 功能：
 * - 成员列表：membershipId / userId / email / 展示名，角色徽章并集展示
 *   （同一成员可持多 role：owner+admin、admin+member…，与后端 multitenancy 多角色并集语义一致）；
 * - 角色分配：Owner/Admin 可在每个成员卡片上勾选角色（多选，替换整组）并保存，
 *   支持 open/request/invite_only 所有工作台；非 Owner/Admin 隐藏分配操作；
 * - 数据：mock 先行（lib/workspaces），后端 #64 完成后切真实 meWorkspaces /
 *   assignRoles（USE_MOCK_WORKSPACES = false 即可，调用方无需改）。
 */

import { useCallback, useEffect, useState } from "react";
import { useParams, useRouter } from "next/navigation";
import Link from "next/link";
import { isAuthenticated, clearAuthToken } from "@/lib/auth";
import {
  MOCK_WORKSPACES,
  fetchWorkspaceMembers,
  assignMemberRoles,
  currentUserCanAssignRoles,
  type WorkspaceListItem,
  type WorkspaceMember,
} from "@/lib/workspaces";
import {
  JOIN_POLICY_LABEL,
  MEMBERSHIP_ROLES,
  ROLE_BADGE_CLASS,
  ROLE_LABEL,
  ROLE_LABEL_ZH,
  type MembershipRoleName,
} from "@/lib/graphql/workspace";

export default function WorkspaceMembersPage() {
  const params = useParams<{ slug: string }>();
  const slug = params?.slug ?? "";
  const router = useRouter();
  const authed = isAuthenticated();

  const ws: WorkspaceListItem | undefined = MOCK_WORKSPACES.find((w) => w.slug === slug);
  const canAssign = currentUserCanAssignRoles(ws);

  const [members, setMembers] = useState<WorkspaceMember[] | null>(null);
  // 初始 loading 与 ws 是否存在关联：无 ws 直接显示不存在，无需 loading 态
  const [loading, setLoading] = useState(Boolean(ws));
  const [savingId, setSavingId] = useState<string | null>(null);
  const [errorMsg, setErrorMsg] = useState<string | null>(null);
  /** 正在编辑的成员的待保存角色选择（membershipId -> 角色数组） */
  const [draft, setDraft] = useState<Record<string, MembershipRoleName[]>>({});

  useEffect(() => {
    if (!authed) {
      router.replace("/login");
      return;
    }
    if (!ws) {
      // 无 ws：loading 初始即 false（useState(Boolean(ws))），直接展示不存在
      return;
    }
    fetchWorkspaceMembers(ws.id)
      .then((list) => {
        setMembers(list);
        // 初始化草稿为当前角色（供 Owner/Admin 修改）
        setDraft(Object.fromEntries(list.map((m) => [m.membershipId, [...m.roles]])));
        setErrorMsg(null);
      })
      .catch((e: unknown) => {
        setErrorMsg(e instanceof Error ? e.message : "加载成员失败");
      })
      .finally(() => setLoading(false));
  }, [authed, router, ws]);

  function handleSignOut() {
    clearAuthToken();
    router.push("/login");
  }

  const toggleRole = useCallback(
    (membershipId: string, role: MembershipRoleName) => {
      setDraft((prev) => {
        const cur = prev[membershipId] ?? [];
        const next = cur.includes(role)
          ? cur.filter((r) => r !== role)
          : [...cur, role];
        return { ...prev, [membershipId]: next };
      });
    },
    [],
  );

  async function handleSave(member: WorkspaceMember) {
    if (!ws) return;
    const roleNames = draft[member.membershipId] ?? member.roles;
    setSavingId(member.membershipId);
    setErrorMsg(null);
    try {
      const updated = await assignMemberRoles(ws.id, member.membershipId, roleNames);
      setMembers((prev) =>
        prev
          ? prev.map((m) =>
              m.membershipId === member.membershipId ? { ...m, roles: updated.roles } : m,
            )
          : prev,
      );
    } catch (e) {
      setErrorMsg(e instanceof Error ? e.message : "保存失败");
    } finally {
      setSavingId(null);
    }
  }

  if (!authed) {
    return (
      <main className="flex flex-1 items-center justify-center bg-canvas">
        <span className="l-p text-ink-3">加载中…</span>
      </main>
    );
  }

  return (
    <div className="min-h-screen bg-canvas">
      <header className="flex h-[72px] items-center border-b border-line">
        <div className="mx-auto flex w-full max-w-6xl items-center justify-between px-6">
          <div className="flex items-center gap-4">
            <Link href={`/w/${slug}`} className="l-btn-ghost">
              ← 返回工作区
            </Link>
            <div>
              <div className="l-overline">Members · 成员角色管理</div>
              <h1 className="l-h2 text-ink">{ws?.name ?? slug} / 成员</h1>
            </div>
          </div>
          <button className="l-btn-outline" onClick={handleSignOut}>
            退出登录
          </button>
        </div>
      </header>

      <main className="mx-auto max-w-6xl px-6 py-8">
        {!ws ? (
          <div className="rounded-large bg-card p-10 text-center ring-1 ring-line">
            <p className="l-p text-ink-2">工作区「{slug}」不存在或不可访问。</p>
            <Link href="/" className="l-btn-ghost mt-4 inline-block">
              ← 工作台
            </Link>
          </div>
        ) : (
          <>
            {/* 工作台上下文信息 */}
            <div className="mb-6 flex flex-wrap items-center gap-2">
              <span className="l-chip">{JOIN_POLICY_LABEL[ws.joinPolicy]}工作台</span>
              <span className="l-chip">
                {canAssign ? "你是 Owner/Admin，可分配角色" : "仅 Owner/Admin 可分配角色"}
              </span>
              {ws.myRoleNames && ws.myRoleNames.length > 0 && (
                <span className="l-chip">
                  我的角色：{ws.myRoleNames.map((r) => ROLE_LABEL_ZH[r]).join(" + ")}
                </span>
              )}
            </div>

            {errorMsg && (
              <div className="mb-4 rounded-large bg-card p-3 text-sm text-status-red ring-1 ring-line">
                {errorMsg}
              </div>
            )}

            {loading ? (
              <div className="space-y-3">
                {[0, 1, 2].map((i) => (
                  <div key={i} className="h-16 animate-pulse rounded-large bg-card ring-1 ring-line" />
                ))}
              </div>
            ) : members && members.length > 0 ? (
              <div className="space-y-3">
                {members.map((m) => {
                  const currentRoles = draft[m.membershipId] ?? m.roles;
                  return (
                    <div
                      key={m.membershipId}
                      className="rounded-large bg-card p-4 ring-1 ring-line"
                      data-testid="member-card"
                    >
                      <div className="flex flex-wrap items-center justify-between gap-3">
                        <div className="flex items-center gap-3">
                          {/* 头像：displayName/email 首字母 */}
                          <div className="flex h-9 w-9 items-center justify-center rounded-full bg-accent-mentionbg text-sm font-medium text-accent">
                            {(m.displayName ?? m.email ?? m.userId).slice(0, 1).toUpperCase()}
                          </div>
                          <div>
                            <div className="l-p font-medium text-ink">
                              {m.displayName ?? m.email ?? m.userId}
                            </div>
                            <div className="l-mono text-xs text-ink-3">{m.email ?? m.userId}</div>
                          </div>
                        </div>
                        {/* 角色并集徽章 */}
                        <div className="flex flex-wrap items-center gap-1.5">
                          {currentRoles.length === 0 ? (
                            <span className="l-chip">无角色</span>
                          ) : (
                            currentRoles.map((r) => (
                              <span key={r} className={ROLE_BADGE_CLASS[r]} data-testid="role-badge">
                                {ROLE_LABEL[r]} · {ROLE_LABEL_ZH[r]}
                              </span>
                            ))
                          )}
                        </div>
                      </div>

                      {/* 角色分配：仅 Owner/Admin 可见 */}
                      {canAssign && (
                        <div className="mt-3 flex flex-wrap items-center gap-4 border-t border-line pt-3">
                          <div className="flex flex-wrap items-center gap-2">
                            {MEMBERSHIP_ROLES.map((role) => {
                              const checked = currentRoles.includes(role);
                              return (
                                <label
                                  key={role}
                                  className={`l-chip cursor-pointer select-none ${checked ? "!text-accent" : ""}`}
                                >
                                  <input
                                    type="checkbox"
                                    className="accent-[var(--accent)]"
                                    checked={checked}
                                    onChange={() => toggleRole(m.membershipId, role)}
                                  />
                                  {ROLE_LABEL[role]}
                                </label>
                              );
                            })}
                          </div>
                          <button
                            className="l-btn-primary ml-auto"
                            disabled={savingId === m.membershipId}
                            onClick={() => handleSave(m)}
                          >
                            {savingId === m.membershipId ? "保存中…" : "保存角色"}
                          </button>
                        </div>
                      )}

                      {/* 成员标识信息 */}
                      <div className="l-mono mt-2 text-xs text-ink-3">
                        membership {m.membershipId} · user {m.userId}
                      </div>
                    </div>
                  );
                })}
              </div>
            ) : (
              <div className="rounded-large bg-card p-10 text-center ring-1 ring-line">
                <p className="l-p text-ink-2">暂无成员。</p>
              </div>
            )}
          </>
        )}
      </main>
    </div>
  );
}
