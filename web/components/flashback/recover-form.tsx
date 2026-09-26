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
 * 自助找回（U6/R21/F5 承接）：凭当年预留的邮箱发起 → 同形文案（不泄露命中与否）
 * → 提示查收恢复邮件（每张卡一个入口链接）。
 *
 * 手机通道暂停（2026-09-26：库里人人有邮箱、未必有手机号，短信按条计费）：`phoneEnabled`
 * 默认关——手机号就地提示填邮箱、不发起；打开时手机号输码验证 → 绑定成功进胶囊，多档案
 * 返回「你的 N 张卡」选择列表。重新开放须同时打开后端 `:flashback_recover_phone_enabled`
 * 并先补短信投递（见 backend Flashback.Recover 模块文档）。
 */
export default function RecoverForm({ phoneEnabled = false }: { phoneEnabled?: boolean }) {
	const t = useTranslations("flashback.recover");
	const errorT = usePaymentErrorTranslator();
	const router = useRouter();

	const [identifier, setIdentifier] = useState("");
	const [code, setCode] = useState("");
	const [phase, setPhase] = useState<"input" | "sent" | "code" | "cards" | "done">("input");
	const [error, setError] = useState<string | null>(null);
	const [cards, setCards] = useState<FlashbackRecoverCard[]>([]);

	const [runRecover] = useMutation(FLASHBACK_RECOVER);
	const [runVerify] = useMutation(FLASHBACK_RECOVER_VERIFY);

	// 提交前 trim（实测 bug 1 前半段）：聊天复制的首尾空白/换行不进 identifier；
	// 包裹符由后端 classify 剥壳兜底（前端不猜包裹形态）
	const trimmedIdentifier = identifier.trim();

	const handleInitiate = async () => {
		setError(null);
		// 含 @ 即邮箱（同后端 classify）；其余按手机号——通道关闭时就地提示，不发起
		const isEmail = trimmedIdentifier.includes("@");
		if (!isEmail && !phoneEnabled) {
			setError(t("emailRequired"));
			return;
		}
		try {
			const { data } = await runRecover({ variables: { identifier: trimmedIdentifier } });
			if (data?.flashbackRecover) {
				setPhase(isEmail ? "sent" : "code");
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

			{phase === "sent" && <p className="fb-hint">{t("sentHint")}</p>}

			{phase === "code" && (
				<div className="fb-recover-form">
					<p className="fb-hint">{t("codeHint")}</p>
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
