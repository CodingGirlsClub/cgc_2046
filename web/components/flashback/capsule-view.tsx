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
import Corridor, { useWideCorridor } from "./corridor";
import CardExport from "./card-export";
import QuoteLicensePanel from "./quote-license-panel";
import AnswersFog from "./answers-fog";
import DeleteAccount from "./delete-account";
import InvalidToken from "./invalid-token";
import { useStageTitleFocus } from "./use-reduced-motion";

/** token 会话内持有（与 enter 页同 key；URL 读入后即刻清除，KTD2） */
const TOKEN_STORAGE_KEY = "flashback.token";
/** 相册开放告知已读（#933 一次性，与小程序长廊同规则；跨会话记住，放 localStorage） */
const ALBUM_NOTICE_KEY = "flashback.album_notice_done";

/**
 * #933 相册开放告知：开放前就寄出的人第一次回来时看到可见范围变了；进来时还没寄出的人寄出前
 * 会读到新的可见范围文案——直接置位，寄出后不再打扰。sent = null 表示胶囊还没到。
 */
function useAlbumNotice(sent: boolean | null): [boolean, () => void] {
	const [show, setShow] = useState(false);
	useEffect(() => {
		if (sent === null || window.localStorage.getItem(ALBUM_NOTICE_KEY)) return;
		// microtask 包裹：同本文件既有写法，避开 effect 内同步 setState（react-hooks/set-state-in-effect）
		if (sent) Promise.resolve().then(() => setShow(true));
		else window.localStorage.setItem(ALBUM_NOTICE_KEY, "1");
	}, [sent]);
	const dismiss = useCallback(() => {
		window.localStorage.setItem(ALBUM_NOTICE_KEY, "1");
		setShow(false);
	}, []);
	return [show, dismiss];
}

type CapsuleState =
	| { phase: "loading" }
	| { phase: "invalid"; reason: "flashback_token_not_found" | "flashback_token_claimed" | "flashback_token_revoked" }
	| { phase: "authRequired"; signedIn: boolean }
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
	const wide = useWideCorridor();
	const titleRef = useStageTitleFocus<HTMLHeadingElement>([state.phase]);
	const [albumNotice, dismissAlbumNotice] = useAlbumNotice(
		state.phase === "ok" && state.capsule ? Boolean(state.capsule.me.today?.sentToWallAt) : null,
	);

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

		const load = (token: string | null) =>
			client
				.query({ query: FLASHBACK_CAPSULE, variables: { token, city }, fetchPolicy: "network-only" })
				.then(({ data }) => ({ token, capsule: data?.flashbackCapsule }));

		load(held)
			.catch((error) => {
				// 收好（任一路径）会作废档案的全部链接，会话里那条随之失效：丢掉它、改用登录身份重拉。
				// 不看 useAuthed——手机号收好刚换过会话，登录态上下文可能还是旧值；重拉失败再落失效页。
				if (held && graphqlErrorDetails(error)?.code === "flashback_token_claimed") {
					window.sessionStorage.removeItem(TOKEN_STORAGE_KEY);
					return load(null).catch(() => Promise.reject(error));
				}
				throw error;
			})
			.then(({ token, capsule }) => {
				if (capsule) {
					setState({ phase: "ok", token, capsule });
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
					setState({ phase: "authRequired", signedIn: code === "flashback_person_not_bound" });
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
					{t(state.signedIn ? "unboundTitle" : "authRequiredTitle")}
				</h2>
				<p className="fb-lead">{t(state.signedIn ? "unboundBody" : "authRequiredBody")}</p>
				<div className="fb-invalid-actions">
					{!state.signedIn && <Link href="/login?next=%2Fflashback%2Fcapsule">{t("login")}</Link>}
					<Link href="/flashback#recover">{t("authRequiredAction")}</Link>
					{state.signedIn && <>
						<Link href="/flashback/wishes">{t("writeWish")}</Link>
						<Link href="/flashback/wishes/mine">{t("myWishes")}</Link>
					</>}
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
			</header>
			{albumNotice && (
				<aside className="fb-album-notice" data-testid="fb-album-notice">
					<p>{t("albumNotice")}</p>
					<button type="button" onClick={dismissAlbumNotice}>
						{t("albumNoticeOk")}
					</button>
				</aside>
			)}
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
			{/* 提示分端（用户定稿）：位置照原型 D——城市钉下方；宽屏横滑照原型逐字
			    语序（尾注 = 当前城市/全部城市），窄屏与小程序保留竖滑版 */}
			<p className="fb-hint fb-corridor-scrollhint">
				{wide ? t("scrollHintWide", { city: city ?? t("cityAllWide") }) : t("scrollHint")}
			</p>
			<Corridor capsule={capsule} cityFiltered={city !== null} token={token} onChanged={reload} />
			<CardExport me={capsule.me} />
			<div className="fb-today-actions">
				<AnswersFog me={capsule.me} token={token} onChanged={reload} />
			</div>
			<QuoteLicensePanel me={capsule.me} token={token} onChanged={reload} />
			<footer className="fb-capsule-footer">
				<p className="fb-hint">{t("footerHint")}</p>
				<DeleteAccount token={token} />
			</footer>
		</div>
	);
}
