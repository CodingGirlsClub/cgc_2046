"use client";

import { useTranslations } from "next-intl";

/**
 * 学习 objective 四态图标与标签（S8，ADR-0011 / R43）。
 *
 * mastery 由 Attempt 账本投影派生（unassessed/developing/mastered/
 * needs_review），非手柄——图标只读展示。kind 二分沿 issue 语义（course-map
 * 消费 IssueKindChip）。
 */

export type ObjectiveMastery =
  | "unassessed"
  | "developing"
  | "mastered"
  | "needs_review";

/** 值 = learning messages key 名(渲染方 useTranslations("learning") 翻译) */
export const MASTERY_LABEL: Record<ObjectiveMastery, string> = {
  unassessed: "masteryUnassessed",
  developing: "masteryDeveloping",
  mastered: "masteryMastered",
  needs_review: "masteryNeedsReview",
};

/** 值 = learning messages key 名(渲染方 useTranslations("learning") 翻译) */
export const ISSUE_KIND_LABEL: Record<string, string> = {
  thoughtwork: "issueKindThoughtwork",
  handwork: "issueKindHandwork",
};

/** 四态图标:unassessed 空心圆 / developing 半填充 / mastered 实心勾 /
 *  needs_review 感叹号(Linear 同款语汇) */
export function MasteryIcon({ mastery }: { mastery: ObjectiveMastery }) {
  const t = useTranslations("learning");
  if (mastery === "mastered") {
    return (
      <svg
        data-testid="mastery-mastered"
        aria-label={t(MASTERY_LABEL.mastered)}
        width="14"
        height="14"
        viewBox="0 0 16 16"
        className="shrink-0 text-emerald-500"
      >
        <circle cx="8" cy="8" r="7" fill="currentColor" opacity="0.18" />
        <path
          d="M4.5 8.2 7 10.7l4.5-4.9"
          fill="none"
          stroke="currentColor"
          strokeWidth="1.8"
          strokeLinecap="round"
          strokeLinejoin="round"
        />
      </svg>
    );
  }

  if (mastery === "developing") {
    return (
      <svg
        data-testid="mastery-developing"
        aria-label={t(MASTERY_LABEL.developing)}
        width="14"
        height="14"
        viewBox="0 0 16 16"
        className="shrink-0 text-amber-500"
      >
        <circle
          cx="8"
          cy="8"
          r="6.4"
          fill="none"
          stroke="currentColor"
          strokeWidth="1.6"
        />
        <path d="M8 4.4a3.6 3.6 0 0 1 3.6 3.6H8z" fill="currentColor" />
      </svg>
    );
  }

  if (mastery === "needs_review") {
    return (
      <svg
        data-testid="mastery-needs_review"
        aria-label={t(MASTERY_LABEL.needs_review)}
        width="14"
        height="14"
        viewBox="0 0 16 16"
        className="shrink-0 text-orange-500"
      >
        <circle
          cx="8"
          cy="8"
          r="6.4"
          fill="none"
          stroke="currentColor"
          strokeWidth="1.6"
        />
        <circle cx="8" cy="11.2" r="0.9" fill="currentColor" />
        <path d="M8 4.2v4" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" />
      </svg>
    );
  }

  return (
    <svg
      data-testid="mastery-unassessed"
      aria-label={t(MASTERY_LABEL.unassessed)}
      width="14"
      height="14"
      viewBox="0 0 16 16"
      className="shrink-0 text-ink-3"
    >
      <circle
        cx="8"
        cy="8"
        r="6.4"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.6"
      />
    </svg>
  );
}

/** kind 标签 chip(thoughtwork/handwork;未知 kind 灰显原文) */
export function IssueKindChip({ kind }: { kind: string }) {
  const t = useTranslations("learning");
  const label = ISSUE_KIND_LABEL[kind] ? t(ISSUE_KIND_LABEL[kind]) : kind;
  return (
    <span
      data-testid={`issue-kind-${kind}`}
      className="shrink-0 rounded-full border border-line px-2 py-0.5 text-[11px] leading-4 text-ink-3"
    >
      {label}
    </span>
  );
}
