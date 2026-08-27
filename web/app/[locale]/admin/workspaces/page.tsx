"use client";

/**
 * /admin/workspaces 工作台列表（Phase 8 / R13）。
 * 分页 + 搜索（name/slug）+ 状态/Owner/成员数/创建日期。
 * 后端 listWorkspaces 返回裸数组，分页用 offset（after）。
 */
import { Link } from "@/i18n/navigation";
import { useCallback, useEffect, useState } from "react";
import { useTranslations } from "next-intl";
import { fetchWorkspaces } from "@/lib/admin";
import type { AdminWorkspace } from "@/lib/graphql/admin";
import { JOIN_POLICY_LABEL } from "@/lib/graphql/workspace";

const PAGE_SIZE = 50;

export default function AdminWorkspacesPage() {
	const t = useTranslations("admin");
	const labelsT = useTranslations();
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
			<div className="admin-page__head">
				<h1>{t("navWorkspaces")}</h1>
				<Link
					href="/admin/workspaces/create"
					className="l-btn-primary"
				>
					{t("createWorkspace")}
				</Link>
			</div>

			<div className="admin-toolbar">
				<input
					value={search}
					onChange={(e) => setSearch(e.target.value)}
					onKeyDown={(e) => e.key === "Enter" && handleSearch()}
					placeholder={t("searchWorkspacePlaceholder")}
					aria-label={t("searchWorkspaceAria")}
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
			{loading && <p className="admin-muted">{t("loading")}</p>}

			{!loading && !error && workspaces && workspaces.length === 0 && (
				<p className="admin-empty">{t("noWorkspaces")}</p>
			)}

			{!loading && !error && workspaces && workspaces.length > 0 && (
				<div className="admin-card admin-table-wrap">
					<table className="admin-table">
						<thead>
							<tr>
								<th>{t("thName")}</th>
								<th>{t("thSlug")}</th>
								<th>{t("thJoinPolicy")}</th>
								<th className="admin-table__num">{t("thMemberCount")}</th>
								<th>{t("thCreatedAt")}</th>
								<th className="admin-table__actions">{t("thActions")}</th>
							</tr>
						</thead>
						<tbody>
							{workspaces.map((ws) => (
								<tr key={ws.id}>
									<td>
										<Link
											href={`/admin/workspaces/${ws.id}`}
											className="admin-table__primary hover:underline"
										>
											{ws.name}
										</Link>
									</td>
									<td>{ws.slug}</td>
									<td>{labelsT(JOIN_POLICY_LABEL[ws.joinPolicy])}</td>
									<td className="admin-table__num">{ws.memberCount}</td>
									<td>
										{new Date(ws.insertedAt).toLocaleDateString("zh-CN")}
									</td>
									<td className="admin-table__actions">
										<Link
											href={`/admin/workspaces/${ws.id}`}
											className="l-btn-outline"
										>
											{t("viewWorkspace")}
										</Link>
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
		</section>
	);
}
