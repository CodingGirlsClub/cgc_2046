"use client";

import { useTranslations } from "next-intl";
import { useAuthed } from "@/lib/auth-provider";
import { Link } from "@/i18n/navigation";
import { useStageTitleFocus } from "./use-reduced-motion";

/** 失效原因（后端顶层错误 code 可区分，R1） */
export type InvalidTokenReason = "flashback_token_not_found" | "flashback_token_claimed" | "flashback_token_revoked";

/**
 * 失效链接落地页（U4 三分支）：
 * - claimed（已注册）：引导登录/小程序，说明账号已接管；
 * - revoked（已删除）：告知档案已清除 + 重新开始出口（公开首页）；
 * - not_found（不存在/错抄）：自助找回入口（公开首页 recover 区块）。
 */
export default function InvalidToken({ reason }: { reason: InvalidTokenReason }) {
	const t = useTranslations("flashback.invalid");
	const { authed, confirmed } = useAuthed();
	const titleRef = useStageTitleFocus<HTMLHeadingElement>([reason]);
	const authedBody = reason === "flashback_token_claimed" && confirmed && authed;

	return (
		<section className="fb-stage fb-stage-pad fb-invalid">
			<h2 className="fb-stage-title" ref={titleRef} tabIndex={-1}>
				{t(`${reason}.title`)}
			</h2>
			<p className="fb-lead">{t(authedBody ? `${reason}.bodyAuthed` : `${reason}.body`)}</p>
			<div className="fb-invalid-actions">
				{reason === "flashback_token_claimed" && (
					<Link href={confirmed && authed ? "/flashback/capsule" : "/login?next=%2Fflashback%2Fcapsule"}>{t(confirmed && authed ? "claimed.capsule" : "claimed.action")}</Link>
				)}
				{/* L4：not_found = 去找回，直落首页找回锚点；revoked 是「回到首页」不带 */}
				{reason !== "flashback_token_claimed" && (
					<Link href={reason === "flashback_token_not_found" ? "/flashback#recover" : "/flashback"}>{t(`${reason}.action`)}</Link>
				)}
			</div>
		</section>
	);
}
