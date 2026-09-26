"use client";

import { useEffect, useRef, useState } from "react";
import { useTranslations } from "next-intl";
import { Link, useRouter } from "@/i18n/navigation";
import { client } from "@/lib/apollo-client";
import { graphqlErrorDetails } from "@/lib/graphql/auth";
import { FLASHBACK_ARCHIVES, FLASHBACK_CAPSULE, type FlashbackCapsuleArchive } from "@/lib/graphql/flashback";
import EventRoster from "./event-roster";
import InvalidToken, { type InvalidTokenReason } from "./invalid-token";
import { useStageTitleFocus } from "./use-reduced-motion";

/** token 会话内持有（与 enter / capsule 同 key；URL 读入后即刻清除，KTD2） */
const TOKEN_STORAGE_KEY = "flashback.token";

type State =
	| { phase: "loading" }
	| { phase: "invalid"; reason: InvalidTokenReason }
	| { phase: "missing" }
	| { phase: "login" }
	/** viewer = 已登录无档案（#933 相册读面）：返回闪念间首页而非胶囊 */
	| { phase: "ok"; archive: FlashbackCapsuleArchive; viewer: boolean };

/**
 * 场次页（E 的 event 步 / R12 场次名册）：长廊点某一格 → 这一场的完整名册——
 * 统计行（报名/走进教室/已回来）+「这一场的人」3 列拍立得网格
 * （已寄出=显影卡带名字 / 未回来=雾卡「王** · 城市 · 职业 · 答案还在等她」）
 * + 找回 CTA（三级视角②：参加过没回来的人从这里认领自己那张）。
 *
 * 数据（#933 相册对所有已登录用户开放）：有档案读 capsule；已登录无档案读
 * flashbackArchives（与胶囊名册同一套白名单投影：roster 混排 attended 与
 * not_selected（圆梦线进名册，applied_at asc）、未寄出者只有姓氏隐名）；
 * 未登录 → 登录页，登录后回到这一场。
 * 统计行不编造：报名数、走进教室（后端 attendedCount 权威字段）缺失（导入未带该列）
 * 与教练数（R22：教练表属其他场次）都直接不显示，而不是填 0——#933 起未寄出者
 * 不下发参与类型，名册也数不出走进教室的人（事实纪律）。
 */
export default function EventDetail({ eventKey }: { eventKey: string }) {
	const t = useTranslations("flashback.event");
	const [state, setState] = useState<State>({ phase: "loading" });
	const router = useRouter();
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
				setState(archive ? { phase: "ok", archive, viewer: false } : { phase: "missing" });
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
				if (code === "flashback_auth_required") {
					setState({ phase: "login" });
					return;
				}
				if (code === "flashback_person_not_bound") {
					client
						.query({ query: FLASHBACK_ARCHIVES, fetchPolicy: "network-only" })
						.then(({ data }) => {
							const archive = data?.flashbackArchives?.archives.find((item) => item.key === eventKey);
							setState(archive ? { phase: "ok", archive, viewer: true } : { phase: "missing" });
						})
						.catch(() => setState({ phase: "missing" }));
					return;
				}
				setState({ phase: "missing" });
			});
	}, [eventKey]);

	// #933 未登录想看相册 → 登录页（replace：返回键不会回到这一页再跳一次），登录后回到这一场。
	// 跳转放 effect：渲染期调用 router.replace 在严格模式 / 重渲染下会重复导航；router 引用
	// 不保证稳定，用 ref 记住已跳过的场次，同一场只跳一次
	const redirectedFor = useRef<string | null>(null);
	useEffect(() => {
		if (state.phase === "login" && redirectedFor.current !== eventKey) {
			redirectedFor.current = eventKey;
			router.replace(`/login?next=${encodeURIComponent(`/flashback/event/${eventKey}`)}`);
		}
	}, [state.phase, eventKey, router]);

	if (state.phase === "invalid") {
		return (
			<div className="fb-root">
				<InvalidToken reason={state.reason} />
			</div>
		);
	}

	if (state.phase === "login") return null;

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

	const { archive, viewer } = state;
	const returned = archive.roster.filter((entry) => entry.sentToWallAt).length;

	return (
		<div className="fb-root fb-event">
			<Link href={viewer ? "/flashback" : "/flashback/capsule"} className="fb-event-back">
				{viewer ? t("backHome") : t("back")}
			</Link>
			<h2 className="fb-event-title" ref={titleRef} tabIndex={-1}>
				{archive.occurredOn?.replace(/-/g, ".") ?? archive.key}
				{archive.name ? ` · ${archive.name}` : ""}
			</h2>
			<p className="fb-event-stats">
				{/* 报名数缺失（导入未带该列）时不显示——不编造 0（教练数同理：本场无数据） */}
				{archive.appliedCount ? <span>{t("applied", { count: archive.appliedCount })}</span> : null}
				{archive.attendedCount ? <span>{t("attended", { count: archive.attendedCount })}</span> : null}
				<span className="fb-event-returned">{t("returned", { count: returned })}</span>
			</p>
			<p className="fb-event-section">
				{t("peopleTitle")} · {t("peopleHint")}
			</p>
			<EventRoster archive={archive} />
			<div className="fb-event-find">
				<Link href="/flashback" className="fb-cta fb-cta-primary fb-dream-cta">
					{t("findMine")}
				</Link>
			</div>
		</div>
	);
}
