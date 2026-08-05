"use client";

/**
 * #69 Profile 查看 / 编辑。
 *
 * 视觉与信息架构按 08-profile-view-light-v3 / 09-profile-edit-dark 落地：
 * - 查看态展示租户内可见的摘要、关于我、技能、作品集预览和角色并集；
 * - 首页只展示前三个作品，完整列表通过“查看全部 N 个作品”入口承载；
 * - 编辑态把基本资料、只读的 Workspace 身份和 Portfolio 编辑区分开；
 * - #68 API 当前只保证 displayName/avatarUrl，其他字段保留为前端可扩展资料模型。
 */

import { Suspense, useCallback, useEffect, useMemo, useState } from "react";
import { useSearchParams } from "next/navigation";
import { useAuthed } from "@/lib/use-authed";
import WorkspaceShell from "@/components/workspace-shell";
import { Icon } from "@/components/icons";
import {
  createPortfolioItem,
  deletePortfolioItem,
  fetchCurrentProfile,
  fetchPortfolioItems,
  fetchProfileRoleSummary,
  updateCurrentProfile,
  updatePortfolioItem,
  getProfileContent,
  toDraft,
  type CurrentProfile,
  type ProfileDraft,
  type ProfilePortfolioItem,
  type ProfileRoleSummary,
  VISIBILITY_FOOTER_TEXT,
} from "@/lib/profile";
import {
  Breadcrumb,
  ProfileSummary,
  ViewContent,
} from "./_sections/view-sections";
import { EditContent } from "./_sections/edit-content";

function ProfilePageInner() {
  // 数据 effect 的认证守卫（壳管渲染/重定向；页面管「未认证不拉数据」）
  const { authed, confirmed } = useAuthed();
  const [profile, setProfile] = useState<CurrentProfile | null>(null);
  const [summaries, setSummaries] = useState<ProfileRoleSummary[]>([]);
  const [loading, setLoading] = useState(true);
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState<ProfileDraft | null>(null);
  const [saving, setSaving] = useState(false);
  const [errorMsg, setErrorMsg] = useState<string | null>(null);
  const [savedMsg, setSavedMsg] = useState<string | null>(null);

  useEffect(() => {
    if (!confirmed || !authed) return;
    let cancelled = false;
    Promise.all([
      fetchCurrentProfile(),
      fetchProfileRoleSummary(),
      fetchPortfolioItems(),
    ])
      .then(([nextProfile, nextSummaries, portfolio]) => {
        if (cancelled) return;
        const withPortfolio = { ...nextProfile, portfolio };
        setProfile(withPortfolio);
        setSummaries(nextSummaries);
        // P2-2：不再在加载时预填 draft，进入编辑态时再从真实值初始化（startEdit）
        setDraft(null);
        setErrorMsg(null);
      })
      .catch((error: unknown) => {
        if (!cancelled)
          setErrorMsg(error instanceof Error ? error.message : "加载资料失败");
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [authed, confirmed]);

  const wsSlug = useSearchParams().get("ws");
  const content = useMemo(
    () => (profile ? getProfileContent(profile, summaries, wsSlug) : null),
    [profile, summaries, wsSlug],
  );
  const workspaceSlug = content?.workspaceSlug || "";

  const startEdit = useCallback(() => {
    if (!content) return;
    setDraft(toDraft(content));
    setEditing(true);
    setSavedMsg(null);
    setErrorMsg(null);
  }, [content]);

  const cancelEdit = useCallback(() => {
    if (content) setDraft(toDraft(content));
    setEditing(false);
    setErrorMsg(null);
  }, [content]);

  async function handleSave() {
    if (!profile || !draft) return;
    const name = draft.name.trim();
    if (!name) {
      setErrorMsg("姓名不能为空");
      return;
    }
    setSaving(true);
    setErrorMsg(null);
    try {
      // P1：真实分支提交全部可编辑字段（displayName/avatarUrl/location/about/skills/visibility），
      // 修复 G8 假保存——扩展字段不再只留在前端状态伪造。
      const updated = await updateCurrentProfile({
        displayName: name,
        avatarUrl: draft.avatarUrl,
        location: draft.location,
        about: draft.about,
        skills: draft.skills,
        visibility: draft.visibility,
      });
      // P1：同步作品集 CRUD（新增/删除/变更 diff 提交后端，真实模式）
      await syncPortfolioChanges(profile, draft.portfolio);
      // 保存成功后重新拉取作品集，确保 id 与后端一致（新增条目由后端生成 uuid）
      const refreshedPortfolio = await fetchPortfolioItems();
      setProfile({
        ...profile,
        ...updated,
        displayName: name,
        avatarUrl: draft.avatarUrl,
        location: draft.location,
        about: draft.about,
        skills: draft.skills,
        visibility: draft.visibility,
        portfolio: refreshedPortfolio,
      });
      setEditing(false);
      setSavedMsg("资料已保存");
    } catch (error: unknown) {
      setErrorMsg(error instanceof Error ? error.message : "保存失败");
    } finally {
      setSaving(false);
    }
  }

  /** 作品集 diff 同步：新增条目 create、被移除条目 delete、内容变化条目 update（P1 CRUD 接线） */
  async function syncPortfolioChanges(
    prev: CurrentProfile,
    next: ProfilePortfolioItem[],
  ) {
    const original = new Map(
      (prev.portfolio ?? []).map((item) => [item.id, item]),
    );
    const nextIds = new Set(next.map((item) => item.id));
    for (const item of next) {
      const orig = original.get(item.id);
      if (!orig) {
        await createPortfolioItem({
          title: item.title,
          description: item.description,
          url: item.url ?? null,
          icon: item.icon ?? "document",
        });
      } else if (
        orig.title !== item.title ||
        (orig.description ?? "") !== (item.description ?? "") ||
        (orig.url ?? null) !== (item.url ?? null) ||
        (orig.icon ?? "document") !== (item.icon ?? "document")
      ) {
        await updatePortfolioItem(item.id, {
          title: item.title,
          description: item.description,
          url: item.url ?? null,
          icon: item.icon ?? "document",
        });
      }
    }
    for (const item of prev.portfolio ?? []) {
      if (!nextIds.has(item.id)) {
        await deletePortfolioItem(item.id);
      }
    }
  }

  if (loading) {
    return (
      <WorkspaceShell slug={workspaceSlug} requireWs={false}>
        <div className="profile-main__inner">
          <div className="profile-skeleton" />
        </div>
      </WorkspaceShell>
    );
  }

  if (!profile || !content) {
    return (
      <main className="profile-loading">
        <strong>无法加载个人资料</strong>
        <span>{errorMsg || "请稍后重试。"}</span>
      </main>
    );
  }

  const currentDraft = draft ?? toDraft(content);
  // P2-1：底部可见范围文案随当前可见范围联动（编辑态实时预览 draft，查看态用真实值）
  const footerVisibility = editing
    ? currentDraft.visibility
    : content.visibility;

  return (
    <WorkspaceShell
      slug={workspaceSlug}
      requireWs={false}
      workspaceName={content.workspaceName || undefined}
      className={editing ? "ws-shell-page--editing" : undefined}
    >
      <div className="profile-main__inner">
        <Breadcrumb
          editing={editing}
          workspaceSlug={workspaceSlug}
          workspaceName={content.workspaceName || ""}
        />
        <header className="profile-heading">
          <h1>{editing ? "编辑个人资料" : "我的个人资料"}</h1>
          {editing ? (
            <div className="profile-heading__actions">
              <button
                type="button"
                className="profile-button profile-button--quiet"
                onClick={cancelEdit}
                disabled={saving}
              >
                取消
              </button>
              <button
                type="button"
                className="profile-button profile-button--primary"
                onClick={handleSave}
                disabled={saving}
              >
                {saving ? "保存中…" : "保存更改"}
              </button>
            </div>
          ) : (
            <button
              type="button"
              className="profile-button profile-button--outline"
              onClick={startEdit}
            >
              <Icon name="edit" size={18} />
              编辑资料
            </button>
          )}
        </header>

        {savedMsg && (
          <div className="profile-toast" role="status">
            <Icon name="check" size={16} />
            {savedMsg}
          </div>
        )}
        {errorMsg && (
          <div className="profile-error" role="alert">
            {errorMsg}
          </div>
        )}

        {editing ? (
          <EditContent
            draft={currentDraft}
            roles={content.workspaceRoles}
            memberNumber={content.memberNumber}
            onDraftChange={setDraft}
          />
        ) : (
          <>
            <ProfileSummary content={content} />
            <ViewContent content={content} />
          </>
        )}

        <footer className="profile-footer">
          <span>{VISIBILITY_FOOTER_TEXT[footerVisibility]}</span>
        </footer>
      </div>
    </WorkspaceShell>
  );
}

export default function ProfilePage() {
  return (
    <Suspense fallback={<main className="profile-loading">正在加载资料…</main>}>
      <ProfilePageInner />
    </Suspense>
  );
}
