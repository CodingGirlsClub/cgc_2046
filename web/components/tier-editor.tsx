"use client";

/**
 * 价格档位编辑器（organizer-payment U6/KTD7）。
 *
 * 从 pricing-management.tsx 抽取的共享子组件：TierDraft 状态形状 + 两个纯
 * 转换器（toDraft/fromDraft）+ 行块渲染。嵌入创建表单、编辑表单与详情面板；
 * 原定价配置页在 U9 退役前同用此组件（档位编辑逻辑单一来源）。
 *
 * 受控组件：drafts/onChange（caller 持有状态与 dirty 标记）；manage 门控
 * 只读态。校验语义同步后端 PriceTiersValidation（金额 ≥ 1 分、缺名拒绝）
 * ——fromDraft 行级返回 null，caller 计数拦截提交，后端兜底。
 *
 * JsonString 序列化遵循 caller-serializes 先例（sponsorshipTiers 同款）。
 */

import { useTranslations } from "next-intl";

export interface TierDraft {
	id: string;
	name: string;
	/** 元输入（展示层习惯）；保存转分 */
	amount: string;
	/** yyyy-mm-dd 可空（date input 值） */
	availableUntil: string;
	/** review F9：加载时的原始 available_until ISO——用户未改日期时原样回写 */
	originalUntil?: string | null;
}
export function toDraft(raw: string[] | null | undefined): TierDraft[] {
	if (!Array.isArray(raw)) return [];
	return raw.flatMap((item) => {
		try {
			const t = JSON.parse(item) as Record<string, unknown>;
			if (typeof t.id !== "string" || typeof t.name !== "string") return [];
			const cents = typeof t.amount_cents === "number" ? t.amount_cents : null;
			return [
				{
					id: t.id,
					name: t.name,
					amount: cents === null ? "" : (cents / 100).toFixed(2),
					availableUntil:
						typeof t.available_until === "string"
							? t.available_until.slice(0, 10)
							: "",
					// review F9：原始 ISO 保真——用户未改日期时保存回写原值
					//（不重写 23:59:59Z / 不丢时分秒与时区）
					originalUntil:
						typeof t.available_until === "string" ? t.available_until : null,
				},
			];
		} catch {
			return [];
		}
	});
}

/** draft → PriceTier JSON；非法行返回 null（行级剔除 + 计数） */
export function fromDraft(draft: TierDraft): Record<string, unknown> | null {
	const name = draft.name.trim();
	if (name === "") return null;
	const yuan = Number(draft.amount);
	if (!Number.isFinite(yuan) || yuan <= 0) return null;
	const cents = Math.round(yuan * 100);
	if (cents < 1) return null;
	const tier: Record<string, unknown> = {
		id: draft.id,
		name,
		amount_cents: cents,
	};
	if (draft.availableUntil.trim() !== "") {
		// F9：日期未变（date input 值 = 原值前缀）→ 回写 originalUntil 原始 ISO；
		// 用户改了日期 → 按当日 23:59:59Z 截止（新增/改期语义不变）
		const changed =
			!draft.originalUntil ||
			draft.originalUntil.slice(0, 10) !== draft.availableUntil.trim();
		tier.available_until = changed
			? `${draft.availableUntil.trim()}T23:59:59Z`
			: draft.originalUntil;
	}
	return tier;
}

export default function TierEditor({
	drafts,
	onChange,
	manage,
}: {
	drafts: TierDraft[];
	onChange: (drafts: TierDraft[]) => void;
	manage: boolean;
}) {
	const t = useTranslations("pricing");

	function addTier() {
		onChange([
			...drafts,
			{
				id: crypto.randomUUID(),
				name: "",
				amount: "",
				availableUntil: "",
				originalUntil: null,
			},
		]);
	}

	function removeTier(id: string) {
		onChange(drafts.filter((d) => d.id !== id));
	}

	function patchTier(id: string, patch: Partial<TierDraft>) {
		onChange(drafts.map((d) => (d.id === id ? { ...d, ...patch } : d)));
	}

	return (
		<div className="grid gap-2" data-testid="tier-editor">
			{drafts.length === 0 ? (
				<p className="text-sm text-ink-3" data-testid="tier-empty">
					{t("noTiersPlain")}
				</p>
			) : (
				drafts.map((d) => (
					<div
						key={d.id}
						className="grid grid-cols-[1fr_100px_150px_auto] items-center gap-2"
						data-testid={`tier-row-${d.id}`}
					>
						<input
							className="w-full rounded-large border border-line bg-soft-2 px-3 py-2 text-sm text-ink"
							placeholder={t("tierNamePlaceholder")}
							value={d.name}
							disabled={!manage}
							onChange={(e) => patchTier(d.id, { name: e.target.value })}
							data-testid={`tier-name-${d.id}`}
						/>
						<input
							className="w-full rounded-large border border-line bg-soft-2 px-3 py-2 text-sm text-ink"
							placeholder={t("tierAmountPlaceholder")}
							inputMode="decimal"
							value={d.amount}
							disabled={!manage}
							onChange={(e) => patchTier(d.id, { amount: e.target.value })}
							data-testid={`tier-amount-${d.id}`}
						/>
						<input
							type="date"
							className="w-full rounded-large border border-line bg-soft-2 px-3 py-2 text-sm text-ink"
							aria-label={t("tierUntilAria")}
							title={t("tierUntilAria")}
							value={d.availableUntil}
							disabled={!manage}
							onChange={(e) =>
								patchTier(d.id, { availableUntil: e.target.value })
							}
							data-testid={`tier-until-${d.id}`}
						/>
						{manage && (
							<button
								type="button"
								className="rounded-large border border-line px-3 py-2 text-xs text-ink-3 hover:border-line-strong"
								onClick={() => removeTier(d.id)}
								data-testid={`tier-remove-${d.id}`}
							>
								{t("delete")}
							</button>
						)}
					</div>
				))
			)}

			{drafts.length > 0 && (
				<p className="text-xs text-ink-3" data-testid="tier-until-hint">
					{t("tierUntilHint")}
				</p>
			)}

			{manage && (
				<div className="flex flex-wrap items-center gap-3">
					<button
						type="button"
						className="rounded-large border border-line px-4 py-2 text-sm text-ink-2 hover:border-line-strong"
						onClick={addTier}
						data-testid="tier-add"
					>
						{t("addTier")}
					</button>
				</div>
			)}
		</div>
	);
}
