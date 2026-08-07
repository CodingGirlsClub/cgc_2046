"use client";

/**
 * 工作区设置 → 个人资料（决策 B：profile 迁入 settings）。
 *
 * 展示当前用户资料编辑表单，工作区身份（角色/成员编号）取当前 slug 上下文。
 * 数据路径：fetchCurrentProfile + fetchProfileRoleSummary（pickRoleSummary 按
 * slug 匹配）+ fetchPortfolioItems；壳 WorkspaceShell（requireWs 默认 true，
 * 未知 slug 自动「工作区不可访问」）。
 */

import { useEffect, useState } from "react";
import Link from "next/link";
import { useParams } from "next/navigation";
import { useAuthed } from "@/lib/use-authed";
import WorkspaceShell from "@/components/workspace-shell";
import { ProfileSettingsForm } from "@/components/profile-settings-form";
import {
  fetchCurrentProfile,
  fetchPortfolioItems,
  fetchProfileRoleSummary,
  pickRoleSummary,
  type CurrentProfile,
  type ProfileRoleSummary,
} from "@/lib/profile";

export default function WorkspaceAccountProfilePage() {
  const params = useParams<{ slug: string }>();
  const slug = params?.slug ?? "";
  const { authed, confirmed } = useAuthed();
  const [profile, setProfile] = useState<CurrentProfile | null>(null);
  const [summaries, setSummaries] = useState<ProfileRoleSummary[]>([]);
  const [loading, setLoading] = useState(true);
  const [errorMsg, setErrorMsg] = useState<string | null>(null);

  useEffect(() => {
    if (!confirmed || !authed) return;
    let cancelled = false;
    Promise.all([
      fetchCurrentProfile(),
      fetchProfileRoleSummary(),
      fetchPortfolioItems(),
    ])
      .then(([nextProfile, nextSummaries, nextPortfolio]) => {
        if (cancelled) return;
        setProfile({ ...nextProfile, portfolio: nextPortfolio });
        setSummaries(nextSummaries);
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

  if (loading) {
    return (
      <WorkspaceShell slug={slug}>
        <div className="ws-page-main__inner">
          <div className="settings-loading" aria-label="加载中">
            <div className="settings-skeleton settings-skeleton--title" />
            <div className="settings-skeleton" />
            <div className="settings-skeleton" />
          </div>
        </div>
      </WorkspaceShell>
    );
  }

  if (!profile) {
    return (
      <WorkspaceShell slug={slug}>
        <div className="ws-page-main__inner">
          <div className="members-error" role="alert">
            {errorMsg || "无法加载个人资料"}
          </div>
        </div>
      </WorkspaceShell>
    );
  }

  const summary = pickRoleSummary(summaries, slug);
  const roles = summary?.myRoleNames ?? [];

  return (
    <WorkspaceShell slug={slug}>
      <div className="ws-page-main__inner">
        <div className="ws-page-breadcrumb" aria-label="页面路径">
          <Link href="/">工作台</Link>
          <span>›</span>
          <Link href={`/w/${slug}`}>{summary?.workspaceName ?? slug}</Link>
          <span>›</span>
          <Link href={`/w/${slug}/settings`}>设置</Link>
          <span>›</span>
          <strong>个人资料</strong>
        </div>

        <header className="ws-page-heading">
          <div>
            <h1>个人资料</h1>
            <p>管理你的展示信息与可见范围</p>
          </div>
        </header>

        <ProfileSettingsForm
          profile={profile}
          roles={roles}
          memberNumber={profile.memberNumber ?? "—"}
        />
      </div>
    </WorkspaceShell>
  );
}
