"use client";

import { useTranslations } from "next-intl";
import { Link } from "@/i18n/navigation";
import { richTags } from "./pow";
import { rawArray } from "./raw-array";

/**
 * 志愿者侧两段（R2 第 5-6 段）：成为志愿者专区（三职位小卡 + 批次卡 + 支持一行）
 * → 时间线（三节点）。
 *
 * - 批次卡写静态「首批招募进行中」+ 产品化状态徽章，**不写死日期**（R2：真实状态
 *   与截止时间由申请页动态承载，避免上线日期滑档时页面说谎）。
 * - 申请页路由 = U7 的 /hackerstart-1024/volunteer（R3/R10 的志愿者入口落点）。
 */

const VOLUNTEER_PATH = "/hackerstart-1024/volunteer";

/** 时间线三节点：启动 → 首期 64 场 → 批次滚动至 1,024 场（R17） */
const TIMELINE_KEYS = ["start", "firstBatch", "rolling"] as const;

export function VolunteerSection() {
	const t = useTranslations("hackerstart1024.volunteer");
	const roles = rawArray<{
		t: string;
		en: string;
		badge?: string;
		one: string;
		fit: string;
	}>(t.raw("roles"));
	const support = rawArray<string>(t.raw("support"));

	return (
		<section
			className="hs24-section"
			id="hs24-volunteer"
			aria-labelledby="hs24-volunteer-title"
		>
			<div className="hs24-container">
				<div className="hs24-badge-row">
					<span className="hs24-badge">{t("badge")}</span>
					<span className="hs24-badge-label">{t("label")}</span>
				</div>
				<h2 className="hs24-title" id="hs24-volunteer-title">
					{t.rich("title", richTags)}
				</h2>
				<p className="hs24-lead">{t("lead")}</p>

				{/* 三职位小卡：一排常驻，深读在申请页 */}
				<div className="hs24-cap3">
					{roles.map((role, index) => (
						<div
							key={role.t}
							className={`hs24-tile${role.badge ? " hs24-tile--featured" : ""}`}
						>
							<div className="hs24-tile__t">
								<span className="hs24-tile__n">{index + 1}</span>
								{role.t}
								{role.badge ? (
									<span className="hs24-tile__badge">{role.badge}</span>
								) : null}
								<small>{role.en}</small>
							</div>
							<div className="hs24-tile__d">{role.one}</div>
							<div className="hs24-tile__d hs24-tile__d--fit">{role.fit}</div>
						</div>
					))}
				</div>

				{/* 当前批次卡（状态徽章 + 静态进行中文案 + 申请入口） */}
				<div className="hs24-tile hs24-cohort">
					<span className="hs24-cohort__status">{t("cohortStatus")}</span>
					<span className="hs24-cohort__name">{t("cohortName")}</span>
					<span className="hs24-cohort__note">{t("cohortNote")}</span>
					<span className="hs24-cohort__spacer" />
					<Link href={VOLUNTEER_PATH} className="hs24-cta--rose hs24-cta--flush">
						{t("cohortCta")}
					</Link>
				</div>

				{/* 支持一行 */}
				<div className="hs24-endorse">
					{support.map((item) => (
						<span key={item}>{item}</span>
					))}
				</div>
				<p className="hs24-cta-note">{t("note")}</p>
			</div>
		</section>
	);
}

export function TimelineSection() {
	const t = useTranslations("hackerstart1024.timeline");

	return (
		<section className="hs24-section" aria-labelledby="hs24-timeline-title">
			<div className="hs24-container">
				<div className="hs24-badge-row">
					<span className="hs24-badge">{t("badge")}</span>
					<span className="hs24-badge-label">{t("label")}</span>
				</div>
				<h2 className="hs24-title" id="hs24-timeline-title">
					{t.rich("title", richTags)}
				</h2>
				<div className="hs24-timeline">
					{TIMELINE_KEYS.map((key, index) => (
						<div
							key={key}
							className={`hs24-tl__item${index === 0 ? " hs24-tl__item--start" : ""}`}
						>
							<div className="hs24-tl__t">
								{t.rich(`${key}.t`, richTags)}
							</div>
							<div className="hs24-tl__d">
								{t.rich(`${key}.d`, richTags)}
							</div>
						</div>
					))}
				</div>
			</div>
		</section>
	);
}
