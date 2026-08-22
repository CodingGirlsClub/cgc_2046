"use client";

/**
 * MCP 连接 token 签发行（单一内容源，plan 2026-08-22 first-mile-onboarding U4）。
 *
 * 从 agents/mcp 页抽取：「签发新 token」按钮 + 签发表单 + 一次性明文横幅。
 * 消费方：
 * - agents/mcp 页：onIssued 把新 token 插入列表；「我已保存」仅关横幅；
 * - 首公里向导（onboarding-wizard.tsx）：onSaved 作两段式完成判定的第一段。
 *
 * 错误一律内联 role="alert"（members-error 模式），不引全局 toast。
 */

import { useCallback, useEffect, useRef, useState } from "react";
import { useTranslations } from "next-intl";
import { issueMcpToken, type McpTokenItem } from "@/lib/mcp";
import { copyText } from "@/lib/clipboard";
import { Icon } from "@/components/icons";

export default function McpTokenIssuePanel({
	onIssued,
	onSaved,
}: {
	/** 签发成功回调（列表侧插入新 token 用；明文横幅由本组件自闭环） */
	onIssued?: (token: McpTokenItem) => void;
	/** 「我已保存」确认回调（向导完成判定用；横幅总会关闭） */
	onSaved?: () => void;
}) {
	const t = useTranslations("workspaceMcp");
	const labelsT = useTranslations();

	// 签发表单
	const [showForm, setShowForm] = useState(false);
	const [formName, setFormName] = useState("");
	const [formSubmitting, setFormSubmitting] = useState(false);
	const [formError, setFormError] = useState<string | null>(null);

	// 一次性明文（仅签发成功瞬间存在）
	const [freshToken, setFreshToken] = useState<{
		name: string;
		plainToken: string;
	} | null>(null);
	const [copiedFresh, setCopiedFresh] = useState(false);
	const [copyFreshFailed, setCopyFreshFailed] = useState(false);

	// 「已复制」2s 复位定时器：连续复制重置计时；卸载时清理
	// （向导完成态会换树卸载本组件，旧版定时器会对已卸载组件 setState）
	const copiedTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
	useEffect(() => {
		return () => {
			if (copiedTimerRef.current) clearTimeout(copiedTimerRef.current);
		};
	}, []);

	const handleIssue = useCallback(async () => {
		const name = formName.trim();
		if (!name) return;
		setFormSubmitting(true);
		setFormError(null);
		try {
			const { token, plainToken } = await issueMcpToken(name);
			onIssued?.(token);
			setFreshToken({ name, plainToken });
			setCopiedFresh(false);
			setShowForm(false);
			setFormName("");
		} catch (e) {
			setFormError(e instanceof Error ? labelsT(e.message) : t("issueFailed"));
		} finally {
			setFormSubmitting(false);
		}
	}, [formName, onIssued, t, labelsT]);

	return (
		<>
			<div className="settings-actions">
				<button
					type="button"
					className="join-button join-button--primary"
					onClick={() => setShowForm(true)}
				>
					<Icon name="plus" />
					{t("issueNew")}
				</button>
			</div>

			{/* 一次性明文展示（仅签发成功瞬间） */}
			{freshToken && (
				<div className="mcp-token-once" role="status">
					<p>
						{t("freshTokenNote", { name: freshToken.name })}
					</p>
					<div className="mcp-token-once__row">
						<code>{freshToken.plainToken}</code>
						<button
							type="button"
							className="join-button join-button--outline"
							onClick={() => {
								void copyText(freshToken.plainToken).then((ok) => {
									if (ok) {
										setCopiedFresh(true);
										setCopyFreshFailed(false);
										if (copiedTimerRef.current) clearTimeout(copiedTimerRef.current);
										copiedTimerRef.current = setTimeout(() => setCopiedFresh(false), 2000);
									} else {
										setCopyFreshFailed(true);
									}
								});
							}}
						>
							{copiedFresh ? t("copied") : t("copy")}
						</button>
						<button
							type="button"
							className="join-button join-button--ghost"
							onClick={() => {
								setFreshToken(null);
								onSaved?.();
							}}
						>
							{t("savedConfirm")}
						</button>
					</div>
					{copyFreshFailed && (
						<p className="mcp-copy-error" role="alert">
							{t("copyFailed")}
						</p>
					)}
				</div>
			)}

			{/* 签发表单 */}
			{showForm && (
				<div className="invitation-form-card">
					<h2>{t("issueHeading")}</h2>
					<div className="invitation-form">
						<label className="join-field">
							<span>{t("nameLabel")}</span>
							<input
								type="text"
								className="join-input"
								placeholder={t("namePlaceholder")}
								value={formName}
								onChange={(e) => setFormName(e.target.value)}
								disabled={formSubmitting}
							/>
						</label>
						{formError && (
							<div className="members-error" role="alert">
								{formError}
							</div>
						)}
						<div className="invitation-form-actions">
							<button
								type="button"
								className="join-button join-button--primary"
								onClick={handleIssue}
								disabled={formSubmitting || !formName.trim()}
							>
								{formSubmitting ? t("issuing") : t("issue")}
							</button>
							<button
								type="button"
								className="join-button join-button--ghost"
								onClick={() => {
									setShowForm(false);
									setFormError(null);
								}}
								disabled={formSubmitting}
							>
								{t("cancel")}
							</button>
						</div>
					</div>
				</div>
			)}
		</>
	);
}
