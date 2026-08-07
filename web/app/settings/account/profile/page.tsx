"use client";

/**
 * 全局设置 → 个人资料（决策 B：profile 迁入 settings，首页 header 入口指向此处）。
 *
 * 无工作区上下文（requireWs=false 壳）：角色/成员编号取排序后首个持有角色的
 * 工作区（pickRoleSummary 无 slug 分支），与旧 /profile 默认上下文一致。
 */

import { useEffect, useState } from "react";
import Link from "next/link";
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

export default function AccountProfilePage() {
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
      <WorkspaceShell slug="" requireWs={false}>
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
      <WorkspaceShell slug="" requireWs={false}>
        <div className="ws-page-main__inner">
          <div className="members-error" role="alert">
            {errorMsg || "无法加载个人资料"}
          </div>
        </div>
      </WorkspaceShell>
    );
  }

  const summary = pickRoleSummary(summaries);
  const roles = summary?.myRoleNames ?? [];

  return (
    <WorkspaceShell slug="" requireWs={false}>
      <div className="ws-page-main__inner">
        <div className="ws-page-breadcrumb" aria-label="页面路径">
          <Link href="/">工作台</Link>
          <span>›</span>
          <Link href="/settings/account/profile">设置</Link>
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
