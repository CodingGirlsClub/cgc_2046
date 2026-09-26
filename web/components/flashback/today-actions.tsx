"use client";

import { useEffect, useState } from "react";
import { useTranslations } from "next-intl";
import { client } from "@/lib/apollo-client";
import {
	FLASHBACK_RETRACT,
	FLASHBACK_SEND_TO_WALL,
	FLASHBACK_SUBMIT_TODAY,
	FLASHBACK_ADJUST_TODAY_FOG,
	sentencesWithFogMark,
	TODAY_FIELDS,
	type FlashbackCapsuleMe,
	type FlashbackFogSpan,
} from "@/lib/graphql/flashback";
import { normalizeSpans, sameSpans, toggleSpanIn } from "./fog-toggle";
import { useDialogA11y } from "../modal-a11y";

/** 保存成功轻反馈后自动关弹层的停留时长（回到胶囊视图，刷新走 onChanged） */
const SAVED_LINGER_MS = 600;

/**
 * 胶囊「我的卡」动作（今天格内）：
 *
 * - G2「编辑今天的你」：token 持有者与登录态回访者都可用（submitToday 双入口，
 *   token 空值走登录会话）。弹层预填 me.today 四字段；保存 = 覆盖式 submitToday；
 *   **已寄出者**紧接幂等 flashbackSendToWall（与小程序 MyCard「写完寄出」同款语义，
 *   确保墙卡即新内容）——#931 起 sendToWall 双入口，登录态无 token 以 null 发出；
 *   未寄出者只存草稿。
 *   失败错误 + 原钮重试；成功后轻反馈并关弹层回到胶囊（父级 onChanged 重拉数据）。
 * - G3「撤下」：已寄出即渲染——#931 起 flashbackRetract 双入口（token 或登录态）。
 *   二次确认弹层讲清后果，
 *   确认即撤 + 关弹层 + onChanged 刷新（回到未寄出态由 U5 既有呈现兜底）。
 *
 * 弹层 a11y 照 modal-a11y 先例（开框聚焦 + Esc 关 + Tab trap）；样式全走
 * flashback.css（零内联 style）。
 */
export default function TodayActions({
	me,
	token,
	onChanged,
}: {
	me: FlashbackCapsuleMe;
	token: string | null;
	onChanged: () => void;
}) {
	const t = useTranslations("flashback.todaySlot");
	const [editing, setEditing] = useState(false);
	const [confirmRetract, setConfirmRetract] = useState(false);

	const sent = Boolean(me.today?.sentToWallAt);

	return (
		<>
			<div className="fb-today-actions">
				<button type="button" className="fb-cta" onClick={() => setEditing(true)}>
					{t("editEntry")}
				</button>
				{/* 已寄出即可撤下（#931 双入口）；未寄出无可撤 */}
				{sent && (
					<button type="button" className="fb-cta" onClick={() => setConfirmRetract(true)}>
						{t("retractEntry")}
					</button>
				)}
			</div>
			{editing && (
				<EditTodayDialog
					me={me}
					token={token}
					sentAtStart={sent}
					onClose={() => setEditing(false)}
					onSaved={() => {
						setEditing(false);
						onChanged();
					}}
				/>
			)}
			{confirmRetract && (
				<RetractDialog
					token={token}
					onClose={() => setConfirmRetract(false)}
					onRetracted={() => {
						setConfirmRetract(false);
						onChanged();
					}}
				/>
			)}
		</>
	);
}

/** 编辑弹层：四字段覆盖式保存；已寄出者保存后幂等补寄 */
function EditTodayDialog({
	me,
	token,
	sentAtStart,
	onClose,
	onSaved,
}: {
	me: FlashbackCapsuleMe;
	token: string | null;
	/** 打开编辑时的寄出态（决定保存后是否补寄；编辑期间墙态按此刻为准） */
	sentAtStart: boolean;
	onClose: () => void;
	onSaved: () => void;
}) {
	const t = useTranslations("flashback.todaySlot");
	const writeT = useTranslations("flashback.write");
	const sendT = useTranslations("flashback.sendRegister");
	const { dialogRef, handleKeyDown } = useDialogA11y(onClose);

	/** form 字段名（nowStatus/want/need/say）→ 雾区间键（now/want/need/say），只说一次 */
	const fogOf = (formField: keyof typeof fields) =>
		TODAY_FIELDS.find((host) => host.field === formField)!.fog;

	const [fields, setFields] = useState({
		nowStatus: me.today?.nowStatus ?? "",
		want: me.today?.want ?? "",
		need: me.today?.need ?? "",
		say: me.today?.say ?? "",
	});
	/** today 雾区间（fog 字段名 → spans；初始 = 服务端既有雾（胶囊侧最终闭环最后一块） */
	const [spansByField, setSpansByField] = useState<Record<string, FlashbackFogSpan[]>>(() =>
		Object.fromEntries(
			TODAY_FIELDS.map((host) => [host.fog, [...(me.today?.fogSpans?.[host.fog] ?? [])]]),
		),
	);
	const [busy, setBusy] = useState(false);
	const [error, setError] = useState(false);
	const [saved, setSaved] = useState(false);

	// 轻反馈停留后自动关层（定时器随弹层卸载清理）
	useEffect(() => {
		if (!saved) return;
		const timer = window.setTimeout(onSaved, SAVED_LINGER_MS);
		return () => window.clearTimeout(timer);
	}, [saved, onSaved]);

	const save = async () => {
		if (busy || saved) return;
		setBusy(true);
		setError(false);
		try {
			const { data } = await client.mutate({
				mutation: FLASHBACK_SUBMIT_TODAY,
				variables: { token, input: { ...fields } },
			});
			if (!data?.flashbackSubmitToday?.today) {
				setError(true);
				return;
			}
			// today 雾面必须落在新文本之后（adjustTodayFog 按服务端当前文本校验区间）；
			// 脏检查与服务端基线（me.today.fogSpans）比对：未变化零 mutation，
			// 全部切回亮也显式同步清雾；雾调整失败直接暂停在上墙前——已寄出的墙
			// 保持原状，不会把用户要求遮蔽的字裸露给校友
			for (const host of TODAY_FIELDS) {
				const next = normalizeSpans(spansByField[host.fog]);
				if (sameSpans(next, normalizeSpans(me.today?.fogSpans?.[host.fog]))) continue;
				const { data: fogData } = await client.mutate({
					mutation: FLASHBACK_ADJUST_TODAY_FOG,
					variables: { token, field: host.fog, spans: next },
				});
				if (!fogData?.flashbackAdjustTodayFog) {
					setError(true);
					return;
				}
			}
			// 已寄出：幂等补寄，墙卡即新内容（小程序 MyCard 同款语义）；
			// #931 起双入口，登录态无 token 以 null 发出
			if (sentAtStart) {
				const { data: wallData } = await client.mutate({
					mutation: FLASHBACK_SEND_TO_WALL,
					variables: { token: token ?? null },
				});
				if (!wallData?.flashbackSendToWall?.sentToWallAt) {
					setError(true);
					return;
				}
			}
			setSaved(true);
		} catch {
			setError(true);
		} finally {
			setBusy(false);
		}
	};

	const set = (key: keyof typeof fields, value: string) =>
		setFields((prev) => ({ ...prev, [key]: value }));

	return (
		<div className="fb-send-overlay" onKeyDown={handleKeyDown}>
			<div
				className="fb-send-step fb-today-dialog"
				role="dialog"
				aria-modal="true"
				aria-labelledby="fb-edit-today-title"
				tabIndex={-1}
				ref={dialogRef}
				data-testid="fb-edit-today-dialog"
			>
				<h3 id="fb-edit-today-title" className="fb-send-title">
					{t("editTitle")}
				</h3>
				{saved ? (
					<p className="fb-promise" role="status">
						{t("editSaved")}
					</p>
				) : (
					<>
						<div className="fb-today-dialog-fields">
							{(
								[
									["nowStatus", "nowLabel"],
									["want", "wantLabel"],
									["need", "needLabel"],
									["say", "sayLabel"],
								] as const
							).map(([field, label]) => (
								<div key={field}>
									<label className="fb-field-label" htmlFor={`fb-edit-${field}`}>
										{writeT(label)}
									</label>
									<textarea
										id={`fb-edit-${field}`}
										className="fb-today-dialog-textarea"
										value={fields[field]}
										onChange={(event) => set(field, event.target.value)}
									/>
									{fields[field] ? (
										<div className="fb-review-sentences" data-testid={`fb-edit-fog-${fogOf(field)}`}>
											{sentencesWithFogMark(fields[field], spansByField[fogOf(field)]).map((sentence) => (
												<button
													key={sentence.start}
													type="button"
													className={`fb-review-sentence${sentence.fogged ? " fb-review-sentence--fog" : ""}`}
													aria-pressed={sentence.fogged}
													onClick={() =>
														setSpansByField((prev) => toggleSpanIn(prev, fogOf(field), sentence))
													}
												>
													<span className="fb-review-sentence-text">{sentence.text}</span>
													{sentence.fogged && (
														<span className="fb-review-fog-badge" aria-hidden="true">
															{sendT("fogBadge")}
														</span>
													)}
												</button>
											))}
										</div>
									) : null}
								</div>
							))}
						</div>
						<p className="fb-hint">{t("editFogHint")}</p>
						{error && (
							<p role="alert" className="fb-hint">
								{t("editError")}
							</p>
						)}
						<button
							type="button"
							className="fb-cta fb-cta-primary"
							disabled={busy}
							onClick={() => void save()}
						>
							{busy ? t("editSaving") : t("editSave")}
						</button>
						<button type="button" className="fb-cta" disabled={busy} onClick={onClose}>
							{t("editCancel")}
						</button>
					</>
				)}
			</div>
		</div>
	);
}

/** 撤下确认弹层：讲清后果，确认即撤 */
function RetractDialog({
	token,
	onClose,
	onRetracted,
}: {
	token: string | null;
	onClose: () => void;
	onRetracted: () => void;
}) {
	const t = useTranslations("flashback.todaySlot");
	const { dialogRef, handleKeyDown } = useDialogA11y(onClose);
	const [busy, setBusy] = useState(false);
	const [error, setError] = useState(false);

	const retract = async () => {
		if (busy) return;
		setBusy(true);
		setError(false);
		try {
			const { data } = await client.mutate({
				mutation: FLASHBACK_RETRACT,
				variables: { token: token ?? null },
			});
			if (data?.flashbackRetract?.retracted) {
				onRetracted();
			} else {
				setError(true);
			}
		} catch {
			setError(true);
		} finally {
			setBusy(false);
		}
	};

	return (
		<div className="fb-send-overlay" onKeyDown={handleKeyDown}>
			<div
				className="fb-send-step fb-today-dialog"
				role="dialog"
				aria-modal="true"
				aria-labelledby="fb-retract-title"
				tabIndex={-1}
				ref={dialogRef}
				data-testid="fb-retract-dialog"
			>
				<h3 id="fb-retract-title" className="fb-send-title">
					{t("retractTitle")}
				</h3>
				<p className="fb-lead">{t("retractBody")}</p>
				{error && (
					<p role="alert" className="fb-hint">
						{t("retractError")}
					</p>
				)}
				<button
					type="button"
					className="fb-cta fb-cta-primary"
					disabled={busy}
					onClick={() => void retract()}
				>
					{t("retractConfirm")}
				</button>
				<button type="button" className="fb-cta" disabled={busy} onClick={onClose}>
					{t("retractCancel")}
				</button>
			</div>
		</div>
	);
}
