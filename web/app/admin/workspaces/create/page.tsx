"use client";

/**
 * /admin/workspaces/create 创建工作台（Phase 8 / R3/R4/R5）。
 * - 元数据：名称 / slug / 加入策略
 * - Owner 指定：选择已有用户（搜索 email/display_name）或邀请新用户（ownerEmail，
 *   pending-owner 邀请，返回 ownerInvitationToken 仅展示一次）
 */
import { useState } from "react";
import Link from "next/link";
import { createWorkspaceWithOwner, fetchUsers } from "@/lib/admin";
import type { AdminUser } from "@/lib/graphql/admin";
import { JOIN_POLICY_LABEL, type JoinPolicy } from "@/lib/graphql/workspace";

type OwnerMode = "existing" | "invite";

export default function AdminWorkspacesCreatePage() {
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
				setError("创建工作台失败");
			}
		} catch {
			setError("网络错误，请稍后重试");
		} finally {
			setSubmitting(false);
		}
	};

	if (createdSlug) {
		return (
			<section>
				<h1 className="text-2xl font-semibold mb-2">工作台已创建</h1>
				<p className="text-neutral-600 mb-2">
					工作台 <span className="font-medium">{createdSlug}</span> 创建成功。
				</p>
				{inviteToken && (
					<div className="mb-4 p-3 rounded-md bg-amber-50 border border-amber-200 text-sm">
						<p className="font-medium mb-1">Owner 邀请已生成（仅显示一次）</p>
						<code className="text-xs break-all">{inviteToken}</code>
					</div>
				)}
				<Link href="/admin/workspaces" className="text-sm text-blue-600 hover:underline">
					返回工作台列表
				</Link>
			</section>
		);
	}

	return (
		<section className="max-w-xl">
			<h1 className="text-2xl font-semibold mb-4">创建工作台</h1>

			<div className="space-y-4">
				<div>
					<label htmlFor="ws-name" className="block text-sm font-medium mb-1">
						名称
					</label>
					<input
						id="ws-name"
						value={name}
						onChange={(e) => setName(e.target.value)}
						className="w-full px-3 py-1.5 rounded-md border border-neutral-300 text-sm"
					/>
				</div>

				<div>
					<label htmlFor="ws-slug" className="block text-sm font-medium mb-1">
						slug
					</label>
					<input
						id="ws-slug"
						value={slug}
						onChange={(e) => setSlug(e.target.value)}
						placeholder="小写字母/数字/连字符"
						className="w-full px-3 py-1.5 rounded-md border border-neutral-300 text-sm"
					/>
				</div>

				<div>
					<label htmlFor="ws-join-policy" className="block text-sm font-medium mb-1">
						加入策略
					</label>
					<select
						id="ws-join-policy"
						value={joinPolicy}
						onChange={(e) => setJoinPolicy(e.target.value as JoinPolicy)}
						className="w-full px-3 py-1.5 rounded-md border border-neutral-300 text-sm"
					>
						{(Object.keys(JOIN_POLICY_LABEL) as JoinPolicy[]).map((p) => (
							<option key={p} value={p}>
								{JOIN_POLICY_LABEL[p]}
							</option>
						))}
					</select>
				</div>

				<fieldset>
					<legend className="text-sm font-medium mb-1">Owner 指定</legend>
					<div className="flex gap-4 mb-2">
						<label className="flex items-center gap-1 text-sm">
							<input
								type="radio"
								name="owner-mode"
								checked={ownerMode === "existing"}
								onChange={() => setOwnerMode("existing")}
							/>
							选择已有用户
						</label>
						<label className="flex items-center gap-1 text-sm">
							<input
								type="radio"
								name="owner-mode"
								checked={ownerMode === "invite"}
								onChange={() => setOwnerMode("invite")}
							/>
							邀请新用户
						</label>
					</div>

					{ownerMode === "existing" ? (
						<div>
							{!selectedUser && (
								<div className="flex gap-2">
									<input
										value={userSearch}
										onChange={(e) => setUserSearch(e.target.value)}
										placeholder="搜索用户（email / 显示名）"
										className="flex-1 px-3 py-1.5 rounded-md border border-neutral-300 text-sm"
									/>
									<button
										type="button"
										onClick={handleSearchUser}
										className="px-3 py-1.5 rounded-md border border-neutral-300 text-sm"
									>
										搜索
									</button>
								</div>
							)}
							{searching && <p className="text-sm text-neutral-500 mt-2">搜索中…</p>}
							{userResults && userResults.length === 0 && (
								<p className="text-sm text-neutral-500 mt-2">未找到匹配用户。</p>
							)}
							{userResults && userResults.length > 0 && (
								<ul className="mt-2 border border-neutral-200 rounded-md divide-y divide-neutral-100">
									{userResults.map((u) => (
										<li key={u.id}>
											<button
												type="button"
												onClick={() => {
													setSelectedUser(u);
													setUserResults(null);
												}}
												className="w-full text-left px-3 py-2 text-sm hover:bg-neutral-50"
											>
												{u.displayName || u.email}（{u.email}）
											</button>
										</li>
									))}
								</ul>
							)}
							{selectedUser && (
								<p className="text-sm mt-2">
									已选 Owner：{selectedUser.displayName || selectedUser.email}
									<button
										type="button"
										onClick={() => setSelectedUser(null)}
										className="ml-2 text-blue-600 hover:underline"
									>
										更换
									</button>
								</p>
							)}
						</div>
					) : (
						<div>
							<label htmlFor="ws-owner-email" className="block text-sm mb-1">
								邀请邮箱
							</label>
							<input
								id="ws-owner-email"
								type="email"
								value={ownerEmail}
								onChange={(e) => setOwnerEmail(e.target.value)}
								placeholder="newowner@example.com"
								className="w-full px-3 py-1.5 rounded-md border border-neutral-300 text-sm"
							/>
						</div>
					)}
				</fieldset>

				{error && <p className="text-sm text-red-600">{error}</p>}

				<button
					type="button"
					onClick={handleSubmit}
					disabled={submitting || !name || !slug}
					className="px-4 py-2 rounded-md bg-neutral-900 text-white text-sm hover:bg-neutral-700 disabled:opacity-50"
				>
					创建工作台
				</button>
			</div>
		</section>
	);
}
