import { describe, it, expect } from "vitest";
import type { FlashbackAnswer } from "@/lib/graphql/flashback";
import { currentSuggestion, nextSuggestion, quoteSuggestions } from "./quote-suggestion";

const answer = (id: string, questionKey: string, rawText: string): FlashbackAnswer => ({
	id,
	questionKey,
	rawText,
	fogSpans: null,
});

describe("quoteSuggestions（#1022 寄出时「放进金句墙」的推荐句）", () => {
	it("只从当年自由文本题取句，os / social_media 不推荐；自我介绍在前", () => {
		const list = quoteSuggestions(
			[
				answer("a-os", "os", "Windows 7 旗舰版，用了很多年。"),
				answer("a-fun", "funny_thing", "用 Excel 做过一个小游戏。"),
				answer("a-self", "self_intro", "一个刚毕业的文科生。想亲眼看看代码是不是魔法。"),
				answer("a-sm", "social_media", "每天刷微博到半夜。"),
			],
			{},
			"王晓雨",
			"王",
		);

		expect(list.map((s) => s.sentence)).toEqual([
			"一个刚毕业的文科生。",
			"想亲眼看看代码是不是魔法。",
			"用 Excel 做过一个小游戏。",
		]);
		expect(list[0]).toMatchObject({ questionKey: "self_intro", start: 0, len: 10 });
	});

	it("雾住的句子不推荐（按检查页当前雾态）", () => {
		const list = quoteSuggestions(
			[answer("a1", "self_intro", "我是一个文科生。我在深圳做设计。")],
			{ a1: [{ start: 8, len: 8 }] },
			"王晓雨",
			"王",
		);

		expect(list.map((s) => s.sentence)).toEqual(["我是一个文科生。"]);
	});

	it("含本人全名或名（≥ 2 字）、疑似手机号或邮箱、不足 6 字的句子都不推荐", () => {
		const list = quoteSuggestions(
			[
				answer(
					"a1",
					"self_intro",
					"大家好，我是王晓雨。叫我晓雨就好。电话 13800138000。邮箱 wxy@example.com。你好。想亲眼看看代码是不是魔法。",
				),
			],
			{},
			"王晓雨",
			"王",
		);

		expect(list.map((s) => s.sentence)).toEqual(["想亲眼看看代码是不是魔法。"]);
	});

	it("名只有一个字时不按名过滤（避免误伤含同字的句子）", () => {
		const list = quoteSuggestions(
			[answer("a1", "self_intro", "我想做一个芳草地的小网站。")],
			{},
			"李芳",
			"李",
		);

		expect(list.map((s) => s.sentence)).toEqual(["我想做一个芳草地的小网站。"]);
	});
});

describe("currentSuggestion / nextSuggestion", () => {
	const list = quoteSuggestions(
		[answer("a1", "self_intro", "第一句话在这里。第二句话在这里。第三句话在这里。")],
		{},
		"王晓雨",
		"王",
	);

	it("没选过 → 第一句；「换一句」循环", () => {
		expect(currentSuggestion(list, null)?.sentence).toBe("第一句话在这里。");
		expect(nextSuggestion(list, list[0])?.sentence).toBe("第二句话在这里。");
		expect(nextSuggestion(list, list[2])?.sentence).toBe("第一句话在这里。");
	});

	it("选中的句被雾住（从候选里消失）→ 顺延到它之后的一句", () => {
		const remaining = list.filter((s) => s.start !== list[1].start);

		expect(currentSuggestion(remaining, list[1])?.sentence).toBe("第三句话在这里。");
		expect(currentSuggestion(remaining, list[0])?.sentence).toBe("第一句话在这里。");
	});

	it("没有候选 → null", () => {
		expect(currentSuggestion([], null)).toBeNull();
		expect(nextSuggestion([], null)).toBeNull();
	});
});
