import { describe, it, expect, afterEach } from "vitest";
import { cleanup, screen } from "@testing-library/react";
import { render } from "@/test-utils";
import Reveal from "./reveal";
import type {
	FlashbackAnswer,
	FlashbackProfile,
	FlashbackProgress,
} from "@/lib/graphql/flashback";

/**
 * 显影卡正面（face=front）自由答案区的 DOM 契约：
 * 题面（.fb-answer-q）与答案（.fb-answer-a）必须是分离的兄弟元素——
 * 视觉审计 2026-09：题面与答案 inline 连排挤在同一行（无空白无断行），
 * 现约定靠 .fb-answer-q 块级化在视觉上分行 >片段。
 */
const FREE_ANSWERS: FlashbackAnswer[] = [
	{
		id: "a1",
		questionKey: "self_intro",
		rawText: "自由插画师一枚，周末在运河边带三个人的小小美术课。",
		fogSpans: null,
	},
	{
		id: "a2",
		questionKey: "funny_thing",
		rawText: "凌晨四点骑车去西湖边等日出画海报。",
		fogSpans: null,
	},
	// PII 句与非常规键不进正面（FREE_TEXT_KEYS 过滤）
	{
		id: "a3",
		questionKey: "phone",
		rawText: "13800000000",
		fogSpans: null,
	},
];

const PROFILE: FlashbackProfile = {
	fullName: "李雯",
	city: "杭州",
	occupationThen: "美术老师",
	gender: "女",
	role: "learner",
	participation: "attended",
	archive: { key: "rails-girls-hangzhou-2013", name: "Rails Girls 杭州", city: "杭州", occurredOn: "2013-06-15" },
	answers: FREE_ANSWERS,
};

const PROGRESS = {} as unknown as FlashbackProgress;

function renderFront() {
	return render(
		<Reveal
			profile={PROFILE}
			line="memory"
			dreamTarget={null}
			quizChoice="correct"
			onRevealed={() => {}}
			role="learner"
			answers={FREE_ANSWERS}
			progress={PROGRESS}
			onWriteNext={() => {}}
		/>,
	);
}

afterEach(() => {
	cleanup();
});

describe("Reveal 显影卡正面答案区（视觉审计 2026-09）", () => {
	it("题面与答案是分离的兄弟元素：q 块只含题面、a 块只含答案", () => {
		renderFront();

		const pairs = document.querySelectorAll(".fb-answer");
		expect(pairs.length).toBe(2); // phone 被 FREE_TEXT_KEYS 过滤

		for (const pair of pairs) {
			const q = pair.querySelector(".fb-answer-q");
			const a = pair.querySelector(".fb-answer-a");
			expect(q).not.toBeNull();
			expect(a).not.toBeNull();
			// q/a 必须是直接相邻的兄弟（视觉分行靠 .fb-answer-q 的 display:block）
			expect(a!.previousElementSibling).toBe(q);
			// 分离：题面文本不出现在答案块，答案文本不出现在题面块
			expect(a!.textContent).not.toBe(q!.textContent);
			expect(q!.textContent).not.toEqual(expect.stringContaining("自由插画师"));
		}

		// 题面取 flashback.questionLabels 的中文文案
		expect(
			screen.getByText("请简单的介绍一下自己"),
		).toBeInTheDocument();
		expect(
			screen.getByText("你做过的有意思的事情"),
		).toBeInTheDocument();
		// 答案原文渲染（FogText spans=null 直出）
		expect(
			screen.getByText(/自由插画师一枚/),
		).toBeInTheDocument();
	});

	it("PII 键（phone/email/full_name）永远不进正面", () => {
		renderFront();
		expect(screen.queryByText("13800000000")).not.toBeInTheDocument();
	});
});
