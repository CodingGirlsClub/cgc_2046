"use client";

/**
 * E-3 #48 赞助意向表单（公开宿主页「赞助本场」）。
 *
 * - 入口条件（对齐 E-5 readiness 清单②）：sponsorshipEnabled && tiers 已配置；
 * - 登录后提交（全局账号，不成为 Workspace 成员）；未登录由宿主页引导 /login；
 * - 提交 → createSponsorship（level=event）→ pending 停住（权益不生效），
 *   回显「已提交，等待审批」中间态；
 * - 档位可选（tier_id 可空）；amount 仅登记不收款（v1 资金边界）。
 */

import { useState } from "react";
import { client } from "@/lib/apollo-client";
import {
	CREATE_SPONSORSHIP,
	type SponsorshipTierConfig,
} from "@/lib/graphql/sponsorship";

export interface SponsorshipIntentFormProps {
	eventId: string;
	sponsorUserId: string;
	tiers: SponsorshipTierConfig[];
}

type SubmitState =
	| { kind: "idle" }
	| { kind: "submitted" }
	| { kind: "error"; message: string };

const STATUS_LABEL: Record<string, string> = {
	pending: "审批中",
	active: "已生效",
	rejected: "已拒绝",
	expired: "已过期",
	ended: "已结束",
};

export function statusLabel(status: string): string {
	return STATUS_LABEL[status] ?? status;
}

export default function SponsorshipIntentForm({
	eventId,
	sponsorUserId,
	tiers,
}: SponsorshipIntentFormProps) {
	const [tierId, setTierId] = useState<string>(tiers[0]?.id ?? "");
	const [companyName, setCompanyName] = useState("");
	const [contactEmail, setContactEmail] = useState("");
	const [contactPhone, setContactPhone] = useState("");
	const [amount, setAmount] = useState("");
	const [message, setMessage] = useState("");
	const [busy, setBusy] = useState(false);
	const [state, setState] = useState<SubmitState>({ kind: "idle" });

	async function submit() {
		if (companyName.trim() === "" || contactEmail.trim() === "") {
			setState({ kind: "error", message: "公司名与联系邮箱必填" });
			return;
		}
		setBusy(true);
		setState({ kind: "idle" });
		try {
			const { data } = await client.mutate({
				mutation: CREATE_SPONSORSHIP,
				variables: {
					input: {
						level: "event",
						eventId,
						sponsorUserId,
						tierId: tierId === "" ? null : tierId,
						amount: amount.trim() === "" ? null : Number(amount),
						companyName: companyName.trim(),
						contactEmail: contactEmail.trim(),
						contactPhone: contactPhone.trim() === "" ? null : contactPhone.trim(),
						message: message.trim() === "" ? null : message.trim(),
					},
				},
			});

			const payload = data?.createSponsorship;
			if (payload?.result) {
				setState({ kind: "submitted" });
			} else {
				setState({
					kind: "error",
					message: payload?.errors?.[0]?.message ?? "提交失败，请稍后重试",
				});
			}
		} catch (e: unknown) {
			setState({
				kind: "error",
				message: e instanceof Error ? e.message : "提交失败，请稍后重试",
			});
		} finally {
			setBusy(false);
		}
	}

	if (state.kind === "submitted") {
		return (
			<div role="status">
				<p className="font-medium">✓ 赞助意向已提交</p>
				<p className="mt-1 text-[13px] text-ink-3">
					等待工作台 Owner/Admin 审批，通过后权益生效。
				</p>
			</div>
		);
	}

	return (
		<div className="grid gap-3">
			<label className="block">
				<span className="block text-[13px] text-ink-3">赞助档位</span>
				<select
					value={tierId}
					onChange={(e) => setTierId(e.target.value)}
					className="mt-1 w-full rounded-large border border-line bg-soft-2 px-3 py-2 text-sm"
				>
					<option value="">不指定档位</option>
					{tiers.map((tier) => (
						<option key={tier.id} value={tier.id}>
							{tier.name}
							{tier.amountSuggestion ? `（建议 ¥${tier.amountSuggestion}）` : ""}
						</option>
					))}
				</select>
			</label>
			<label className="block">
				<span className="block text-[13px] text-ink-3">公司/展示名（必填）</span>
				<input
					value={companyName}
					onChange={(e) => setCompanyName(e.target.value)}
					className="mt-1 w-full rounded-large border border-line bg-soft-2 px-3 py-2 text-sm"
					aria-label="公司名"
				/>
			</label>
			<label className="block">
				<span className="block text-[13px] text-ink-3">联系邮箱（必填）</span>
				<input
					type="email"
					value={contactEmail}
					onChange={(e) => setContactEmail(e.target.value)}
					className="mt-1 w-full rounded-large border border-line bg-soft-2 px-3 py-2 text-sm"
					aria-label="联系邮箱"
				/>
			</label>
			<label className="block">
				<span className="block text-[13px] text-ink-3">联系电话（选填）</span>
				<input
					value={contactPhone}
					onChange={(e) => setContactPhone(e.target.value)}
					className="mt-1 w-full rounded-large border border-line bg-soft-2 px-3 py-2 text-sm"
					aria-label="联系电话"
				/>
			</label>
			<label className="block">
				<span className="block text-[13px] text-ink-3">意向金额（元，选填，v1 仅登记不收款）</span>
				<input
					type="number"
					min={0}
					value={amount}
					onChange={(e) => setAmount(e.target.value)}
					className="mt-1 w-full rounded-large border border-line bg-soft-2 px-3 py-2 text-sm"
					aria-label="意向金额"
				/>
			</label>
			<label className="block">
				<span className="block text-[13px] text-ink-3">合作意向备注（选填）</span>
				<input
					value={message}
					onChange={(e) => setMessage(e.target.value)}
					className="mt-1 w-full rounded-large border border-line bg-soft-2 px-3 py-2 text-sm"
					aria-label="备注"
				/>
			</label>
			{state.kind === "error" ? (
				<p className="text-[13px] text-ink-3" role="alert">
					{state.message}
				</p>
			) : null}
			<button
				type="button"
				disabled={busy}
				onClick={() => void submit()}
				className="join-button join-button--primary justify-self-start"
			>
				{busy ? "提交中…" : "提交赞助意向"}
			</button>
		</div>
	);
}
