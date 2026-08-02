"use client";

/**
 * Profile 作品集全量页。
 * 查看首页只预览前三条；这里用普通文档流承载任意数量作品，避免首页卡片内滚动。
 */

import { useEffect, useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { clearAuthToken } from "@/lib/auth";
import { useAuthed } from "@/lib/use-authed";
import {
  fetchCurrentProfile,
  fetchPortfolioItems,
  fetchProfileRoleSummary,
  type ProfilePortfolioItem,
  type ProfileRoleSummary,
} from "@/lib/profile";
import { ROLE_BADGE_CLASS, ROLE_LABEL, type MembershipRoleName } from "@/lib/graphql/workspace";

function PortfolioIcon({ icon }: { icon?: ProfilePortfolioItem["icon"] }) {
  const common = { width: 22, height: 22, viewBox: "0 0 24 24", fill: "none", stroke: "currentColor", strokeWidth: 1.8, strokeLinecap: "round" as const, strokeLinejoin: "round" as const };
  const graphic = icon === "book"
    ? <svg {...common}><path d="M4 5.5A3.5 3.5 0 0 1 7.5 2H12v18H7.5A3.5 3.5 0 0 0 4 23Z" /><path d="M20 5.5A3.5 3.5 0 0 0 16.5 2H12v18h4.5a3.5 3.5 0 0 1 3.5 3Z" /></svg>
    : icon === "guide"
      ? <svg {...common}><path d="M5 4h6a3 3 0 0 1 3 3v13H8a3 3 0 0 0-3 1Z" /><path d="M19 4h-5a3 3 0 0 0-3 3v13h6a3 3 0 0 1 3 1Z" /></svg>
      : <svg {...common}><path d="M6 3h8l4 4v14H6Z" /><path d="M14 3v5h5M9 13h6M9 17h6" /></svg>;
  return <span className={`profile-portfolio-icon profile-portfolio-icon--${icon ?? "document"}`} aria-hidden="true">{graphic}</span>;
}

function NavIcon({ name }: { name: "home" | "users" | "settings" | "user" }) {
  const common = { width: 22, height: 22, viewBox: "0 0 24 24", fill: "none", stroke: "currentColor", strokeWidth: 1.8, strokeLinecap: "round" as const, strokeLinejoin: "round" as const, "aria-hidden": true };
  if (name === "home") return <svg {...common}><path d="m3 10 9-7 9 7v10a1 1 0 0 1-1 1h-5v-6H9v6H4a1 1 0 0 1-1-1Z" /></svg>;
  if (name === "users") return <svg {...common}><circle cx="9" cy="8" r="3" /><path d="M3.5 20c.6-3.2 2.4-5 5.5-5s4.9 1.8 5.5 5M15.5 5.8a3 3 0 0 1 0 5.5M17.2 14.3c1.8.8 2.8 2.2 3.3 4.7" /></svg>;
  if (name === "settings") return <svg {...common}><circle cx="12" cy="12" r="3" /><path d="M19.4 15a1.7 1.7 0 0 0 .34 1.88l.06.06-1.7 1.7-.06-.06a1.7 1.7 0 0 0-1.88-.34 1.7 1.7 0 0 0-1.03 1.56V21h-2.4v-.2a1.7 1.7 0 0 0-1.03-1.56 1.7 1.7 0 0 0-1.88.34l-.06.06-1.7-1.7.06-.06A1.7 1.7 0 0 0 8.46 15a1.7 1.7 0 0 0-1.56-1.03H6.7v-2.4h.2A1.7 1.7 0 0 0 8.46 10a1.7 1.7 0 0 0-.34-1.88l-.06-.06 1.7-1.7.06.06A1.7 1.7 0 0 0 10.99 7.46 1.7 1.7 0 0 0 12.02 5.9V5h2.4v.2a1.7 1.7 0 0 0 1.03 1.56 1.7 1.7 0 0 0 1.88-.34l.06-.06 1.7 1.7-.06.06A1.7 1.7 0 0 0 19.4 10a1.7 1.7 0 0 0 1.56 1.03h.2A1.7 1.7 0 0 0 19.4 15Z" /></svg>;
  return <svg {...common}><circle cx="12" cy="8" r="3.5" /><path d="M4 21a8 8 0 0 1 16 0" /></svg>;
}

function PortfolioSidebar({ workspaceSlug }: { workspaceSlug: string }) {
  return (
    <aside className="profile-sidebar">
      <div className="profile-brand"><span className="profile-brand__mark">CGC</span><span>上海 Coding Girls Club</span><span className="profile-brand__chevron">⌄</span></div>
      <nav className="profile-sidebar__nav" aria-label="工作区导航">
        <Link href={`/w/${workspaceSlug}`} className="profile-sidebar__item"><NavIcon name="home" /><span>概览</span></Link>
        <Link href={`/w/${workspaceSlug}/members`} className="profile-sidebar__item"><NavIcon name="users" /><span>成员与角色</span></Link>
        <button type="button" disabled className="profile-sidebar__item profile-sidebar__item--disabled"><NavIcon name="settings" /><span>工作区设置</span></button>
        <Link href="/profile" className="profile-sidebar__item profile-sidebar__item--selected" aria-current="page"><NavIcon name="user" /><span>个人资料</span></Link>
      </nav>
    </aside>
  );
}

export default function ProfilePortfolioPage() {
  const router = useRouter();
  const { authed, confirmed } = useAuthed();
  const [portfolio, setPortfolio] = useState<ProfilePortfolioItem[]>([]);
  const [profileName, setProfileName] = useState("我的个人资料");
  const [workspaceSlug, setWorkspaceSlug] = useState("cgc-shanghai");
  const [roles, setRoles] = useState<MembershipRoleName[]>([]);
  const [loading, setLoading] = useState(true);
  const [errorMsg, setErrorMsg] = useState<string | null>(null);

  useEffect(() => {
    if (!confirmed) return;
    if (!authed) {
      router.replace("/login");
      return;
    }
    let cancelled = false;
    Promise.all([fetchCurrentProfile(), fetchProfileRoleSummary(), fetchPortfolioItems()])
      .then(([profile, summaries, portfolio]) => {
        if (cancelled) return;
        const summary = summaries.find((item: ProfileRoleSummary) => item.myRoleNames.length > 0) ?? summaries[0];
        setProfileName(profile.displayName?.trim() || "我的个人资料");
        setWorkspaceSlug(profile.workspaceSlug || summary?.workspaceSlug || "cgc-shanghai");
        setRoles(profile.workspaceRoles?.length ? profile.workspaceRoles : (summary?.myRoleNames ?? []));
        setPortfolio(portfolio);
      })
      .catch((error: unknown) => {
        if (!cancelled) setErrorMsg(error instanceof Error ? error.message : "加载作品集失败");
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => { cancelled = true; };
  }, [authed, confirmed, router]);

  function handleSignOut() {
    clearAuthToken();
    router.push("/login");
  }

  if (!authed) return <main className="profile-loading">正在确认登录状态…</main>;
  if (loading) return <main className="profile-loading">正在加载作品集…</main>;
  if (errorMsg) return <main className="profile-loading"><strong>无法加载作品集</strong><span>{errorMsg}</span><Link href="/profile" className="profile-button profile-button--outline">返回个人资料</Link></main>;

  return (
    <div className="profile-page profile-portfolio-page">
      <PortfolioSidebar workspaceSlug={workspaceSlug} />
      <main className="profile-main">
        <div className="profile-main__inner">
          <div className="profile-breadcrumb" aria-label="页面路径"><Link href="/profile">个人资料</Link><span>›</span><strong>全部作品集</strong></div>
          <header className="profile-heading profile-portfolio-heading"><div><h1>全部作品集</h1><p>来自 {profileName} 的 {portfolio.length} 个作品</p></div><Link href="/profile" className="profile-button profile-button--outline">返回个人资料</Link></header>
          {portfolio.length === 0 ? <div className="profile-card profile-portfolio-empty">还没有添加作品集。</div> : <section className="profile-card profile-portfolio-full-list" data-testid="portfolio-full-list"><div className="profile-portfolio-full-list__meta"><span>共 {portfolio.length} 个作品</span><div className="profile-role-chips">{roles.map((role) => <span key={role} className={ROLE_BADGE_CLASS[role]}>{ROLE_LABEL[role]}</span>)}</div></div><div className="profile-portfolio-list">{portfolio.map((item) => <a key={item.id} href={item.url || "#"} className="profile-portfolio-item"><PortfolioIcon icon={item.icon} /><span className="profile-portfolio-item__body"><strong>{item.title}</strong><span>{item.description}</span></span><span className="profile-portfolio-link-label">查看 <span aria-hidden="true">→</span></span></a>)}</div><p className="profile-portfolio-full-list__footer">已显示全部 {portfolio.length} 个作品</p></section>}
          <footer className="profile-footer"><span>资料仅在当前 Workspace 内可见。</span><button type="button" onClick={handleSignOut}>退出登录</button></footer>
        </div>
      </main>
    </div>
  );
}
