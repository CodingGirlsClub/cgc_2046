"use client";

/**
 * /admin/users 用户列表（Phase 9 / R8 + R9）。
 * 分页 + 搜索（email/display_name）+ is_platform_admin 徽章 + membership 概要。
 * promote/demote：demote 自己需确认弹窗；最后一个 admin 由后端原子拒绝（显示错误）。
 */
import { useCallback, useEffect, useState } from "react";
import { demoteUser, fetchUsers, promoteUser } from "@/lib/admin";
import type { AdminUser } from "@/lib/graphql/admin";
import { useAuthed } from "@/lib/use-authed";

const PAGE_SIZE = 50;

export default function AdminUsersPage() {
	const { userId } = useAuthed();
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
				setActionError(payload.errors[0].message ?? "操作失败");
			} else {
				// 成功后重新拉取，刷新 is_platform_admin 状态
				await load(search, offset);
			}
		} catch {
			setActionError("操作失败，请稍后重试");
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
				<h1>用户</h1>
			</div>

			<div className="admin-toolbar">
				<input
					value={search}
					onChange={(e) => setSearch(e.target.value)}
					onKeyDown={(e) => e.key === "Enter" && handleSearch()}
					placeholder="搜索用户（email / 显示名）"
					aria-label="搜索用户"
					className="l-input"
				/>
				<button
					type="button"
					onClick={handleSearch}
					className="l-btn-outline"
				>
					搜索
				</button>
			</div>

			{error && <p className="admin-alert admin-alert--error">加载失败，请稍后重试。</p>}
			{actionError && <p className="admin-alert admin-alert--error">{actionError}</p>}
			{loading && <p className="admin-muted">加载中…</p>}

			{!loading && !error && users && users.length === 0 && (
				<p className="admin-empty">暂无用户。</p>
			)}

			{!loading && !error && users && users.length > 0 && (
				<div className="admin-card admin-table-wrap">
					<table className="admin-table">
						<thead>
							<tr>
								<th>用户</th>
								<th>平台管理员</th>
								<th className="admin-table__num">成员概要</th>
								<th>加入时间</th>
								<th className="admin-table__actions">操作</th>
							</tr>
						</thead>
						<tbody>
							{users.map((user) => (
								<tr key={user.id}>
									<td>
										<span className="admin-table__primary">
											{user.displayName || user.email || "（未命名）"}
										</span>
										{user.email && user.displayName && (
											<span className="admin-table__sub">{user.email}</span>
										)}
									</td>
									<td>
										{user.isPlatformAdmin ? (
											<span className="l-badge l-badge-admin">管理员</span>
										) : (
											<span className="l-badge l-badge-muted">普通用户</span>
										)}
									</td>
									<td className="admin-table__num">
										{user.workspaceMembershipCount ?? 0} 个成员
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
												降级
											</button>
										) : (
											<button
												type="button"
												onClick={() => handlePromote(user)}
												disabled={busyId === user.id}
												className="l-btn-outline"
											>
												提升
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
					上一页
				</button>
				<button
					type="button"
					onClick={handleNext}
					disabled={loading}
					className="l-btn-outline"
				>
					下一页
				</button>
			</div>

			{confirmDemote && (
				<div
					role="dialog"
					aria-label="确认降级"
					className="admin-modal-overlay"
				>
					<div className="admin-modal">
						<h2>确认降级</h2>
						<p>
							你将降级自己（{confirmDemote.email || confirmDemote.displayName || "当前用户"}）的
							平台管理员权限。请确认。
						</p>
						<div className="admin-modal__actions">
							<button
								type="button"
								onClick={() => setConfirmDemote(null)}
								className="l-btn-outline"
							>
								取消
							</button>
							<button
								type="button"
								onClick={handleConfirmDemote}
								className="l-btn-danger"
							>
								确认
							</button>
						</div>
					</div>
				</div>
			)}
		</section>
	);
}
