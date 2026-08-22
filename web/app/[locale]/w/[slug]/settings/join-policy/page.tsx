"use client";

/**
 * #78 加入策略页 /w/[slug]/settings（#79 IA 改名：原「工作区设置」页）。
 *
 * 最小设置页：加入策略三态切换（开放加入 / 申请制 / 邀请制）。
 * - 数据路径：useWorkspaceBySlug（meWorkspaces 唯一真实路径），myAbilities
 *   含 update_join_policy 才可修改（能力接口门控，判定单源为后端 Rbac.abilities_for/2）；
 * - 保存：updateWorkspaceJoinPolicy（updateWorkspace mutation + refetch
 *   ME_WORKSPACES 缓存，概览页/工作台徽章跨页同步）；
 * - 壳：WorkspaceShell（requireWs 默认 true，未知 slug 自动「工作区不可访问」）；
 *   settings 前缀路由预留 B-3 审批/邀请子页（settings/requests、settings/invitations）。
 *
 * P3：settings 三子页统一 tab 导航（与 members/permissions tab 模式一致），
 * 审批/邀请 tab 按 manage_members 能力过滤。
 */

import { useState } from "react";
import { Link } from "@/i18n/navigation";
import { useParams } from "next/navigation";
import { useTranslations } from "next-intl";
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
import MembersTabs from "@/components/members-tabs";

const JOIN_POLICIES: JoinPolicy[] = ["open", "request", "invite_only"];

export default function WorkspaceSettingsPage() {
	const params = useParams<{ slug: string }>();
	const slug = params?.slug ?? "";
	const t = useTranslations("workspaceJoinPolicy");
	const tCommon = useTranslations("common");
	const labelsT = useTranslations();
	const {
		ws,
		readOnlyVisitor,
		loading: wsLoading,
	} = useWorkspaceBySlug(slug);
	const canUpdate =
		!readOnlyVisitor && currentUserCanUpdateJoinPolicy(ws);

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
			setSaveState({ wsId: ws.id, kind: "saved", text: t("saved") });
		} catch (error) {
			setSaveState({
				wsId: ws.id,
				kind: "error",
				text: error instanceof Error ? error.message : t("saveFailed"),
			});
		} finally {
			setSaving(false);
		}
	}

	return (
		<WorkspaceShell slug={slug} requireAbility="update_join_policy">
			<div className="ws-page-main__inner">
				<div
					className="ws-page-breadcrumb"
					aria-label={tCommon("breadcrumbAria")}
				>
					<Link href="/">{t("breadcrumbHome")}</Link>
					<span>›</span>
					<Link href={`/w/${slug}`}>{ws?.name ?? slug}</Link>
					<span>›</span>
					<Link href={`/w/${slug}/settings/join-policy`}>
						{t("breadcrumbSettings")}
					</Link>
					<span>›</span>
					<strong>{t("breadcrumbTitle")}</strong>
				</div>

				<header className="ws-page-heading">
					<div>
						<h1>{t("title")}</h1>
						<p>{t("subtitle")}</p>
					</div>
				</header>

				{ws && (
					<MembersTabs
						slug={slug}
						current="policy"
						abilities={ws.myAbilities ?? []}
					/>
				)}

				{wsLoading || !ws ? (
					<div
						className="settings-loading"
						data-testid="settings-loading"
						aria-label={t("loadingAria")}
					>
						<div className="settings-skeleton settings-skeleton--title" />
						<div className="settings-skeleton" />
						<div className="settings-skeleton" />
					</div>
				) : (
					<section className="settings-policy-card" aria-label={t("title")}>
						<div className="settings-policy-card__header">
							<div>
								<strong>{t("title")}</strong>
								<p>{t("subtitle")}</p>
							</div>
							<span
								className={`workspace-policy workspace-policy--${effective}`}
							>
								{effective ? labelsT(JOIN_POLICY_LABEL[effective]) : ""}
							</span>
						</div>

						<fieldset
							className="settings-policy-options"
							disabled={!canUpdate || saving}
						>
							<legend className="settings-policy-options__legend">
								{t("choosePolicy")}
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
										aria-label={labelsT(JOIN_POLICY_LABEL[policy])}
									/>
									<span className="settings-policy-option__label">
										{labelsT(JOIN_POLICY_LABEL[policy])}
									</span>
									<span className="settings-policy-option__hint">
										{labelsT(JOIN_POLICY_HINT[policy])}
									</span>
								</label>
							))}
						</fieldset>

						{!canUpdate && (
							<div
								className="settings-note"
								data-testid="settings-readonly-note"
							>
								{readOnlyVisitor
									? t("readonlyAdmin")
									: t("readonlyOwner")}
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
								{saving ? t("saving") : t("saveChanges")}
							</button>
						</div>
					</section>
				)}
			</div>
		</WorkspaceShell>
	);
}
