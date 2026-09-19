"use client";

import { useCallback, useRef, useState, useSyncExternalStore } from "react";
import { useTranslations } from "next-intl";
import { useMutation } from "@apollo/client/react";
import {
	appliedStamp,
	FLASHBACK_SET_QUOTE_LICENSE,
	type FlashbackCapsuleMe,
} from "@/lib/graphql/flashback";

/** 摘要卡竖版比例（R14：适配朋友圈/小红书） */
const SUMMARY_W = 600;
const SUMMARY_H = 800;

/**
 * 卡片导出（U5/R14/R15）：摘要卡（默认分享物：时间戳+城市+金句+今天的
 * 回答）与全文卡（雾化态）共用 DOM 模板源；下载图用 canvas 同版式绘制，
 * Markdown 用 Blob 下载——页面卡片与下载图是同一物件的两态。
 *
 * 缺省版式（R14）：未选金句 → 占位句；未填今天 → 省略今天段。
 *
 * R37 分享 opt-in：卡片展示的金句就是 `me.quote`——它的来源（question_key +
 * chosen_quote_span）由 capsule.me 一并给出，勾选即用**同一区间**开匿名金句档
 * （现有 setQuoteLicense mutation；只传 level 会把 span 覆盖成 nil，见
 * AlumniProjection.quote_payload 注释）。因此：
 * - 卡上没有真金句（占位句/未选）→ 不显示该选项（保守：无法映射到候选区间）；
 * - 已授权（anonymous/credited）→ 勾选态 + 禁用（分享永不改档，也不静默撤权）。
 * 授权永不预选：默认不勾。
 */
export default function CardExport({ me, token }: { me: FlashbackCapsuleMe; token?: string | null }) {
	const t = useTranslations("flashback.cardExport");
	const questionT = useTranslations("flashback.questionLabels");
	const canvasRef = useRef<HTMLCanvasElement>(null);
	const [kind, setKind] = useState<"summary" | "full">("summary");
	const [runSetQuoteLicense] = useMutation(FLASHBACK_SET_QUOTE_LICENSE);
	/** 本地勾选覆盖（null = 跟随授权档；授权永不预选，已在授权中才显示勾选态） */
	const [optInOverride, setOptInOverride] = useState<boolean | null>(null);
	const [optInBusy, setOptInBusy] = useState(false);

	const alreadyLicensed = (me.quoteLevel ?? "off") !== "off";
	const shareOptIn = optInOverride ?? alreadyLicensed;
	/** 可回填的区间三件套齐备才给选项（R37：span = 卡片上展示的金句） */
	const optInAvailable = Boolean(token && me.quote && (me.quoteSpans?.length ?? 0) > 0);

	/** 勾选 → 开匿名金句档（span 与卡片同源）；取消勾选 → 保持关闭（不撤销既有档位） */
	const toggleShareOptIn = async (next: boolean) => {
		if (!token || !optInAvailable || alreadyLicensed) return;
		setOptInOverride(next);
		if (!next) return;
		setOptInBusy(true);
		try {
			await runSetQuoteLicense({
				variables: {
					token,
					level: "anonymous",
					chosenQuoteSpans: me.quoteSpans ?? undefined,
				},
			});
		} catch {
			setOptInOverride(false);
		} finally {
			setOptInBusy(false);
		}
	};

	const stamp = appliedStamp(me.appliedAt);
	const quote = me.quote?.trim() || null;
	const todayLine = me.today?.want?.trim() || me.today?.nowStatus?.trim() || null;

	const stampText = stamp ? `${stamp}${me.city ? " · " + me.city : ""}` : (me.city ?? "");
	const quoteText = quote ?? t("quoteFallback");
	const todayText = todayLine ? `${t("todayTag")}：${todayLine}` : "";

	const fullLines = me.answers.map((answer) => ({
		key: answer.questionKey,
		question: questionT.has(answer.questionKey) ? questionT(answer.questionKey) : answer.questionKey,
		text: answer.text,
	}));

	const drawCard = useCallback(() => {
		const canvas = canvasRef.current;
		if (!canvas) return;
		const ctx = canvas.getContext("2d");
		if (!ctx) return;

		canvas.width = SUMMARY_W;
		canvas.height = SUMMARY_H;

		// 纸底 + 内框
		ctx.fillStyle = "#f6f2e8";
		ctx.fillRect(0, 0, SUMMARY_W, SUMMARY_H);
		ctx.strokeStyle = "rgba(43,39,35,0.25)";
		ctx.lineWidth = 2;
		ctx.strokeRect(24, 24, SUMMARY_W - 48, SUMMARY_H - 48);

		ctx.fillStyle = "#2b2723";
		ctx.textAlign = "center";

		ctx.font = "600 22px 'Kaiti SC', 'Noto Serif SC', serif";
		ctx.fillText(t("brand"), SUMMARY_W / 2, 96);

		ctx.font = "20px 'Kaiti SC', 'Noto Serif SC', serif";
		ctx.fillStyle = "rgba(43,39,35,0.7)";
		ctx.fillText(stampText, SUMMARY_W / 2, 160);

		if (kind === "summary") {
			ctx.fillStyle = "#2b2723";
			ctx.font = "italic 30px 'Kaiti SC', 'Noto Serif SC', serif";
			wrapText(ctx, `“${quoteText}”`, SUMMARY_W / 2, 300, SUMMARY_W - 160, 46);
			if (todayText) {
				ctx.font = "22px 'Kaiti SC', 'Noto Serif SC', serif";
				ctx.fillStyle = "rgba(43,39,35,0.85)";
				wrapText(ctx, todayText, SUMMARY_W / 2, 560, SUMMARY_W - 160, 34);
			}
		} else {
			ctx.textAlign = "left";
			ctx.font = "19px 'Kaiti SC', 'Noto Serif SC', serif";
			let y = 280;
			for (const line of fullLines) {
				for (const piece of [line.question, line.text]) {
					y = wrapText(ctx, piece, 72, y, SUMMARY_W - 144, 30) + 14;
					if (y > SUMMARY_H - 60) break;
				}
				if (y > SUMMARY_H - 60) break;
			}
			ctx.textAlign = "center";
		}

		ctx.font = "16px 'Kaiti SC', 'Noto Serif SC', serif";
		ctx.fillStyle = "rgba(43,39,35,0.5)";
		ctx.fillText(t("canvasFooter"), SUMMARY_W / 2, SUMMARY_H - 56);
	}, [kind, stampText, quoteText, todayText, fullLines, t]);

	/** 出图 blob（保存与分享共用同一物件；R15「页面卡片与下载图同一模板源」） */
	const renderPngBlob = useCallback(
		() =>
			new Promise<Blob | null>((resolve) => {
				drawCard();
				const canvas = canvasRef.current;
				if (!canvas) {
					resolve(null);
					return;
				}
				canvas.toBlob((blob) => resolve(blob), "image/png");
			}),
		[drawCard],
	);

	const downloadPng = () => {
		void renderPngBlob().then((blob) => {
			if (blob) triggerDownload(URL.createObjectURL(blob), "flashback-card.png", "image/png");
		});
	};

	/**
	 * 系统分享（第 4 件，轻档：只做 navigator.share，不引微信 JS-SDK/扫码）。
	 * 能力探测全在客户端（effect）：无 navigator.share 的浏览器不渲染按钮，只留下载。
	 * 优先分享卡片图文件（canShare 通过时），否则降级 url+text；用户取消（AbortError）静默。
	 */
	const shareSupported = useSyncExternalStore(
		() => () => {},
		() => typeof navigator !== "undefined" && typeof navigator.share === "function",
		() => false,
	);

	const shareCard = async () => {
		if (typeof navigator === "undefined" || !navigator.share) return;
		const blob = await renderPngBlob();
		const file =
			blob && typeof File !== "undefined"
				? new File([blob], "flashback-card.png", { type: "image/png" })
				: null;
		const filePayload = file && navigator.canShare?.({ files: [file] }) ? { files: [file] } : null;
		try {
			if (filePayload) {
				await navigator.share({ ...filePayload, title: t("summaryTitle") });
			} else {
				await navigator.share({
					title: t("summaryTitle"),
					text: `${quoteText}${todayText ? `\n${todayText}` : ""}`,
					url: window.location.href,
				});
			}
		} catch {
			// 用户取消或系统拒绝：不弹错（分享不是主路径）
		}
	};

	const downloadMarkdown = () => {
		const lines =
			kind === "summary"
				? ["# " + t("summaryTitle"), "", stampText, "", `> ${quoteText}`, ...(todayText ? ["", todayText] : [])]
				: [
						"# " + t("fullTitle"),
						"",
						...fullLines.flatMap((line) => [line.question, line.text, ""]),
					];

		const blob = new Blob([lines.join("\n")], { type: "text/markdown" });
		triggerDownload(URL.createObjectURL(blob), "flashback-card.md", "text/markdown");
	};

	return (
		<section className="fb-card-export" aria-label={t("ariaLabel")}>
			<h3 className="fb-action-title">{t("title")}</h3>
			<div className="fb-export-switch" role="group" aria-label={t("kindAria")}>
				<button
					type="button"
					className={`fb-export-tab${kind === "summary" ? " fb-export-tab--active" : ""}`}
					aria-pressed={kind === "summary"}
					onClick={() => setKind("summary")}
				>
					{t("summaryTab")}
				</button>
				<button
					type="button"
					className={`fb-export-tab${kind === "full" ? " fb-export-tab--active" : ""}`}
					aria-pressed={kind === "full"}
					onClick={() => setKind("full")}
				>
					{t("fullTab")}
				</button>
			</div>

			{/* DOM 模板（与 canvas 同版式——页面卡片与下载图同一物件，R15） */}
			<div className={`fb-polaroid fb-grain fb-export-card${kind === "full" ? " fb-export-card--full" : ""}`} data-testid="fb-export-card">
				<div className="fb-photo fb-export-photo">
					<span className="fb-export-kicker">{t("brand")}</span>
					<span className="fb-export-stamp">{stampText}</span>
					{kind === "summary" ? (
						<>
							<p className="fb-export-quote">“{quoteText}”</p>
							{todayText && <p className="fb-export-today">{todayText}</p>}
						</>
					) : (
						fullLines.map((line) => (
							<p key={line.key} className="fb-export-full-line">
								<span className="fb-answer-q">{line.question}</span>
								{line.text}
							</p>
						))
					)}
				</div>
			</div>

			<div className="fb-export-actions">
				<button type="button" className="fb-cta fb-cta-primary" onClick={downloadPng}>
					{t("downloadPng")}
				</button>
				{shareSupported && (
					<button type="button" className="fb-cta" data-testid="fb-export-share" onClick={() => void shareCard()}>
						{t("shareTo")}
					</button>
				)}
				<button type="button" className="fb-cta" onClick={downloadMarkdown}>
					{t("downloadMd")}
				</button>
			</div>
			{optInAvailable && (
				<label className="fb-export-optin">
					<input
						type="checkbox"
						data-testid="fb-export-optin"
						checked={shareOptIn}
						disabled={alreadyLicensed || optInBusy}
						onChange={(event) => void toggleShareOptIn(event.target.checked)}
					/>
					<span>{alreadyLicensed ? t("shareOptInAlready") : t("shareOptIn")}</span>
				</label>
			)}
			<p className="fb-hint">{t("privacyNote")}</p>
			<canvas ref={canvasRef} className="fb-visually-hidden" aria-hidden="true" />
		</section>
	);
}

function wrapText(
	ctx: CanvasRenderingContext2D,
	text: string,
	centerX: number,
	startY: number,
	maxWidth: number,
	lineHeight: number,
): number {
	const chars = Array.from(text);
	let line = "";
	let y = startY;

	const flush = () => {
		ctx.fillText(line, centerX, y);
		line = "";
		y += lineHeight;
	};

	for (const char of chars) {
		if (ctx.measureText(line + char).width > maxWidth) flush();
		line += char;
	}
	if (line) flush();
	return y;
}

function triggerDownload(url: string, filename: string, mime: string) {
	const anchor = document.createElement("a");
	anchor.href = url;
	anchor.download = filename;
	anchor.type = mime;
	document.body.appendChild(anchor);
	anchor.click();
	anchor.remove();
	window.setTimeout(() => URL.revokeObjectURL(url), 1000);
}
