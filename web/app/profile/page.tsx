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

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { clearAuthToken } from "@/lib/auth";
import { useAuthed } from "@/lib/use-authed";
import { formatJoinedDate } from "@/lib/format";
import {
  createPortfolioItem,
  deletePortfolioItem,
  fetchCurrentProfile,
  fetchPortfolioItems,
  fetchProfileRoleSummary,
  MOCK_PROFILE_PORTFOLIO,
  updateCurrentProfile,
  updatePortfolioItem,
  type CurrentProfile,
  type PortfolioIcon,
  type ProfilePortfolioItem,
  type ProfileRoleSummary,
} from "@/lib/profile";
import {
  ROLE_BADGE_CLASS,
  ROLE_LABEL,
  type MembershipRoleName,
} from "@/lib/graphql/workspace";
import { USE_MOCK_WORKSPACES } from "@/lib/workspaces";
import type { ProfileVisibility } from "@/lib/graphql/profile";

type IconName =
  | "home"
  | "users"
  | "settings"
  | "user"
  | "pin"
  | "calendar"
  | "visibility"
  | "edit"
  | "lock"
  | "document"
  | "book"
  | "guide"
  | "plus"
  | "trash"
  | "grip"
  | "arrow"
  | "check"
  | "chevron";

function Icon({ name, size = 22 }: { name: IconName; size?: number }) {
  const common = {
    width: size,
    height: size,
    viewBox: "0 0 24 24",
    fill: "none",
    stroke: "currentColor",
    strokeWidth: 1.8,
    strokeLinecap: "round" as const,
    strokeLinejoin: "round" as const,
    "aria-hidden": true,
  };

  switch (name) {
    case "home":
      return <svg {...common}><path d="m3 10 9-7 9 7v10a1 1 0 0 1-1 1h-5v-6H9v6H4a1 1 0 0 1-1-1Z" /></svg>;
    case "users":
      return <svg {...common}><circle cx="9" cy="8" r="3" /><path d="M3.5 20c.6-3.2 2.4-5 5.5-5s4.9 1.8 5.5 5" /><path d="M15.5 5.8a3 3 0 0 1 0 5.5M17.2 14.3c1.8.8 2.8 2.2 3.3 4.7" /></svg>;
    case "settings":
      return <svg {...common}><circle cx="12" cy="12" r="3" /><path d="M19.4 15a1.7 1.7 0 0 0 .34 1.88l.06.06-1.7 1.7-.06-.06a1.7 1.7 0 0 0-1.88-.34 1.7 1.7 0 0 0-1.03 1.56V21h-2.4v-.2a1.7 1.7 0 0 0-1.03-1.56 1.7 1.7 0 0 0-1.88.34l-.06.06-1.7-1.7.06-.06A1.7 1.7 0 0 0 8.46 15a1.7 1.7 0 0 0-1.56-1.03H6.7v-2.4h.2A1.7 1.7 0 0 0 8.46 10a1.7 1.7 0 0 0-.34-1.88l-.06-.06 1.7-1.7.06.06A1.7 1.7 0 0 0 10.99 7.46 1.7 1.7 0 0 0 12.02 5.9V5h2.4v.2a1.7 1.7 0 0 0 1.03 1.56 1.7 1.7 0 0 0 1.88-.34l.06-.06 1.7 1.7-.06.06A1.7 1.7 0 0 0 19.4 10a1.7 1.7 0 0 0 1.56 1.03h.2A1.7 1.7 0 0 0 19.4 15Z" /></svg>;
    case "user":
      return <svg {...common}><circle cx="12" cy="8" r="3.5" /><path d="M4 21a8 8 0 0 1 16 0" /></svg>;
    case "pin":
      return <svg {...common}><path d="M20 10c0 5-8 11-8 11S4 15 4 10a8 8 0 1 1 16 0Z" /><circle cx="12" cy="10" r="2.5" /></svg>;
    case "calendar":
      return <svg {...common}><rect x="3" y="5" width="18" height="16" rx="2" /><path d="M7 3v4M17 3v4M3 10h18" /></svg>;
    case "visibility":
      return <svg {...common}><path d="M2.5 12s3.2-5 9.5-5 9.5 5 9.5 5-3.2 5-9.5 5-9.5-5-9.5-5Z" /><circle cx="12" cy="12" r="2.2" /></svg>;
    case "edit":
      return <svg {...common}><path d="m4 16.5-.7 3.8 3.8-.7L18.6 8.1a2.1 2.1 0 0 0-3-3L4 16.5Z" /><path d="m13.8 6.2 4 4" /></svg>;
    case "lock":
      return <svg {...common}><rect x="5" y="10" width="14" height="11" rx="2" /><path d="M8 10V7a4 4 0 0 1 8 0v3" /></svg>;
    case "document":
      return <svg {...common}><path d="M6 3h8l4 4v14H6Z" /><path d="M14 3v5h5M9 13h6M9 17h6" /></svg>;
    case "book":
      return <svg {...common}><path d="M4 5.5A3.5 3.5 0 0 1 7.5 2H12v18H7.5A3.5 3.5 0 0 0 4 23Z" /><path d="M20 5.5A3.5 3.5 0 0 0 16.5 2H12v18h4.5a3.5 3.5 0 0 1 3.5 3Z" /></svg>;
    case "guide":
      return <svg {...common}><path d="M5 4h6a3 3 0 0 1 3 3v13H8a3 3 0 0 0-3 1Z" /><path d="M19 4h-5a3 3 0 0 0-3 3v13h6a3 3 0 0 1 3 1Z" /></svg>;
    case "plus":
      return <svg {...common}><path d="M12 5v14M5 12h14" /></svg>;
    case "trash":
      return <svg {...common}><path d="M4 7h16M10 11v6M14 11v6M6 7l1 14h10l1-14M9 7V4h6v3" /></svg>;
    case "grip":
      return <svg {...common}><circle cx="8" cy="7" r="1" fill="currentColor" stroke="none" /><circle cx="16" cy="7" r="1" fill="currentColor" stroke="none" /><circle cx="8" cy="12" r="1" fill="currentColor" stroke="none" /><circle cx="16" cy="12" r="1" fill="currentColor" stroke="none" /><circle cx="8" cy="17" r="1" fill="currentColor" stroke="none" /><circle cx="16" cy="17" r="1" fill="currentColor" stroke="none" /></svg>;
    case "arrow":
      return <svg {...common}><path d="M4 12h15M13 6l6 6-6 6" /></svg>;
    case "check":
      return <svg {...common}><path d="m5 12 4.5 4.5L19 7" /></svg>;
    case "chevron":
      return <svg {...common}><path d="m9 6 6 6-6 6" /></svg>;
  }
}

interface ProfileContent {
  name: string;
  location: string;
  about: string;
  skills: string[];
  joinedAt: string;
  visibility: ProfileVisibility;
  memberNumber: string;
  workspaceName: string;
  workspaceSlug: string;
  workspaceRoles: MembershipRoleName[];
  portfolio: ProfilePortfolioItem[];
  avatarUrl: string | null;
}

interface ProfileDraft {
  name: string;
  location: string;
  about: string;
  skills: string[];
  visibility: ProfileVisibility;
  portfolio: ProfilePortfolioItem[];
  avatarUrl: string | null;
}

const DEFAULT_ABOUT = "关注社区学习、AI 教育与开放协作。喜欢把复杂的问题整理成清晰、可执行的课程与活动。";
const DEFAULT_SKILLS = ["AI 教育", "课程设计", "社区运营", "Elixir"];

/** 资料可见范围三档（2026-08-02 对齐：public / workspace / only_me） */
const VISIBILITY_LABEL: Record<ProfileVisibility, string> = {
  public: "全站公开",
  workspace: "工作区公开",
  only_me: "仅自己可见",
};

/** 编辑态 select 选项文案（带括号说明） */
const VISIBILITY_OPTION_LABEL: Record<ProfileVisibility, string> = {
  public: "全站公开（所有登录用户可见）",
  workspace: "工作区公开（同工作区登录用户可见）",
  only_me: "仅自己可见",
};

/** 底部可见范围说明文案 */
const VISIBILITY_FOOTER_TEXT: Record<ProfileVisibility, string> = {
  public: "资料对全站公开（所有登录用户可见）。",
  workspace: "资料在同工作区公开（同工作区登录用户可见）。",
  only_me: "资料仅自己可见。",
};

function roleLabel(role: MembershipRoleName) {
  return ROLE_LABEL[role] ?? role;
}

function roleBadgeClass(role: MembershipRoleName) {
  return ROLE_BADGE_CLASS[role] ?? "l-badge l-badge-member";
}

function portfolioIconName(icon: PortfolioIcon | undefined): IconName {
  if (icon === "book") return "book";
  if (icon === "guide") return "guide";
  return "document";
}

function getProfileContent(profile: CurrentProfile, summaries: ProfileRoleSummary[]): ProfileContent {
  const summary = summaries.find((item) => item.myRoleNames.length > 0) ?? summaries[0];
  const roles = profile.workspaceRoles?.length ? profile.workspaceRoles : (summary?.myRoleNames ?? []);
  // P1-2（QA 复验 FAIL 修复）：渲染兜底区分数据源模式——
  // - USE_MOCK_WORKSPACES=true（mock 样例）：字段缺失时用设计稿示例兜底（上海 / DEFAULT_ABOUT 等）；
  // - 真实模式：字段缺失展示空态（未设置 / 暂无简介 / [] / —），不再伪造样例；
  //   workspaceName / workspaceSlug 保留 summary 真实回退，去掉固定 mock 兜底。
  const portfolio = profile.portfolio ?? (USE_MOCK_WORKSPACES ? MOCK_PROFILE_PORTFOLIO : []);
  return {
    name: profile.displayName?.trim() || "未设置展示名",
    location: USE_MOCK_WORKSPACES ? profile.location || "上海" : profile.location || "未设置",
    about: USE_MOCK_WORKSPACES ? profile.about || DEFAULT_ABOUT : profile.about || "暂无简介",
    skills: USE_MOCK_WORKSPACES
      ? profile.skills?.length
        ? [...profile.skills]
        : [...DEFAULT_SKILLS]
      : profile.skills?.length
        ? [...profile.skills]
        : [],
    joinedAt: formatJoinedDate(USE_MOCK_WORKSPACES ? profile.joinedAt || "2024 年 3 月" : profile.joinedAt),
    visibility: profile.visibility ?? "only_me",
    memberNumber: USE_MOCK_WORKSPACES ? profile.memberNumber || "CGC-SH-0018" : profile.memberNumber || "—",
    workspaceName: profile.workspaceName || summary?.workspaceName || (USE_MOCK_WORKSPACES ? "上海 Coding Girls Club" : ""),
    workspaceSlug: profile.workspaceSlug || summary?.workspaceSlug || (USE_MOCK_WORKSPACES ? "cgc-shanghai" : ""),
    workspaceRoles: roles,
    portfolio: portfolio.map((item) => ({ ...item })),
    avatarUrl: profile.avatarUrl ?? null,
  };
}

function toDraft(content: ProfileContent): ProfileDraft {
  return {
    name: content.name === "未设置展示名" ? "" : content.name,
    location: content.location === "未设置" ? "" : content.location,
    about: content.about === "暂无简介" ? "" : content.about,
    skills: [...content.skills],
    visibility: content.visibility,
    portfolio: content.portfolio.map((item) => ({ ...item })),
    avatarUrl: content.avatarUrl,
  };
}

function Avatar({ content, editable = false, onFile }: { content: Pick<ProfileContent, "name" | "avatarUrl">; editable?: boolean; onFile?: (value: string) => void }) {
  const inputRef = useRef<HTMLInputElement>(null);
  const letter = (content.name || "?").slice(0, 1).toUpperCase();

  function handleFile(event: React.ChangeEvent<HTMLInputElement>) {
    const file = event.target.files?.[0];
    if (!file || !onFile) return;
    const reader = new FileReader();
    reader.onload = () => {
      if (typeof reader.result === "string") onFile(reader.result);
    };
    reader.readAsDataURL(file);
  }

  return (
    <div className={`profile-avatar-wrap ${editable ? "profile-avatar-wrap--editable" : ""}`}>
      {content.avatarUrl ? (
        // eslint-disable-next-line @next/next/no-img-element
        <img src={content.avatarUrl} alt={`${content.name} 的头像`} className="profile-avatar" />
      ) : (
        <span className="profile-avatar profile-avatar--fallback">{letter}</span>
      )}
      {editable && (
        <>
          <input ref={inputRef} type="file" accept="image/png,image/jpeg,image/webp,image/gif" className="profile-file-input" onChange={handleFile} />
          <button type="button" className="profile-change-avatar" onClick={() => inputRef.current?.click()}>更换头像</button>
        </>
      )}
    </div>
  );
}

function ProfileSidebar({ workspaceSlug }: { workspaceSlug: string }) {
  return (
    <aside className="profile-sidebar">
      <div className="profile-brand">
        <span className="profile-brand__mark">CGC</span>
        <span>上海 Coding Girls Club</span>
        <span className="profile-brand__chevron">⌄</span>
      </div>
      <nav className="profile-sidebar__nav" aria-label="工作区导航">
        <Link href={`/w/${workspaceSlug}`} className="profile-sidebar__item"><Icon name="home" size={23} /><span>概览</span></Link>
        <Link href={`/w/${workspaceSlug}/members`} className="profile-sidebar__item"><Icon name="users" size={23} /><span>成员与角色</span></Link>
        <button type="button" disabled className="profile-sidebar__item profile-sidebar__item--disabled"><Icon name="settings" size={23} /><span>工作区设置</span></button>
        <Link href="/profile" className="profile-sidebar__item profile-sidebar__item--selected" aria-current="page"><Icon name="user" size={23} /><span>个人资料</span></Link>
      </nav>
    </aside>
  );
}

function Breadcrumb({ editing }: { editing: boolean }) {
  return (
    <div className="profile-breadcrumb" aria-label="页面路径">
      {editing ? (
        <>
          <Link href="/profile">成员 Profile</Link><span>›</span><strong>编辑个人资料</strong>
        </>
      ) : (
        <>
          <Link href="/" aria-label="返回工作台"><Icon name="home" size={17} /></Link><span>›</span><Link href="/profile">个人资料</Link><span>›</span><strong>成员 Profile</strong>
        </>
      )}
    </div>
  );
}

function RoleChips({ roles, className = "" }: { roles: MembershipRoleName[]; className?: string }) {
  return (
    <div className={`profile-role-chips ${className}`}>
      {roles.length > 0 ? roles.map((role) => <span key={role} className={roleBadgeClass(role)}>{roleLabel(role)}</span>) : <span className="profile-role-empty">未分配角色</span>}
    </div>
  );
}

function ProfileSummary({ content }: { content: ProfileContent }) {
  return (
    <section className="profile-summary" data-testid="profile-summary">
      <Avatar content={content} />
      <div className="profile-summary__identity">
        <h2 data-testid="profile-display-name">{content.name}</h2>
        <RoleChips roles={content.workspaceRoles} />
        <div className="profile-summary__meta">
          <span><Icon name="pin" size={20} />{content.location}</span><i />
          <span><Icon name="calendar" size={20} />加入于 {content.joinedAt}</span><i />
          <span className="profile-visibility-pill"><Icon name="visibility" size={18} />{VISIBILITY_LABEL[content.visibility]}</span>
        </div>
      </div>
    </section>
  );
}

function PortfolioPreview({ portfolio }: { portfolio: ProfilePortfolioItem[] }) {
  const preview = portfolio.slice(0, 3);
  return (
    <section className="profile-card profile-portfolio-card" data-testid="portfolio-card">
      <header className="profile-card__heading">
        <h2>作品集 <span className="profile-count">{portfolio.length}</span></h2>
      </header>
      {preview.length > 0 ? (
        <div className="profile-portfolio-list">
          {preview.map((item) => (
            <a key={item.id} href={item.url || "#"} className="profile-portfolio-item" data-testid="portfolio-preview-item">
              <span className={`profile-portfolio-icon profile-portfolio-icon--${item.icon ?? "document"}`}><Icon name={portfolioIconName(item.icon)} size={26} /></span>
              <span className="profile-portfolio-item__body"><strong>{item.title}</strong><span>{item.description}</span></span>
              <Icon name="arrow" size={20} />
            </a>
          ))}
          <Link href="/profile/portfolio" className="profile-portfolio-more" data-testid="portfolio-all-link">查看全部 {portfolio.length} 个作品 <Icon name="arrow" size={18} /></Link>
        </div>
      ) : (
        <div className="profile-empty-card">还没有添加作品集。</div>
      )}
    </section>
  );
}

function ViewContent({ content }: { content: ProfileContent }) {
  return (
    <div className="profile-view-grid">
      <div className="profile-view-main">
        <section className="profile-card profile-about-card" data-testid="about-card">
          <h2>关于我</h2>
          <p>{content.about}</p>
        </section>
        <PortfolioPreview portfolio={content.portfolio} />
      </div>
      <div className="profile-view-aside">
        <section className="profile-card profile-skills-card" data-testid="skills-card">
          <h2>技能标签</h2>
          <div className="profile-skill-list">{content.skills.map((skill) => <span key={skill}>{skill}</span>)}</div>
        </section>
        <section className="profile-card profile-identity-card" data-testid="identity-card">
          <h2>工作区身份</h2>
          <span className="profile-card__eyebrow">角色并集</span>
          <RoleChips roles={content.workspaceRoles} />
          <p>权限按所有角色并集合并</p>
          <div className="profile-identity-divider" />
          <div className="profile-member-number"><span>成员编号</span><strong>{content.memberNumber}</strong></div>
        </section>
      </div>
    </div>
  );
}

function EditPortfolioRow({ item, onChange, onRemove }: { item: ProfilePortfolioItem; onChange: (next: ProfilePortfolioItem) => void; onRemove: () => void }) {
  return (
    <div className="profile-edit-portfolio-row" data-testid="portfolio-edit-row">
      <span className="profile-drag-handle" aria-hidden="true"><Icon name="grip" size={19} /></span>
      <label><span>作品标题</span><input value={item.title} onChange={(event) => onChange({ ...item, title: event.target.value })} /></label>
      <label><span>作品简介</span><input value={item.description} onChange={(event) => onChange({ ...item, description: event.target.value })} /></label>
      <label><span>作品链接</span><input value={item.url ?? ""} onChange={(event) => onChange({ ...item, url: event.target.value })} /></label>
      <label><span>图标类型</span><select value={item.icon ?? "document"} aria-label="作品图标类型" onChange={(event) => onChange({ ...item, icon: event.target.value as PortfolioIcon })}>
        <option value="document">文档</option>
        <option value="book">书籍</option>
        <option value="guide">指南</option>
      </select></label>
      <button type="button" className="profile-remove-portfolio" aria-label={`删除作品：${item.title || "未命名作品"}`} onClick={onRemove}><Icon name="trash" size={19} /></button>
    </div>
  );
}

function EditContent({ draft, roles, memberNumber, onDraftChange }: { draft: ProfileDraft; roles: MembershipRoleName[]; memberNumber: string; onDraftChange: (next: ProfileDraft) => void }) {
  const [showAllPortfolio, setShowAllPortfolio] = useState(false);
  const visiblePortfolio = showAllPortfolio ? draft.portfolio : draft.portfolio.slice(0, 2);

  function addSkill() {
    const skill = window.prompt("添加技能标签");
    if (!skill?.trim() || draft.skills.includes(skill.trim())) return;
    onDraftChange({ ...draft, skills: [...draft.skills, skill.trim()] });
  }

  return (
    <div className="profile-edit-layout">
      <section className="profile-edit-basic profile-card" data-testid="edit-basic-card">
        <h2>基本资料</h2>
        <div className="profile-edit-avatar-block">
          <span className="profile-form-label">头像</span>
          <div className="profile-edit-avatar-row">
            <Avatar content={{ name: draft.name || "?", avatarUrl: draft.avatarUrl }} editable onFile={(avatarUrl) => onDraftChange({ ...draft, avatarUrl })} />
            <p>支持 PNG、JPG、WebP、GIF，文件大小不超过 2.2MB。</p>
          </div>
        </div>
        <div className="profile-edit-form-grid">
          <label><span className="profile-form-label">姓名</span><input data-testid="profile-name-input" value={draft.name} onChange={(event) => onDraftChange({ ...draft, name: event.target.value })} /></label>
          <label><span className="profile-form-label">所在地</span><input data-testid="profile-location-input" value={draft.location} onChange={(event) => onDraftChange({ ...draft, location: event.target.value })} /></label>
        </div>
        <label className="profile-edit-about"><span className="profile-form-label">个人简介</span><textarea data-testid="profile-about-input" maxLength={240} value={draft.about} onChange={(event) => onDraftChange({ ...draft, about: event.target.value })} /><span className="profile-char-count">{draft.about.length} / 240</span></label>
        <div className="profile-edit-skills"><span className="profile-form-label">技能标签</span><div className="profile-edit-skill-box">{draft.skills.map((skill) => <span key={skill}>{skill}<button type="button" aria-label={`删除标签 ${skill}`} onClick={() => onDraftChange({ ...draft, skills: draft.skills.filter((item) => item !== skill) })}>×</button></span>)}<button type="button" className="profile-add-skill" onClick={addSkill}><Icon name="plus" size={16} />添加标签</button></div></div>
      </section>

      <aside className="profile-edit-side">
        <section className="profile-card profile-edit-readonly" data-testid="edit-visibility-card">
          <h2>可见范围</h2>
          <label className="profile-visibility-options">
            <span className="profile-form-label">资料可见范围</span>
            <select
              data-testid="profile-visibility-input"
              value={draft.visibility}
              onChange={(event) => onDraftChange({ ...draft, visibility: event.target.value as ProfileVisibility })}
            >
              {(Object.keys(VISIBILITY_OPTION_LABEL) as ProfileVisibility[]).map((value) => (
                <option key={value} value={value}>{VISIBILITY_OPTION_LABEL[value]}</option>
              ))}
            </select>
          </label>
          <div className="profile-edit-divider" />
          <h2>工作区身份</h2>
          <p>角色由 Owner / Admin 管理，此处不可编辑</p>
          <RoleChips roles={roles} />
          <label><span className="profile-form-label">成员编号</span><input value={memberNumber} readOnly /></label>
        </section>
      </aside>

      <section className="profile-card profile-edit-portfolio" data-testid="edit-portfolio-card">
        <h2>作品集</h2>
        <div className="profile-edit-portfolio-list">
          {visiblePortfolio.map((item) => (
            <EditPortfolioRow key={item.id} item={item} onChange={(next) => onDraftChange({ ...draft, portfolio: draft.portfolio.map((entry) => entry.id === item.id ? next : entry) })} onRemove={() => onDraftChange({ ...draft, portfolio: draft.portfolio.filter((entry) => entry.id !== item.id) })} />
          ))}
        </div>
        {!showAllPortfolio && draft.portfolio.length > 2 && <button type="button" className="profile-expand-portfolio" onClick={() => setShowAllPortfolio(true)}>展开其余 {draft.portfolio.length - 2} 个作品</button>}
        <button type="button" className="profile-add-portfolio" onClick={() => onDraftChange({ ...draft, portfolio: [...draft.portfolio, { id: `portfolio-${Date.now()}`, title: "", description: "", url: "", icon: "document" }] })}><Icon name="plus" size={18} />添加作品</button>
      </section>
    </div>
  );
}

export default function ProfilePage() {
  const router = useRouter();
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
    if (!confirmed) return;
    if (!authed) {
      router.replace("/login");
      return;
    }
    let cancelled = false;
    Promise.all([fetchCurrentProfile(), fetchProfileRoleSummary(), fetchPortfolioItems()])
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
        if (!cancelled) setErrorMsg(error instanceof Error ? error.message : "加载资料失败");
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => { cancelled = true; };
  }, [authed, confirmed, router]);

  const content = useMemo(() => profile ? getProfileContent(profile, summaries) : null, [profile, summaries]);
  const workspaceSlug = content?.workspaceSlug || "cgc-shanghai";

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
      setProfile({ ...profile, ...updated, displayName: name, avatarUrl: draft.avatarUrl, location: draft.location, about: draft.about, skills: draft.skills, visibility: draft.visibility, portfolio: refreshedPortfolio });
      setEditing(false);
      setSavedMsg("资料已保存");
    } catch (error: unknown) {
      setErrorMsg(error instanceof Error ? error.message : "保存失败");
    } finally {
      setSaving(false);
    }
  }

  /** 作品集 diff 同步：新增条目 create、被移除条目 delete、内容变化条目 update（P1 CRUD 接线） */
  async function syncPortfolioChanges(prev: CurrentProfile, next: ProfilePortfolioItem[]) {
    const original = new Map((prev.portfolio ?? []).map((item) => [item.id, item]));
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

  function handleSignOut() {
    clearAuthToken();
    router.push("/login");
  }

  if (!authed) return <main className="profile-loading">正在确认登录状态…</main>;

  if (loading) {
    return <div className="profile-page"><ProfileSidebar workspaceSlug={workspaceSlug} /><main className="profile-main"><div className="profile-main__inner"><div className="profile-skeleton" /></div></main></div>;
  }

  if (!profile || !content) {
    return <main className="profile-loading"><strong>无法加载个人资料</strong><span>{errorMsg || "请稍后重试。"}</span></main>;
  }

  const currentDraft = draft ?? toDraft(content);
  // P2-1：底部可见范围文案随当前可见范围联动（编辑态实时预览 draft，查看态用真实值）
  const footerVisibility = editing ? currentDraft.visibility : content.visibility;

  return (
    <div className={`profile-page ${editing ? "profile-page--editing" : ""}`}>
      <ProfileSidebar workspaceSlug={workspaceSlug} />
      <main className="profile-main">
        <div className="profile-main__inner">
          <Breadcrumb editing={editing} />
          <header className="profile-heading">
            <h1>{editing ? "编辑个人资料" : "我的个人资料"}</h1>
            {editing ? (
              <div className="profile-heading__actions"><button type="button" className="profile-button profile-button--quiet" onClick={cancelEdit} disabled={saving}>取消</button><button type="button" className="profile-button profile-button--primary" onClick={handleSave} disabled={saving}>{saving ? "保存中…" : "保存更改"}</button></div>
            ) : <button type="button" className="profile-button profile-button--outline" onClick={startEdit}><Icon name="edit" size={18} />编辑资料</button>}
          </header>

          {savedMsg && <div className="profile-toast" role="status"><Icon name="check" size={16} />{savedMsg}</div>}
          {errorMsg && <div className="profile-error" role="alert">{errorMsg}</div>}

          {editing ? (
            <EditContent draft={currentDraft} roles={content.workspaceRoles} memberNumber={content.memberNumber} onDraftChange={setDraft} />
          ) : (
            <>
              <ProfileSummary content={content} />
              <ViewContent content={content} />
            </>
          )}

          <footer className="profile-footer"><span>{VISIBILITY_FOOTER_TEXT[footerVisibility]}</span><button type="button" onClick={handleSignOut}>退出登录</button></footer>
        </div>
      </main>
    </div>
  );
}
