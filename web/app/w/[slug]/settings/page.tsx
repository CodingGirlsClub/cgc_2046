"use client";

/**
 * #78 加入策略页 /w/[slug]/settings（#79 IA 改名：原「工作区设置」页）。
 *
 * 最小设置页：加入策略三态切换（开放加入 / 申请制 / 邀请制）。
 * - 数据路径：useWorkspaceBySlug（meWorkspaces 唯一真实路径），myAbilities
 *   含 update_join_policy 才可修改（能力接口门控，与 Rbac.can?/3 语义一致）；
 * - 保存：updateWorkspaceJoinPolicy（updateWorkspace mutation + refetch
 *   ME_WORKSPACES 缓存，概览页/工作台徽章跨页同步）；
 * - 壳：WorkspaceShell（requireWs 默认 true，未知 slug 自动「工作区不可访问」）；
 *   settings 前缀路由预留 B-3 审批/邀请子页（settings/requests、settings/invitations）。
 *
 * P3：settings 三子页统一 tab 导航（与 members/permissions tab 模式一致），
 * 审批/邀请 tab 按 manage_members 能力过滤。
 */

import { useState } from "react";
import Link from "next/link";
import { useParams } from "next/navigation";
import { useWorkspaceBySlug } from "@/lib/use-workspace-by-slug";
import {
	currentUserCanUpdateJoinPolicy,
	updateWorkspaceJoinPolicy,
} from "@/lib/workspaces";
import {
	JOIN_POLICY_HINT,
	JOIN_POLICY_LABEL,
	type JoinPolicy,
} from "@/lib/graphql/workspace";
import WorkspaceShell from "@/components/workspace-shell";

const JOIN_POLICIES: JoinPolicy[] = ["open", "request", "invite_only"];

export default function WorkspaceSettingsPage() {
	const params = useParams<{ slug: string }>();
	const slug = params?.slug ?? "";
	const { ws, loading: wsLoading } = useWorkspaceBySlug(slug);
	const canUpdate = currentUserCanUpdateJoinPolicy(ws);
	const canManage = ws?.myAbilities?.includes("manage_members") ?? false;

	// 草稿策略：以 wsId 键控的派生状态（对齐 useWorkspaceBySlug 派生模式，
	// 避免 effect 内同步 setState；跨 slug 切换时旧草稿自动失效不串台）
	const [draftState, setDraftState] = useState<{
		wsId: string;
		policy: JoinPolicy;
	} | null>(null);
	// 已持久化策略（保存成功后的服务端值）：按钮禁用判定以它为准，
	// 不对比 ws.joinPolicy（hook 本地状态在 refetch 后不自动更新）
	const [savedPolicyState, setSavedPolicyState] = useState<{
		wsId: string;
		policy: JoinPolicy;
	} | null>(null);
	// 保存结果消息（同样 wsId 键控，跨工作区切换自动隐藏）
	const [saveState, setSaveState] = useState<{
		wsId: string;
		kind: "saved" | "error";
		text: string;
	} | null>(null);
	const [saving, setSaving] = useState(false);

	const draft =
		draftState && draftState.wsId === ws?.id ? draftState.policy : null;
	const effective = draft ?? ws?.joinPolicy ?? null;
	const lastPersisted =
		savedPolicyState && savedPolicyState.wsId === ws?.id
			? savedPolicyState.policy
			: (ws?.joinPolicy ?? null);
	const message =
		saveState && saveState.wsId === ws?.id
			? { kind: saveState.kind, text: saveState.text }
			: null;

	async function handleSave() {
		if (!ws || !canUpdate || !effective || effective === lastPersisted) return;
		setSaving(true);
		setSaveState(null);
		try {
			const updated = await updateWorkspaceJoinPolicy(ws.id, effective);
			setDraftState({ wsId: ws.id, policy: updated.joinPolicy });
			setSavedPolicyState({ wsId: ws.id, policy: updated.joinPolicy });
			setSaveState({ wsId: ws.id, kind: "saved", text: "加入策略已更新" });
		} catch (error) {
			setSaveState({
				wsId: ws.id,
				kind: "error",
				text: error instanceof Error ? error.message : "保存失败，请稍后重试",
			});
		} finally {
			setSaving(false);
		}
	}

	return (
		<WorkspaceShell slug={slug}>
			<div className="ws-page-main__inner">
				<div className="ws-page-breadcrumb" aria-label="页面路径">
					<Link href="/">工作台</Link>
					<span>›</span>
					<Link href={`/w/${slug}`}>{ws?.name ?? slug}</Link>
					<span>›</span>
					<strong>加入策略</strong>
				</div>

				<header className="ws-page-heading">
					<div>
						<h1>加入策略</h1>
						<p>决定谁能加入这个 Workspace</p>
					</div>
				</header>

				{ws && (
					<nav className="ws-tabs" aria-label="加入管理页签">
						<Link
							href={`/w/${slug}/settings`}
							className="ws-tab ws-tab--selected"
							aria-current="page"
						>
							加入策略
						</Link>
						{canManage && (
							<>
								<Link
									href={`/w/${slug}/settings/requests`}
									className="ws-tab"
								>
									加入审批
								</Link>
								<Link
									href={`/w/${slug}/settings/invitations`}
									className="ws-tab"
								>
									邀请管理
								</Link>
							</>
						)}
					</nav>
				)}

				{wsLoading || !ws ? (
					<div
						className="settings-loading"
						data-testid="settings-loading"
						aria-label="加载中"
					>
						<div className="settings-skeleton settings-skeleton--title" />
						<div className="settings-skeleton" />
						<div className="settings-skeleton" />
					</div>
				) : (
					<section className="settings-policy-card" aria-label="加入策略">
						<div className="settings-policy-card__header">
							<div>
								<strong>加入策略</strong>
								<p>决定谁能加入这个 Workspace</p>
							</div>
							<span
								className={`workspace-policy workspace-policy--${effective}`}
							>
								{effective ? JOIN_POLICY_LABEL[effective] : ""}
							</span>
						</div>

						<fieldset
							className="settings-policy-options"
							disabled={!canUpdate || saving}
						>
							<legend className="settings-policy-options__legend">
								选择加入方式
							</legend>
							{JOIN_POLICIES.map((policy) => (
								<label
									key={policy}
									className={`settings-policy-option ${
										effective === policy
											? "settings-policy-option--selected"
											: ""
									}`}
								>
									<input
										type="radio"
										name="join-policy"
										value={policy}
										checked={effective === policy}
										onChange={() => {
											setDraftState({ wsId: ws.id, policy });
											setSaveState(null);
										}}
										aria-label={JOIN_POLICY_LABEL[policy]}
									/>
									<span className="settings-policy-option__label">
										{JOIN_POLICY_LABEL[policy]}
									</span>
									<span className="settings-policy-option__hint">
										{JOIN_POLICY_HINT[policy]}
									</span>
								</label>
							))}
						</fieldset>

						{!canUpdate && (
							<div
								className="settings-note"
								data-testid="settings-readonly-note"
							>
								仅 Owner / Admin 可修改加入策略；当前为只读展示。
							</div>
						)}

						{message?.kind === "error" && (
							<div className="members-error" role="alert">
								{message.text}
							</div>
						)}
						{message?.kind === "saved" && (
							<div className="settings-saved" role="status">
								{message.text}
							</div>
						)}

						<div className="settings-actions">
							<button
								type="button"
								className="settings-save"
								onClick={handleSave}
								disabled={
									!canUpdate ||
									saving ||
									!effective ||
									effective === lastPersisted
								}
							>
								{saving ? "保存中…" : "保存更改"}
							</button>
						</div>
					</section>
				)}
			</div>
		</WorkspaceShell>
	);
}