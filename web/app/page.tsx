"use client";

/**
 * #63 工作台（根路径 "/"）：当前用户可进入的 Workspace 列表选择页。
 *
 * 数据源：lib/workspaces.ts —— 当前 mock（后端 #62 无 list 查询，#64 membership
 * 落地后由 myWorkspaces 切换真实数据）；UI/交互/路由为 #63 验收重点。
 *
 * 交互：
 * - 登录成功后跳转 "/"（#61 useAuthSubmit 已实现）
 * - 每个 workspace 卡片展示 slug / 名称 / join_policy 标识 / 赞助入口标识
 * - 点击"进入工作台" → /w/[slug]（工作区占位页，后续 ticket 填充）
 * - 未登录访问 → 重定向 /login
 */

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import Link from "next/link";
import { isAuthenticated, clearAuthToken } from "@/lib/auth";
import {
  fetchMyWorkspaces,
  type WorkspaceListItem,
} from "@/lib/workspaces";
import {
  JOIN_POLICY_LABEL,
  JOIN_POLICY_HINT,
  type JoinPolicy,
} from "@/lib/graphql/workspace";

/** join_policy 徽章：Linear 小圆点 + 浅底 pill */
function JoinBadge({ policy }: { policy: JoinPolicy }) {
  const dot =
    policy === "open"
      ? "bg-status-green"
      : policy === "request"
        ? "bg-status-cyan"
        : "bg-status-violet";
  return (
    <span className="l-chip">
      <span className={`h-1.5 w-1.5 rounded-full ${dot}`} />
      {JOIN_POLICY_LABEL[policy]}
    </span>
  );
}

function WorkspaceAvatar({ name, size = "h-10 w-10 text-sm" }: { name: string; size?: string }) {
  return (
    <div
      className={`flex shrink-0 items-center justify-center rounded-[6px] bg-soft font-[590] text-ink-2 ring-1 ring-line ${size}`}
    >
      {name.slice(0, 1)}
    </div>
  );
}

function WorkspaceCard({ ws }: { ws: WorkspaceListItem }) {
  return (
    <article className="group flex flex-col rounded-large bg-card p-5 ring-1 ring-line transition hover:shadow-elevated hover:ring-line-strong">
      <div className="flex items-start justify-between">
        <WorkspaceAvatar name={ws.name} />
        <JoinBadge policy={ws.joinPolicy} />
      </div>
      <h2 className="l-h4 mt-3 text-ink">{ws.name}</h2>
      <div className="l-mono mt-0.5 text-xs text-ink-3">{ws.slug}</div>
      {ws.description && <p className="l-p mt-2 flex-1 text-ink-2">{ws.description}</p>}

      <div className="mt-3 flex flex-wrap items-center gap-2 text-xs text-ink-3">
        <span className="rounded-[4px] bg-soft px-1.5 py-0.5 ring-1 ring-line">
          {ws.sponsorshipEnabled ? "赞助入口已开启" : "赞助入口关闭"}
        </span>
        {typeof ws.memberCount === "number" && <span>{ws.memberCount} 成员</span>}
      </div>

      <div className="mt-4 border-t border-line pt-3">
        {ws.membershipStatus === "active" ? (
          <Link
            href={`/w/${ws.slug}`}
            className="l-btn-primary w-full justify-center transition group-hover:bg-accent-mention"
          >
            进入工作台 →
          </Link>
        ) : (
          <div className="flex items-center justify-between">
            <span className="inline-flex items-center gap-1.5 text-xs text-status-violet">
              <span className="h-1.5 w-1.5 rounded-full bg-status-violet" />
              {ws.membershipStatus === "invited" ? "待凭据加入" : "申请审批中"}
            </span>
            <span className="text-[11px] text-ink-3">{JOIN_POLICY_HINT[ws.joinPolicy]}</span>
          </div>
        )}
      </div>
    </article>
  );
}

export default function HomePage() {
  const router = useRouter();
  const [workspaces, setWorkspaces] = useState<WorkspaceListItem[]>([]);
  const [loading, setLoading] = useState(true);
  // isAuthenticated() 同步读 cookie；登录跳转由 useAuthSubmit router.push 触发重渲染
  const authed = isAuthenticated();

  useEffect(() => {
    if (!authed) {
      router.replace("/login");
      return;
    }
    let cancelled = false;
    fetchMyWorkspaces()
      .then((list) => {
        if (!cancelled) setWorkspaces(list);
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [authed, router]);

  function handleSignOut() {
    clearAuthToken();
    router.push("/login");
  }

  // 未登录重定向中：渲染空壳避免闪烁
  if (!authed) {
    return (
      <main className="flex flex-1 items-center justify-center bg-canvas">
        <span className="l-p text-ink-3">加载中…</span>
      </main>
    );
  }

  const activeCount = workspaces.filter((w) => w.membershipStatus === "active").length;
  const pendingCount = workspaces.length - activeCount;

  return (
    <div className="min-h-screen bg-canvas">
      <header className="flex h-[72px] items-center border-b border-line">
        <div className="mx-auto flex w-full max-w-6xl items-center justify-between px-6">
          <div>
            <div className="l-overline">Coding Girls Club</div>
            <h1 className="l-h2 text-ink">选择你的工作台</h1>
          </div>
          <div className="flex items-center gap-3">
            <span className="l-p text-ink-3">已登录 · CGC 2046</span>
            <button className="l-btn-outline" onClick={handleSignOut}>
              退出登录
            </button>
          </div>
        </div>
      </header>

      <main className="mx-auto max-w-6xl px-6 py-8">
        <p className="l-p mb-6 text-ink-2">
          你加入了{" "}
          <span className="font-[510] text-ink">{activeCount}</span> 个工作区
          {pendingCount > 0 && (
            <>
              ，还有 <span className="font-[510] text-ink">{pendingCount}</span> 个待处理
            </>
          )}
          。
        </p>

        {loading ? (
          <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
            {[0, 1, 2].map((i) => (
              <div key={i} className="h-56 animate-pulse rounded-large bg-soft-2 ring-1 ring-line" />
            ))}
          </div>
        ) : workspaces.length === 0 ? (
          <div className="rounded-large bg-card p-10 text-center ring-1 ring-line">
            <p className="l-p text-ink-3">还没有可进入的工作台。</p>
            <p className="l-p mt-1 text-ink-3">发现 / 申请加入新工作区（后续 ticket）</p>
          </div>
        ) : (
          <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
            {workspaces.map((ws) => (
              <WorkspaceCard key={ws.id} ws={ws} />
            ))}
            {/* 加入新工作区占位卡片（后续 ticket 实现） */}
            <button
              type="button"
              disabled
              className="flex min-h-[240px] flex-col items-center justify-center gap-2 rounded-large border border-dashed border-line-strong text-ink-3"
            >
              <span className="text-3xl font-[400]">+</span>
              <span className="l-btn">发现 / 申请加入新工作区</span>
            </button>
          </div>
        )}
      </main>
    </div>
  );
}
