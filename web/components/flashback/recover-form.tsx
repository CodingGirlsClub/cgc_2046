"use client";

import { useState } from "react";
import { useTranslations } from "next-intl";
import { useRouter } from "@/i18n/navigation";
import { useMutation } from "@apollo/client/react";
import {
	FLASHBACK_RECOVER,
	FLASHBACK_RECOVER_VERIFY,
	type FlashbackRecoverCard,
} from "@/lib/graphql/flashback";
import { graphqlErrorDetails } from "@/lib/graphql/auth";
import { usePaymentErrorTranslator } from "@/lib/payment-errors";

/**
 * 自助找回（U6/R21/F5 承接）：凭当年预留的手机号/邮箱发起 → 同形文案
 * （不泄露命中与否）→ 手机通道输码验证 → 绑定成功进胶囊；多档案返回
 * 「你的 N 张卡」选择列表。邮箱通道提示查收恢复邮件（每张卡一个入口链接）。
 */
export default function RecoverForm() {
	const t = useTranslations("flashback.recover");
	const errorT = usePaymentErrorTranslator();
	const router = useRouter();

	const [identifier, setIdentifier] = useState("");
	const [code, setCode] = useState("");
	const [phase, setPhase] = useState<"input" | "code" | "cards" | "done">("input");
	const [error, setError] = useState<string | null>(null);
	const [cards, setCards] = useState<FlashbackRecoverCard[]>([]);

	const [runRecover] = useMutation(FLASHBACK_RECOVER);
	const [runVerify] = useMutation(FLASHBACK_RECOVER_VERIFY);

	// 提交前 trim（实测 bug 1 前半段）：聊天复制的首尾空白/换行不进 identifier；
	// 包裹符由后端 classify 剥壳兜底（前端不猜包裹形态）
	const trimmedIdentifier = identifier.trim();

	const handleInitiate = async () => {
		setError(null);
		try {
			const { data } = await runRecover({ variables: { identifier: trimmedIdentifier } });
			if (data?.flashbackRecover) {
				setPhase("code");
			}
		} catch (err) {
			// code → messages.errors 文案（errorT 两参签名：code + fallback）
			setError(errorT(graphqlErrorDetails(err)?.code ?? null, t("errorRetry")));
		}
	};

	const handleVerify = async () => {
		setError(null);
		try {
			const { data } = await runVerify({ variables: { identifier: trimmedIdentifier, code } });
			const result = data?.flashbackRecoverVerify;
			if (result?.bound) {
				if (result.cards.length > 1) {
					setCards(result.cards);
					setPhase("cards");
				} else {
					setPhase("done");
				}
			} else {
				setError(errorT("invalid_or_expired_code", t("errorCode")));
			}
		} catch (err) {
			// code → messages.errors 文案（errorT 两参签名：code + fallback）
			setError(errorT(graphqlErrorDetails(err)?.code ?? null, t("errorRetry")));
		}
	};

	const enterCapsule = () => router.push("/flashback/capsule");

	return (
		<section className="fb-recover" id="recover" aria-labelledby="fb-recover-title">
			<h3 id="fb-recover-title" className="fb-action-title">
				{t("title")}
			</h3>
			<p className="fb-hint">{t("lead")}</p>

			{phase === "input" && (
				<div className="fb-recover-form">
					<input
						className="fb-field-input fb-recover-input"
						placeholder={t("identifierPlaceholder")}
						aria-label={t("identifierPlaceholder")}
						value={identifier}
						onChange={(event) => setIdentifier(event.target.value)}
						inputMode="email"
					/>
					<button type="button" className="fb-cta fb-cta-primary" disabled={!identifier.trim()} onClick={handleInitiate}>
						{t("initiate")}
					</button>
				</div>
			)}

			{phase === "code" && (
				<div className="fb-recover-form">
					<p className="fb-hint">{t("sentHint")}</p>
					<input
						className="fb-field-input fb-recover-input"
						placeholder={t("codePlaceholder")}
						aria-label={t("codePlaceholder")}
						value={code}
						onChange={(event) => setCode(event.target.value)}
						inputMode="numeric"
					/>
					<button type="button" className="fb-cta fb-cta-primary" disabled={code.trim().length < 4} onClick={handleVerify}>
						{t("verify")}
					</button>
				</div>
			)}

			{phase === "cards" && (
				<div className="fb-recover-cards">
					<p className="fb-hint">{t("cardsTitle", { count: cards.length })}</p>
					<ul>
						{cards.map((card) => (
							<li key={card.personId} className="fb-recover-card">
								{card.surnameMasked} · {card.eventName ?? ""} · {card.city ?? ""}
							</li>
						))}
					</ul>
					<button type="button" className="fb-cta fb-cta-primary" onClick={enterCapsule}>
						{t("enterCapsule")}
					</button>
				</div>
			)}

			{phase === "done" && (
				<div className="fb-recover-done">
					<p className="fb-hint">{t("bound")}</p>
					<button type="button" className="fb-cta fb-cta-primary" onClick={enterCapsule}>
						{t("enterCapsule")}
					</button>
				</div>
			)}

			{error && (
				<p role="alert" className="fb-hint">
					{error}
				</p>
			)}
		</section>
	);
}
