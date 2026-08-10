"use client";

/**
 * /admin/workspaces 工作台列表（Phase 8 / R13）。
 * 分页 + 搜索（name/slug）+ 状态/Owner/成员数/创建日期。
 * 后端 listWorkspaces 返回裸数组，分页用 offset（after）。
 */
import Link from "next/link";
import { useCallback, useEffect, useState } from "react";
import { fetchWorkspaces } from "@/lib/admin";
import type { AdminWorkspace } from "@/lib/graphql/admin";
import { JOIN_POLICY_LABEL } from "@/lib/graphql/workspace";

const PAGE_SIZE = 50;

export default function AdminWorkspacesPage() {
	const [workspaces, setWorkspaces] = useState<AdminWorkspace[] | null>(null);
	const [search, setSearch] = useState("");
	const [offset, setOffset] = useState(0);
	const [loading, setLoading] = useState(false);
	const [error, setError] = useState(false);

	const load = useCallback((term: string, after: number) => {
		// .then/.catch 链（Phase 9 统一模式）：effect 内调用不触发 set-state-in-effect
		return fetchWorkspaces(term, { first: PAGE_SIZE, after: String(after) })
			.then((list) => {
				setWorkspaces(list);
				setError(false);
			})
			.catch(() => {
				setError(true);
				setWorkspaces([]);
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
		const next = offset + (workspaces?.length ?? 0);
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

	return (
		<section>
			<div className="flex items-center justify-between mb-4">
				<h1 className="text-2xl font-semibold">工作台</h1>
				<Link
					href="/admin/workspaces/create"
					className="px-3 py-1.5 rounded-md bg-neutral-900 text-white text-sm hover:bg-neutral-700"
				>
					创建工作台
				</Link>
			</div>

			<div className="flex gap-2 mb-4">
				<input
					value={search}
					onChange={(e) => setSearch(e.target.value)}
					onKeyDown={(e) => e.key === "Enter" && handleSearch()}
					placeholder="搜索工作台（name / slug）"
					aria-label="搜索工作台"
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
			{loading && <p className="text-sm text-neutral-500">加载中…</p>}

			{!loading && !error && workspaces && workspaces.length === 0 && (
				<p className="text-sm text-neutral-500">暂无工作台。</p>
			)}

			{!loading && !error && workspaces && workspaces.length > 0 && (
				<table className="w-full text-sm border-collapse">
					<thead>
						<tr className="text-left text-neutral-500 border-b border-neutral-200">
							<th className="py-2">名称</th>
							<th className="py-2">slug</th>
							<th className="py-2">加入策略</th>
							<th className="py-2">成员数</th>
							<th className="py-2">创建时间</th>
						</tr>
					</thead>
					<tbody>
						{workspaces.map((ws) => (
							<tr key={ws.id} className="border-b border-neutral-100">
								<td className="py-2">
									<Link
										href={`/admin/workspaces/${ws.id}`}
										className="font-medium hover:underline"
									>
										{ws.name}
									</Link>
								</td>
								<td className="py-2 text-neutral-600">{ws.slug}</td>
								<td className="py-2">{JOIN_POLICY_LABEL[ws.joinPolicy]}</td>
								<td className="py-2">{ws.memberCount}</td>
								<td className="py-2 text-neutral-600">
									{new Date(ws.insertedAt).toLocaleDateString("zh-CN")}
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
		</section>
	);
}
