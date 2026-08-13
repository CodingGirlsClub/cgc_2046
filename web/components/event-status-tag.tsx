import type { EventStatus } from "@/lib/graphql/events";
import { EVENT_STATUS_LABEL, EVENT_STATUS_TONE } from "@/lib/graphql/events";

/**
 * E-11 #127 活动状态徽章（workspace-ui StatusTag 为 Workspace 状态专用，
 * 活动状态语义不同——草稿/开放/结束/取消 + neutral/positive/negative 三调）。
 */

const TONE_CLASS: Record<"neutral" | "positive" | "negative", string> = {
	neutral: "border-line text-ink-3",
	positive: "border-accent text-accent",
	negative: "border-danger text-danger",
};

export default function EventStatusTag({ status }: { status: EventStatus }) {
	const tone = EVENT_STATUS_TONE[status];
	return (
		<span
			className={`inline-flex items-center rounded-full border px-2 py-0.5 text-[12px] leading-4 ${TONE_CLASS[tone]}`}
		>
			{EVENT_STATUS_LABEL[status]}
		</span>
	);
}
