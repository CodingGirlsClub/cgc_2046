"use client";

import { useEffect, useState } from "react";
import { useTranslations } from "next-intl";
import { Link } from "@/i18n/navigation";
import { client } from "@/lib/apollo-client";
import { graphqlErrorDetails } from "@/lib/graphql/auth";
import { FLASHBACK_CAPSULE, type FlashbackCapsuleArchive } from "@/lib/graphql/flashback";
import EventRoster from "./event-roster";
import InvalidToken, { type InvalidTokenReason } from "./invalid-token";
import { useStageTitleFocus } from "./use-reduced-motion";

/** token 会话内持有（与 enter / capsule 同 key；URL 读入后即刻清除，KTD2） */
const TOKEN_STORAGE_KEY = "flashback.token";

type State =
	| { phase: "loading" }
	| { phase: "invalid"; reason: InvalidTokenReason }
	| { phase: "missing" }
	| { phase: "ok"; archive: FlashbackCapsuleArchive };

/**
 * 场次页（E 的 event 步 / R12 场次名册）：长廊点某一格 → 这一场的完整名册——
 * 统计行（报名/走进教室/已回来）+「这一场的人」3 列拍立得网格
 * （已寄出=显影卡带名字 / 未回来=雾卡「王** · 城市 · 职业 · 答案还在等她」）
 * + 找回 CTA（三级视角②：参加过没回来的人从这里认领自己那张）。
 *
 * 数据复用 capsule 投影（白名单 DTO 同一份：roster 已按 R12 只含 attended、
 * 未寄出者仅姓氏隐名）——不新增后端读面，也就不新增泄露面。
 * 统计行不编造：报名数缺失（导入未带该列）与教练数（R22：教练表属其他场次）
 * 都直接不显示，而不是填 0。
 */
export default function EventDetail({ eventKey }: { eventKey: string }) {
	const t = useTranslations("flashback.event");
	const [state, setState] = useState<State>({ phase: "loading" });
	const titleRef = useStageTitleFocus<HTMLHeadingElement>([eventKey]);

	useEffect(() => {
		const url = new URL(window.location.href);
		const raw = url.searchParams.get("token");
		if (raw) {
			url.searchParams.delete("token");
			window.history.replaceState(window.history.state, "", `${url.pathname}${url.search}${url.hash}`);
			window.sessionStorage.setItem(TOKEN_STORAGE_KEY, raw);
		}
		const held = raw ?? window.sessionStorage.getItem(TOKEN_STORAGE_KEY);

		Promise.resolve().then(() => setState({ phase: "loading" }));

		client
			.query({ query: FLASHBACK_CAPSULE, variables: { token: held }, fetchPolicy: "network-only" })
			.then(({ data }) => {
				const archive = data?.flashbackCapsule?.archives.find((item) => item.key === eventKey);
				setState(archive ? { phase: "ok", archive } : { phase: "missing" });
			})
			.catch((error) => {
				const code = graphqlErrorDetails(error)?.code;
				if (
					code === "flashback_token_not_found" ||
					code === "flashback_token_claimed" ||
					code === "flashback_token_revoked"
				) {
					window.sessionStorage.removeItem(TOKEN_STORAGE_KEY);
					setState({ phase: "invalid", reason: code });
					return;
				}
				setState({ phase: "missing" });
			});
	}, [eventKey]);

	if (state.phase === "invalid") {
		return (
			<div className="fb-root">
				<InvalidToken reason={state.reason} />
			</div>
		);
	}

	if (state.phase === "missing") {
		return (
			<div className="fb-root fb-stage fb-stage-pad">
				<p className="fb-lead">{t("missing")}</p>
				<Link href="/flashback/capsule" className="fb-cta fb-cta-primary fb-dream-cta">
					{t("back")}
				</Link>
			</div>
		);
	}

	if (state.phase !== "ok") {
		return (
			<div className="fb-root fb-stage" role="status">
				{t("loading")}
			</div>
		);
	}

	const { archive } = state;
	const returned = archive.roster.filter((entry) => entry.sentToWallAt).length;
	const attended = archive.attendedCount ?? archive.roster.length;

	return (
		<div className="fb-root fb-event">
			<Link href="/flashback/capsule" className="fb-event-back">
				{t("back")}
			</Link>
			<h2 className="fb-event-title" ref={titleRef} tabIndex={-1}>
				{archive.occurredOn?.replace(/-/g, ".") ?? archive.key}
				{archive.name ? ` · ${archive.name}` : ""}
			</h2>
			<p className="fb-event-stats">
				{/* 报名数缺失（导入未带该列）时不显示——不编造 0（教练数同理：本场无数据） */}
				{archive.appliedCount ? <span>{t("applied", { count: archive.appliedCount })}</span> : null}
				<span>{t("attended", { count: attended })}</span>
				<span className="fb-event-returned">{t("returned", { count: returned })}</span>
			</p>
			<p className="fb-event-section">
				{t("peopleTitle")} · {t("peopleHint")}
			</p>
			<EventRoster archive={archive} variant="grid" />
			<div className="fb-event-find">
				<Link href="/flashback" className="fb-cta fb-cta-primary fb-dream-cta">
					{t("findMine")}
				</Link>
			</div>
		</div>
	);
}
