"use client";

import { useState } from "react";
import { useTranslations } from "next-intl";
import { Link } from "@/i18n/navigation";
import { useMutation } from "@apollo/client/react";
import { FLASHBACK_ENDORSE, type FlashbackActionCard } from "@/lib/graphql/flashback";
import { usePaymentErrorTranslator } from "@/lib/payment-errors";
import EndorseForm from "./endorse-form";

/**
 * 行动板（U5/R13 四态卡）：空板 / proposed / forming（附议计数+认领角色）/
 * scheduled（亮起+直链 Initiative 场次报名页+web 端退回触达文案）/ done 回贴。
 * 墙是行动板不是纪念墙：每张卡任何时刻都有可见的下一步动作。
 * 附议走 FLASHBACK_ENDORSE（U9 起双入口：token 或登录态）；成功后经 onChanged 重拉胶囊。
 */
export default function ActionBoard({
	cards,
	token,
	onChanged,
}: {
	cards: FlashbackActionCard[];
	token: string | null;
	onChanged: () => void;
}) {
	const t = useTranslations("flashback.actionBoard");
	const [runEndorse] = useMutation(FLASHBACK_ENDORSE);
	const [busy, setBusy] = useState(false);

	const endorse = async (cardId: string, role?: string) => {
		setBusy(true);
		try {
			const { data } = await runEndorse({
				variables: { token, cardId, roleClaimed: role ?? null },
			});
			if (data?.flashbackEndorse) {
				onChanged();
				return true;
			}
			return false;
		} catch {
			return false;
		} finally {
			setBusy(false);
		}
	};

	return (
		<section className="fb-action-board" aria-label={t("ariaLabel")}>
			<h3 className="fb-action-title">{t("title")}</h3>
			{cards.length === 0 ? (
				<p className="fb-action-empty" data-testid="fb-action-empty">
					{t("empty")}
				</p>
			) : (
				<ul className="fb-action-grid">
					{cards.map((card) => (
						<li
							key={card.id}
							className={`fb-action-card fb-action-card--${card.status}`}
							data-testid="fb-action-card"
							data-status={card.status}
						>
							<div className="fb-action-head">
								<span className="fb-action-name">{card.title}</span>
								{card.city ? <span className="fb-action-city">{card.city}</span> : null}
							</div>
							<p className="fb-action-count" aria-label={t("countAria", { count: card.endorsementCount })}>
								{t("count", { count: card.endorsementCount })}
							</p>
							{card.rolesClaimed.length > 0 && (
								<ul className="fb-action-roles">
									{card.rolesClaimed.map((role) => (
										<li key={role}>{t(`role_${role}`)}</li>
									))}
								</ul>
							)}
							<p className="fb-action-status">{t(`status_${card.status}`)}</p>

							{card.status === "scheduled" && card.eventSlug ? (
								<div className="fb-action-scheduled">
									<Link href={`/events/${card.eventSlug}`} className="fb-cta fb-cta-primary">
										{t("signup")}
									</Link>
									{/* web 端拿不到小程序订阅授权（KTD5 通道分派）：退回触达文案 */}
									<p className="fb-hint">{t("scheduledNote")}</p>
								</div>
							) : null}

							{card.status === "done" ? <p className="fb-hint">{t("doneNote")}</p> : null}

							{card.status !== "scheduled" && card.status !== "done" ? (
								card.endorsedByMe ? (
									<p className="fb-hint">{t("endorsed")}</p>
								) : (
									<EndorseForm disabled={busy} onEndorse={(role) => endorse(card.id, role)} />
								)
							) : null}
						</li>
					))}
				</ul>
			)}
		</section>
	);
}
