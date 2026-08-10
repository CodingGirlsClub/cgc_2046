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
			<div className="flex items-center justify-between mb-4">
				<h1 className="text-2xl font-semibold">用户</h1>
			</div>

			<div className="flex gap-2 mb-4">
				<input
					value={search}
					onChange={(e) => setSearch(e.target.value)}
					onKeyDown={(e) => e.key === "Enter" && handleSearch()}
					placeholder="搜索用户（email / 显示名）"
					aria-label="搜索用户"
					className="px-3 py-1.5 rounded-md border border-neutral-300 text-sm flex-1"
				/>
				<button
					type="button"
					onClick={handleSearch}
					className="px-3 py-1.5 rounded-md border border-neutral-300 text-sm hover:bg-neutral-50"
				>
					搜索
				</button>
			</div>

			{error && <p className="text-sm text-red-600 mb-4">加载失败，请稍后重试。</p>}
			{actionError && <p className="text-sm text-red-600 mb-4">{actionError}</p>}
			{loading && <p className="text-sm text-neutral-500">加载中…</p>}

			{!loading && !error && users && users.length === 0 && (
				<p className="text-sm text-neutral-500">暂无用户。</p>
			)}

			{!loading && !error && users && users.length > 0 && (
				<table className="w-full text-sm border-collapse">
					<thead>
						<tr className="text-left text-neutral-500 border-b border-neutral-200">
							<th className="py-2">用户</th>
							<th className="py-2">平台管理员</th>
							<th className="py-2">成员概要</th>
							<th className="py-2">加入时间</th>
							<th className="py-2">操作</th>
						</tr>
					</thead>
					<tbody>
						{users.map((user) => (
							<tr key={user.id} className="border-b border-neutral-100">
								<td className="py-2">
									<div className="font-medium">
										{user.displayName || user.email || "（未命名）"}
									</div>
									{user.email && user.displayName && (
										<div className="text-neutral-500 text-xs">{user.email}</div>
									)}
								</td>
								<td className="py-2">
									{user.isPlatformAdmin ? (
										<span className="l-badge l-badge-success">管理员</span>
									) : (
										<span className="l-badge l-badge-muted">普通用户</span>
									)}
								</td>
								<td className="py-2 text-neutral-600">
									{user.workspaceMembershipCount ?? 0} 个成员
								</td>
								<td className="py-2 text-neutral-600">
									{new Date(user.insertedAt).toLocaleDateString("zh-CN")}
								</td>
								<td className="py-2">
									{user.isPlatformAdmin ? (
										<button
											type="button"
											onClick={() => handleDemoteClick(user)}
											disabled={busyId === user.id}
											className="px-2 py-1 rounded-md border border-neutral-300 text-xs hover:bg-neutral-50 disabled:opacity-50"
										>
											降级
										</button>
									) : (
										<button
											type="button"
											onClick={() => handlePromote(user)}
											disabled={busyId === user.id}
											className="px-2 py-1 rounded-md border border-neutral-300 text-xs hover:bg-neutral-50 disabled:opacity-50"
										>
											提升
										</button>
									)}
								</td>
							</tr>
						))}
					</tbody>
				</table>
			)}

			<div className="flex gap-2 mt-4">
				<button
					type="button"
					onClick={handlePrev}
					disabled={offset === 0 || loading}
					className="px-3 py-1.5 rounded-md border border-neutral-300 text-sm disabled:opacity-50"
				>
					上一页
				</button>
				<button
					type="button"
					onClick={handleNext}
					disabled={loading}
					className="px-3 py-1.5 rounded-md border border-neutral-300 text-sm disabled:opacity-50"
				>
					下一页
				</button>
			</div>

			{confirmDemote && (
				<div
					role="dialog"
					aria-label="确认降级"
					className="fixed inset-0 bg-black/40 flex items-center justify-center"
				>
					<div className="bg-white rounded-lg p-6 max-w-sm w-full">
						<h2 className="text-lg font-semibold mb-2">确认降级</h2>
						<p className="text-sm text-neutral-600 mb-4">
							你将降级自己（{confirmDemote.email || confirmDemote.displayName || "当前用户"}）的
							平台管理员权限。请确认。
						</p>
						<div className="flex justify-end gap-2">
							<button
								type="button"
								onClick={() => setConfirmDemote(null)}
								className="px-3 py-1.5 rounded-md border border-neutral-300 text-sm hover:bg-neutral-50"
							>
								取消
							</button>
							<button
								type="button"
								onClick={handleConfirmDemote}
								className="px-3 py-1.5 rounded-md bg-red-600 text-white text-sm hover:bg-red-500"
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
