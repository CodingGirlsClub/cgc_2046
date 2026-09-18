"use client";

import { useCallback, useEffect, useState } from "react";
import { useTranslations } from "next-intl";
import { Link } from "@/i18n/navigation";
import { client } from "@/lib/apollo-client";
import { graphqlErrorDetails } from "@/lib/graphql/auth";
import {
	FLASHBACK_CAPSULE,
	type FlashbackCapsule,
} from "@/lib/graphql/flashback";
import Corridor from "./corridor";
import ActionBoard from "./action-board";
import CardExport from "./card-export";
import DeleteAccount from "./delete-account";
import InvalidToken from "./invalid-token";
import { useStageTitleFocus } from "./use-reduced-motion";

/** token 会话内持有（与 enter 页同 key；URL 读入后即刻清除，KTD2） */
const TOKEN_STORAGE_KEY = "flashback.token";

type CapsuleState =
	| { phase: "loading" }
	| { phase: "invalid"; reason: "flashback_token_not_found" | "flashback_token_claimed" | "flashback_token_revoked" }
	| { phase: "authRequired" }
	| { phase: "error" }
	| { phase: "ok"; token: string | null; capsule: FlashbackCapsule };

/**
 * 时间胶囊主体（U5）：corridor（场次时间轴+名册+今天格）+ 行动板 + 卡片导出。
 * token 从 URL/sessionStorage 读；登录态（已绑定账号）由 GraphQL context 承载
 * （R28 回访正门——AE9 回访直达胶囊不重走仪式的落点）。
 */
export default function CapsuleView() {
	const t = useTranslations("flashback.capsule");
	const [state, setState] = useState<CapsuleState>({ phase: "loading" });
	const [reloadKey, setReloadKey] = useState(0);
	/** 城市钉筛选（R34）：null = 全部；切换即带 city 重拉（服务端过滤名册与行动板） */
	const [city, setCity] = useState<string | null>(null);
	const titleRef = useStageTitleFocus<HTMLHeadingElement>([state.phase]);

	const reload = useCallback(() => {
		setReloadKey((key) => key + 1);
	}, []);

	useEffect(() => {
		const url = new URL(window.location.href);
		const raw = url.searchParams.get("token");
		if (raw) {
			url.searchParams.delete("token");
			window.history.replaceState(window.history.state, "", `${url.pathname}${url.search}${url.hash}`);
			window.sessionStorage.setItem(TOKEN_STORAGE_KEY, raw);
		}
		const held = raw ?? window.sessionStorage.getItem(TOKEN_STORAGE_KEY);

		// 非首次拉取（城市切换）沿用已渲染的胶囊，新数据到达再覆盖——筛选不闪 loading 面。
		// microtask 包裹避开 effect 内同步 setState 级联渲染（react-hooks/set-state-in-effect）。
		Promise.resolve().then(() =>
			setState((prev) => (prev.phase === "ok" ? prev : { phase: "loading" })),
		)

		client
			.query({ query: FLASHBACK_CAPSULE, variables: { token: held, city }, fetchPolicy: "network-only" })
			.then(({ data }) => {
				const capsule = data?.flashbackCapsule;
				if (capsule) {
					setState({ phase: "ok", token: held, capsule });
					return;
				}
				// null 不该出现（手写 field 失败走顶层错误）——防御态
				setState({ phase: "error" });
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
				} else if (code === "flashback_auth_required" || code === "flashback_person_not_bound") {
					setState({ phase: "authRequired" });
				} else {
					setState({ phase: "error" });
				}
			});
	}, [reloadKey, city]);

	if (state.phase === "loading") {
		return (
			<div className="fb-root fb-stage" role="status">
				{t("loading")}
			</div>
		);
	}

	if (state.phase === "invalid") {
		return (
			<div className="fb-root">
				<InvalidToken reason={state.reason} />
			</div>
		);
	}

	if (state.phase === "authRequired") {
		return (
			<div className="fb-root fb-stage fb-stage-pad">
				<h2 className="fb-stage-title" ref={titleRef} tabIndex={-1}>
					{t("authRequiredTitle")}
				</h2>
				<p className="fb-lead">{t("authRequiredBody")}</p>
				<div className="fb-invalid-actions">
					<Link href="/flashback">{t("authRequiredAction")}</Link>
				</div>
			</div>
		);
	}

	if (state.phase === "error" || !state.capsule) {
		return (
			<div className="fb-root fb-stage">
				<p role="alert" className="fb-lead">
					{t("error")}
				</p>
				<button type="button" className="fb-cta" onClick={reload}>
					{t("retry")}
				</button>
			</div>
		);
	}

	const { capsule, token } = state;

	return (
		<div className="fb-root fb-capsule">
			<header className="fb-capsule-header">
				<h2 className="fb-stage-title" ref={titleRef} tabIndex={-1}>
					{t("title")}
				</h2>
				<p className="fb-hint">{t("subtitle")}</p>
			</header>
			{capsule.cities.length > 1 && (
				<div className="fb-city-pins" role="group" aria-label={t("cityAria")}>
					<button
						type="button"
						className={`fb-city-pin${city === null ? " fb-city-pin--active" : ""}`}
						aria-pressed={city === null}
						onClick={() => setCity(null)}
					>
						{t("cityAll")}
					</button>
					{capsule.cities.map((name) => (
						<button
							type="button"
							key={name}
							className={`fb-city-pin${city === name ? " fb-city-pin--active" : ""}`}
							aria-pressed={city === name}
							onClick={() => setCity(name)}
						>
							{name}
						</button>
					))}
				</div>
			)}
			<Corridor capsule={capsule} cityFiltered={city !== null} />
			<ActionBoard
				cards={capsule.actionCards}
				token={token}
				onChanged={reload}
				filtered={city !== null}
			/>
			<CardExport me={capsule.me} />
			<footer className="fb-capsule-footer">
				<p className="fb-hint">{t("footerHint")}</p>
				<DeleteAccount token={token} />
			</footer>
		</div>
	);
}
