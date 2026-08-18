"use client";

/**
 * /admin/users 用户列表（Phase 9 / R8 + R9）。
 * 分页 + 搜索（email/display_name）+ is_platform_admin 徽章 + membership 概要。
 * promote/demote：demote 自己需确认弹窗；最后一个 admin 由后端原子拒绝（显示错误）。
 */
import { useCallback, useEffect, useState } from "react";
import { useTranslations } from "next-intl";
import { demoteUser, fetchUsers, promoteUser } from "@/lib/admin";
import type { AdminUser } from "@/lib/graphql/admin";
import { useAuthed } from "@/lib/use-authed";

const PAGE_SIZE = 50;

export default function AdminUsersPage() {
	const { userId } = useAuthed();
	const t = useTranslations("admin");
	const [users, setUsers] = useState<AdminUser[] | null>(null);
	const [search, setSearch] = useState("");
	const [offset, setOffset] = useState(0);
	const [loading, setLoading] = useState(false);
	const [error, setError] = useState(false);
	const [busyId, setBusyId] = useState<string | null>(null);
	const [actionError, setActionError] = useState<string | null>(null);
	/** 自降级确认弹窗的目标用户（null = 无弹窗） */
	const [confirmDemote, setConfirmDemote] = useState<AdminUser | null>(null);

	const load = useCallback((term: string, after: number) => {
		// .then/.catch 链（join 页模式）：effect 内调用不触发
		// react-hooks/set-state-in-effect（setState 全在 promise 回调）
		return fetchUsers(term, { first: PAGE_SIZE, after: String(after) })
			.then((list) => {
				setUsers(list);
				setError(false);
			})
			.catch(() => {
				setError(true);
				setUsers([]);
			})
			.finally(() => {
				setLoading(false);
			});
	}, []);

	useEffect(() => {
		void load("", 0);
	}, [load]);

	const handleSearch = () => {
		setOffset(0);
		setLoading(true);
		void load(search, 0);
	};

	const handleNext = () => {
		const next = offset + (users?.length ?? 0);
		setOffset(next);
		setLoading(true);
		void load(search, next);
	};

	const handlePrev = () => {
		const prev = Math.max(offset - PAGE_SIZE, 0);
		setOffset(prev);
		setLoading(true);
		void load(search, prev);
	};

	const runAction = async (id: string, action: typeof promoteUser) => {
		setBusyId(id);
		setActionError(null);
		try {
			const payload = await action(id);
			if (payload?.errors?.length) {
				setActionError(payload.errors[0].message ?? t("operationFailed"));
			} else {
				// 成功后重新拉取，刷新 is_platform_admin 状态
				await load(search, offset);
			}
		} catch {
			setActionError(t("operationFailedRetry"));
		} finally {
			setBusyId(null);
		}
	};

	const handlePromote = (user: AdminUser) => {
		void runAction(user.id, promoteUser);
	};

	const handleDemoteClick = (user: AdminUser) => {
		// 自降级需确认弹窗（R9）；降级他人直接执行
		if (user.id === userId) {
			setConfirmDemote(user);
		} else {
			void runAction(user.id, demoteUser);
		}
	};

	const handleConfirmDemote = () => {
		if (confirmDemote) {
			void runAction(confirmDemote.id, demoteUser);
		}
		setConfirmDemote(null);
	};

	return (
		<section>
			<div className="admin-page__head">
				<h1>{t("usersTitle")}</h1>
			</div>

			<div className="admin-toolbar">
				<input
					value={search}
					onChange={(e) => setSearch(e.target.value)}
					onKeyDown={(e) => e.key === "Enter" && handleSearch()}
					placeholder={t("searchUserPlaceholder")}
					aria-label={t("searchUserAria")}
					className="l-input"
				/>
				<button
					type="button"
					onClick={handleSearch}
					className="l-btn-outline"
				>
					{t("search")}
				</button>
			</div>

			{error && <p className="admin-alert admin-alert--error">{t("loadFailed")}</p>}
			{actionError && <p className="admin-alert admin-alert--error">{actionError}</p>}
			{loading && <p className="admin-muted">{t("loading")}</p>}

			{!loading && !error && users && users.length === 0 && (
				<p className="admin-empty">{t("noUsers")}</p>
			)}

			{!loading && !error && users && users.length > 0 && (
				<div className="admin-card admin-table-wrap">
					<table className="admin-table">
						<thead>
							<tr>
								<th>{t("thUser")}</th>
								<th>{t("thPlatformAdmin")}</th>
								<th className="admin-table__num">{t("thMembershipSummary")}</th>
								<th>{t("thJoinedAt")}</th>
								<th className="admin-table__actions">{t("thActions")}</th>
							</tr>
						</thead>
						<tbody>
							{users.map((user) => (
								<tr key={user.id}>
									<td>
										<span className="admin-table__primary">
											{user.displayName || user.email || t("unnamed")}
										</span>
										{user.email && user.displayName && (
											<span className="admin-table__sub">{user.email}</span>
										)}
									</td>
									<td>
										{user.isPlatformAdmin ? (
											<span className="l-badge l-badge-admin">{t("adminBadge")}</span>
										) : (
											<span className="l-badge l-badge-muted">{t("regularBadge")}</span>
										)}
									</td>
									<td className="admin-table__num">
										{t("memberCountValue", { count: user.workspaceMembershipCount ?? 0 })}
									</td>
									<td>
										{new Date(user.insertedAt).toLocaleDateString("zh-CN")}
									</td>
									<td className="admin-table__actions">
										{user.isPlatformAdmin ? (
											<button
												type="button"
												onClick={() => handleDemoteClick(user)}
												disabled={busyId === user.id}
												className="l-btn-outline l-btn-outline--danger"
											>
												{t("demote")}
											</button>
										) : (
											<button
												type="button"
												onClick={() => handlePromote(user)}
												disabled={busyId === user.id}
												className="l-btn-outline"
											>
												{t("promote")}
											</button>
										)}
									</td>
								</tr>
							))}
						</tbody>
					</table>
				</div>
			)}

			<div className="admin-pager">
				<button
					type="button"
					onClick={handlePrev}
					disabled={offset === 0 || loading}
					className="l-btn-outline"
				>
					{t("prevPage")}
				</button>
				<button
					type="button"
					onClick={handleNext}
					disabled={loading}
					className="l-btn-outline"
				>
					{t("nextPage")}
				</button>
			</div>

			{confirmDemote && (
				<div
					role="dialog"
					aria-label={t("demoteDialogAria")}
					className="admin-modal-overlay"
				>
					<div className="admin-modal">
						<h2>{t("demoteTitle")}</h2>
						<p>
							{t("demoteSelfDesc", {
								user: confirmDemote.email || confirmDemote.displayName || t("currentUser"),
							})}
						</p>
						<div className="admin-modal__actions">
							<button
								type="button"
								onClick={() => setConfirmDemote(null)}
								className="l-btn-outline"
							>
								{t("cancel")}
							</button>
							<button
								type="button"
								onClick={handleConfirmDemote}
								className="l-btn-danger"
							>
								{t("confirm")}
							</button>
						</div>
					</div>
				</div>
			)}
		</section>
	);
}
