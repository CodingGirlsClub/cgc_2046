"use client";

import { useEffect, useMemo, useState } from "react";
import { useTranslations } from "next-intl";

/**
 * 审批倒计时 chip（原型验证结论 #4：琥珀/青色脉冲 + <48h 高亮）。
 * 供 B-3 加入申请审批页与 E-8 全局审批控制台共用。
 */
export function ApprovalChip({ deadline }: { deadline: string | null }) {
	const t = useTranslations("approvals");
	const [now, setNow] = useState(() => Date.now());

	useEffect(() => {
		const timer = setInterval(() => setNow(Date.now()), 60000);
		return () => clearInterval(timer);
	}, []);

	const timeLeft = useMemo(() => {
		if (!deadline) return null;
		const deadlineMs = new Date(deadline).getTime();
		const diff = deadlineMs - now;
		if (diff <= 0) return { hours: 0, minutes: 0, expired: true as const };
		return {
			hours: Math.floor(diff / 3600000),
			minutes: Math.floor((diff % 3600000) / 60000),
			expired: false as const,
		};
	}, [deadline, now]);

	if (!timeLeft) return null;
	if (timeLeft.expired) {
		return (
			<span className="approval-chip approval-chip--expired">
				{t("chipExpired")}
			</span>
		);
	}

	const urgent = timeLeft.hours < 48;
	return (
		<span
			className={`approval-chip ${urgent ? "approval-chip--urgent" : ""}`}
			title={t("chipRemaining", {
				hours: timeLeft.hours,
				minutes: timeLeft.minutes,
			})}
		>
			{urgent && <span className="approval-chip__pulse" aria-hidden="true" />}
			{timeLeft.hours > 0
				? t("chipHours", { hours: timeLeft.hours })
				: t("chipMinutes", { minutes: timeLeft.minutes })}
		</span>
	);
}
