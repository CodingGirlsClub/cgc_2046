"use client";

/**
 * #69 Profile 查看 / 编辑。
 *
 * 视觉与信息架构按 08-profile-view-light-v3 / 09-profile-edit-dark 落地：
 * - 查看态展示租户内可见的摘要、关于我、技能、作品集预览和角色并集；
 * - 首页只展示前三个作品，完整列表通过“查看全部 N 个作品”入口承载；
 * - 编辑态把基本资料、只读的 Workspace 身份和 Portfolio 编辑区分开；
 * - #68 API 当前只保证 displayName/avatarUrl，其他字段保留为前端可扩展资料模型。
 */

import {
	Suspense,
	useCallback,
	useEffect,
	useMemo,
	useState,
} from "react";
import Link from "next/link";
import { useSearchParams } from "next/navigation";
import { useAuthed } from "@/lib/use-authed";
import WorkspaceShell from "@/components/workspace-shell";
import { Icon, type IconName } from "@/components/icons";
import {
	createPortfolioItem,
	deletePortfolioItem,
	fetchCurrentProfile,
	fetchPortfolioItems,
	fetchProfileRoleSummary,
	profileHref,
	updateCurrentProfile,
	updatePortfolioItem,
	getProfileContent,
	toDraft,
	type CurrentProfile,
	type PortfolioIcon,
	type ProfileContent,
	type ProfileDraft,
	type ProfilePortfolioItem,
	type ProfileRoleSummary,
	VISIBILITY_LABEL,
	VISIBILITY_OPTION_LABEL,
	VISIBILITY_FOOTER_TEXT,
} from "@/lib/profile";
import { type MembershipRoleName } from "@/lib/graphql/workspace";
import type { ProfileVisibility } from "@/lib/graphql/profile";
import { RoleChips } from "./_sections/profile-role";
import { Avatar } from "./_sections/profile-avatar";
import { PortfolioPreview } from "./_sections/portfolio-preview";

function Breadcrumb({
	editing,
	workspaceSlug,
	workspaceName,
}: {
	editing: boolean;
	workspaceSlug: string;
	workspaceName: string;
}) {
	return (
		<div className="profile-breadcrumb" aria-label="页面路径">
			<Link href="/">工作台</Link>
			{workspaceSlug ? (
				<>
					<span>›</span>
					<Link href={`/w/${workspaceSlug}`}>
						{workspaceName || workspaceSlug}
					</Link>
				</>
			) : null}
			<span>›</span>
			<Link href={profileHref(workspaceSlug)}>个人资料</Link>
			{editing ? (
				<>
					<span>›</span>
					<strong>编辑个人资料</strong>
				</>
			) : null}
		</div>
	);
}

function ProfileSummary({ content }: { content: ProfileContent }) {
	return (
		<section className="profile-summary" data-testid="profile-summary">
			<Avatar content={content} />
			<div className="profile-summary__identity">
				<h2 data-testid="profile-display-name">{content.name}</h2>
				<RoleChips roles={content.workspaceRoles} />
				<div className="profile-summary__meta">
					<span>
						<Icon name="pin" size={20} />
						{content.location}
					</span>
					<i />
					<span>
						<Icon name="calendar" size={20} />
						加入于 {content.joinedAt}
					</span>
					<i />
					<span className="profile-visibility-pill">
						<Icon name="visibility" size={18} />
						{VISIBILITY_LABEL[content.visibility]}
					</span>
				</div>
			</div>
		</section>
	);
}

function ViewContent({ content }: { content: ProfileContent }) {
	return (
		<div className="profile-view-grid">
			<div className="profile-view-main">
				<section
					className="profile-card profile-about-card"
					data-testid="about-card"
				>
					<h2>关于我</h2>
					<p>{content.about}</p>
				</section>
				<Suspense fallback={null}>
					<PortfolioPreview portfolio={content.portfolio} />
				</Suspense>
			</div>
			<div className="profile-view-aside">
				<section
					className="profile-card profile-skills-card"
					data-testid="skills-card"
				>
					<h2>技能标签</h2>
					<div className="profile-skill-list">
						{content.skills.map((skill) => (
							<span key={skill}>{skill}</span>
						))}
					</div>
				</section>
				<section
					className="profile-card profile-identity-card"
					data-testid="identity-card"
				>
					<h2>工作区身份</h2>
					<span className="profile-card__eyebrow">角色并集</span>
					<RoleChips roles={content.workspaceRoles} />
					<p>权限按所有角色并集合并</p>
					<div className="profile-identity-divider" />
					<div className="profile-member-number">
						<span>成员编号</span>
						<strong>{content.memberNumber}</strong>
					</div>
				</section>
			</div>
		</div>
	);
}

function EditPortfolioRow({
	item,
	onChange,
	onRemove,
}: {
	item: ProfilePortfolioItem;
	onChange: (next: ProfilePortfolioItem) => void;
	onRemove: () => void;
}) {
	return (
		<div
			className="profile-edit-portfolio-row"
			data-testid="portfolio-edit-row"
		>
			<span className="profile-drag-handle" aria-hidden="true">
				<Icon name="grip" size={19} />
			</span>
			<label>
				<span>作品标题</span>
				<input
					value={item.title}
					onChange={(event) => onChange({ ...item, title: event.target.value })}
				/>
			</label>
			<label>
				<span>作品简介</span>
				<input
					value={item.description}
					onChange={(event) =>
						onChange({ ...item, description: event.target.value })
					}
				/>
			</label>
			<label>
				<span>作品链接</span>
				<input
					value={item.url ?? ""}
					onChange={(event) => onChange({ ...item, url: event.target.value })}
				/>
			</label>
			<label>
				<span>图标类型</span>
				<select
					value={item.icon ?? "document"}
					aria-label="作品图标类型"
					onChange={(event) =>
						onChange({ ...item, icon: event.target.value as PortfolioIcon })
					}
				>
					<option value="document">文档</option>
					<option value="book">书籍</option>
					<option value="guide">指南</option>
				</select>
			</label>
			<button
				type="button"
				className="profile-remove-portfolio"
				aria-label={`删除作品：${item.title || "未命名作品"}`}
				onClick={onRemove}
			>
				<Icon name="trash" size={19} />
			</button>
		</div>
	);
}

function EditContent({
	draft,
	roles,
	memberNumber,
	onDraftChange,
}: {
	draft: ProfileDraft;
	roles: MembershipRoleName[];
	memberNumber: string;
	onDraftChange: (next: ProfileDraft) => void;
}) {
	const [showAllPortfolio, setShowAllPortfolio] = useState(false);
	const visiblePortfolio = showAllPortfolio
		? draft.portfolio
		: draft.portfolio.slice(0, 2);

	function addSkill() {
		const skill = window.prompt("添加技能标签");
		if (!skill?.trim() || draft.skills.includes(skill.trim())) return;
		onDraftChange({ ...draft, skills: [...draft.skills, skill.trim()] });
	}

	return (
		<div className="profile-edit-layout">
			<section
				className="profile-edit-basic profile-card"
				data-testid="edit-basic-card"
			>
				<h2>基本资料</h2>
				<div className="profile-edit-avatar-block">
					<span className="profile-form-label">头像</span>
					<div className="profile-edit-avatar-row">
						<Avatar
							content={{ name: draft.name || "?", avatarUrl: draft.avatarUrl }}
							editable
							onFile={(avatarUrl) => onDraftChange({ ...draft, avatarUrl })}
						/>
						<p>支持 PNG、JPG、WebP、GIF，文件大小不超过 2.2MB。</p>
					</div>
				</div>
				<div className="profile-edit-form-grid">
					<label>
						<span className="profile-form-label">姓名</span>
						<input
							data-testid="profile-name-input"
							value={draft.name}
							onChange={(event) =>
								onDraftChange({ ...draft, name: event.target.value })
							}
						/>
					</label>
					<label>
						<span className="profile-form-label">所在地</span>
						<input
							data-testid="profile-location-input"
							value={draft.location}
							onChange={(event) =>
								onDraftChange({ ...draft, location: event.target.value })
							}
						/>
					</label>
				</div>
				<label className="profile-edit-about">
					<span className="profile-form-label">个人简介</span>
					<textarea
						data-testid="profile-about-input"
						maxLength={240}
						value={draft.about}
						onChange={(event) =>
							onDraftChange({ ...draft, about: event.target.value })
						}
					/>
					<span className="profile-char-count">{draft.about.length} / 240</span>
				</label>
				<div className="profile-edit-skills">
					<span className="profile-form-label">技能标签</span>
					<div className="profile-edit-skill-box">
						{draft.skills.map((skill) => (
							<span key={skill}>
								{skill}
								<button
									type="button"
									aria-label={`删除标签 ${skill}`}
									onClick={() =>
										onDraftChange({
											...draft,
											skills: draft.skills.filter((item) => item !== skill),
										})
									}
								>
									×
								</button>
							</span>
						))}
						<button
							type="button"
							className="profile-add-skill"
							onClick={addSkill}
						>
							<Icon name="plus" size={16} />
							添加标签
						</button>
					</div>
				</div>
			</section>

			<aside className="profile-edit-side">
				<section
					className="profile-card profile-edit-readonly"
					data-testid="edit-visibility-card"
				>
					<h2>可见范围</h2>
					<label className="profile-visibility-options">
						<span className="profile-form-label">资料可见范围</span>
						<select
							data-testid="profile-visibility-input"
							value={draft.visibility}
							onChange={(event) =>
								onDraftChange({
									...draft,
									visibility: event.target.value as ProfileVisibility,
								})
							}
						>
							{(
								Object.keys(VISIBILITY_OPTION_LABEL) as ProfileVisibility[]
							).map((value) => (
								<option key={value} value={value}>
									{VISIBILITY_OPTION_LABEL[value]}
								</option>
							))}
						</select>
					</label>
					<div className="profile-edit-divider" />
					<h2>工作区身份</h2>
					<p>角色由 Owner / Admin 管理，此处不可编辑</p>
					<RoleChips roles={roles} />
					<label>
						<span className="profile-form-label">成员编号</span>
						<input value={memberNumber} readOnly />
					</label>
				</section>
			</aside>

			<section
				className="profile-card profile-edit-portfolio"
				data-testid="edit-portfolio-card"
			>
				<h2>作品集</h2>
				<div className="profile-edit-portfolio-list">
					{visiblePortfolio.map((item) => (
						<EditPortfolioRow
							key={item.id}
							item={item}
							onChange={(next) =>
								onDraftChange({
									...draft,
									portfolio: draft.portfolio.map((entry) =>
										entry.id === item.id ? next : entry,
									),
								})
							}
							onRemove={() =>
								onDraftChange({
									...draft,
									portfolio: draft.portfolio.filter(
										(entry) => entry.id !== item.id,
									),
								})
							}
						/>
					))}
				</div>
				{!showAllPortfolio && draft.portfolio.length > 2 && (
					<button
						type="button"
						className="profile-expand-portfolio"
						onClick={() => setShowAllPortfolio(true)}
					>
						展开其余 {draft.portfolio.length - 2} 个作品
					</button>
				)}
				<button
					type="button"
					className="profile-add-portfolio"
					onClick={() =>
						onDraftChange({
							...draft,
							portfolio: [
								...draft.portfolio,
								{
									id: `portfolio-${Date.now()}`,
									title: "",
									description: "",
									url: "",
									icon: "document",
								},
							],
						})
					}
				>
					<Icon name="plus" size={18} />
					添加作品
				</button>
			</section>
		</div>
	);
}

function ProfilePageInner() {
	// 数据 effect 的认证守卫（壳管渲染/重定向；页面管「未认证不拉数据」）
	const { authed, confirmed } = useAuthed();
	const [profile, setProfile] = useState<CurrentProfile | null>(null);
	const [summaries, setSummaries] = useState<ProfileRoleSummary[]>([]);
	const [loading, setLoading] = useState(true);
	const [editing, setEditing] = useState(false);
	const [draft, setDraft] = useState<ProfileDraft | null>(null);
	const [saving, setSaving] = useState(false);
	const [errorMsg, setErrorMsg] = useState<string | null>(null);
	const [savedMsg, setSavedMsg] = useState<string | null>(null);

	useEffect(() => {
		if (!confirmed || !authed) return;
		let cancelled = false;
		Promise.all([
			fetchCurrentProfile(),
			fetchProfileRoleSummary(),
			fetchPortfolioItems(),
		])
			.then(([nextProfile, nextSummaries, portfolio]) => {
				if (cancelled) return;
				const withPortfolio = { ...nextProfile, portfolio };
				setProfile(withPortfolio);
				setSummaries(nextSummaries);
				// P2-2：不再在加载时预填 draft，进入编辑态时再从真实值初始化（startEdit）
				setDraft(null);
				setErrorMsg(null);
			})
			.catch((error: unknown) => {
				if (!cancelled)
					setErrorMsg(error instanceof Error ? error.message : "加载资料失败");
			})
			.finally(() => {
				if (!cancelled) setLoading(false);
			});
		return () => {
			cancelled = true;
		};
	}, [authed, confirmed]);

	const wsSlug = useSearchParams().get("ws");
	const content = useMemo(
		() => (profile ? getProfileContent(profile, summaries, wsSlug) : null),
		[profile, summaries, wsSlug],
	);
	const workspaceSlug = content?.workspaceSlug || "";

	const startEdit = useCallback(() => {
		if (!content) return;
		setDraft(toDraft(content));
		setEditing(true);
		setSavedMsg(null);
		setErrorMsg(null);
	}, [content]);

	const cancelEdit = useCallback(() => {
		if (content) setDraft(toDraft(content));
		setEditing(false);
		setErrorMsg(null);
	}, [content]);

	async function handleSave() {
		if (!profile || !draft) return;
		const name = draft.name.trim();
		if (!name) {
			setErrorMsg("姓名不能为空");
			return;
		}
		setSaving(true);
		setErrorMsg(null);
		try {
			// P1：真实分支提交全部可编辑字段（displayName/avatarUrl/location/about/skills/visibility），
			// 修复 G8 假保存——扩展字段不再只留在前端状态伪造。
			const updated = await updateCurrentProfile({
				displayName: name,
				avatarUrl: draft.avatarUrl,
				location: draft.location,
				about: draft.about,
				skills: draft.skills,
				visibility: draft.visibility,
			});
			// P1：同步作品集 CRUD（新增/删除/变更 diff 提交后端，真实模式）
			await syncPortfolioChanges(profile, draft.portfolio);
			// 保存成功后重新拉取作品集，确保 id 与后端一致（新增条目由后端生成 uuid）
			const refreshedPortfolio = await fetchPortfolioItems();
			setProfile({
				...profile,
				...updated,
				displayName: name,
				avatarUrl: draft.avatarUrl,
				location: draft.location,
				about: draft.about,
				skills: draft.skills,
				visibility: draft.visibility,
				portfolio: refreshedPortfolio,
			});
			setEditing(false);
			setSavedMsg("资料已保存");
		} catch (error: unknown) {
			setErrorMsg(error instanceof Error ? error.message : "保存失败");
		} finally {
			setSaving(false);
		}
	}

	/** 作品集 diff 同步：新增条目 create、被移除条目 delete、内容变化条目 update（P1 CRUD 接线） */
	async function syncPortfolioChanges(
		prev: CurrentProfile,
		next: ProfilePortfolioItem[],
	) {
		const original = new Map(
			(prev.portfolio ?? []).map((item) => [item.id, item]),
		);
		const nextIds = new Set(next.map((item) => item.id));
		for (const item of next) {
			const orig = original.get(item.id);
			if (!orig) {
				await createPortfolioItem({
					title: item.title,
					description: item.description,
					url: item.url ?? null,
					icon: item.icon ?? "document",
				});
			} else if (
				orig.title !== item.title ||
				(orig.description ?? "") !== (item.description ?? "") ||
				(orig.url ?? null) !== (item.url ?? null) ||
				(orig.icon ?? "document") !== (item.icon ?? "document")
			) {
				await updatePortfolioItem(item.id, {
					title: item.title,
					description: item.description,
					url: item.url ?? null,
					icon: item.icon ?? "document",
				});
			}
		}
		for (const item of prev.portfolio ?? []) {
			if (!nextIds.has(item.id)) {
				await deletePortfolioItem(item.id);
			}
		}
	}

	if (loading) {
		return (
			<WorkspaceShell slug={workspaceSlug} requireWs={false}>
				<div className="profile-main__inner">
					<div className="profile-skeleton" />
				</div>
			</WorkspaceShell>
		);
	}

	if (!profile || !content) {
		return (
			<main className="profile-loading">
				<strong>无法加载个人资料</strong>
				<span>{errorMsg || "请稍后重试。"}</span>
			</main>
		);
	}

	const currentDraft = draft ?? toDraft(content);
	// P2-1：底部可见范围文案随当前可见范围联动（编辑态实时预览 draft，查看态用真实值）
	const footerVisibility = editing
		? currentDraft.visibility
		: content.visibility;

	return (
		<WorkspaceShell
			slug={workspaceSlug}
			requireWs={false}
			workspaceName={content.workspaceName || undefined}
			className={editing ? "ws-shell-page--editing" : undefined}
		>
			<div className="profile-main__inner">
				<Breadcrumb
					editing={editing}
					workspaceSlug={workspaceSlug}
					workspaceName={content.workspaceName || ""}
				/>
				<header className="profile-heading">
					<h1>{editing ? "编辑个人资料" : "我的个人资料"}</h1>
					{editing ? (
						<div className="profile-heading__actions">
							<button
								type="button"
								className="profile-button profile-button--quiet"
								onClick={cancelEdit}
								disabled={saving}
							>
								取消
							</button>
							<button
								type="button"
								className="profile-button profile-button--primary"
								onClick={handleSave}
								disabled={saving}
							>
								{saving ? "保存中…" : "保存更改"}
							</button>
						</div>
					) : (
						<button
							type="button"
							className="profile-button profile-button--outline"
							onClick={startEdit}
						>
							<Icon name="edit" size={18} />
							编辑资料
						</button>
					)}
				</header>

				{savedMsg && (
					<div className="profile-toast" role="status">
						<Icon name="check" size={16} />
						{savedMsg}
					</div>
				)}
				{errorMsg && (
					<div className="profile-error" role="alert">
						{errorMsg}
					</div>
				)}

				{editing ? (
					<EditContent
						draft={currentDraft}
						roles={content.workspaceRoles}
						memberNumber={content.memberNumber}
						onDraftChange={setDraft}
					/>
				) : (
					<>
						<ProfileSummary content={content} />
						<ViewContent content={content} />
					</>
				)}

				<footer className="profile-footer">
					<span>{VISIBILITY_FOOTER_TEXT[footerVisibility]}</span>
				</footer>
			</div>
		</WorkspaceShell>
	);
}

export default function ProfilePage() {
	return (
		<Suspense fallback={<main className="profile-loading">正在加载资料…</main>}>
			<ProfilePageInner />
		</Suspense>
	);
}
