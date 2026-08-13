"use client";

import { useEffect, useMemo, useState } from "react";

/**
 * 审批倒计时 chip（原型验证结论 #4：琥珀/青色脉冲 + <48h 高亮）。
 * 供 B-3 加入申请审批页与 E-8 全局审批控制台共用。
 */
export function ApprovalChip({ deadline }: { deadline: string | null }) {
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
		return <span className="approval-chip approval-chip--expired">已过期</span>;
	}

	const urgent = timeLeft.hours < 48;
	return (
		<span
			className={`approval-chip ${urgent ? "approval-chip--urgent" : ""}`}
			title={`审批剩余：${timeLeft.hours} 小时 ${timeLeft.minutes} 分钟`}
		>
			{urgent && <span className="approval-chip__pulse" aria-hidden="true" />}
			{timeLeft.hours > 0
				? `剩余 ${timeLeft.hours}h`
				: `剩余 ${timeLeft.minutes}m`}
		</span>
	);
}
