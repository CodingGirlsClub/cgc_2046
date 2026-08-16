"use client";

/**
 * plan 020 U2.2/U3.3 上下文交接复制按钮（Agents 页待办 + workflows 页 CTA 共用）。
 *
 * 交接文本（固定模板；标注为「平台操作引导」——不是给助手的任务指令本体）：
 *   workspace: <slug>(<id>) / run: <id> / step: <key> / 工具提示：用 save_step_output 写回该 step
 *
 * workspace_id 是助手调 save_step_output 的必需参数，随文本直达用户剪贴板。
 */

import { useState } from "react";
import { copyText } from "@/lib/clipboard";

export interface HandoffTextInput {
	workspaceSlug: string;
	workspaceId: string;
	runId: string;
	stepKey: string;
}

/** 交接文本（导出供测试断言内容） */
export function buildHandoffText({
	workspaceSlug,
	workspaceId,
	runId,
	stepKey,
}: HandoffTextInput): string {
	return `workspace: ${workspaceSlug}(${workspaceId}) / run: ${runId} / step: ${stepKey} / 工具提示：用 save_step_output 写回该 step`;
}

interface StepHandoffCopyProps extends HandoffTextInput {
	/** 按钮文案（默认「复制交接文本」） */
	label?: string;
	className?: string;
}

/** 复制按钮：成功显示「已复制」，失败显示「复制失败，请手动复制」；2s 后复位。 */
export default function StepHandoffCopy({
	workspaceSlug,
	workspaceId,
	runId,
	stepKey,
	label = "复制交接文本",
	className = "",
}: StepHandoffCopyProps) {
	const [state, setState] = useState<"idle" | "copied" | "failed">("idle");
	const text = buildHandoffText({ workspaceSlug, workspaceId, runId, stepKey });

	async function handleCopy() {
		const ok = await copyText(text);
		setState(ok ? "copied" : "failed");
		window.setTimeout(() => setState("idle"), 2000);
	}

	return (
		<button
			type="button"
			className={`agents-copy-button ${className}`}
			data-testid="step-handoff-copy"
			data-state={state}
			data-handoff={text}
			onClick={handleCopy}
		>
			{state === "copied" ? "已复制" : state === "failed" ? "复制失败" : label}
		</button>
	);
}
