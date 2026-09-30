import { sentencesWithFogMark, type FlashbackAnswer, type FlashbackFogSpan } from "@/lib/graphql/flashback";

/** 寄出时「放进金句墙」的推荐句（#1022）；questionKey/start/len 即 chosenQuoteSpans 的一项 */
export interface QuoteSuggestion {
	questionKey: string;
	start: number;
	len: number;
	/** 展示用（首尾空白已去；区间仍覆盖整句，含句读） */
	sentence: string;
}

type SuggestionSpot = Pick<QuoteSuggestion, "questionKey" | "start">;

/** 推荐来源 = 当年的自由文本题，按此顺序；os / social_media 是结构化答案，不当金句推荐 */
const SOURCE_KEYS = ["self_intro", "funny_thing"];
// ponytail: 字数门槛是经验值（挡「你好。」这类碎句），看到真实选句分布再调
const MIN_CHARS = 6;
const PHONE_LIKE = /\d{7,}/;

/**
 * 候选 = 来源题里未雾住的句子（雾态取检查页当前选择），排除：含本人全名或名
 * （名 ≥ 2 字才比对，单字名误伤太多）、疑似手机号或邮箱、去空白后不足 6 字。
 * 当年答案几乎没有预先雾化，「我叫王晓雨」这类句子一旦被默认推荐，匿名就破了。
 */
export function quoteSuggestions(
	answers: FlashbackAnswer[],
	spansByAnswer: Record<string, FlashbackFogSpan[] | null | undefined>,
	fullName: string,
	surname?: string | null,
): QuoteSuggestion[] {
	const givenName = surname && fullName.startsWith(surname) ? fullName.slice(surname.length) : Array.from(fullName).slice(1).join("");
	const names = Array.from(givenName).length >= 2 ? [fullName, givenName] : [fullName];

	return SOURCE_KEYS.flatMap((questionKey) =>
		answers
			.filter((answer) => answer.questionKey === questionKey)
			.flatMap((answer) =>
				sentencesWithFogMark(answer.rawText, spansByAnswer[answer.id])
					.filter((sentence) => !sentence.fogged)
					.map((sentence) => ({
						questionKey,
						start: sentence.start,
						len: sentence.len,
						sentence: sentence.text.trim(),
					})),
			),
	).filter(
		({ sentence }) =>
			Array.from(sentence).length >= MIN_CHARS &&
			!names.some((name) => name && sentence.includes(name)) &&
			!PHONE_LIKE.test(sentence) &&
			!sentence.includes("@"),
	);
}

const sameSpot = (a: SuggestionSpot, b: SuggestionSpot) =>
	a.questionKey === b.questionKey && a.start === b.start;

const isAfter = (a: SuggestionSpot, b: SuggestionSpot) => {
	const order = SOURCE_KEYS.indexOf(a.questionKey) - SOURCE_KEYS.indexOf(b.questionKey);
	return order > 0 || (order === 0 && a.start > b.start);
};

/** 当前展示句：选中的还在候选里就是它；被雾住（从候选里消失）→ 顺延到它之后的一句，没有则回到第一句 */
export function currentSuggestion(
	list: QuoteSuggestion[],
	chosen: SuggestionSpot | null,
): QuoteSuggestion | null {
	if (!list.length) return null;
	if (!chosen) return list[0];
	return list.find((item) => sameSpot(item, chosen)) ?? list.find((item) => isAfter(item, chosen)) ?? list[0];
}

/** 「换一句」：循环到下一句 */
export function nextSuggestion(
	list: QuoteSuggestion[],
	current: SuggestionSpot | null,
): QuoteSuggestion | null {
	if (!list.length) return null;
	const index = current ? list.findIndex((item) => sameSpot(item, current)) : -1;
	return list[(index + 1) % list.length];
}
