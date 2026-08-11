"use client";

/**
 * /apply 申请创建工作台（Phase 9 / R6 + R7a）。
 * 已登录用户提交创建申请（name / slug / purpose，applicant 自动取当前用户）。
 * 提交后展示自己的申请列表（状态 + 拒绝原因，R7a）。
 */
import { useCallback, useEffect, useState } from "react";
import Link from "next/link";
import { createApplication, fetchMyApplications } from "@/lib/admin";
import {
	APPLICATION_STATUS_CLASS,
	APPLICATION_STATUS_LABEL,
	type AdminWorkspaceApplication,
} from "@/lib/graphql/admin";
import { useAuthed } from "@/lib/use-authed";

export default function ApplyPage() {
	const { authed, confirmed, userId } = useAuthed();
	const [name, setName] = useState("");
	const [slug, setSlug] = useState("");
	const [purpose, setPurpose] = useState("");
	const [submitting, setSubmitting] = useState(false);
	const [formError, setFormError] = useState<string | null>(null);
	const [submitted, setSubmitted] = useState(false);
	const [myApps, setMyApps] = useState<AdminWorkspaceApplication[] | null>(null);
	const [listError, setListError] = useState(false);

	const loadMyApps = useCallback(() => {
		// 用 .then/.catch 链（join 页模式）：避免 async 函数体在 effect 同步段
		// 触碰 setState（react-hooks/set-state-in-effect）
		return fetchMyApplications()
			.then((list) => {
				setMyApps(list);
				setListError(false);
			})
			.catch(() => {
				setListError(true);
				setMyApps([]);
			});
	}, []);

	useEffect(() => {
		if (authed) {
			void loadMyApps();
		}
	}, [authed, loadMyApps]);

	const handleSubmit = async (e: React.FormEvent) => {
		e.preventDefault();
		setFormError(null);
		setSubmitting(true);
		try {
			const res = await createApplication({ name, slug, purpose, applicantId: userId! });
			if (res.result) {
				setSubmitted(true);
				setName("");
				setSlug("");
				setPurpose("");
				await loadMyApps();
			} else {
				setFormError(res.errors[0]?.message ?? "提交失败，请稍后重试");
			}
		} catch {
			setFormError("提交失败，请稍后重试");
		} finally {
			setSubmitting(false);
		}
	};

	// 登录确认中：不渲染表单（避免未登录提交）
	if (!confirmed) {
		return (
			<section className="mx-auto max-w-xl px-4 py-10">
				<p className="text-sm text-neutral-500">加载中…</p>
			</section>
		);
	}

	if (!authed) {
		return (
			<section className="mx-auto max-w-xl px-4 py-10">
				<h1 className="text-2xl font-semibold mb-2">申请创建工作台</h1>
				<p className="text-neutral-600">
					请先{" "}
					<Link href="/login" className="text-blue-600 hover:underline">
						登录
					</Link>{" "}
					后提交申请。
				</p>
			</section>
		);
	}

	return (
		<section className="mx-auto max-w-xl px-4 py-10">
			<h1 className="text-2xl font-semibold mb-2">申请创建工作台</h1>
			<p className="text-neutral-600 mb-6">
				填写你希望创建的工作台信息，提交后由平台管理员审批。审批通过后你将作为该工作台的
				Owner。
			</p>

			<form onSubmit={handleSubmit} className="flex flex-col gap-4 mb-8">
				<div className="flex flex-col gap-1">
					<label htmlFor="apply-name" className="text-sm font-medium">
						工作台名称
					</label>
					<input
						id="apply-name"
						value={name}
						onChange={(e) => setName(e.target.value)}
						placeholder="工作台名称（如：研究协作空间）"
						required
						className="px-3 py-2 rounded-md border border-neutral-300 text-sm"
					/>
				</div>

				<div className="flex flex-col gap-1">
					<label htmlFor="apply-slug" className="text-sm font-medium">
						slug（唯一标识，小写字母/数字/连字符）
					</label>
					<input
						id="apply-slug"
						value={slug}
						onChange={(e) => setSlug(e.target.value)}
						placeholder="slug（如：research-collab）"
						required
						pattern="[a-z0-9-]+"
						className="px-3 py-2 rounded-md border border-neutral-300 text-sm"
					/>
				</div>

				<div className="flex flex-col gap-1">
					<label htmlFor="apply-purpose" className="text-sm font-medium">
						用途
					</label>
					<textarea
						id="apply-purpose"
						value={purpose}
						onChange={(e) => setPurpose(e.target.value)}
						placeholder="申请用途（如：团队研究协作）"
						required
						rows={3}
						className="px-3 py-2 rounded-md border border-neutral-300 text-sm"
					/>
				</div>

				{formError && <p className="text-sm text-red-600">{formError}</p>}
				{submitted && (
					<p className="text-sm text-green-700">
						提交成功！你的申请已进入待审批状态。
					</p>
				)}

				<button
					type="submit"
					disabled={submitting}
					className="px-4 py-2 rounded-md bg-neutral-900 text-white text-sm hover:bg-neutral-700 disabled:opacity-50"
				>
					提交申请
				</button>
			</form>

			<section aria-label="我的申请">
				<h2 className="text-lg font-semibold mb-3">我的申请</h2>
				{listError && <p className="text-sm text-red-600 mb-3">申请列表加载失败。</p>}
				{myApps && myApps.length === 0 && (
					<p className="text-sm text-neutral-500">暂无申请。</p>
				)}
				{myApps && myApps.length > 0 && (
					<ul className="flex flex-col gap-2">
						{myApps.map((app) => (
							<li
								key={app.id}
								className="rounded-lg border border-neutral-200 p-3"
							>
								<div className="flex items-center justify-between">
									<span className="font-medium">{app.name}</span>
									<span className={APPLICATION_STATUS_CLASS[app.status]}>
										{APPLICATION_STATUS_LABEL[app.status]}
									</span>
								</div>
								<div className="text-xs text-neutral-500 mt-1">{app.slug}</div>
								{app.rejectionReason && (
									<div className="text-xs text-red-600 mt-1">
										拒绝原因：{app.rejectionReason}
									</div>
								)}
							</li>
						))}
					</ul>
				)}
			</section>
		</section>
	);
}
