"use client";

/**
 * E-11 #127 新建活动页 /w/[slug]/events/new。
 *
 * - Owner/Admin 专属（前端门控 + 后端 policy 兜底）；
 * - 表单：标题（必填）/ 报名策略 / 可见性（默认 public）/ 名额（空=不限）/
 *   报名截止（空=不设截止）；
 * - 提交成功 → 跳转详情页（/w/[slug]/events/[id]）。
 */

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useState } from "react";
import { useParams } from "next/navigation";
import { useWorkspaceBySlug } from "@/lib/use-workspace-by-slug";
import { canManageEvents, createEvent } from "@/lib/events";
import type { EnrollmentPolicy, Visibility } from "@/lib/graphql/events";
import {
	ENROLLMENT_POLICIES,
	ENROLLMENT_POLICY_LABEL,
	VISIBILITIES,
	VISIBILITY_LABEL,
} from "@/lib/graphql/events";
import WorkspaceShell from "@/components/workspace-shell";

function toIsoOrNull(value: string): string | null {
	if (!value) return null;
	const d = new Date(value);
	return Number.isNaN(d.getTime()) ? null : d.toISOString();
}

export default function WorkspaceNewEventPage() {
	const params = useParams<{ slug: string }>();
	const slug = params?.slug ?? "";
	const router = useRouter();
	const { ws, loading: wsLoading } = useWorkspaceBySlug(slug);

	const [title, setTitle] = useState("");
	const [enrollmentPolicy, setEnrollmentPolicy] = useState<EnrollmentPolicy>("open");
	const [visibility, setVisibility] = useState<Visibility>("public");
	const [capacity, setCapacity] = useState("");
	const [deadline, setDeadline] = useState("");
	const [busy, setBusy] = useState(false);
	const [error, setError] = useState<string | null>(null);

	const manage = ws ? canManageEvents(ws.myRoleNames) : false;

	async function submit() {
		if (!ws) return;
		setBusy(true);
		setError(null);

		const res = await createEvent(ws.id, {
			title: title.trim(),
			enrollmentPolicy,
			visibility,
			capacity: capacity === "" ? null : Number(capacity),
			registrationDeadline: toIsoOrNull(deadline),
		});
		setBusy(false);

		if (res.result) {
			router.push(`/w/${slug}/events/${res.result.id}`);
		} else {
			setError(res.errors[0]?.message ?? "创建失败");
		}
	}

	if (wsLoading) {
		return (
			<WorkspaceShell slug={slug}>
				<div className="ws-page-main__inner">
					<div className="h-56 animate-pulse rounded-large bg-soft-2 ring-1 ring-line" />
				</div>
			</WorkspaceShell>
		);
	}

	if (!manage) {
		return (
			<WorkspaceShell slug={slug}>
				<div className="ws-page-main__inner">
					<div className="rounded-large border border-line bg-card p-10 text-center text-sm text-ink-3">
						仅 Owner/Admin 可创建活动。
						<Link href={`/w/${slug}/events`} className="ml-2 text-accent">
							返回活动列表
						</Link>
					</div>
				</div>
			</WorkspaceShell>
		);
	}

	return (
		<WorkspaceShell slug={slug}>
			<div className="ws-page-main__inner">
				<div className="ws-page-breadcrumb" aria-label="页面路径">
					<Link href="/">工作台</Link>
					<span>›</span>
					<Link href={`/w/${slug}`}>{ws?.name ?? slug}</Link>
					<span>›</span>
					<Link href={`/w/${slug}/events`}>活动</Link>
					<span>›</span>
					<strong>新建活动</strong>
				</div>

				<header className="ws-page-heading">
					<div>
						<h1>新建活动</h1>
						<p>创建后为草稿，发布后进入开放报名</p>
					</div>
				</header>

				<div className="max-w-xl rounded-large border border-line bg-card p-6">
					<div className="grid gap-4">
						<label className="block">
							<span className="block text-[13px] text-ink-3">标题（必填）</span>
							<input
								value={title}
								onChange={(e) => setTitle(e.target.value)}
								className="mt-1 w-full rounded-large border border-line bg-soft-2 px-3 py-2 text-sm text-ink"
							/>
						</label>

						<label className="block">
							<span className="block text-[13px] text-ink-3">报名策略</span>
							<select
								value={enrollmentPolicy}
								onChange={(e) =>
									setEnrollmentPolicy(e.target.value as EnrollmentPolicy)
								}
								className="mt-1 w-full rounded-large border border-line bg-soft-2 px-3 py-2 text-sm text-ink"
							>
								{ENROLLMENT_POLICIES.map((p) => (
									<option key={p} value={p}>
										{ENROLLMENT_POLICY_LABEL[p]}
									</option>
								))}
							</select>
						</label>

						<div>
							<span className="block text-[13px] text-ink-3">可见性</span>
							<div className="mt-2 flex gap-2">
								{VISIBILITIES.map((v) => (
									<button
										key={v}
										type="button"
										onClick={() => setVisibility(v)}
										className={`rounded-full border px-3 py-1 text-[13px] ${
											visibility === v
												? "border-accent bg-soft-2 text-accent"
												: "border-line text-ink-3 hover:border-line-strong"
										}`}
									>
										{VISIBILITY_LABEL[v]}
									</button>
								))}
							</div>
						</div>

						<label className="block">
							<span className="block text-[13px] text-ink-3">
								名额上限（留空 = 不限）
							</span>
							<input
								type="number"
								min={1}
								value={capacity}
								onChange={(e) => setCapacity(e.target.value)}
								className="mt-1 w-full rounded-large border border-line bg-soft-2 px-3 py-2 text-sm text-ink"
							/>
						</label>

						<label className="block">
							<span className="block text-[13px] text-ink-3">
								报名截止（留空 = 不设截止）
							</span>
							<input
								type="datetime-local"
								value={deadline}
								onChange={(e) => setDeadline(e.target.value)}
								className="mt-1 w-full rounded-large border border-line bg-soft-2 px-3 py-2 text-sm text-ink"
							/>
						</label>

						{error ? <p className="text-[13px] text-ink-3">{error}</p> : null}

						<button
							type="button"
							disabled={busy || title.trim() === ""}
							onClick={() => void submit()}
							className="rounded-large border border-line-strong bg-card px-4 py-2 text-sm font-medium text-ink hover:border-line disabled:opacity-50"
						>
							{busy ? "创建中…" : "创建活动"}
						</button>
					</div>
				</div>
			</div>
		</WorkspaceShell>
	);
}
