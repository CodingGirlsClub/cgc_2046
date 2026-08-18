"use client";

/**
 * B-3 统一加入入口页（决策 7）。
 *
 * 路由：/join（根级，输入 slug 分流）+ /join?token=xxx（邀请落地流程）。
 * token 参数优先走邀请落地流程。
 *
 * 三策略分流：
 * - open → 直接 join 按钮（joinWorkspace）
 * - request → 申请表单（留言 + createJoinRequest → 显示申请审批中中间态）
 * - invite_only → 提示凭邀请链接加入 + token 输入框（validateInvitation 后跳邀请落地流程）
 *
 * Next.js 16 注意：useSearchParams 需包 Suspense 边界（issue #73）。
 */

import { Suspense, useCallback, useEffect, useRef, useState } from "react";
import Link from "next/link";
import { useSearchParams } from "next/navigation";
import { useTranslations } from "next-intl";
import { useAuthed } from "@/lib/use-authed";
import {
  fetchWorkspaceBySlug,
  joinWorkspace,
  createJoinRequest,
} from "@/lib/requests";
import type { Workspace } from "@/lib/graphql/workspace";
import { validateInvitation, acceptInvitation } from "@/lib/invitations";
import { INVITATION_STATUS_LABEL } from "@/lib/graphql/invitation";
import { Icon } from "@/components/icons";
import type { InvitationItem } from "@/lib/invitations";
import { WorkspacePreviewStep } from "./_steps/workspace-preview-step";
import { SlugInputStep } from "./_steps/slug-input-step";
import { InviteTokenInputStep } from "./_steps/invite-token-input-step";
import { InvitePreviewStep } from "./_steps/invite-preview-step";
import { InviteInvalidStep } from "./_steps/invite-invalid-step";
import { JoinErrorStep } from "./_steps/join-error-step";

type JoinStep =
  | "input-slug"
  | "workspace-preview"
  | "join-success"
  | "join-error"
  | "request-submitted"
  | "invite-token-input"
  | "invite-preview"
  | "invite-accepted"
  | "invite-invalid";

function JoinPageInner() {
  const searchParams = useSearchParams();
  const t = useTranslations("join");
  const labelsT = useTranslations();
  const { authed, confirmed, userId } = useAuthed();

  const token = searchParams?.get("token") ?? null;
  // E-9 #123：审批页 expired join_request 行的重提链接 /join?workspace=<slug>——
  // 参数预填 slug 并在确认登录后自动查找（token 参数流程优先，互不干扰）
  const workspaceParam = searchParams?.get("workspace") ?? null;

  const [step, setStep] = useState<JoinStep>(
    token ? "invite-token-input" : "input-slug",
  );
  const [slug, setSlug] = useState(workspaceParam ?? "");
  const [workspace, setWorkspace] = useState<Workspace | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [inviteToken, setInviteToken] = useState(token ?? "");
  const [invitation, setInvitation] = useState<InvitationItem | null>(null);
  const validatingRef = useRef(false);

  // 邀请校验结果分流：null/非 active → invite-invalid + 错误文案；active → invite-preview。
  // useEffect 自动校验与 handleValidateToken 手动校验共用（避免两处重复分支）。
  const routeInvitation = useCallback((inv: InvitationItem | null) => {
    if (!inv) {
      setError(t("invalidInvite"));
      setStep("invite-invalid");
      return;
    }
    if (inv.status !== "active") {
      setError(t("inviteStatus", { status: labelsT(INVITATION_STATUS_LABEL[inv.status]) }));
      setInvitation(inv);
      setStep("invite-invalid");
      return;
    }
    setInvitation(inv);
    setStep("invite-preview");
  }, [t, labelsT]);

  // token 参数存在时自动校验
  useEffect(() => {
    if (!token || !authed || validatingRef.current) return;
    validatingRef.current = true;
    let cancelled = false;
    validateInvitation(token)
      .then((inv) => {
        if (cancelled) return;
        routeInvitation(inv);
      })
      .catch((e) => {
        if (!cancelled) {
          setError(e instanceof Error ? e.message : t("validateFailed"));
          setStep("invite-invalid");
        }
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [token, authed, routeInvitation, t]);

  /** 按 slug 查找工作区 */
  const handleLookup = useCallback(async () => {
    if (!slug.trim()) return;
    setLoading(true);
    setError(null);
    try {
      const ws = await fetchWorkspaceBySlug(slug.trim());
      if (!ws) {
        setError(t("notFound", { slug }));
        return;
      }
      setWorkspace(ws);
      setStep("workspace-preview");
    } catch (e) {
      setError(e instanceof Error ? e.message : t("lookupFailed"));
    } finally {
      setLoading(false);
    }
  }, [slug, t]);

  // E-9 #123：?workspace=<slug> 参数自动查找（ref 守卫只触发一次；用户手动编辑
  // slug 不重触发；token 流程存在时不自动查找）
  const autoLookupDone = useRef(false);
  useEffect(() => {
    if (token || !workspaceParam || autoLookupDone.current || !authed) return;
    autoLookupDone.current = true;
    handleLookup();
  }, [token, workspaceParam, authed, handleLookup]);

  /** open 直接加入 */
  const handleJoinOpen = useCallback(async () => {
    if (!workspace) return;
    setLoading(true);
    setError(null);
    try {
      await joinWorkspace(workspace.id);
      setStep("join-success");
    } catch (e) {
      setError(e instanceof Error ? e.message : t("joinFailed"));
      setStep("join-error");
    } finally {
      setLoading(false);
    }
  }, [workspace, t]);

  /** request 提交申请 */
  const handleSubmitRequest = useCallback(
    async (message: string) => {
      if (!workspace || !authed || !userId) return;
      setLoading(true);
      setError(null);
      try {
        await createJoinRequest(workspace.id, userId, message || null);
        setStep("request-submitted");
      } catch (e) {
        setError(e instanceof Error ? e.message : t("submitFailed"));
      } finally {
        setLoading(false);
      }
    },
    [workspace, authed, userId, t],
  );

  /** 校验邀请 token */
  const handleValidateToken = useCallback(async () => {
    if (!inviteToken.trim()) return;
    setLoading(true);
    setError(null);
    try {
      const inv = await validateInvitation(inviteToken.trim());
      routeInvitation(inv);
    } catch (e) {
      setError(e instanceof Error ? e.message : t("validateFailed"));
      setStep("invite-invalid");
    } finally {
      setLoading(false);
    }
  }, [inviteToken, routeInvitation, t]);

  /** 接受邀请（须透传 validate 时拿到的明文 token，后端复验持 token） */
  const handleAcceptInvitation = useCallback(async () => {
    if (!invitation || !inviteToken.trim()) return;
    setLoading(true);
    setError(null);
    try {
      await acceptInvitation(invitation.id, inviteToken.trim());
      setStep("invite-accepted");
    } catch (e) {
      setError(e instanceof Error ? e.message : t("acceptFailed"));
    } finally {
      setLoading(false);
    }
  }, [invitation, inviteToken, t]);

  if (!confirmed) {
    return (
      <main className="ws-shell-loading">
        <div className="join-card">
          <div className="join-loading">{t("confirming")}</div>
        </div>
      </main>
    );
  }

  if (!authed) {
    return (
      <main className="ws-shell-loading">
        <div className="join-card">
          <h1>{t("title")}</h1>
          <p>{t("loginFirst")}</p>
          <Link href="/login" className="join-button join-button--primary">
            {t("goLogin")}
          </Link>
        </div>
      </main>
    );
  }

  return (
    <main className="ws-shell-loading">
      <div className="join-card">
        {/* 面包屑 */}
        <div className="join-breadcrumb">
            <Link href="/">{t("breadcrumbHome")}</Link>
            <span>›</span>
            <strong>{t("title")}</strong>
          </div>

          {/* 输入 slug */}
          {(step === "input-slug" || step === "workspace-preview") && (
            <SlugInputStep
              slug={slug}
              setSlug={setSlug}
              loading={loading}
              onLookup={handleLookup}
            />
          )}

          {/* 工作台预览 + 分流 */}
          {step === "workspace-preview" && workspace && (
            <WorkspacePreviewStep
              workspace={workspace}
              loading={loading}
              onJoinOpen={handleJoinOpen}
              onSubmitRequest={handleSubmitRequest}
              onHaveInvite={() => setStep("invite-token-input")}
              onBack={() => setStep("input-slug")}
            />
          )}

          {/* 申请已提交中间态 */}
          {step === "request-submitted" && (
            <div className="join-status-card">
              <Icon name="request" />
              <h2>{t("requestSubmittedTitle")}</h2>
              <p>{t("requestSubmittedDesc")}</p>
              <div className="join-status-meta">
                <span className="workspace-status workspace-status--pending">
                  <span className="workspace-status__dot" />
                  {t("requestPending")}
                </span>
              </div>
              <div className="join-actions">
                <Link href="/" className="join-button join-button--primary">
                  {t("backToHome")}
                </Link>
              </div>
            </div>
          )}

          {/* 加入成功 */}
          {step === "join-success" && (
            <div className="join-status-card">
              <Icon name="check" />
              <h2>{t("joinSuccessTitle")}</h2>
              <p>{t("joinSuccessDesc")}</p>
              <div className="join-actions">
                <Link href="/" className="join-button join-button--primary">
                  {t("backToHome")}
                </Link>
              </div>
            </div>
          )}

          {/* 邀请 token 输入 */}
          {step === "invite-token-input" && (
            <InviteTokenInputStep
              inviteToken={inviteToken}
              setInviteToken={setInviteToken}
              loading={loading}
              onValidate={handleValidateToken}
              onBack={() => setStep("input-slug")}
            />
          )}

          {/* 邀请预览 */}
          {step === "invite-preview" && invitation && (
            <InvitePreviewStep
              invitation={invitation}
              loading={loading}
              onAccept={handleAcceptInvitation}
            />
          )}

          {/* 邀请已接受 */}
          {step === "invite-accepted" && (
            <div className="join-status-card">
              <Icon name="check" />
              <h2>{t("joinSuccessTitle")}</h2>
              <p>{t("joinSuccessInviteDesc")}</p>
              <div className="join-actions">
                <Link href="/" className="join-button join-button--primary">
                  {t("backToHome")}
                </Link>
              </div>
            </div>
          )}

          {/* 邀请无效 */}
          {step === "invite-invalid" && (
            <InviteInvalidStep
              error={error}
              invitation={invitation}
              onRetry={() => {
                setStep("invite-token-input");
                setError(null);
              }}
            />
          )}

          {/* 加入错误 */}
          {step === "join-error" && (
            <JoinErrorStep
              error={error}
              onRetry={() => setStep("workspace-preview")}
            />
          )}

          {/* 通用错误 */}
          {error && step !== "join-error" && step !== "invite-invalid" && (
            <div className="join-error-banner" role="alert">
              {error}
            </div>
          )}
      </div>
    </main>
  );
}

export default function JoinPage() {
  const t = useTranslations("join");
  return (
    <Suspense
      fallback={
        <main className="ws-shell-loading">
          <div className="join-card">
            <div className="join-loading">{t("loading")}</div>
          </div>
        </main>
      }
    >
      <JoinPageInner />
    </Suspense>
  );
}
