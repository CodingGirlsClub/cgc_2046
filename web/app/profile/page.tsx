"use client";

/**
 * #69 个人资料页 /profile。
 *
 * 功能：
 * - 查看当前用户资料：头像（avatarUrl 或首字母圆形兜底）/ 展示名 / email / 平台管理员标记；
 * - 编辑：展示名可编辑（input + 保存），保存调 updateCurrentProfile（mock 内存更新），
 *   成功后刷新展示并提示；
 * - 角色汇总：当前用户所进入 Workspace 列表 + 各工作台角色并集徽章（owner/admin/member）；
 * - 数据：mock 先行（lib/profile + lib/workspaces），后端 #68 定稿后切真实
 *   （USE_MOCK_WORKSPACES = false 即可，调用方无需改）。
 */

import { useCallback, useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import Link from "next/link";
import { clearAuthToken } from "@/lib/auth";
import { useAuthed } from "@/lib/use-authed";
import {
  fetchCurrentProfile,
  fetchProfileRoleSummary,
  updateCurrentProfile,
  type CurrentProfile,
  type ProfileRoleSummary,
} from "@/lib/profile";
import {
  ROLE_BADGE_CLASS,
  ROLE_LABEL,
  ROLE_LABEL_ZH,
} from "@/lib/graphql/workspace";

export default function ProfilePage() {
  const router = useRouter();
  // useAuthed()：首帧固定未确认/未登录（SSR/客户端 hydration 一致），挂载后读 cookie 确认
  const { authed, confirmed } = useAuthed();

  const [profile, setProfile] = useState<CurrentProfile | null>(null);
  const [roles, setRoles] = useState<ProfileRoleSummary[]>([]);
  const [loading, setLoading] = useState(true);
  // 编辑态：displayName draft
  const [editing, setEditing] = useState(false);
  const [draftName, setDraftName] = useState("");
  const [saving, setSaving] = useState(false);
  const [errorMsg, setErrorMsg] = useState<string | null>(null);
  const [savedMsg, setSavedMsg] = useState<string | null>(null);

  useEffect(() => {
    // 登录态确认前不重定向也不拉取（避免已登录用户被先跳 /login）
    if (!confirmed) return;
    if (!authed) {
      router.replace("/login");
      return;
    }
    let cancelled = false;
    Promise.all([fetchCurrentProfile(), fetchProfileRoleSummary()])
      .then(([p, r]) => {
        if (cancelled) return;
        setProfile(p);
        setRoles(r);
        setDraftName(p.displayName ?? "");
      })
      .catch((e: unknown) => {
        if (!cancelled) setErrorMsg(e instanceof Error ? e.message : "加载资料失败");
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [authed, confirmed, router]);

  function handleSignOut() {
    clearAuthToken();
    router.push("/login");
  }

  const startEdit = useCallback(() => {
    setDraftName(profile?.displayName ?? "");
    setEditing(true);
    setSavedMsg(null);
    setErrorMsg(null);
  }, [profile]);

  const cancelEdit = useCallback(() => {
    setDraftName(profile?.displayName ?? "");
    setEditing(false);
    setErrorMsg(null);
  }, [profile]);

  async function handleSave() {
    const name = draftName.trim();
    if (!name) {
      setErrorMsg("展示名不能为空");
      return;
    }
    setSaving(true);
    setErrorMsg(null);
    try {
      const updated = await updateCurrentProfile({ displayName: name });
      setProfile(updated);
      setDraftName(updated.displayName ?? "");
      setEditing(false);
      setSavedMsg("资料已保存");
    } catch (e) {
      setErrorMsg(e instanceof Error ? e.message : "保存失败");
    } finally {
      setSaving(false);
    }
  }

  if (!authed) {
    return (
      <main className="flex flex-1 items-center justify-center bg-canvas">
        <span className="l-p text-ink-3">加载中…</span>
      </main>
    );
  }

  const avatarText = (profile?.displayName ?? profile?.email ?? "?").slice(0, 1).toUpperCase();

  return (
    <div className="min-h-screen bg-canvas">
      <header className="flex h-[72px] items-center border-b border-line">
        <div className="mx-auto flex w-full max-w-6xl items-center justify-between px-6">
          <div className="flex items-center gap-4">
            <Link href="/" className="l-btn-ghost">
              ← 工作台
            </Link>
            <div>
              <div className="l-overline">Profile · 个人资料</div>
              <h1 className="l-h2 text-ink">我的资料</h1>
            </div>
          </div>
          <button className="l-btn-outline" onClick={handleSignOut}>
            退出登录
          </button>
        </div>
      </header>

      <main className="mx-auto max-w-6xl px-6 py-8">
        {loading ? (
          <div className="grid gap-4 lg:grid-cols-[320px_1fr]">
            <div className="h-64 animate-pulse rounded-large bg-card ring-1 ring-line" />
            <div className="h-64 animate-pulse rounded-large bg-card ring-1 ring-line" />
          </div>
        ) : !profile ? (
          <div className="rounded-large bg-card p-10 text-center ring-1 ring-line">
            <p className="l-p text-ink-2">无法加载个人资料。</p>
            {errorMsg && <p className="l-p mt-1 text-xs text-status-red">{errorMsg}</p>}
          </div>
        ) : (
          <div className="grid gap-4 lg:grid-cols-[320px_1fr]">
            {/* 左：资料卡 */}
            <section className="h-fit rounded-large bg-card p-6 ring-1 ring-line" data-testid="profile-card">
              <div className="flex flex-col items-center text-center">
                {profile.avatarUrl ? (
                  // eslint-disable-next-line @next/next/no-img-element
                  <img
                    src={profile.avatarUrl}
                    alt="头像"
                    className="h-20 w-20 rounded-full object-cover ring-1 ring-line"
                  />
                ) : (
                  <div className="flex h-20 w-20 items-center justify-center rounded-full bg-accent-mentionbg text-2xl font-medium text-accent">
                    {avatarText}
                  </div>
                )}
                <div className="l-h3 mt-4 text-ink" data-testid="profile-display-name">
                  {profile.displayName || "未设置展示名"}
                </div>
                <div className="l-mono mt-1 text-xs text-ink-3">{profile.email}</div>
                <div className="mt-2 flex flex-wrap items-center justify-center gap-1.5">
                  <span className="l-chip">
                    {profile.isPlatformAdmin ? "平台管理员" : "普通用户"}
                  </span>
                  <span className="l-chip">ID {profile.id}</span>
                </div>
              </div>

              {/* 编辑区 */}
              <div className="mt-6 border-t border-line pt-4">
                {!editing ? (
                  <button className="l-btn-outline w-full justify-center" onClick={startEdit}>
                    编辑资料
                  </button>
                ) : (
                  <div className="space-y-2">
                    <label className="l-overline block" htmlFor="display-name-input">
                      展示名
                    </label>
                    <input
                      id="display-name-input"
                      className="l-input w-full"
                      value={draftName}
                      onChange={(e) => setDraftName(e.target.value)}
                      data-testid="display-name-input"
                    />
                    <div className="flex items-center gap-2">
                      <button
                        className="l-btn-primary"
                        disabled={saving}
                        onClick={handleSave}
                        data-testid="save-profile-btn"
                      >
                        {saving ? "保存中…" : "保存"}
                      </button>
                      <button
                        className="l-btn-ghost"
                        disabled={saving}
                        onClick={cancelEdit}
                        data-testid="cancel-edit-btn"
                      >
                        取消
                      </button>
                    </div>
                  </div>
                )}
                {savedMsg && <p className="l-p mt-3 text-sm text-status-green">{savedMsg}</p>}
                {errorMsg && <p className="l-p mt-3 text-sm text-status-red">{errorMsg}</p>}
              </div>
            </section>

            {/* 右：角色汇总 */}
            <section className="rounded-large bg-card p-6 ring-1 ring-line" data-testid="role-summary">
              <div className="l-overline">我的工作区与角色</div>
              <h2 className="l-h3 mt-1 text-ink">角色汇总</h2>
              <p className="l-p mt-1 text-ink-2">当前用户在各 Workspace 的角色并集（owner/admin/member）。</p>

              {roles.length === 0 ? (
                <div className="mt-6 rounded-large bg-soft-2 p-6 text-center ring-1 ring-line">
                  <p className="l-p text-ink-3">还没有可进入的工作台。</p>
                </div>
              ) : (
                <div className="mt-4 space-y-3">
                  {roles.map((r) => (
                    <div
                      key={r.workspaceId}
                      className="flex flex-wrap items-center justify-between gap-3 rounded-large bg-view p-4 ring-1 ring-line"
                      data-testid="role-summary-row"
                    >
                      <div className="min-w-0">
                        <Link
                          href={`/w/${r.workspaceSlug}`}
                          className="l-p font-medium text-ink transition hover:text-accent"
                        >
                          {r.workspaceName}
                        </Link>
                        <div className="l-mono text-xs text-ink-3">{r.workspaceSlug}</div>
                      </div>
                      <div className="flex flex-wrap items-center gap-1.5">
                        {r.myRoleNames.length === 0 ? (
                          <span className="l-chip">无角色 · 受邀</span>
                        ) : (
                          r.myRoleNames.map((role) => (
                            <span key={role} className={ROLE_BADGE_CLASS[role]} data-testid="role-summary-badge">
                              {ROLE_LABEL[role]} · {ROLE_LABEL_ZH[role]}
                            </span>
                          ))
                        )}
                      </div>
                    </div>
                  ))}
                </div>
              )}
            </section>
          </div>
        )}
      </main>
    </div>
  );
}
