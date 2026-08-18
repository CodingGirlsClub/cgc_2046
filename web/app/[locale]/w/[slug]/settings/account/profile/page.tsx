"use client";

/**
 * 工作区设置 → 个人资料（ADR-0004 per-workspace）。
 *
 * 展示当前用户在该工作区的档案编辑表单：per-workspace 字段
 * （avatar/location/about/skills/visibility/portfolio）取 workspaceProfile +
 * myWorkspacePortfolio；全局身份（displayName/memberNumber/joinedAt）取 me。
 * 工作区身份（角色/成员编号）取当前 slug 上下文。
 */

import { useEffect, useState } from "react";
import { Link } from "@/i18n/navigation";
import { useParams } from "next/navigation";
import { useTranslations } from "next-intl";
import { useAuthed } from "@/lib/use-authed";
import { useWorkspaceBySlug } from "@/lib/use-workspace-by-slug";
import WorkspaceShell from "@/components/workspace-shell";
import { ProfileSettingsForm } from "@/components/profile-settings-form";
import {
  fetchCurrentProfile,
  fetchWorkspaceProfile,
  fetchPortfolioItems,
  fetchProfileRoleSummary,
  pickRoleSummary,
  type CurrentProfile,
  type ProfilePortfolioItem,
  type ProfileRoleSummary,
  type WorkspaceProfileContent,
} from "@/lib/profile";

export default function WorkspaceAccountProfilePage() {
  const t = useTranslations("workspaceAccount");
  const tCommon = useTranslations("common");
  const params = useParams<{ slug: string }>();
  const slug = params?.slug ?? "";
  const { authed, confirmed } = useAuthed();
  const { ws } = useWorkspaceBySlug(slug);
  const [profile, setProfile] = useState<CurrentProfile | null>(null);
  const [wsProfile, setWsProfile] = useState<WorkspaceProfileContent | null>(null);
  const [portfolio, setPortfolio] = useState<ProfilePortfolioItem[]>([]);
  const [summaries, setSummaries] = useState<ProfileRoleSummary[]>([]);
  const [loading, setLoading] = useState(true);
  const [errorMsg, setErrorMsg] = useState<string | null>(null);

  const workspaceId = ws?.id;

  useEffect(() => {
    if (!confirmed || !authed || !workspaceId) return;
    let cancelled = false;
    Promise.all([
      fetchCurrentProfile(),
      fetchWorkspaceProfile(workspaceId),
      fetchPortfolioItems(workspaceId),
      fetchProfileRoleSummary(),
    ])
      .then(([nextProfile, nextWsProfile, nextPortfolio, nextSummaries]) => {
        if (cancelled) return;
        setProfile(nextProfile);
        // portfolio 单独经 initialPortfolio 传给表单：wsProfile 为 null（尚无 WorkspaceProfile 行）
        // 时也不丢刚拉到的作品集
        setWsProfile(nextWsProfile);
        setPortfolio(nextPortfolio);
        setSummaries(nextSummaries);
        setErrorMsg(null);
      })
      .catch((error: unknown) => {
        if (!cancelled)
          setErrorMsg(error instanceof Error ? error.message : t("loadFailed"));
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [authed, confirmed, workspaceId, t]);

  if (loading) {
    return (
      <WorkspaceShell slug={slug}>
        <div className="ws-page-main__inner">
          <div className="settings-loading" aria-label={tCommon("loadingAria")}>
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
            {errorMsg || t("unableLoad")}
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
        <div className="ws-page-breadcrumb" aria-label={tCommon("breadcrumbAria")}>
          <Link href="/">{t("breadcrumbHome")}</Link>
          <span>›</span>
          <Link href={`/w/${slug}`}>{summary?.workspaceName ?? slug}</Link>
          <span>›</span>
          <Link href={`/w/${slug}/settings/join-policy`}>{t("breadcrumbSettings")}</Link>
          <span>›</span>
          <strong>{t("breadcrumbTitle")}</strong>
        </div>

        <header className="ws-page-heading">
          <div>
            <h1>{t("title")}</h1>
            <p>{t("subtitle")}</p>
          </div>
        </header>

        <ProfileSettingsForm
          profile={profile}
          wsProfile={wsProfile}
          workspaceId={workspaceId ?? ""}
          roles={roles}
          memberNumber={profile.memberNumber ?? "—"}
          initialPortfolio={portfolio}
        />
      </div>
    </WorkspaceShell>
  );
}
