"use client";

/**
 * 工作台设置页 /w/[slug]/settings/general（Owner/Admin 自助改工作台名称）。
 *
 * - 写入路径：updateWorkspaceName（updateWorkspace mutation，input.name）；
 *   后端 present(:name) 拒绝空名，前端只做 trim 非空守卫（空/纯空白不发请求）；
 * - 门控：能力字符串 update_join_policy —— 它当前即「工作台元数据写权限」
 *   的载体（#78 放开时的最小面），与加入策略页共用；判定单源为后端
 *   Rbac.abilities_for/2（SETTINGS_NAV 注册表同源，见 workspace-nav.ts）；
 * - 保存成功后刷新 meWorkspaces 缓存：概览页/面包屑/切换器下次挂载显示新名；
 *   本页自身用 wsId 键控的本地 state 即时回显（hook 已解析的 state 不随
 *   refetch 重跑，与加入策略页同款模式）；
 * - slug 不在本页范围：它是公开路由段 /w/[slug]，本页只改展示名，文案明确
 *   「公开链接不受影响」。
 */

import { useState } from "react";
import { Link } from "@/i18n/navigation";
import { useParams } from "next/navigation";
import { useTranslations } from "next-intl";
import { useWorkspaceBySlug } from "@/lib/use-workspace-by-slug";
import {
	currentUserCanUpdateJoinPolicy,
	updateWorkspaceName,
} from "@/lib/workspaces";
import WorkspaceShell from "@/components/workspace-shell";
import MembersTabs from "@/components/members-tabs";

export default function WorkspaceGeneralSettingsPage() {
	const params = useParams<{ slug: string }>();
	const slug = params?.slug ?? "";
	const t = useTranslations("workspaceGeneral");
	const tCommon = useTranslations("common");
	const { ws, readOnlyVisitor, loading: wsLoading } = useWorkspaceBySlug(slug);
	const canUpdate = !readOnlyVisitor && currentUserCanUpdateJoinPolicy(ws);

	// 草稿名称：wsId 键控的派生状态（跨 slug 切换时旧草稿自动失效不串台）
	const [draftState, setDraftState] = useState<{
		wsId: string;
		name: string;
	} | null>(null);
	// 已持久化名称（保存成功后的服务端值）：按钮禁用判定以它为准
	const [savedNameState, setSavedNameState] = useState<{
		wsId: string;
		name: string;
	} | null>(null);
	// 保存结果消息（同样 wsId 键控，跨工作区切换自动隐藏）
	const [saveState, setSaveState] = useState<{
		wsId: string;
		kind: "saved" | "error";
		text: string;
	} | null>(null);
	const [saving, setSaving] = useState(false);

	const draft =
		draftState && draftState.wsId === ws?.id ? draftState.name : null;
	const effective = draft ?? ws?.name ?? "";
	const lastPersisted =
		savedNameState && savedNameState.wsId === ws?.id
			? savedNameState.name
			: (ws?.name ?? "");
	const message =
		saveState && saveState.wsId === ws?.id
			? { kind: saveState.kind, text: saveState.text }
			: null;
	// 提交值一律 trim：空/纯空白既禁用按钮也不发请求
	const trimmed = effective.trim();
	const canSave =
		canUpdate && !saving && trimmed.length > 0 && trimmed !== lastPersisted;

	async function handleSave() {
		if (!ws || !canSave) return;
		setSaving(true);
		setSaveState(null);
		try {
			const updated = await updateWorkspaceName(ws.id, trimmed);
			setDraftState({ wsId: ws.id, name: updated.name });
			setSavedNameState({ wsId: ws.id, name: updated.name });
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
					<Link href={`/w/${slug}/settings/general`}>
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
						current="general"
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
								<strong>{t("nameCardTitle")}</strong>
								<p>{t("nameCardHint", { slug })}</p>
							</div>
						</div>

						<label className="settings-field">
							<span className="settings-field__label">{t("nameLabel")}</span>
							<input
								data-testid="workspace-name-input"
								className="l-input"
								value={effective}
								disabled={!canUpdate || saving}
								onChange={(event) => {
									setDraftState({ wsId: ws.id, name: event.target.value });
									setSaveState(null);
								}}
							/>
						</label>

						{!canUpdate && (
							<div
								className="settings-note"
								data-testid="settings-readonly-note"
							>
								{readOnlyVisitor ? t("readonlyAdmin") : t("readonlyOwner")}
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
								disabled={!canSave}
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
