"use client";

/**
 * #63 工作台选择页。
 *
 * 正式形态是「B 侧栏 + 详情区」：点击侧栏中的工作区，右侧详情跟随切换，
 * 并且 active / pending / invited 三种 membership 状态分别表达。
 * 首次登录卡片网格保留为 `/?view=grid`，便于 onboarding 与验收使用。
 */

import Link from "next/link";
import { useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { clearAuthToken } from "@/lib/auth";
import { useAuthed } from "@/lib/use-authed";
import {
  fetchMyWorkspaces,
  type WorkspaceListItem,
} from "@/lib/workspaces";
import ProfileEntry from "@/components/profile-entry";
import { ROLE_LABEL } from "@/lib/graphql/workspace";

type WorkspaceStatus = "active" | "pending" | "invited";
type IconName = "community" | "role" | "members" | "activity" | "settings" | "enter" | "request" | "invite";

const POLICY_META = {
  open: { label: "开放加入", shortLabel: "公开", hint: "任何人都可直接加入" },
  request: { label: "申请制", shortLabel: "申请审批", hint: "提交申请后由 Owner / Admin 审批" },
  invite_only: { label: "邀请制", shortLabel: "仅邀请", hint: "凭邀请链接或批次码加入" },
} as const;

const STATUS_META: Record<WorkspaceStatus, { label: string; className: string }> = {
  active: { label: "Active", className: "workspace-status--active" },
  pending: { label: "申请审批中", className: "workspace-status--pending" },
  invited: { label: "待凭据加入", className: "workspace-status--invited" },
};

const APPLICATION_DATE = "2026 年 8 月 1 日";

function getWorkspaceStatus(ws: WorkspaceListItem): WorkspaceStatus {
  if (ws.membershipStatus) return ws.membershipStatus;
  return ws.myRoleNames?.length ? "active" : "invited";
}

function getWorkspaceRoles(ws: WorkspaceListItem): string[] {
  const roles = ws.myRoleNames?.length ? ws.myRoleNames : ws.roles ?? [];
  return roles.map((role) => ROLE_LABEL[role as keyof typeof ROLE_LABEL] ?? role);
}

function workspaceInitials(ws: WorkspaceListItem): string {
  const words = ws.name.trim().split(/\s+/).filter(Boolean);
  const latinWords = words.filter((word) => /^[A-Za-z]/.test(word));
  if (latinWords.length >= 2) return latinWords.slice(0, 2).map((word) => word[0]).join("").toUpperCase();
  if (latinWords.length === 1 && latinWords[0].length >= 2) return latinWords[0].slice(0, 2).toUpperCase();
  return ws.name.replace(/\s/g, "").slice(0, 2) || "WS";
}

function WorkspaceIcon({ name }: { name: IconName }) {
  const common = { viewBox: "0 0 24 24", fill: "none", stroke: "currentColor", strokeWidth: 1.7, "aria-hidden": true } as const;

  if (name === "community" || name === "members") {
    return (
      <svg {...common}>
        <circle cx="9" cy="8" r="3" />
        <path d="M3.5 19c.6-3.2 2.4-5 5.5-5s4.9 1.8 5.5 5" />
        <path d="M15.5 5.8a3 3 0 0 1 0 5.5M17.2 14.3c1.8.8 2.8 2.2 3.3 4.7" />
      </svg>
    );
  }

  if (name === "role") {
    return (
      <svg {...common}>
        <circle cx="12" cy="8" r="3" />
        <path d="M5.5 19.5c.8-3.2 3-4.8 6.5-4.8s5.7 1.6 6.5 4.8" />
      </svg>
    );
  }

  if (name === "activity") {
    return (
      <svg {...common}>
        <path d="M4 5.5h16v10H9l-5 4v-14Z" />
        <path d="M8 9.5h8M8 12.5h5" />
      </svg>
    );
  }

  if (name === "settings") {
    return (
      <svg {...common}>
        <path d="m12 3 1 2.2 2.3.9 2.2-1 1.4 1.4-1 2.2.9 2.3L21 12l-2.2 1-.9 2.3 1 2.2-1.4 1.4-2.2-1-2.3.9L12 21l-1-2.2-2.3-.9-2.2 1-1.4-1.4 1-2.2L5.2 13 3 12l2.2-1 .9-2.3-1-2.2 1.4-1.4 2.2 1 2.3-.9L12 3Z" />
        <circle cx="12" cy="12" r="2.6" />
      </svg>
    );
  }

  if (name === "enter") {
    return (
      <svg {...common}>
        <path d="M13 5h6v14h-6M4 12h11M11 8l4 4-4 4" />
      </svg>
    );
  }

  if (name === "request") {
    return (
      <svg {...common}>
        <path d="M12 3v18M7.5 7.5h9M7.5 16.5h9" />
        <circle cx="12" cy="12" r="8.5" />
      </svg>
    );
  }

  return (
    <svg {...common}>
      <path d="M6 9.5V6.8A6 6 0 0 1 18 6.8v2.7" />
      <rect x="4" y="9.5" width="16" height="10.5" rx="2" />
      <path d="M12 13v3" />
    </svg>
  );
}

function WorkspaceAvatar({ ws, large = false }: { ws: WorkspaceListItem; large?: boolean }) {
  const status = getWorkspaceStatus(ws);
  return (
    <span className={`workspace-avatar workspace-avatar--${status} ${large ? "workspace-avatar--large" : ""}`}>
      {workspaceInitials(ws)}
    </span>
  );
}

function StatusTag({ status, lowercase = false }: { status: WorkspaceStatus; lowercase?: boolean }) {
  const meta = STATUS_META[status];
  return (
    <span className={`workspace-status ${meta.className}`}>
      <span className="workspace-status__dot" />
      {lowercase ? status : meta.label}
    </span>
  );
}

function RoleChips({ roles }: { roles: string[] }) {
  if (roles.length === 0) return <span className="workspace-empty-value">暂无角色</span>;
  return (
    <span className="workspace-role-chips">
      {roles.map((role) => <span className="workspace-role-chip" key={role}>{role}</span>)}
    </span>
  );
}

function WorkspaceNavItem({
  ws,
  selected,
  onSelect,
}: {
  ws: WorkspaceListItem;
  selected: boolean;
  onSelect: () => void;
}) {
  const status = getWorkspaceStatus(ws);
  const roles = getWorkspaceRoles(ws);

  return (
    <button
      type="button"
      className={`workspace-nav-item ${selected ? "workspace-nav-item--selected" : ""}`}
      aria-pressed={selected}
      onClick={onSelect}
    >
      <WorkspaceAvatar ws={ws} />
      <span className="workspace-nav-item__body">
        <strong>{ws.name}</strong>
        {status === "active" ? (
          <span className="workspace-nav-item__subline">
            {roles.length ? roles.join(" / ") : "已加入"}
          </span>
        ) : (
          <StatusTag status={status} />
        )}
      </span>
      {ws.unreadCount ? <span className="workspace-unread">{ws.unreadCount}</span> : null}
      {status !== "active" && <span className="workspace-nav-item__chevron" aria-hidden="true">›</span>}
    </button>
  );
}

function WorkspaceSidebar({
  workspaces,
  selectedId,
  onSelect,
  onSignOut,
}: {
  workspaces: WorkspaceListItem[];
  selectedId: string | null;
  onSelect: (id: string) => void;
  onSignOut: () => void;
}) {
  const activeCount = workspaces.filter((ws) => getWorkspaceStatus(ws) === "active").length;
  const pendingCount = workspaces.length - activeCount;

  return (
    <aside className="workspace-sidebar" aria-label="工作区导航">
      <div className="workspace-sidebar__brand">CGC 2046</div>
      <div className="workspace-sidebar__heading">
        <h1>我的工作区</h1>
        <p>你加入了 {activeCount} 个工作区{pendingCount > 0 ? ` · ${pendingCount} 个待处理` : ""}</p>
      </div>

      <nav className="workspace-sidebar__nav" aria-label="我的工作区列表">
        {workspaces.map((ws) => (
          <WorkspaceNavItem
            key={ws.id}
            ws={ws}
            selected={ws.id === selectedId}
            onSelect={() => onSelect(ws.id)}
          />
        ))}
      </nav>

      <div className="workspace-sidebar__footer">
        <button type="button" className="workspace-dashed-action">
          <span aria-hidden="true">＋</span>
          发现 / 申请加入新工作区
        </button>
        <div className="workspace-sidebar__account">
          <ProfileEntry />
          <button type="button" className="workspace-signout" onClick={onSignOut}>退出登录</button>
        </div>
      </div>
    </aside>
  );
}

function WorkspaceHero({ ws, status }: { ws: WorkspaceListItem; status: WorkspaceStatus }) {
  const roles = getWorkspaceRoles(ws);
  const policy = POLICY_META[ws.joinPolicy];

  return (
    <div className="workspace-detail-hero">
      <WorkspaceAvatar ws={ws} large />
      <div className="workspace-detail-hero__body">
        <h2>{ws.name}</h2>
        <p className="workspace-slug">{ws.slug}</p>
        {status === "active" ? (
          <div className="workspace-detail-hero__meta">
            <StatusTag status="active" />
            <RoleChips roles={roles} />
          </div>
        ) : (
          <div className="workspace-detail-hero__meta">
            <StatusTag status={status} />
          </div>
        )}
      </div>
      <div className="workspace-detail-hero__policy">
        <span>加入方式</span>
        <strong className={`workspace-policy workspace-policy--${ws.joinPolicy}`}>{policy.label}</strong>
        <p>{policy.hint}</p>
      </div>
    </div>
  );
}

function InfoCard({
  icon,
  title,
  children,
  className = "",
}: {
  icon: IconName;
  title: string;
  children: React.ReactNode;
  className?: string;
}) {
  return (
    <section className={`workspace-info-card ${className}`}>
      <span className="workspace-info-card__icon"><WorkspaceIcon name={icon} /></span>
      <div className="workspace-info-card__body">
        <p className="workspace-info-card__title">{title}</p>
        {children}
      </div>
    </section>
  );
}

function ActivityFeed({ ws }: { ws: WorkspaceListItem }) {
  const items = [
    { icon: "activity" as IconName, text: `${ws.name} 最新动态已发布`, time: "2 小时前" },
    { icon: "members" as IconName, text: "新成员加入社区", time: "1 天前" },
    { icon: "request" as IconName, text: "教研材料已更新", time: "3 天前" },
  ];

  return (
    <section className="workspace-activity" aria-labelledby="workspace-activity-title">
      <div className="workspace-section-heading">
        <h3 id="workspace-activity-title">最近动态</h3>
        <span>{ws.unreadCount ? `${ws.unreadCount} 条未读` : ""}</span>
      </div>
      <div className="workspace-activity__list">
        {items.map((item) => (
          <div className="workspace-activity__item" key={item.text}>
            <span className="workspace-activity__icon"><WorkspaceIcon name={item.icon} /></span>
            <strong>{item.text}</strong>
            <time>{item.time}</time>
          </div>
        ))}
      </div>
      <button type="button" className="workspace-activity__more">查看全部动态</button>
    </section>
  );
}

function ActiveWorkspaceDetail({ ws }: { ws: WorkspaceListItem }) {
  const roles = getWorkspaceRoles(ws);
  const memberCount = typeof ws.memberCount === "number" ? `${ws.memberCount} 位成员` : "成员数待同步";

  return (
    <>
      <WorkspaceHero ws={ws} status="active" />
      <div className="workspace-info-grid">
        <InfoCard icon="community" title="加入方式">
          <strong className="workspace-info-card__value">{POLICY_META[ws.joinPolicy].label}</strong>
          <p>{POLICY_META[ws.joinPolicy].hint}</p>
        </InfoCard>
        <InfoCard icon="role" title="我的角色">
          <RoleChips roles={roles} />
          <p>权限按当前角色并集计算</p>
        </InfoCard>
        <InfoCard icon="members" title="社区规模">
          <strong className="workspace-info-card__value">{memberCount}</strong>
          <p>{ws.sponsorshipEnabled ? "开放赞助" : "暂未开放赞助"}</p>
        </InfoCard>
      </div>
      <ActivityFeed ws={ws} />
      <div className="workspace-detail-actions">
        <Link href={`/w/${ws.slug}`} className="workspace-button workspace-button--primary">
          <WorkspaceIcon name="enter" />
          进入工作台
        </Link>
        <Link href={`/w/${ws.slug}/members`} className="workspace-button workspace-button--outline">
          <WorkspaceIcon name="members" />
          成员与角色
        </Link>
        <button type="button" className="workspace-button workspace-button--outline" disabled title="Workspace 设置将在后续页面开放">
          <WorkspaceIcon name="settings" />
          Workspace 设置
        </button>
      </div>
    </>
  );
}

function ProgressStep({ number, title, caption, state }: { number: string; title: string; caption: string; state: "done" | "current" | "waiting" }) {
  return (
    <div className={`workspace-progress-step workspace-progress-step--${state}`}>
      <span className="workspace-progress-step__marker">{state === "done" ? "✓" : state === "current" ? "●" : number}</span>
      <strong>{title}</strong>
      <span>{caption}</span>
    </div>
  );
}

function PendingWorkspaceDetail({ ws, onBack }: { ws: WorkspaceListItem; onBack: () => void }) {
  return (
    <>
      <WorkspaceHero ws={ws} status="pending" />
      <section className="workspace-progress-card" aria-labelledby="workspace-progress-title">
        <h3 id="workspace-progress-title">申请进度</h3>
        <div className="workspace-progress-line" aria-hidden="true" />
        <div className="workspace-progress-steps">
          <ProgressStep number="1" title="申请已提交" caption={APPLICATION_DATE} state="done" />
          <ProgressStep number="2" title="管理员审批中" caption="当前步骤" state="current" />
          <ProgressStep number="3" title="加入工作区" caption="待完成" state="waiting" />
        </div>
      </section>
      <section className="workspace-status-card">
        <span className="workspace-status-card__icon"><WorkspaceIcon name="request" /></span>
        <div>
          <p>当前状态</p>
          <strong>申请审批中</strong>
          <span>提交于 {APPLICATION_DATE}</span>
        </div>
        <div className="workspace-status-card__notice">
          <span aria-hidden="true">ⓘ</span>
          <div>
            <strong>你暂时不需要做任何操作</strong>
            <p>审批通过后，我们会把这个工作区加入你的列表。</p>
          </div>
        </div>
      </section>
      <div className="workspace-detail-actions workspace-detail-actions--split">
        <button type="button" className="workspace-button workspace-button--outline" onClick={onBack}>← 返回我的工作区</button>
        <button type="button" className="workspace-button workspace-button--pending" disabled>撤回申请</button>
      </div>
    </>
  );
}

function InvitedWorkspaceDetail({ ws, onBack }: { ws: WorkspaceListItem; onBack: () => void }) {
  return (
    <>
      <WorkspaceHero ws={ws} status="invited" />
      <section className="workspace-status-card workspace-status-card--invited">
        <span className="workspace-status-card__icon"><WorkspaceIcon name="invite" /></span>
        <div>
          <p>当前状态</p>
          <strong>待凭据加入</strong>
          <span>这个工作区需要邀请凭据才能加入。</span>
        </div>
        <div className="workspace-status-card__notice">
          <span aria-hidden="true">ⓘ</span>
          <div>
            <strong>使用邀请链接或批次码加入</strong>
            <p>如果你已经收到邀请，请从邀请链接继续。</p>
          </div>
        </div>
      </section>
      <div className="workspace-detail-actions workspace-detail-actions--split">
        <button type="button" className="workspace-button workspace-button--outline" onClick={onBack}>← 返回我的工作区</button>
        <button type="button" className="workspace-button workspace-button--pending" disabled>输入邀请凭据</button>
      </div>
    </>
  );
}

function WorkspaceDetail({ ws, onBack }: { ws: WorkspaceListItem; onBack: () => void }) {
  const status = getWorkspaceStatus(ws);

  return (
    <main className="workspace-detail" aria-labelledby="workspace-detail-title">
      <header className="workspace-detail__header">
        {status === "active" ? (
          <h1 id="workspace-detail-title">工作区详情</h1>
        ) : (
          <button type="button" className="workspace-back-title" onClick={onBack}>
            ← <span id="workspace-detail-title">工作区详情</span>
          </button>
        )}
      </header>
      <div className="workspace-detail__content">
        {status === "active" && <ActiveWorkspaceDetail ws={ws} />}
        {status === "pending" && <PendingWorkspaceDetail ws={ws} onBack={onBack} />}
        {status === "invited" && <InvitedWorkspaceDetail ws={ws} onBack={onBack} />}
      </div>
    </main>
  );
}

function EmptyWorkspaceDetail() {
  return (
    <main className="workspace-detail workspace-detail--empty">
      <header className="workspace-detail__header"><h1>工作区详情</h1></header>
      <div className="workspace-empty-detail">
        <h2>还没有可进入的工作区</h2>
        <p>发现公开工作区，或使用邀请凭据加入新的协作空间。</p>
        <button type="button" className="workspace-button workspace-button--outline">发现 / 申请加入新工作区</button>
      </div>
    </main>
  );
}

function GridWorkspaceCard({ ws }: { ws: WorkspaceListItem }) {
  const status = getWorkspaceStatus(ws);
  const roles = getWorkspaceRoles(ws);
  const policy = POLICY_META[ws.joinPolicy];

  return (
    <article className={`workspace-grid-card workspace-grid-card--${status}`}>
      <StatusTag status={status} lowercase />
      <div className="workspace-grid-card__identity">
        <WorkspaceAvatar ws={ws} large />
        <div>
          <h2>{ws.name}</h2>
          <p className="workspace-slug">{ws.slug}</p>
        </div>
      </div>
      <div className="workspace-grid-card__divider" />
      <div className="workspace-grid-card__policy">
        <strong className={`workspace-policy workspace-policy--${ws.joinPolicy}`}>{policy.label}</strong>
        <span>{status === "active" ? policy.hint : STATUS_META[status].label}</span>
      </div>
      {status === "active" ? (
        <>
          <RoleChips roles={roles} />
          <div className="workspace-grid-card__meta">
            <span><WorkspaceIcon name="members" />{typeof ws.memberCount === "number" ? `${ws.memberCount} 位成员` : "成员数待同步"}</span>
            {ws.unreadCount ? <span><WorkspaceIcon name="activity" />{ws.unreadCount} 条未读</span> : null}
          </div>
          <Link href={`/w/${ws.slug}`} className="workspace-button workspace-button--primary">进入工作台</Link>
        </>
      ) : (
        <p className="workspace-grid-card__hint">{policy.hint}</p>
      )}
    </article>
  );
}

function WorkspaceGrid({ workspaces, onSignOut }: { workspaces: WorkspaceListItem[]; onSignOut: () => void }) {
  return (
    <div className="workspace-grid-page">
      <header className="workspace-grid-page__header">
        <strong>CGC 2046</strong>
        <div className="workspace-grid-page__account">
          <ProfileEntry />
          <button type="button" className="workspace-signout" onClick={onSignOut}>退出登录</button>
        </div>
      </header>
      <main className="workspace-grid-page__content">
        <h1>选择你的工作区</h1>
        <p>一个账号可以加入多个工作区，随时切换你的协作现场。</p>
        <div className="workspace-grid">
          {workspaces.map((ws) => <GridWorkspaceCard key={ws.id} ws={ws} />)}
          <button type="button" className="workspace-grid-card workspace-grid-card--discover">
            <span className="workspace-discover-icon">♧</span>
            <strong>发现 / 申请加入新工作区</strong>
            <span>浏览公开社区，或使用邀请凭据加入</span>
          </button>
        </div>
      </main>
    </div>
  );
}

function LoadingState() {
  return (
    <main className="workspace-loading" aria-label="正在加载工作区">
      <span className="workspace-loading__brand">CGC 2046</span>
      <span className="workspace-loading__text">加载工作区…</span>
    </main>
  );
}

export default function HomePage() {
  const router = useRouter();
  const { authed, confirmed } = useAuthed();
  const [workspaces, setWorkspaces] = useState<WorkspaceListItem[]>([]);
  const [loading, setLoading] = useState(true);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [gridView, setGridView] = useState(false);

  useEffect(() => {
    if (typeof window === "undefined") return;
    queueMicrotask(() => {
      setGridView(new URLSearchParams(window.location.search).get("view") === "grid");
    });
  }, []);

  useEffect(() => {
    if (!confirmed) return;
    if (!authed) {
      router.replace("/login");
      return;
    }

    let cancelled = false;
    fetchMyWorkspaces()
      .then((list) => {
        if (!cancelled) setWorkspaces(list);
      })
      .catch(() => {
        if (!cancelled) setWorkspaces([]);
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });

    return () => {
      cancelled = true;
    };
  }, [authed, confirmed, router]);

  const selectedWorkspace = useMemo(() => {
    if (selectedId) {
      const selected = workspaces.find((ws) => ws.id === selectedId);
      if (selected) return selected;
    }
    return workspaces.find((ws) => getWorkspaceStatus(ws) === "active") ?? workspaces[0];
  }, [selectedId, workspaces]);

  function handleSignOut() {
    clearAuthToken();
    router.push("/login");
  }

  if (!confirmed || !authed) return <LoadingState />;
  if (loading) return <LoadingState />;
  if (gridView) return <WorkspaceGrid workspaces={workspaces} onSignOut={handleSignOut} />;

  return (
    <div className="workspace-page">
      <WorkspaceSidebar
        workspaces={workspaces}
        selectedId={selectedWorkspace?.id ?? null}
        onSelect={setSelectedId}
        onSignOut={handleSignOut}
      />
      {selectedWorkspace ? (
        <WorkspaceDetail ws={selectedWorkspace} onBack={() => setSelectedId(workspaces.find((ws) => getWorkspaceStatus(ws) === "active")?.id ?? null)} />
      ) : (
        <EmptyWorkspaceDetail />
      )}
    </div>
  );
}
