"use client";

/**
 * #63 工作区占位页 /w/[slug]。
 *
 * 从工作台点击某个 workspace 后进入；当前仅展示该 workspace 的基本信息
 * （名称 / slug / join_policy / 赞助入口），工作区具体功能由后续 ticket 填充
 * （#64 membership、#65+ 教研/报名/赞助等）。
 *
 * 数据：优先从 mock 列表按 slug 匹配（与工作台同源，切换真实数据时保持一致）；
 * 未匹配则展示 slug 与"工作区建设中"占位。
 */

import { useEffect } from "react";
import { useParams, useRouter } from "next/navigation";
import Link from "next/link";
import { isAuthenticated, clearAuthToken } from "@/lib/auth";
import { MOCK_WORKSPACES, type WorkspaceListItem } from "@/lib/workspaces";
import { JOIN_POLICY_LABEL, JOIN_POLICY_HINT } from "@/lib/graphql/workspace";

export default function WorkspacePage() {
  const params = useParams<{ slug: string }>();
  const slug = params?.slug ?? "";
  const router = useRouter();
  // isAuthenticated() 同步读 cookie；登录跳转由 useAuthSubmit router.push 触发重渲染
  const authed = isAuthenticated();

  useEffect(() => {
    if (!authed) {
      router.replace("/login");
    }
  }, [authed, router]);

  function handleSignOut() {
    clearAuthToken();
    router.push("/login");
  }

  if (!authed) {
    return (
      <main className="flex flex-1 items-center justify-center bg-canvas">
        <span className="l-p text-ink-3">加载中…</span>
      </main>
    );
  }

  const ws: WorkspaceListItem | undefined = MOCK_WORKSPACES.find((w) => w.slug === slug);

  return (
    <div className="min-h-screen bg-canvas">
      <header className="flex h-[72px] items-center border-b border-line">
        <div className="mx-auto flex w-full max-w-6xl items-center justify-between px-6">
          <div className="flex items-center gap-4">
            <Link href="/" className="l-btn-ghost">
              ← 工作台
            </Link>
            <div>
              <div className="l-overline">Workspace</div>
              <h1 className="l-h2 text-ink">{ws?.name ?? slug}</h1>
            </div>
          </div>
          <button className="l-btn-outline" onClick={handleSignOut}>
            退出登录
          </button>
        </div>
      </header>

      <main className="mx-auto max-w-6xl px-6 py-8">
        {ws ? (
          <div className="grid gap-4 sm:grid-cols-3">
            <div className="rounded-large bg-card p-5 ring-1 ring-line">
              <div className="l-overline">标识</div>
              <div className="l-mono mt-2 text-sm text-ink">{ws.slug}</div>
            </div>
            <div className="rounded-large bg-card p-5 ring-1 ring-line">
              <div className="l-overline">加入方式</div>
              <div className="l-chip mt-2">
                {JOIN_POLICY_LABEL[ws.joinPolicy]}
              </div>
              <p className="l-p mt-2 text-xs text-ink-3">{JOIN_POLICY_HINT[ws.joinPolicy]}</p>
            </div>
            <div className="rounded-large bg-card p-5 ring-1 ring-line">
              <div className="l-overline">赞助入口</div>
              <div className="mt-2 text-sm text-ink">
                {ws.sponsorshipEnabled ? "已开启" : "已关闭"}
              </div>
            </div>
          </div>
        ) : (
          <div className="rounded-large bg-card p-10 text-center ring-1 ring-line">
            <p className="l-p text-ink-2">工作区「{slug}」建设中。</p>
            <p className="l-p mt-1 text-ink-3">具体功能由后续 ticket 填充（#64 membership 等）。</p>
          </div>
        )}
      </main>
    </div>
  );
}
