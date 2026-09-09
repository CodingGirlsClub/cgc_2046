import { describe, expect, it, vi } from "vitest";
import {
	buildIcs,
	downloadIcs,
	escapeIcsText,
	googleCalendarUrl,
} from "./calendar";

const BASE = {
	id: "event-uuid-1",
	title: "教研分享会",
	startsAt: "2026-10-01T02:00:00.000Z",
	endsAt: "2026-10-01T04:00:00.000Z",
	venue: "中国 上海 徐汇",
};

describe("googleCalendarUrl（P1a 添加日历）", () => {
	it("拼接 TEMPLATE 链接并正确编码标题/时间/地点", () => {
		const url = googleCalendarUrl(BASE);
		expect(url.startsWith("https://calendar.google.com/calendar/render?")).toBe(
			true,
		);
		const params = new URL(url).searchParams;
		expect(params.get("action")).toBe("TEMPLATE");
		expect(params.get("text")).toBe("教研分享会");
		expect(params.get("dates")).toBe("20261001T020000Z/20261001T040000Z");
		expect(params.get("location")).toBe("中国 上海 徐汇");
	});

	it("无 endsAt 按开始后 1 小时兜底；无 venue/details 不带对应参数", () => {
		const params = new URL(
			googleCalendarUrl({ id: "e2", title: "Meet & Greet, 第 2 期", startsAt: BASE.startsAt }),
		).searchParams;
		expect(params.get("dates")).toBe("20261001T020000Z/20261001T030000Z");
		expect(params.get("text")).toBe("Meet & Greet, 第 2 期");
		expect(params.get("location")).toBeNull();
		expect(params.get("details")).toBeNull();
	});

	it("details 参与编码", () => {
		const params = new URL(
			googleCalendarUrl({ ...BASE, details: "携带笔记本\n二楼签到" }),
		).searchParams;
		expect(params.get("details")).toBe("携带笔记本\n二楼签到");
	});
});

describe("buildIcs（P1a .ics 下载内容）", () => {
	it("输出 CRLF 行尾、UTC 基本格式时间与可注入的 DTSTAMP", () => {
		const ics = buildIcs(BASE, new Date("2026-09-09T00:00:00.000Z"));
		const lines = ics.split("\r\n");
		expect(lines[0]).toBe("BEGIN:VCALENDAR");
		expect(lines).toContain("VERSION:2.0");
		expect(lines).toContain("DTSTAMP:20260909T000000Z");
		expect(lines).toContain("DTSTART:20261001T020000Z");
		expect(lines).toContain("DTEND:20261001T040000Z");
		expect(lines).toContain("SUMMARY:教研分享会");
		expect(lines).toContain("LOCATION:中国 上海 徐汇");
		expect(lines[lines.length - 2]).toBe("END:VCALENDAR");
		// CRLF 行尾：除 split 末尾空串外不允许出现裸 \n
		expect(ics.replace(/\r\n/g, "")).not.toContain("\n");
	});

	it("转义 SUMMARY/LOCATION 中的逗号、分号、反斜杠与换行", () => {
		const ics = buildIcs(
			{
				id: "e3",
				title: "A,B;C\\D\nE",
				startsAt: BASE.startsAt,
				venue: "X,Y",
				details: "line1\nline2",
			},
			new Date("2026-09-09T00:00:00.000Z"),
		);
		expect(ics).toContain("SUMMARY:A\\,B\\;C\\\\D\\nE");
		expect(ics).toContain("LOCATION:X\\,Y");
		expect(ics).toContain("DESCRIPTION:line1\\nline2");
	});

	it("无 endsAt 兜底 1 小时；无 venue/details 不输出对应行", () => {
		const ics = buildIcs({ id: "e4", title: "t", startsAt: BASE.startsAt });
		expect(ics).toContain("DTEND:20261001T030000Z");
		expect(ics).not.toContain("LOCATION:");
		expect(ics).not.toContain("DESCRIPTION:");
	});

	it("UID 用稳定活动 ID：同名同时间两个活动 UID 不同；改期 UID 不变（review F2）", () => {
		const sameMoment = { title: BASE.title, startsAt: BASE.startsAt };
		const first = buildIcs({ ...sameMoment, id: "event-a" });
		const second = buildIcs({ ...sameMoment, id: "event-b" });
		expect(first).toContain("UID:cgc-event-a@cgc2046");
		expect(second).toContain("UID:cgc-event-b@cgc2046");

		// 同一活动改期/改名 → UID 保持（日历可更新原事件而非新建）
		const rescheduled = buildIcs({
			id: "event-a",
			title: "改名后的活动",
			startsAt: "2026-11-01T02:00:00.000Z",
		});
		expect(rescheduled).toContain("UID:cgc-event-a@cgc2046");
	});

	it("裸 CR 与 CRLF 一并折叠为 \\n 字面量（review F3：中间回车不进 ICS 文本）", () => {
		const ics = buildIcs({
			id: "e5",
			title: "A\rB",
			startsAt: BASE.startsAt,
			venue: "X\r\nY",
			details: "line1\rline2",
		});
		expect(ics).toContain("SUMMARY:A\\nB");
		expect(ics).toContain("LOCATION:X\\nY");
		expect(ics).toContain("DESCRIPTION:line1\\nline2");
		// 转义后除行尾 CRLF 外不允许残留任何 CR
		expect(ics.replace(/\r\n/g, "")).not.toContain("\r");
	});
});

describe("escapeIcsText", () => {
	it("按 RFC5545 转义顺序处理（先反斜杠）", () => {
		expect(escapeIcsText("a\\b,c;d\ne\rf")).toBe("a\\\\b\\,c\\;d\\ne\\nf");
	});
});

describe("downloadIcs", () => {
	it("构造 text/calendar Blob 并以标题命名触发下载", () => {
		const clicks: string[] = [];
		const appended: Node[] = [];
		const origCreate = URL.createObjectURL;
		const origRevoke = URL.revokeObjectURL;
		URL.createObjectURL = ((blob: Blob) => {
			expect(blob.type).toBe("text/calendar;charset=utf-8");
			return "blob:ics";
		}) as typeof URL.createObjectURL;
		URL.revokeObjectURL = (() => undefined) as typeof URL.revokeObjectURL;
		const origCreateElement = document.createElement.bind(document);
		vi.spyOn(document, "createElement").mockImplementation((tag: string) => {
			const el = origCreateElement(tag);
			if (tag === "a") {
				el.click = () => clicks.push((el as HTMLAnchorElement).download);
			}
			return el;
		});
		vi.spyOn(document.body, "appendChild").mockImplementation((node) => {
			appended.push(node);
			return node;
		});

		downloadIcs(BASE);

		expect(clicks).toEqual(["教研分享会.ics"]);
		expect(appended).toHaveLength(1);
		URL.createObjectURL = origCreate;
		URL.revokeObjectURL = origRevoke;
		vi.restoreAllMocks();
	});
});
