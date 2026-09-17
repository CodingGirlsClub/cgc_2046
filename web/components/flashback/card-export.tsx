"use client";

import { useCallback, useRef, useState } from "react";
import { useTranslations } from "next-intl";
import { appliedStamp, type FlashbackCapsuleMe } from "@/lib/graphql/flashback";

/** 摘要卡竖版比例（R14：适配朋友圈/小红书） */
const SUMMARY_W = 600;
const SUMMARY_H = 800;

/**
 * 卡片导出（U5/R14/R15）：摘要卡（默认分享物：时间戳+城市+金句+今天的
 * 回答）与全文卡（雾化态）共用 DOM 模板源；下载图用 canvas 同版式绘制，
 * Markdown 用 Blob 下载——页面卡片与下载图是同一物件的两态。
 *
 * 缺省版式（R14）：未选金句 → 占位句；未填今天 → 省略今天段。
 */
export default function CardExport({ me }: { me: FlashbackCapsuleMe }) {
	const t = useTranslations("flashback.cardExport");
	const questionT = useTranslations("flashback.questionLabels");
	const canvasRef = useRef<HTMLCanvasElement>(null);
	const [kind, setKind] = useState<"summary" | "full">("summary");

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

	const downloadPng = () => {
		drawCard();
		const canvas = canvasRef.current;
		if (!canvas) return;
		canvas.toBlob((blob) => {
			if (!blob) return;
			triggerDownload(URL.createObjectURL(blob), "flashback-card.png", "image/png");
		}, "image/png");
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
				<button type="button" className="fb-cta" onClick={downloadMarkdown}>
					{t("downloadMd")}
				</button>
			</div>
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
