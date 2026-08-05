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

	// token 参数存在时自动校验
	useEffect(() => {
		if (!token || !authed || validatingRef.current) return;
		validatingRef.current = true;
		let cancelled = false;
		validateInvitation(token)
			.then((inv) => {
				if (cancelled) return;
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
	}, [token, authed]);

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
		} catch (e) {
			setError(e instanceof Error ? e.message : "校验失败");
			setStep("invite-invalid");
		} finally {
			setLoading(false);
		}
	}, [inviteToken]);

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
					<>
						<h1>加入工作区</h1>
						<p>输入工作区标识（slug）查找并加入</p>
						<div className="join-input-row">
							<input
								type="text"
								className="join-input"
								placeholder="输入工作区 slug，如 cgc-shanghai"
								value={slug}
								onChange={(e) => setSlug(e.target.value)}
								onKeyDown={(e) => e.key === "Enter" && handleLookup()}
								disabled={loading}
								aria-label="工作区 slug"
							/>
							<button
								type="button"
								className="join-button join-button--primary"
								onClick={handleLookup}
								disabled={loading || !slug.trim()}
							>
								{loading ? "查询中…" : "查找"}
							</button>
						</div>
					</>
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
					<>
						<h1>使用邀请链接加入</h1>
						<p>输入邀请链接中的 token 或完整链接</p>
						<div className="join-input-row">
							<input
								type="text"
								className="join-input"
								placeholder="输入邀请 token 或粘贴完整链接"
								value={inviteToken}
								onChange={(e) => {
									// 自动提取 token：如果粘贴的是完整 URL，提取 token 参数
									const val = e.target.value;
									try {
										const url = new URL(val);
										const t = url.searchParams.get("token");
										if (t) {
											setInviteToken(t);
											return;
										}
									} catch {
										// 不是 URL，直接使用输入值
									}
									setInviteToken(val);
								}}
								onKeyDown={(e) => e.key === "Enter" && handleValidateToken()}
								disabled={loading}
								aria-label="邀请 token"
							/>
							<button
								type="button"
								className="join-button join-button--primary"
								onClick={handleValidateToken}
								disabled={loading || !inviteToken.trim()}
							>
								{loading ? "校验中…" : "校验"}
							</button>
						</div>
						<button
							type="button"
							className="join-button join-button--ghost"
							onClick={() => setStep("input-slug")}
						>
							← 返回
						</button>
					</>
				)}

				{/* 邀请预览 */}
				{step === "invite-preview" && invitation && (
					<div className="join-workspace-preview">
						<div className="join-workspace-info">
							<h2>{invitation.workspaceName ?? "未知工作区"}</h2>
							{invitation.workspaceSlug && (
								<code>{invitation.workspaceSlug}</code>
							)}
							{invitation.preauthorizedRoleNames &&
								invitation.preauthorizedRoleNames.length > 0 && (
									<div className="join-preauthorized-roles">
										<span>预授权角色：</span>
										{invitation.preauthorizedRoleNames.map((role) => (
											<span className="workspace-role-chip" key={role}>
												{role}
											</span>
										))}
									</div>
								)}
							{(!invitation.preauthorizedRoleNames ||
								invitation.preauthorizedRoleNames.length === 0) && (
								<p className="join-note">
									此邀请未预授权角色，加入后需 Owner 分配角色。
								</p>
							)}
						</div>
						<div className="join-action-area">
							<button
								type="button"
								className="join-button join-button--primary"
								onClick={handleAcceptInvitation}
								disabled={loading}
							>
								{loading ? "接受中…" : "确认加入"}
							</button>
						</div>
					</div>
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
					<div className="join-status-card join-status-card--error">
						<Icon name="lock" />
						<h2>邀请无效</h2>
						<p>{error}</p>
						{invitation && invitation.status !== "active" && (
							<p className="join-status-detail">
								状态：{INVITATION_STATUS_LABEL[invitation.status]}
							</p>
						)}
						<div className="join-actions">
							<button
								type="button"
								className="join-button join-button--outline"
								onClick={() => {
									setStep("invite-token-input");
									setError(null);
								}}
							>
								重新输入
							</button>
							<Link href="/" className="join-button join-button--ghost">
								返回工作台
							</Link>
						</div>
					</div>
				)}

				{/* 加入错误 */}
				{step === "join-error" && (
					<div className="join-status-card join-status-card--error">
						<Icon name="lock" />
						<h2>加入失败</h2>
						<p>{error}</p>
						<div className="join-actions">
							<button
								type="button"
								className="join-button join-button--outline"
								onClick={() => setStep("workspace-preview")}
							>
								重试
							</button>
							<Link href="/" className="join-button join-button--ghost">
								返回工作台
							</Link>
						</div>
					</div>
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
