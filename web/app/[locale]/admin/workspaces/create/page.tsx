"use client";

/**
 * /admin/workspaces/create 创建工作台（Phase 8 / R3/R4/R5）。
 * - 元数据：名称 / slug / 加入策略
 * - Owner 指定：选择已有用户（搜索 email/display_name）或邀请新用户（ownerEmail，
 *   pending-owner 邀请，返回 ownerInvitationToken 仅展示一次）
 */
import { useState } from "react";
import Link from "next/link";
import { useTranslations } from "next-intl";
import { createWorkspaceWithOwner, fetchUsers } from "@/lib/admin";
import type { AdminUser } from "@/lib/graphql/admin";
import { JOIN_POLICY_LABEL, type JoinPolicy } from "@/lib/graphql/workspace";

type OwnerMode = "existing" | "invite";

export default function AdminWorkspacesCreatePage() {
	const t = useTranslations("admin");
	const [name, setName] = useState("");
	const [slug, setSlug] = useState("");
	const [joinPolicy, setJoinPolicy] = useState<JoinPolicy>("request");
	const [ownerMode, setOwnerMode] = useState<OwnerMode>("existing");
	const [userSearch, setUserSearch] = useState("");
	const [userResults, setUserResults] = useState<AdminUser[] | null>(null);
	const [selectedUser, setSelectedUser] = useState<AdminUser | null>(null);
	const [ownerEmail, setOwnerEmail] = useState("");
	const [searching, setSearching] = useState(false);
	const [submitting, setSubmitting] = useState(false);
	const [error, setError] = useState<string | null>(null);
	const [inviteToken, setInviteToken] = useState<string | null>(null);
	const [createdSlug, setCreatedSlug] = useState<string | null>(null);

	const handleSearchUser = async () => {
		setSearching(true);
		try {
			const users = await fetchUsers(userSearch, { first: 10 });
			setUserResults(users);
		} catch {
			setUserResults([]);
		} finally {
			setSearching(false);
		}
	};

	const handleSubmit = async () => {
		setSubmitting(true);
		setError(null);
		try {
			const result = await createWorkspaceWithOwner({
				slug,
				name,
				joinPolicy,
				...(ownerMode === "existing" && selectedUser
					? { ownerUserId: selectedUser.id }
					: {}),
				...(ownerMode === "invite" && ownerEmail ? { ownerEmail } : {}),
			});
			if (result.errors.length > 0) {
				setError(result.errors.map((e) => e.message).join("；"));
			} else if (result.result) {
				setCreatedSlug(result.result.slug);
				setInviteToken(result.metadata?.ownerInvitationToken ?? null);
			} else {
				setError(t("createFailed"));
			}
		} catch {
			setError(t("networkError"));
		} finally {
			setSubmitting(false);
		}
	};

	if (createdSlug) {
		return (
			<section>
				<div className="admin-page__head">
					<h1>{t("createdTitle")}</h1>
				</div>
				<p className="admin-muted">
					{t.rich("createdDesc", {
						slug: createdSlug,
						strong: (chunks) => <strong>{chunks}</strong>,
					})}
				</p>
				{inviteToken && (
					<div className="admin-alert admin-alert--warn admin-result-back">
						<div>
							<p>{t("ownerInviteNote")}</p>
							<code className="l-codeblock">{inviteToken}</code>
						</div>
					</div>
				)}
				<p className="admin-result-back">
					<Link href="/admin/workspaces" className="admin-link">
						{t("backToList")}
					</Link>
				</p>
			</section>
		);
	}

	return (
		<section>
			<div className="admin-page__head">
				<h1>{t("createTitle")}</h1>
			</div>

			<div className="admin-form">
				<div className="admin-field">
					<label htmlFor="ws-name" className="admin-field__label">
						{t("fieldName")}
					</label>
					<input
						id="ws-name"
						value={name}
						onChange={(e) => setName(e.target.value)}
						className="l-input"
					/>
				</div>

				<div className="admin-field">
					<label htmlFor="ws-slug" className="admin-field__label">
						slug
					</label>
					<input
						id="ws-slug"
						value={slug}
						onChange={(e) => setSlug(e.target.value)}
						placeholder={t("fieldSlugPlaceholder")}
						className="l-input"
					/>
				</div>

				<div className="admin-field">
					<label htmlFor="ws-join-policy" className="admin-field__label">
						{t("fieldJoinPolicy")}
					</label>
					<select
						id="ws-join-policy"
						value={joinPolicy}
						onChange={(e) => setJoinPolicy(e.target.value as JoinPolicy)}
						className="l-input"
					>
						{(Object.keys(JOIN_POLICY_LABEL) as JoinPolicy[]).map((p) => (
							<option key={p} value={p}>
								{JOIN_POLICY_LABEL[p]}
							</option>
						))}
					</select>
				</div>

				<fieldset className="admin-field">
					<legend className="admin-field__label">{t("ownerAssign")}</legend>
					<div className="admin-radio-row">
						<label className="admin-radio">
							<input
								type="radio"
								name="owner-mode"
								checked={ownerMode === "existing"}
								onChange={() => setOwnerMode("existing")}
							/>
							{t("chooseExisting")}
						</label>
						<label className="admin-radio">
							<input
								type="radio"
								name="owner-mode"
								checked={ownerMode === "invite"}
								onChange={() => setOwnerMode("invite")}
							/>
							{t("inviteNew")}
						</label>
					</div>

					{ownerMode === "existing" ? (
						<div>
							{!selectedUser && (
								<div className="admin-toolbar">
									<input
										value={userSearch}
										onChange={(e) => setUserSearch(e.target.value)}
										placeholder={t("searchUserPlaceholder")}
										className="l-input"
									/>
									<button
										type="button"
										onClick={handleSearchUser}
										className="l-btn-outline"
									>
										{t("search")}
									</button>
								</div>
							)}
							{searching && <p className="admin-muted">{t("searching")}</p>}
							{userResults && userResults.length === 0 && (
								<p className="admin-muted">{t("noUserMatch")}</p>
							)}
							{userResults && userResults.length > 0 && (
								<ul className="admin-pick-list">
									{userResults.map((u) => (
										<li key={u.id}>
											<button
												type="button"
												onClick={() => {
													setSelectedUser(u);
													setUserResults(null);
												}}
												className="admin-pick-list__item"
											>
												{u.displayName || u.email}（{u.email}）
											</button>
										</li>
									))}
								</ul>
							)}
							{selectedUser && (
								<p className="admin-muted">
									{t("selectedOwner", {
										user: selectedUser.displayName || selectedUser.email || "",
									})}
									{" · "}
									<button
										type="button"
										onClick={() => setSelectedUser(null)}
										className="admin-link"
									>
										{t("change")}
									</button>
								</p>
							)}
						</div>
					) : (
						<div className="admin-field">
							<label htmlFor="ws-owner-email" className="admin-field__label">
								{t("inviteEmail")}
							</label>
							<input
								id="ws-owner-email"
								type="email"
								value={ownerEmail}
								onChange={(e) => setOwnerEmail(e.target.value)}
								placeholder="newowner@example.com"
								className="l-input"
							/>
						</div>
					)}
				</fieldset>

				{error && <p className="admin-alert admin-alert--error">{error}</p>}

				<div>
					<button
						type="button"
						onClick={handleSubmit}
						disabled={submitting || !name || !slug}
						className="l-btn-primary"
					>
						{t("createTitle")}
					</button>
				</div>
			</div>
		</section>
	);
}
