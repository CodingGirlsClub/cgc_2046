"use client";

import { useState } from "react";
import { useTranslations } from "next-intl";

/** 可认领角色（R13：组织者/宣传拉人/场地资源；值与后端 @roles 对齐） */
const ROLES = ["organizer", "promoter", "venue"] as const;

/**
 * 附议表单（U5/R13）：角色可选——选了即认领（role_claimed），不选纯附议。
 * web 端无小程序订阅授权（requestSubscribeMessage 是小程序专属）；成场
 * 通知按 KTD5 通道分派退回邮件/短信（文案在 action-board 的 scheduledNote）。
 */
export default function EndorseForm({
	disabled,
	onEndorse,
}: {
	disabled: boolean;
	onEndorse: (role?: string) => Promise<boolean>;
}) {
	const t = useTranslations("flashback.actionBoard");
	const [role, setRole] = useState<string | undefined>(undefined);
	const [pending, setPending] = useState(false);
	const [failed, setFailed] = useState(false);

	const submit = async () => {
		setPending(true);
		setFailed(false);
		const ok = await onEndorse(role);
		if (!ok) setFailed(true);
		setPending(false);
	};

	return (
		<div className="fb-endorse">
			<fieldset className="fb-endorse-roles">
				<legend className="fb-visually-hidden">{t("endorseRoleLegend")}</legend>
				{ROLES.map((candidate) => (
					<label key={candidate}>
						<input
							type="radio"
							name={`fb-endorse-role-${role}`}
							checked={role === candidate}
							onChange={() => setRole(candidate)}
						/>
						{t(`role_${candidate}`)}
					</label>
				))}
				<label>
					<input type="radio" name="fb-endorse-role-none" checked={role === undefined} onChange={() => setRole(undefined)} />
					{t("role_none")}
				</label>
			</fieldset>
			<button type="button" className="fb-cta" disabled={disabled || pending} onClick={submit}>
				{t("endorse")}
			</button>
			{failed && (
				<p role="alert" className="fb-hint">
					{t("endorseFailed")}
				</p>
			)}
		</div>
	);
}
