"use client";

/**
 * #67 权限映射页 /w/[slug]/permissions。
 *
 * 页面按 07-rbac-permission-map-light 设计稿落地：同一 Workspace 管理壳、
 * 五角色 × 七能力矩阵，以及 Owner + Tutor 的角色并集 can? 判定示例。
 * 权限页只解释能力，不画 Agent / Workflow 执行 UI。
 */

import { useEffect, useMemo, useState } from "react";
import Link from "next/link";
import { useParams, useRouter } from "next/navigation";
import { clearAuthToken } from "@/lib/auth";
import { useAuthed } from "@/lib/use-authed";
import { useWorkspaceBySlug } from "@/lib/use-workspace-by-slug";
import {
  fetchPermissionsMatrix,
  myRolesHaveAbility,
  PERMISSION_ABILITIES,
  PERMISSION_ROLE_LABEL,
  PERMISSION_ROLE_ORDER,
  type PermissionAbility,
  type PermissionMatrixRow,
} from "@/lib/permissions";
import {
  ROLE_BADGE_CLASS,
  type MembershipRoleName,
} from "@/lib/graphql/workspace";
import ProfileEntry from "@/components/profile-entry";

// 演示数据（角色值子集；枚举单源见 lib/graphql/workspace.ts 的 ROLE_NAMES）
const EXAMPLE_ROLES: MembershipRoleName[] = ["owner", "tutor"];

type IconName = "grid" | "users" | "settings" | "user" | "shield" | "info" | "owner" | "check";

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
          <circle cx="9" cy="8" r="3" />
          <path d="M3.5 20c.6-3.2 2.4-5 5.5-5s4.9 1.8 5.5 5" />
          <path d="M15.5 5.8a3 3 0 0 1 0 5.5M17.2 14.3c1.8.8 2.8 2.2 3.3 4.7" />
        </svg>
      );
    case "settings":
      return (
        <svg {...common}>
          <circle cx="12" cy="12" r="3" />
          <path d="M19.4 15a1.7 1.7 0 0 0 .34 1.88l.06.06-1.7 1.7-.06-.06a1.7 1.7 0 0 0-1.88-.34 1.7 1.7 0 0 0-1.03 1.56V21h-2.4v-.2a1.7 1.7 0 0 0-1.03-1.56 1.7 1.7 0 0 0-1.88.34l-.06.06-1.7-1.7.06-.06A1.7 1.7 0 0 0 8.46 15a1.7 1.7 0 0 0-1.56-1.03H6.7v-2.4h.2A1.7 1.7 0 0 0 8.46 10a1.7 1.7 0 0 0-.34-1.88l-.06-.06 1.7-1.7.06.06A1.7 1.7 0 0 0 10.99 7.46 1.7 1.7 0 0 0 12.02 5.9V5h2.4v.2a1.7 1.7 0 0 0 1.03 1.56 1.7 1.7 0 0 0 1.88-.34l.06-.06 1.7 1.7-.06.06A1.7 1.7 0 0 0 19.4 10a1.7 1.7 0 0 0 1.56 1.03h.2v2.4h-.2A1.7 1.7 0 0 0 19.4 15Z" />
        </svg>
      );
    case "user":
      return (
        <svg {...common}>
          <circle cx="12" cy="8" r="3.5" />
          <path d="M4 21a8 8 0 0 1 16 0" />
        </svg>
      );
    case "shield":
      return (
        <svg {...common}>
          <path d="M12 3 19 6v5c0 4.7-2.9 8.1-7 10-4.1-1.9-7-5.3-7-10V6l7-3Z" />
          <path d="m9.3 12 1.8 1.8 3.7-4" />
        </svg>
      );
    case "info":
      return (
        <svg {...common}>
          <circle cx="12" cy="12" r="9" />
          <path d="M12 10.5v5M12 7.5h.01" />
        </svg>
      );
    case "owner":
      return (
        <svg {...common}>
          <circle cx="12" cy="8" r="3.5" />
          <path d="M4 21a8 8 0 0 1 16 0" />
        </svg>
      );
    case "check":
      return (
        <svg {...common}>
          <path d="m5 12 4.5 4.5L19 7" />
        </svg>
      );
  }
}

function roleLabel(role: MembershipRoleName) {
  return PERMISSION_ROLE_LABEL[role] ?? role;
}

function roleBadgeClass(role: MembershipRoleName) {
  return ROLE_BADGE_CLASS[role] ?? "l-badge l-badge-member";
}

function isCrossWorkspace(ability: PermissionAbility) {
  return ability === "cross_workspace_access";
}

function PermissionCell({ row, ability }: { row: PermissionMatrixRow; ability: PermissionAbility }) {
  const allowed = row.abilities[ability];
  return (
    <td
      className={`permissions-matrix__cell ${allowed ? "permissions-matrix__cell--allowed" : "permissions-matrix__cell--denied"}`}
      data-testid={`cell-${row.role}-${ability}`}
      aria-label={`${roleLabel(row.role)} ${ability}：${allowed ? "允许" : "拒绝"}`}
    >
      {allowed ? "✓" : isCrossWorkspace(ability) ? "⊘" : "—"}
    </td>
  );
}

function Sidebar({ slug }: { slug: string }) {
  return (
    <aside className="permissions-sidebar">
      <div className="permissions-sidebar__brand">
        <span>上海 Coding Girls Club</span>
        <span className="permissions-sidebar__chevron">⌄</span>
      </div>

      <nav className="permissions-sidebar__nav" aria-label="工作区导航">
        <Link href={`/w/${slug}`} className="permissions-sidebar__item">
          <Icon name="grid" size={22} />
          <span>概览</span>
        </Link>
        <Link href={`/w/${slug}/members`} className="permissions-sidebar__item permissions-sidebar__item--selected">
          <Icon name="users" size={22} />
          <span>成员与角色</span>
        </Link>
        <button type="button" disabled className="permissions-sidebar__item permissions-sidebar__item--disabled" title="Workspace 设置将在后续版本开放">
          <Icon name="settings" size={22} />
          <span>工作区设置</span>
        </button>
        <Link href="/profile" className="permissions-sidebar__item">
          <Icon name="user" size={22} />
          <span>个人资料</span>
        </Link>
      </nav>

      <div className="permissions-sidebar__divider" />
      <div className="permissions-sidebar__section-title">Workspace 设置</div>
      <Link href={`/w/${slug}/members`} className="permissions-sidebar__item permissions-sidebar__item--subselected">
        <Icon name="settings" size={20} />
        <span>成员与角色</span>
      </Link>

      <div className="permissions-sidebar__footer">
        <ProfileEntry />
      </div>
    </aside>
  );
}

function NoticeCard({ icon, tone, title, detail }: { icon: IconName; tone: string; title: string; detail: string }) {
  return (
    <article className={`permissions-notice permissions-notice--${tone}`}>
      <span className="permissions-notice__icon"><Icon name={icon} size={23} /></span>
      <div>
        <strong>{title}</strong>
        <span>{detail}</span>
      </div>
    </article>
  );
}

function MatrixCard({ matrix }: { matrix: PermissionMatrixRow[] }) {
  const rowsByRole = useMemo(() => new Map(matrix.map((row) => [row.role, row])), [matrix]);
  const orderedRows = PERMISSION_ROLE_ORDER.map((role) => rowsByRole.get(role)).filter(
    (row): row is PermissionMatrixRow => Boolean(row),
  );

  return (
    <section className="permissions-matrix-card" aria-label="权限矩阵">
      <header className="permissions-card-heading">
        <h2>权限矩阵</h2>
        <span>Role → capability</span>
      </header>
      <div className="permissions-matrix-scroll">
        <table className="permissions-matrix">
          <thead>
            <tr>
              <th scope="col">能力</th>
              {PERMISSION_ROLE_ORDER.map((role) => (
                <th key={role} scope="col">
                  <span className="permissions-role-header">{roleLabel(role)}</span>
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {PERMISSION_ABILITIES.map((ability) => {
              const crossRow = isCrossWorkspace(ability.id);
              return (
                <tr
                  key={ability.id}
                  className={crossRow ? "permissions-matrix__row--cross" : undefined}
                  data-testid={`permission-row-${ability.id}`}
                >
                  <th scope="row" className="permissions-ability-label">
                    <strong>{ability.label}</strong>
                    {ability.id === "assign_roles" && <small><Icon name="info" size={14} />不含 Owner 角色授予</small>}
                  </th>
                  {orderedRows.map((row) => <PermissionCell key={`${row.role}-${ability.id}`} row={row} ability={ability.id} />)}
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </section>
  );
}

function ExampleCard({ matrix }: { matrix: PermissionMatrixRow[] }) {
  return (
    <aside className="permissions-example-card" aria-label="判定示例" data-testid="permission-example">
      <h2>判定示例</h2>
      <div className="permissions-example__person">
        <span className="permissions-example__avatar">林</span>
        <div>
          <strong>林溪</strong>
          <div className="permissions-example__roles">
            {EXAMPLE_ROLES.map((role) => <span key={role} className={roleBadgeClass(role)}>{roleLabel(role)}</span>)}
            <button type="button" className="permissions-example__add" aria-label="查看更多角色">＋</button>
          </div>
        </div>
      </div>

      <div className="permissions-example__divider" />
      <h3>合并后能力</h3>
      <ul className="permissions-example__abilities">
        {PERMISSION_ABILITIES.map((ability) => {
          const allowed = myRolesHaveAbility(EXAMPLE_ROLES, matrix, ability.id);
          return (
            <li key={ability.id} data-testid="permission-ability-status">
              <span className={`permissions-example__status ${allowed ? "permissions-example__status--allowed" : "permissions-example__status--denied"}`}>{allowed ? "○" : "⊘"}</span>
              <span>{ability.label}</span>
              <strong className={allowed ? "permissions-result--allowed" : "permissions-result--denied"}>{allowed ? "允许" : "拒绝"}</strong>
            </li>
          );
        })}
      </ul>

      <div className="permissions-example__result">
        <code>can? = true</code>
        <span>允许</span>
      </div>
      <p>权限来自当前 Workspace 的 MembershipRole 并集</p>
    </aside>
  );
}

export default function WorkspacePermissionsPage() {
  const params = useParams<{ slug: string }>();
  const slug = params?.slug ?? "";
  const router = useRouter();
  const { authed, confirmed } = useAuthed();
  const { ws, loading: wsLoading } = useWorkspaceBySlug(slug);
  const wsId = ws?.id;

  const [matrix, setMatrix] = useState<PermissionMatrixRow[] | null>(null);
  const [matrixWorkspaceId, setMatrixWorkspaceId] = useState<string | null>(null);
  const [errorMsg, setErrorMsg] = useState<string | null>(null);

  useEffect(() => {
    if (!confirmed) return;
    if (!authed) {
      router.replace("/login");
      return;
    }
    if (!wsId) return;

    let cancelled = false;
    fetchPermissionsMatrix()
      .then((rows) => {
        if (cancelled) return;
        setMatrix(rows);
        setMatrixWorkspaceId(wsId);
        setErrorMsg(null);
      })
      .catch((error: unknown) => {
        if (cancelled) return;
        setMatrix([]);
        setMatrixWorkspaceId(wsId);
        setErrorMsg(error instanceof Error ? error.message : "加载权限映射失败");
      });

    return () => {
      cancelled = true;
    };
  }, [authed, confirmed, router, wsId]);

  function handleSignOut() {
    clearAuthToken();
    router.push("/login");
  }

  const currentMatrix = matrixWorkspaceId === wsId ? matrix : null;

  if (!authed) {
    return (
      <main className="permissions-loading">
        <span>正在确认登录状态…</span>
      </main>
    );
  }

  if (!ws && !wsLoading) {
    return (
      <main className="permissions-page">
        <div className="permissions-empty-page">
          <h1>工作区不可访问</h1>
          <p>工作区「{slug}」不存在或你没有访问权限。</p>
          <Link href="/" className="permissions-primary-link">返回工作台</Link>
        </div>
      </main>
    );
  }

  return (
    <div className="permissions-page">
      <Sidebar slug={slug} />
      <main className="permissions-main">
        <div className="permissions-main__inner">
          <div className="permissions-breadcrumb" aria-label="页面路径">
            <Link href={`/w/${slug}`}>Workspace 设置</Link>
            <span>›</span>
            <Link href={`/w/${slug}/members`}>成员与角色</Link>
            <span>›</span>
            <strong>权限映射</strong>
          </div>

          <header className="permissions-heading">
            <h1>查看角色到能力的映射与 can? 判定</h1>
          </header>

          <nav className="permissions-tabs" aria-label="成员管理页签">
            <Link href={`/w/${slug}/members`} className="permissions-tab">成员</Link>
            <Link href={`/w/${slug}/permissions`} className="permissions-tab permissions-tab--selected" aria-current="page">权限映射</Link>
          </nav>

          <section className="permissions-notices" aria-label="权限规则说明">
            <NoticeCard icon="users" tone="green" title="多角色取并集" detail="任一角色允许，即可执行" />
            <NoticeCard icon="shield" tone="cyan" title="租户边界优先" detail="跨 Workspace 一律拒绝" />
            <NoticeCard icon="owner" tone="blue" title="Owner 专门指派" detail="不可通过行内角色编辑授予" />
          </section>

          {errorMsg && <div className="permissions-error" role="alert">{errorMsg}</div>}

          {wsLoading || currentMatrix === null ? (
            <div className="permissions-loading-card" data-testid="permissions-loading" />
          ) : currentMatrix.length > 0 ? (
            <div className="permissions-content-grid">
              <MatrixCard matrix={currentMatrix} />
              <ExampleCard matrix={currentMatrix} />
            </div>
          ) : (
            <div className="permissions-empty-table">
              <Icon name="shield" size={30} />
              <strong>暂无权限映射</strong>
              <p>当前 Workspace 还没有可展示的角色能力矩阵。</p>
            </div>
          )}

          <footer className="permissions-footer">
            <span>角色权限按当前 Workspace 隔离；跨 Workspace 资源默认拒绝。</span>
            <button type="button" onClick={handleSignOut}>退出登录</button>
          </footer>
        </div>
      </main>
    </div>
  );
}
