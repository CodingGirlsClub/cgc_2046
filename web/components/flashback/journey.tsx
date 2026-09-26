"use client";

import { useCallback, useEffect, useState } from "react";
import { useTranslations } from "next-intl";
import { useRouter } from "@/i18n/navigation";
import { useMutation } from "@apollo/client/react";
import { client } from "@/lib/apollo-client";
import { graphqlErrorDetails, REQUEST_PHONE_CODE } from "@/lib/graphql/auth";
import {
	FLASHBACK_ENTER,
	FLASHBACK_CLAIM,
	FLASHBACK_MARK_REVEALED,
	FLASHBACK_SUBMIT_TODAY,
	FLASHBACK_SEND_TO_WALL,
	FLASHBACK_SET_QUOTE_LICENSE,
	FLASHBACK_REGISTER_BIND,
	FLASHBACK_DREAM_TARGET,
	FLASHBACK_ADJUST_FOG,
	FLASHBACK_ADJUST_TODAY_FOG,
	type FlashbackDreamTarget,
	type FlashbackEnterResult,
	type FlashbackTodayInput,
} from "@/lib/graphql/flashback";
import Intro from "./intro";
import Desk from "./desk";
import type { QuizChoice } from "./quiz";
import { emptyTodayForm, type TodayFormState } from "./write";
import SendRegister from "./send-register";
import InvalidToken, { type InvalidTokenReason } from "./invalid-token";
import { usePrefersReducedMotion } from "./use-reduced-motion";

/**
 * 阶段只剩两站（原型 E/F 的场景连续性）：开场 → 散照桌面（散照/问答/显影/
 * 翻面写字同场景）→ 寄出浮层覆盖其上，不跳页。
 */
type Stage = "intro" | "desk";

/** URL 读入的 token 即刻清除，sessionStorage 仅会话内持有（KTD2；reset-password 先例） */
const TOKEN_STORAGE_KEY = "flashback.token";

/** 表单态 → 提交 input（剔除金句授权本地字段——它走独立 mutation） */
function toTodayInput(form: TodayFormState): FlashbackTodayInput {
	return {
		nowStatus: form.nowStatus,
		want: form.want,
		need: form.need,
		say: form.say,
		wantGiveTags: form.wantGiveTags,
		mobilizationJoin1024: form.mobilizationJoin1024,
		mobilizationHelpPromote: form.mobilizationHelpPromote,
		mobilizationDonateIntent: form.mobilizationDonateIntent,
		mobilizationVolunteerLead: form.mobilizationVolunteerLead,
		newsletterOptIn: form.newsletterOptIn,
		reconnectTags: form.reconnectTags,
	};
}

/**
 * 首程旅程状态机（U4）：enter 分流 → 记忆线（快门→散照→问答→显影→翻面
 * 写字→寄出+注册引导）/ 圆梦线（信封→显影+圆梦 CTA 两态→写字→寄出）。
 *
 * 回访（AE9）：progress.today 已存在（链接曾走到写字）→ 跳过仪式直达
 * 胶囊，不重走快门。阶段切换播放白光一闪（reduced-motion 跳过）。
 * 完成后进 /flashback/capsule（token 经 sessionStorage，不落 URL）。
 */
export default function Journey() {
	const t = useTranslations("flashback.journey");
	const router = useRouter();
	const reduced = usePrefersReducedMotion();

	const [token, setToken] = useState<string | null>(null);
	const [entering, setEntering] = useState(true);
	const [invalidReason, setInvalidReason] = useState<InvalidTokenReason | null>(null);
	const [enterError, setEnterError] = useState(false);
	const [entry, setEntry] = useState<FlashbackEnterResult | null>(null);
	const [stage, setStage] = useState<Stage>("intro");
	const [quizChoice, setQuizChoice] = useState<QuizChoice | null>(null);
	const [form, setForm] = useState<TodayFormState>(emptyTodayForm);
	const [flash, setFlash] = useState(false);
	const [startOnBack, setStartOnBack] = useState(false);
	/** 寄出浮层（原型 E/F：覆盖在显影场景上，不换页） */
	const [sendOpen, setSendOpen] = useState(false);
	const [dreamTarget, setDreamTarget] = useState<FlashbackDreamTarget | null>(null);

	const [runClaim] = useMutation(FLASHBACK_CLAIM);
	const [runEnter] = useMutation(FLASHBACK_ENTER);
	const [runMarkRevealed] = useMutation(FLASHBACK_MARK_REVEALED);
	const [runSubmitToday] = useMutation(FLASHBACK_SUBMIT_TODAY);
	const [runSendToWall] = useMutation(FLASHBACK_SEND_TO_WALL);
	const [runSetQuoteLicense] = useMutation(FLASHBACK_SET_QUOTE_LICENSE);
	const [runRegisterBind] = useMutation(FLASHBACK_REGISTER_BIND);
	const [runAdjustFog] = useMutation(FLASHBACK_ADJUST_FOG);
	const [runAdjustTodayFog] = useMutation(FLASHBACK_ADJUST_TODAY_FOG);
	const [runRequestPhoneCode] = useMutation(REQUEST_PHONE_CODE);

	const goTo = useCallback(
		(next: Stage) => {
			if (!reduced) {
				setFlash(true);
				window.setTimeout(() => setFlash(false), 80);
			}
			setStage(next);
		},
		[reduced],
	);

	useEffect(() => {
		const url = new URL(window.location.href);
		const raw = url.searchParams.get("token");
		// token 从 URL 读入后即刻清除（KTD2；reset-password 先例：URL 变更同步，
		// 状态切换走 timer 0——避免 effect 内同步 setState 级联渲染）
		if (raw) {
			url.searchParams.delete("token");
			window.history.replaceState(window.history.state, "", `${url.pathname}${url.search}${url.hash}`);
			window.sessionStorage.setItem(TOKEN_STORAGE_KEY, raw);
		}
		const held = raw ?? window.sessionStorage.getItem(TOKEN_STORAGE_KEY);

		const timer = window.setTimeout(() => {
			if (!held) {
				setInvalidReason("flashback_token_not_found");
				setEntering(false);
				return;
			}
			setToken(held);

			runEnter({ variables: { token: held } })
				.then(({ data }) => {
					const result = data?.flashbackEnter;
					if (!result) {
						setEnterError(true);
						return;
					}
				// 回访（AE9）：已寄出（完成态）→ 直达胶囊；已填今天但未寄出
				// → 跳过仪式直达写字（否则 todaySlot 的「去寄出」出口会把用户
				// 弹回胶囊，死循环——e2e 实测）
				const revisitToday = result.progress?.today;
				if (revisitToday?.sentToWallAt) {
					router.push("/flashback/capsule");
					return;
				}
				if (revisitToday) {
					// 已填今天未寄出 → 跳过仪式直达桌面显影态（背面书写面）
					//（第 3 件：写字并入卡背面；AE9 回访不重走快门）
					setStartOnBack(true);
					setStage("desk");
				}
					setEntry(result);
					setEntering(false);
				})
				.catch((error) => {
					const code = graphqlErrorDetails(error)?.code;
					if (
						code === "flashback_token_not_found" ||
						code === "flashback_token_claimed" ||
						code === "flashback_token_revoked"
					) {
						window.sessionStorage.removeItem(TOKEN_STORAGE_KEY);
						setInvalidReason(code);
					} else {
						setEnterError(true);
					}
					setEntering(false);
				});
		}, 0);

		return () => window.clearTimeout(timer);
		// eslint-disable-next-line react-hooks/exhaustive-deps -- 进入流程一次性
	}, []);

	// 圆梦线：显影前取 CTA 两态数据（本城场次；失败按无场次兜底）
	useEffect(() => {
		if (entry?.line !== "dream" || !entry.profile) return;
		client
			.query({
				query: FLASHBACK_DREAM_TARGET,
				variables: { city: entry.profile.city ?? null },
				fetchPolicy: "network-only",
			})
			.then(({ data }) => setDreamTarget(data?.flashbackDreamTarget ?? null))
			.catch(() => setDreamTarget(null));
	}, [entry]);

	const finish = useCallback(() => router.push("/flashback/capsule"), [router]);

	if (entering) {
		return (
			<div className="fb-root fb-stage" role="status">
				{t("loading")}
			</div>
		);
	}

	if (invalidReason) {
		return (
			<div className="fb-root">
				<InvalidToken reason={invalidReason} />
			</div>
		);
	}

	if (enterError || !entry?.profile) {
		return (
			<div className="fb-root fb-stage">
				<p role="alert" className="fb-lead">
					{t("enterError")}
				</p>
				<button type="button" className="fb-cta" onClick={() => window.location.reload()}>
					{t("retry")}
				</button>
			</div>
		);
	}

	const { profile } = entry;
	const freeAnswers = (profile.answers ?? []).filter((answer) =>
		["self_intro", "funny_thing", "os", "social_media"].includes(answer.questionKey),
	);

	return (
		<div className="fb-root">
			{flash && <div className="fb-flash-overlay" aria-hidden="true" />}
			{stage === "intro" && (
				<Intro
					line={entry.line}
					profile={profile}
					onShutter={() => goTo("desk")}
					onOpen={() => goTo("desk")}
				/>
			)}
			{stage === "desk" && (
				<Desk
					profile={profile}
					line={entry.line}
					dreamTarget={dreamTarget}
					quizChoice={quizChoice}
					startOnBack={startOnBack}
					role={profile.role}
					answers={freeAnswers}
					progress={entry.progress ?? { bound: false, quoteLevel: "off" }}
					scatter={entry.scatter?.entries ?? []}
					onAnswer={(choice) => setQuizChoice(choice)}
					onRevealed={() => {
						if (token) void runMarkRevealed({ variables: { token } });
					}}
					onWriteNext={(nextForm) => {
						setForm(nextForm);
						// 浮层化：不换页，直接盖在显影场景上（原型 E/F）
						setSendOpen(true);
					}}
				/>
			)}
			{sendOpen && token && (
				<div className="fb-send-overlay" role="dialog" aria-modal="true" aria-labelledby="fb-send-title">
					<SendRegister
					form={form}
					bound={entry.progress?.bound ?? false}
					onClaim={async () => {
						const { data } = await runClaim({ variables: { token } });
						if (!data?.flashbackClaim.bound) return false;
						window.sessionStorage.removeItem(TOKEN_STORAGE_KEY);
						return true;
					}}
					answers={freeAnswers}
					initialTodayFogSpans={entry.progress?.today?.fogSpans}
					maskedPhone={entry.progress?.maskedPhone}
					maskedEmail={entry.progress?.maskedEmail}
					onAdjustFog={async (answerId, spans) => {
						const { data } = await runAdjustFog({ variables: { token, answerId, spans } });
						return Boolean(data?.flashbackAdjustFog);
					}}
					onAdjustTodayFog={async (field, spans) => {
						const { data } = await runAdjustTodayFog({ variables: { token, field, spans } });
						return Boolean(data?.flashbackAdjustTodayFog);
					}}
					onBack={() => setSendOpen(false)}
					onSubmitToday={async (input) => {
						const { data } = await runSubmitToday({
							variables: { token, input: toTodayInput(input) },
						});
						return Boolean(data?.flashbackSubmitToday.today);
					}}
					onSetQuoteLicense={async (formState) => {
						const { data } = await runSetQuoteLicense({
							variables: {
								token,
								level: formState.quoteLevel,
								chosenQuoteSpans:
									formState.quoteLevel !== "off" && (formState.quotePicks?.length ?? 0) > 0
										? formState.quotePicks
										: undefined,
								creditedNote:
									formState.quoteLevel === "credited" ? formState.creditedNote : undefined,
							},
						});
						return Boolean(data?.flashbackSetQuoteLicense);
					}}
					onSendToWall={async () => {
						const { data } = await runSendToWall({ variables: { token } });
						return Boolean(data?.flashbackSendToWall.sentToWallAt);
					}}
					onRegisterBind={async (phone, code) => {
						const { data } = await runRegisterBind({ variables: { token, phone, code } });
						return Boolean(data?.flashbackRegisterBind.bound);
					}}
					onRequestPhoneCode={async (phone, purpose) => {
						try {
							const { data } = await runRequestPhoneCode({ variables: { phone, purpose } });
							return Boolean(data?.requestPhoneCode?.sent);
						} catch {
							return false;
						}
					}}
						onDone={finish}
					/>
				</div>
			)}
		</div>
	);
}
