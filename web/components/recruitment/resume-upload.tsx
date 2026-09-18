"use client";

import { useRef, useState } from "react";
import { useTranslations } from "next-intl";

/**
 * 简历上传控件（R11 第 1 步；接 U2 的 base64-over-JSON 单入口）。
 *
 * 职责边界：本控件只做**文件选择侧的守卫与回显**——扩展名（.pdf/.doc/.docx）与
 * 原始文件 ≤5MB 的前置校验在控件内（与后端同名错误码同口径的文案），**上传管道
 * 由调用方持有**（先 `upsertResumeProfile` 建档、再 `uploadResumeFile`，U2 契约），
 * 控件通过 `onSelect(file)` 把选中的文件交回页面，不自己发请求。
 *
 * PIPL 告知面（R11）：`disabled`（同意台阶未勾选）时选择入口不可用——未勾选同意
 * 就不得上传，页面不依赖后端兜底。
 */
export type ResumeFileInfo = {
	fileName: string | null;
	fileSize: number | null;
	uploadedAt: string | null;
};

/** 原始文件上限 5MB（KTD3；与后端 `Upload.@max_file_size` 同值） */
export const RESUME_MAX_BYTES = 5 * 1024 * 1024;

/** 扩展名白名单（与后端接受集合同源：.pdf / .doc / .docx） */
export const RESUME_ACCEPT = ".pdf,.doc,.docx";

/** 扩展名族 → 声明 MIME（后端要求扩展名与声明 MIME 同族，三者一致才收） */
const RESUME_CONTENT_TYPES: Record<string, string> = {
	pdf: "application/pdf",
	doc: "application/msword",
	docx: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
};

/** 文件扩展名（小写，无点）；无法识别返回 "" */
export function resumeExtension(fileName: string): string {
	const index = fileName.lastIndexOf(".");
	return index < 0 ? "" : fileName.slice(index + 1).toLowerCase();
}

/** 扩展名对应的声明 MIME（用于 uploadResumeFile 的 contentType） */
export function resumeContentType(fileName: string): string {
	return RESUME_CONTENT_TYPES[resumeExtension(fileName)] ?? "";
}

/** 选择侧守卫：类型 / 大小（返回拒收原因，通过则 null） */
export function rejectResumeFile(file: File): "type" | "size" | null {
	if (!(resumeExtension(file.name) in RESUME_CONTENT_TYPES)) return "type";
	if (file.size > RESUME_MAX_BYTES) return "size";
	return null;
}

/**
 * 读文件内容为**标准 base64**（不带宽数据 URL 前缀）：U2 的 `contentBase64` 入参。
 * 走 FileReader.readAsDataURL 而非 `btoa(String.fromCharCode(...))`——后者在 MB
 * 级文件上会撑爆调用栈。
 */
export function readFileAsBase64(file: File): Promise<string> {
	return new Promise((resolve, reject) => {
		const reader = new FileReader();
		reader.onerror = () => reject(reader.error ?? new Error("file read failed"));
		reader.onload = () => {
			const result = reader.result;
			if (typeof result !== "string") {
				reject(new Error("file read returned a non-text payload"));
				return;
			}
			const comma = result.indexOf(",");
			resolve(comma < 0 ? "" : result.slice(comma + 1));
		};
		reader.readAsDataURL(file);
	});
}

/** 字节数 → 人类可读（KB / MB，一位小数） */
export function formatFileSize(bytes: number): string {
	if (bytes >= 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
	return `${Math.max(1, Math.round(bytes / 1024))} KB`;
}

export type ResumeUploadProps = {
	/** 采集同意台阶未勾选 → 选择入口禁用（PIPL） */
	disabled: boolean;
	/** 上传进行中（选择入口同锁） */
	busy: boolean;
	/** 已落库的简历文件元数据（null = 尚未上传） */
	profile: ResumeFileInfo | null;
	/** 页面侧错误文案（服务端 code 文案或管道错误；与控件内拒收文案择一显示） */
	error: string | null;
	/** 选中文件并过了选择侧守卫：交给页面走「先建档再上传」管道 */
	onSelect: (file: File) => void;
};

export default function ResumeUpload({
	disabled,
	busy,
	profile,
	error,
	onSelect,
}: ResumeUploadProps) {
	const t = useTranslations("volunteerApply.upload");
	const inputRef = useRef<HTMLInputElement>(null);
	const [rejected, setRejected] = useState<string | null>(null);

	const locked = disabled || busy;

	function handleChange(event: React.ChangeEvent<HTMLInputElement>) {
		const file = event.target.files?.[0];
		// 同一文件二次选择也要能触发 change（同值不重放 change 事件）
		event.target.value = "";
		// 同意台阶未勾选 / 上传中：即便 change 事件绕过禁用按钮（程序化触发）也不放行
		if (locked || !file) return;
		const reason = rejectResumeFile(file);
		if (reason) {
			setRejected(reason === "type" ? t("rejectType") : t("rejectSize"));
			return;
		}
		setRejected(null);
		onSelect(file);
	}

	return (
		<div className="flex flex-col gap-2">
			<input
				ref={inputRef}
				id="va-resume-file"
				type="file"
				accept={RESUME_ACCEPT}
				className="hidden"
				onChange={handleChange}
			/>
			<div className="flex flex-wrap items-center gap-3">
				<button
					type="button"
					disabled={locked}
					onClick={() => inputRef.current?.click()}
					className="rounded-full border-2 border-[#c9497d] px-5 py-2 text-[15px] font-bold text-[#b0406b] disabled:cursor-not-allowed disabled:border-[#e8e4ec] disabled:text-[#b9b3c2]"
				>
					{busy ? t("uploading") : profile?.fileName ? t("replace") : t("choose")}
				</button>
				<span className="text-[13px] text-[#857f8f]">
					{t("hint")}
				</span>
			</div>

			{/* 档案回显：已落库文件（U2 管道写入的元数据） */}
			{profile?.fileName ? (
				<p className="text-[13.5px] text-[#2b2b33]" role="status">
					{t("uploaded", {
						name: profile.fileName,
						size: formatFileSize(profile.fileSize ?? 0),
					})}
				</p>
			) : null}

			{rejected ? (
				<p className="text-[13px] text-[#b0406b]" role="alert">
					{rejected}
				</p>
			) : error ? (
				<p className="text-[13px] text-[#b0406b]" role="alert">
					{error}
				</p>
			) : disabled ? (
				<p className="text-[13px] text-[#b9b3c2]">{t("consentRequired")}</p>
			) : null}
		</div>
	);
}
