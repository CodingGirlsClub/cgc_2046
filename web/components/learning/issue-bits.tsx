"use client";

/**
 * 学习 issue 三态图标与 kind 标签(U8,R7/R11)。
 *
 * 状态由学习记录派生(Todo/In Progress/Done),非手柄——图标只读展示。
 * kind 二分:thoughtwork(证据在对话)/ handwork(证据在产物)。
 */

export type IssueStatus = "todo" | "in_progress" | "done";

export const ISSUE_STATUS_LABEL: Record<IssueStatus, string> = {
  todo: "未开始",
  in_progress: "进行中",
  done: "已达成",
};

export const ISSUE_KIND_LABEL: Record<string, string> = {
  thoughtwork: "思考",
  handwork: "动手",
};

/** 三态图标:Todo 空心圆 / In Progress 半填充 / Done 实心勾(Linear 同款语汇) */
export function IssueStatusIcon({ status }: { status: IssueStatus }) {
  if (status === "done") {
    return (
      <svg
        data-testid="issue-status-done"
        aria-label={ISSUE_STATUS_LABEL.done}
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

  if (status === "in_progress") {
    return (
      <svg
        data-testid="issue-status-in_progress"
        aria-label={ISSUE_STATUS_LABEL.in_progress}
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

  return (
    <svg
      data-testid="issue-status-todo"
      aria-label={ISSUE_STATUS_LABEL.todo}
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
  const label = ISSUE_KIND_LABEL[kind] ?? kind;
  return (
    <span
      data-testid={`issue-kind-${kind}`}
      className="shrink-0 rounded-full border border-line px-2 py-0.5 text-[11px] leading-4 text-ink-3"
    >
      {label}
    </span>
  );
}
