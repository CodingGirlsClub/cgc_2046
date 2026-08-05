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
import { useSearchParams, useRouter } from "next/navigation";
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
import { fetchMyWorkspaces, type WorkspaceListItem } from "@/lib/workspaces";
import { clearSession } from "@/lib/auth";
import WorkspaceListSidebar from "@/components/workspace-list-sidebar";
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
	const router = useRouter();
	const { authed, confirmed, userId } = useAuthed();

	const token = searchParams?.get("token") ?? null;

	// 我的工作区列表（侧栏导航用）
	const [workspaces, setWorkspaces] = useState<WorkspaceListItem[]>([]);

	const [step, setStep] = useState<JoinStep>(
		token ? "invite-token-input" : "input-slug",
	);
	const [slug, setSlug] = useState("");
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
			setError("邀请链接无效或已失效");
			setStep("invite-invalid");
			return;
		}
		if (inv.status !== "active") {
			setError(`邀请已${INVITATION_STATUS_LABEL[inv.status]}`);
			setInvitation(inv);
			setStep("invite-invalid");
			return;
		}
		setInvitation(inv);
		setStep("invite-preview");
	}, []);

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
					setError(e instanceof Error ? e.message : "校验失败");
					setStep("invite-invalid");
				}
			})
			.finally(() => {
				if (!cancelled) setLoading(false);
			});
		return () => {
			cancelled = true;
		};
	}, [token, authed, routeInvitation]);

	// 加载我的工作区列表（侧栏用）
	useEffect(() => {
		if (!authed) return;
		let cancelled = false;
		fetchMyWorkspaces()
			.then((list) => {
				if (!cancelled) setWorkspaces(list);
			})
			.catch(() => {});
		return () => {
			cancelled = true;
		};
	}, [authed]);

	/** 按 slug 查找工作区 */
	const handleLookup = useCallback(async () => {
		if (!slug.trim()) return;
		setLoading(true);
		setError(null);
		try {
			const ws = await fetchWorkspaceBySlug(slug.trim());
			if (!ws) {
				setError(`工作区「${slug}」不存在`);
				return;
			}
			setWorkspace(ws);
			setStep("workspace-preview");
		} catch (e) {
			setError(e instanceof Error ? e.message : "查询失败");
		} finally {
			setLoading(false);
		}
	}, [slug]);

	/** open 直接加入 */
	const handleJoinOpen = useCallback(async () => {
		if (!workspace) return;
		setLoading(true);
		setError(null);
		try {
			await joinWorkspace(workspace.id);
			setStep("join-success");
		} catch (e) {
			setError(e instanceof Error ? e.message : "加入失败");
			setStep("join-error");
		} finally {
			setLoading(false);
		}
	}, [workspace]);

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
				setError(e instanceof Error ? e.message : "提交失败");
			} finally {
				setLoading(false);
			}
		},
		[workspace, authed, userId],
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
			setError(e instanceof Error ? e.message : "校验失败");
			setStep("invite-invalid");
		} finally {
			setLoading(false);
		}
	}, [inviteToken, routeInvitation]);

	/** 接受邀请（须透传 validate 时拿到的明文 token，后端复验持 token） */
	const handleAcceptInvitation = useCallback(async () => {
		if (!invitation || !inviteToken.trim()) return;
		setLoading(true);
		setError(null);
		try {
			await acceptInvitation(invitation.id, inviteToken.trim());
			setStep("invite-accepted");
		} catch (e) {
			setError(e instanceof Error ? e.message : "接受邀请失败");
		} finally {
			setLoading(false);
		}
	}, [invitation, inviteToken]);

	async function handleSignOut() {
		await clearSession();
		router.push("/login");
	}

	if (!confirmed) {
		return (
			<main className="join-page join-page--standalone">
				<div className="join-loading">正在确认登录状态…</div>
			</main>
		);
	}

	if (!authed) {
		return (
			<main className="join-page join-page--standalone">
				<div className="join-card">
					<h1>加入工作区</h1>
					<p>请先登录后再加入工作区。</p>
					<Link href="/login" className="join-button join-button--primary">
						去登录
					</Link>
				</div>
			</main>
		);
	}

	return (
		<div className="workspace-page">
			<WorkspaceListSidebar
				workspaces={workspaces}
				activeAction="discover"
				onSignOut={handleSignOut}
			/>

			<main className="join-page">
				<div className="join-card">
					{/* 面包屑 */}
					<div className="join-breadcrumb">
						<Link href="/">工作台</Link>
						<span>›</span>
						<strong>加入工作区</strong>
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
						<h2>申请已提交</h2>
						<p>你的加入申请已提交，请等待 Owner / Admin 审批。</p>
						<div className="join-status-meta">
							<span className="workspace-status workspace-status--pending">
								<span className="workspace-status__dot" />
								申请审批中
							</span>
						</div>
						<div className="join-actions">
							<Link href="/" className="join-button join-button--primary">
								返回工作台
							</Link>
						</div>
					</div>
				)}

				{/* 加入成功 */}
				{step === "join-success" && (
					<div className="join-status-card">
						<Icon name="check" />
						<h2>加入成功</h2>
						<p>你已成功加入该工作区。</p>
						<div className="join-actions">
							<Link href="/" className="join-button join-button--primary">
								返回工作台
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
						<h2>加入成功</h2>
						<p>你已通过邀请加入该工作区。</p>
						<div className="join-actions">
							<Link href="/" className="join-button join-button--primary">
								返回工作台
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
		</div>
	);
}

export default function JoinPage() {
	return (
		<Suspense
			fallback={
				<main className="join-page join-page--standalone">
					<div className="join-card">
						<div className="join-loading">加载中…</div>
					</div>
				</main>
			}
		>
			<JoinPageInner />
		</Suspense>
	);
}
