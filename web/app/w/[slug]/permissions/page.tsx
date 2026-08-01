"use client";

/**
 * #67 权限表可视化 /w/[slug]/permissions。
 *
 * 功能：
 * - 角色 → 能力映射矩阵（角色行 × 能力列，支持标记 ✓/✗），覆盖切片A 相关资源
 *   （Workspace 创建/读取、成员管理、角色分配、invite_only 读取等）；
 * - 能力来源：mock 矩阵（Owner/Admin/Member 三角色），语义对齐后端 #64/#66 Rbac
 *   can? 判定（多角色并集、member 仅基础访问、create_workspace 仅平台管理员）；
 * - 当前用户角色并集高亮 + 「我的能力」汇总（任一角色支持即支持）；
 * - 数据：mock 先行（lib/permissions），后端 #66 Rbac 定稿后切真实
 *   （USE_MOCK_WORKSPACES = false 即可，调用方无需改）。
 */

import { useEffect, useState } from "react";
import { useParams, useRouter } from "next/navigation";
import Link from "next/link";
import { isAuthenticated, clearAuthToken } from "@/lib/auth";
import { MOCK_WORKSPACES, type WorkspaceListItem } from "@/lib/workspaces";
import {
  fetchPermissionsMatrix,
  myRolesHaveAbility,
  PERMISSION_ABILITIES,
  PERMISSION_ROLE_BADGE_CLASS,
  PERMISSION_ROLE_LABEL,
  PERMISSION_ROLE_LABEL_ZH,
  type PermissionMatrixRow,
} from "@/lib/permissions";

export default function WorkspacePermissionsPage() {
  const params = useParams<{ slug: string }>();
  const slug = params?.slug ?? "";
  const router = useRouter();
  const authed = isAuthenticated();

  const ws: WorkspaceListItem | undefined = MOCK_WORKSPACES.find((w) => w.slug === slug);
  const myRoles = ws?.myRoleNames ?? [];

  const [matrix, setMatrix] = useState<PermissionMatrixRow[] | null>(null);
  const [loading, setLoading] = useState(Boolean(ws));
  const [errorMsg, setErrorMsg] = useState<string | null>(null);

  useEffect(() => {
    if (!authed) {
      router.replace("/login");
      return;
    }
    if (!ws) {
      return;
    }
    fetchPermissionsMatrix()
      .then((rows) => {
        setMatrix(rows);
        setErrorMsg(null);
      })
      .catch((e: unknown) => {
        setErrorMsg(e instanceof Error ? e.message : "加载权限表失败");
      })
      .finally(() => setLoading(false));
  }, [authed, router, ws]);

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

  return (
    <div className="min-h-screen bg-canvas">
      <header className="flex h-[72px] items-center border-b border-line">
        <div className="mx-auto flex w-full max-w-6xl items-center justify-between px-6">
          <div className="flex items-center gap-4">
            <Link href={`/w/${slug}`} className="l-btn-ghost">
              ← 返回工作区
            </Link>
            <div>
              <div className="l-overline">Permissions · 权限说明</div>
              <h1 className="l-h2 text-ink">{ws?.name ?? slug} / 权限表</h1>
            </div>
          </div>
          <button className="l-btn-outline" onClick={handleSignOut}>
            退出登录
          </button>
        </div>
      </header>

      <main className="mx-auto max-w-6xl px-6 py-8">
        {!ws ? (
          <div className="rounded-large bg-card p-10 text-center ring-1 ring-line">
            <p className="l-p text-ink-2">工作区「{slug}」不存在或不可访问。</p>
            <Link href="/" className="l-btn-ghost mt-4 inline-block">
              ← 工作台
            </Link>
          </div>
        ) : (
          <>
            {/* 上下文 chips */}
            <div className="mb-6 flex flex-wrap items-center gap-2">
              <span className="l-chip">我的角色</span>
              {myRoles.length === 0 ? (
                <span className="l-chip">（无）</span>
              ) : (
                myRoles.map((r) => (
                  <span key={r} className={PERMISSION_ROLE_BADGE_CLASS[r]}>
                    {PERMISSION_ROLE_LABEL[r]} · {PERMISSION_ROLE_LABEL_ZH[r]}
                  </span>
                ))
              )}
              <span className="l-chip">语义对齐后端 #64/#66 Rbac can?</span>
            </div>

            {errorMsg && (
              <div className="mb-4 rounded-large bg-card p-3 text-sm text-status-red ring-1 ring-line">
                {errorMsg}
              </div>
            )}

            {loading ? (
              <div className="h-40 animate-pulse rounded-large bg-card ring-1 ring-line" />
            ) : matrix && matrix.length > 0 ? (
              <>
                {/* 权限矩阵：角色行 × 能力列 */}
                <div className="overflow-x-auto rounded-large bg-card ring-1 ring-line">
                  <table className="w-full min-w-[720px] border-collapse text-sm">
                    <thead>
                      <tr className="border-b border-line text-left">
                        <th className="l-overline px-4 py-3 text-ink-3">角色</th>
                        {PERMISSION_ABILITIES.map((a) => (
                          <th key={a.id} className="l-overline px-3 py-3 text-center text-ink-3">
                            {a.label}
                          </th>
                        ))}
                        <th className="l-overline px-4 py-3 text-ink-3">说明</th>
                      </tr>
                    </thead>
                    <tbody>
                      {matrix.map((row) => {
                        const isMyRole = myRoles.includes(row.role);
                        return (
                          <tr
                            key={row.role}
                            className={`border-b border-line last:border-b-0 ${
                              isMyRole ? "bg-accent-mentionbg/40" : ""
                            }`}
                            data-testid="permission-row"
                          >
                            <td className="px-4 py-3">
                              <div className="flex items-center gap-2">
                                <span className={PERMISSION_ROLE_BADGE_CLASS[row.role]}>
                                  {PERMISSION_ROLE_LABEL[row.role]} ·{" "}
                                  {PERMISSION_ROLE_LABEL_ZH[row.role]}
                                </span>
                                {isMyRole && (
                                  <span className="l-chip">我的角色</span>
                                )}
                              </div>
                            </td>
                            {PERMISSION_ABILITIES.map((a) => {
                              const ok = row.abilities[a.id];
                              return (
                                <td
                                  key={a.id}
                                  className="px-3 py-3 text-center"
                                  data-testid={`cell-${row.role}-${a.id}`}
                                  aria-label={`${PERMISSION_ROLE_LABEL[row.role]} ${a.label}：${
                                    ok ? "支持" : "不支持"
                                  }`}
                                >
                                  {ok ? (
                                    <span className="inline-flex h-5 w-5 items-center justify-center rounded-full bg-accent-mentionbg text-accent">
                                      ✓
                                    </span>
                                  ) : (
                                    <span className="inline-flex h-5 w-5 items-center justify-center rounded-full bg-ink-2/10 text-ink-3">
                                      ✗
                                    </span>
                                  )}
                                </td>
                              );
                            })}
                            <td className="px-4 py-3 text-xs text-ink-3">{row.note ?? ""}</td>
                          </tr>
                        );
                      })}
                    </tbody>
                  </table>
                </div>

                {/* 能力说明 */}
                <h2 className="l-overline mt-8 mb-3 text-ink-3">能力说明</h2>
                <div className="grid gap-3 md:grid-cols-2">
                  {PERMISSION_ABILITIES.map((a) => {
                    const supported = myRolesHaveAbility(myRoles, matrix, a.id);
                    return (
                      <div key={a.id} className="rounded-large bg-card p-4 ring-1 ring-line">
                        <div className="flex items-center justify-between gap-2">
                          <span className="l-p font-medium text-ink">{a.label}</span>
                          {myRoles.length > 0 && (
                            <span className={`l-chip ${supported ? "!text-accent" : ""}`}>
                              {supported ? "我的角色支持" : "我的角色不支持"}
                            </span>
                          )}
                        </div>
                        <p className="l-p mt-1 text-xs text-ink-3">{a.description}</p>
                      </div>
                    );
                  })}
                </div>

                <p className="l-p mt-6 text-xs text-ink-3">
                  ※ 多角色并集：同一成员可持多个角色，任一角色支持某能力即视为支持（与后端
                  can? 判定语义一致）。「创建工作台」为平台管理员专属，不随工作台角色授予。
                </p>
              </>
            ) : (
              <div className="rounded-large bg-card p-10 text-center ring-1 ring-line">
                <p className="l-p text-ink-2">暂无权限数据。</p>
              </div>
            )}
          </>
        )}
      </main>
    </div>
  );
}
