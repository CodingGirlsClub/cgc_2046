"use client";

import { useEffect, useState } from "react";
import { useTranslations } from "next-intl";
import { Link } from "@/i18n/navigation";
import { client } from "@/lib/apollo-client";
import { FLASHBACK_PUBLIC_PROFILE, type FlashbackPublicProfile } from "@/lib/graphql/flashback";

/**
 * 实名支持档案页（U6/R31 credited 档）：仅已发布 public_slug 者可解析；
 * 未授权/不存在 → 404 态（带回首页出口——计划 U6 空态契约）。
 */
export default function ProfileView({ slug }: { slug: string }) {
	const t = useTranslations("flashback.profile");

	const [profile, setProfile] = useState<FlashbackPublicProfile | null | "loading">("loading");

	useEffect(() => {
		client
			.query({ query: FLASHBACK_PUBLIC_PROFILE, variables: { slug }, fetchPolicy: "network-only" })
			.then(({ data }) => setProfile(data?.flashbackPublicProfile ?? null))
			.catch(() => setProfile(null));
	}, [slug]);

	if (profile === "loading") {
		return (
			<div className="fb-root fb-stage" role="status">
				{t("loading")}
			</div>
		);
	}

	if (!profile) {
		return (
			<div className="fb-root fb-stage fb-stage-pad">
				<h1 className="fb-stage-title">{t("notFoundTitle")}</h1>
				<p className="fb-lead">{t("notFoundBody")}</p>
				<div className="fb-invalid-actions">
					<Link href="/flashback">{t("backHome")}</Link>
				</div>
			</div>
		);
	}

	return (
		<div className="fb-root fb-public">
			<article className="fb-profile">
				<div className="fb-kicker">IN A FLASH · {t("kicker")}</div>
				<h1 className="fb-stage-title">{profile.fullName}</h1>
				<p className="fb-hint">
					{[profile.year, profile.eventName ?? profile.city].filter(Boolean).join(" · ")}
				</p>
				<blockquote className="fb-quote-text">“{profile.quote}”</blockquote>
				{profile.creditedNote && <p className="fb-lead">{profile.creditedNote}</p>}
			</article>
			<footer className="fb-capsule-footer">
				<p className="fb-hint">{t("footer")}</p>
			</footer>
		</div>
	);
}
