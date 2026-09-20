import { gql } from "@apollo/client";
import type { TypedDocumentNode } from "@apollo/client";

/**
 * 闪念间（In a Flash）GraphQL 契约层（U4-U6）——对齐 backend/priv/graphql/schema.graphql
 * 手写 field（U2/U4-U6 落地；schema-contract.test.ts 守卫形状一致性）。
 *
 * 语义纪律：
 * - token 是链接身份（KTD2）：从 URL 读入后即刻 history.replaceState 清除，
 *   内存/sessionStorage 持有，绝不进 next 参数；
 * - 失效走顶层错误 code（flashback_token_not_found/claimed/revoked），前端按
 *   code 映射 messages.errors 文案，不直渲后端 message（错误文案纪律）；
 * - phone/email 明文不出现在任何响应（KTD3），只有掩码回显。
 */

/* ---------------- 类型（SDL 白名单镜像） ---------------- */

/** 雾面区间：grapheme 偏移（start 起、len 长） */
export interface FlashbackFogSpan {
	start: number;
	len: number;
	reason?: string | null;
}

/** 当年答案（本人视图：rawText 永远完整，KTD4） */
export interface FlashbackAnswer {
	id: string;
	questionKey: string;
	rawText: string;
	fogSpans?: FlashbackFogSpan[] | null;
}

export interface FlashbackArchiveRef {
	key: string;
	name?: string | null;
	city?: string | null;
	occurredOn?: string | null;
}

export interface FlashbackProfile {
	fullName: string;
	surname?: string | null;
	city?: string | null;
	occupationThen?: string | null;
	gender?: string | null;
	role: string;
	participation: string;
	appliedAt?: string | null;
	archive?: FlashbackArchiveRef | null;
	answers?: FlashbackAnswer[] | null;
}

export interface FlashbackToday {
	nowStatus?: string | null;
	want?: string | null;
	need?: string | null;
	say?: string | null;
	wantGiveTags?: string[] | null;
	mobilization?: Record<string, unknown> | null;
	newsletterOptIn?: boolean | null;
	reconnectTags?: string[] | null;
	/** 句级雾面(field(now/want/need/say) → spans);本人管理面专用 */
	fogSpans?: Record<string, Array<{ start: number; len: number }>> | null;
	sentToWallAt?: string | null;
}

export interface FlashbackProgress {
	today?: FlashbackToday | null;
	quoteLevel: string;
	maskedPhone?: string | null;
	maskedEmail?: string | null;
}

/** "memory"（记忆线）| "dream"（圆梦线） */
export type FlashbackLine = "memory" | "dream";

export interface FlashbackScatterPhoto {
	photoKey: string;
	/** 场次全名「年份 · 城市」——问答选项与读屏线索用（散照卡只显日期戳） */
	label: string;
	/** 拍立得日期戳「2016 10 15」——放大时渐显，只给日期不给城市（谜不泄底） */
	dateStamp: string;
	isMine: boolean;
	/** 照片主人姓氏（前端渲染姓氏级脱敏 王**，R12） */
	surname?: string | null;
}

export interface FlashbackEnterResult {
	line: FlashbackLine;
	profile?: FlashbackProfile | null;
	progress?: FlashbackProgress | null;
	/** 桌面散照候选（批次二散照迭代）：本人那张 + 其他场次各一人；单场库仅本人 */
	scatter?: { entries: FlashbackScatterPhoto[] } | null;
}

/** 场次线索标签「年份 · 城市」（散照/问答共用口径，与后端 scatter_label 同源） */
export function scatterLabelOf(
	archive?: { city?: string | null; occurredOn?: string | null } | null,
): string {
	const year = archive?.occurredOn?.slice(0, 4) ?? "";
	const city = archive?.city ?? "";
	return [year, city].filter(Boolean).join(" · ");
}

export interface FlashbackSendToWallResult {
	sentToWallAt?: string | null;
	maskedPhone?: string | null;
	maskedEmail?: string | null;
}

export interface FlashbackQuoteLicenseResult {
	level: string;
	chosenQuoteSpans?: { questionKey: string; start: number; len: number }[] | null;
	creditedNote?: string | null;
}

export interface FlashbackRegisterBindResult {
	bound: boolean;
	maskedPhone?: string | null;
}

export interface FlashbackUpdateContactResult {
	maskedPhone?: string | null;
	updated: boolean;
}

export interface FlashbackTodayInput {
	nowStatus?: string;
	want?: string;
	need?: string;
	say?: string;
	wantGiveTags?: string[];
	mobilizationJoin1024?: boolean;
	mobilizationHelpPromote?: boolean;
	mobilizationDonateIntent?: boolean;
	mobilizationVolunteerLead?: boolean;
	newsletterOptIn?: boolean;
	reconnectTags?: string[];
}

/** 圆梦线 CTA 两态（U4）：本城最近一场可报名公开场次；null = 无场次（落 Initiative 公开页） */
export interface FlashbackDreamTarget {
	eventSlug: string;
	eventTitle: string;
	startsAt?: string | null;
	initiativeSlug: string;
}

/* ---------------- U5 时间胶囊（校友层） ---------------- */

/** Action 卡四态（R13 生命周期） */
/** 雾面段（对外版）：fog=true 时 text 恒空——原文字符不出 DOM */
export interface FlashbackRosterSegment {
	text: string;
	fog: boolean;
	len: number;
}

export interface FlashbackRosterAnswer {
	questionKey: string;
	/** 段结构：明文段与雾面段交替（雾面段零字符泄露，KTD4） */
	segments: FlashbackRosterSegment[];
}

export interface FlashbackRosterEntry {
	id: string;
	surnameMasked: string;
	/** 寄出者全名（她回来了即亮名）；未寄出者 null（R12 隐名） */
	fullName?: string | null;
	/** 寄出者的报名时间戳（翻转卡正面白边）；未寄出者 null */
	appliedAt?: string | null;
	city?: string | null;
	occupationThen?: string | null;
	sentToWallAt?: string | null;
	today?: { nowStatus?: string | null; want?: string | null; say?: string | null } | null;
	answers: FlashbackRosterAnswer[];
}

export interface FlashbackCapsuleArchive {
	key: string;
	name?: string | null;
	city?: string | null;
	occurredOn?: string | null;
	appliedCount?: number | null;
	attendedCount?: number | null;
	/** 长廊场次格叙事短标签（原型 D ia-frame-label）：「六城同日」写故事不写地名 */
	label?: string | null;
	isMine: boolean;
	roster: FlashbackRosterEntry[];
}

export interface FlashbackCapsuleMe {
	id: string;
	fullName: string;
	surname?: string | null;
	city?: string | null;
	occupationThen?: string | null;
	participation: string;
	appliedAt?: string | null;
	today?: FlashbackToday | null;
	/** 选定金句（R14 摘要卡；off/未选为 null） */
	quote?: string | null;
	/** 金句授权档（R31/R37：off/anonymous/credited）——分享 opt-in 用它判断是否已授权 */
	quoteLevel?: string | null;
	/** 句子白名单区间（多选；首句 = 消费面展示句，圈选器回显全量） */
	quoteSpans?: { questionKey: string; start: number; len: number }[] | null;
	/** 本人金句点赞数（R36；未授权档为 null） */
	quoteStats?: { likeCount: number } | null;
	/** 本人当年答案雾化版（R15 全文卡；text 形态——me 面 SDL 独立，本人导出用） */
	answers: FlashbackMeAnswer[];
}

/** 本人答案（胶囊 me / 全文卡导出）：雾化版 text + 完整原文与区间（KTD4 本人完整） */
export interface FlashbackMeAnswer {
	id: string;
	questionKey: string;
	rawText: string;
	fogSpans?: FlashbackFogSpan[] | null;
	text: string;
}

export interface FlashbackWishComment {
	id: string;
	content: string;
	commenterMasked: string | null;
	insertedAt: string;
}

export interface FlashbackWish {
	id: string;
	content: string;
	city: string | null;
	wisherMasked: string | null;
	endorsementCount: number;
	endorsedByMe: boolean;
	/** 本人许愿（删除入口只对本人显示，R14） */
	mine: boolean;
	comments: FlashbackWishComment[];
	insertedAt: string;
}

export interface FlashbackFutureEvent {
	id: string;
	slug: string;
	title: string;
	city: string | null;
	startsAt: string | null;
	capacity: number | null;
	confirmedCount: number;
	registrationDeadline: string | null;
}

export interface FlashbackFutureFrame {
	initiativeSlug: string;
	initiativeName: string;
	events: FlashbackFutureEvent[];
}

export interface FlashbackCapsule {
	me: FlashbackCapsuleMe;
	archives: FlashbackCapsuleArchive[];
	/** 未来场次帧（KTD1）：按 initiative 分组、时间升序 */
	futureEvents: FlashbackFutureFrame[];
	/** 公开愿望（附议数降序） */
	publicWishes: FlashbackWish[];
	/** 本人私有许愿（仅自己可见） */
	myPrivateWishes: FlashbackWish[];
	/** 城市钉数据源（KTD6）：名册 ∪ 未来场次 ∪ 公开许愿城市 */
	cities: string[];
}

/* ---------------- U6 公开层（路人） ---------------- */

export interface FlashbackPublicStatsArchive {
	key: string;
	name?: string | null;
	city?: string | null;
	occurredOn?: string | null;
	appliedCount?: number | null;
	attendedCount?: number | null;
	label?: string | null;
}

export interface FlashbackPublicStats {
	archives: FlashbackPublicStatsArchive[];
	returnedCount: number;
	sentCount: number;
}

export interface FlashbackPublicQuote {
	text: string;
	/** 署名：王** · 年 · 城 */
	attribution: string;
	level: string;
	/** credited 档才有：链实名档案页 */
	publicSlug?: string | null;
	/** 点赞定位键（R36）：flashbackLikeQuote 的 personId 入参 */
	personId: string;
	/** 实时点赞数（R36） */
	likeCount: number;
	/** 本访客是否已赞（按 voterKey 去重） */
	likedByViewer: boolean;
}

export interface FlashbackPublicProfile {
	fullName: string;
	city?: string | null;
	eventName?: string | null;
	year?: number | null;
	creditedNote?: string | null;
	quote: string;
}

export interface FlashbackRecoverCard {
	personId: string;
	surnameMasked: string;
	eventName?: string | null;
	city?: string | null;
}

/* ---------------- Query / Mutation TypedDocumentNode ---------------- */

/** 进入首程（R1/R2）：分流 + 本人档案 + 进度快照；失效走顶层错误 code */
export const FLASHBACK_ENTER: TypedDocumentNode<
	{ flashbackEnter: FlashbackEnterResult },
	{ token: string }
> = gql`
	mutation FlashbackEnter($token: String!) {
		flashbackEnter(token: $token) {
			line
			profile {
				fullName
				surname
				city
				occupationThen
				gender
				role
				participation
				appliedAt
				archive {
					key
					name
					city
					occurredOn
				}
				answers {
					id
					questionKey
					rawText
					fogSpans {
						start
						len
						reason
					}
				}
			}
			progress {
				today {
					nowStatus
					want
					need
					say
					wantGiveTags
					mobilization
					newsletterOptIn
					reconnectTags
					sentToWallAt
				}
				quoteLevel
				maskedPhone
				maskedEmail
			}
			scatter {
				entries {
					photoKey
					label
					dateStamp
					isMine
					surname
				}
			}
		}
	}
`;

/** 认领显影完成（四率之 revealed；前端显影完成时调用一次） */
export const FLASHBACK_MARK_REVEALED: TypedDocumentNode<
	{ flashbackMarkRevealed: { recorded: boolean } },
	{ token: string }
> = gql`
	mutation FlashbackMarkRevealed($token: String!) {
		flashbackMarkRevealed(token: $token) {
			recorded
		}
	}
`;

/** 提交「今天的你」（覆盖式；期望管理文案在提交成功后展示，R29） */
export const FLASHBACK_SUBMIT_TODAY: TypedDocumentNode<
	{ flashbackSubmitToday: { today: FlashbackToday } },
	{ token: string; input: FlashbackTodayInput }
> = gql`
	mutation FlashbackSubmitToday($token: String!, $input: FlashbackTodayInput!) {
		flashbackSubmitToday(token: $token, input: $input) {
			today {
				nowStatus
				want
				need
				say
				wantGiveTags
				mobilization
				newsletterOptIn
				reconnectTags
				sentToWallAt
			}
		}
	}
`;

/** 寄出上墙（R11，幂等）；返回注册引导掩码回显（R27） */
export const FLASHBACK_SEND_TO_WALL: TypedDocumentNode<
	{ flashbackSendToWall: FlashbackSendToWallResult },
	{ token: string }
> = gql`
	mutation FlashbackSendToWall($token: String!) {
		flashbackSendToWall(token: $token) {
			sentToWallAt
			maskedPhone
			maskedEmail
		}
	}
`;

/** 调整雾面区间（R16/KTD4）：只改 spans，原文不可达 */
export const FLASHBACK_ADJUST_FOG: TypedDocumentNode<
	{ flashbackAdjustFog: { answerId: string; fogSpans: FlashbackFogSpan[] } },
	{ token: string; answerId: string; spans: FlashbackFogSpan[] }
> = gql`
	mutation FlashbackAdjustFog($token: String!, $answerId: ID!, $spans: [FlashbackFogSpanInput!]!) {
		flashbackAdjustFog(token: $token, answerId: $answerId, spans: $spans) {
			answerId
			fogSpans {
				start
				len
				reason
			}
		}
	}
`;

/** 金句授权（R31 两档 + 关） */
export const FLASHBACK_SET_QUOTE_LICENSE: TypedDocumentNode<
	{ flashbackSetQuoteLicense: FlashbackQuoteLicenseResult },
	{
		token: string;
		level: string;
		chosenQuoteSpans?: { questionKey: string; start: number; len: number }[];
		creditedNote?: string;
	}
> = gql`
	mutation FlashbackSetQuoteLicense(
		$token: String!
		$level: String!
		$chosenQuoteSpans: [FlashbackQuoteSpanInput!]
		$creditedNote: String
	) {
		flashbackSetQuoteLicense(
			token: $token
			level: $level
			chosenQuoteSpans: $chosenQuoteSpans
			creditedNote: $creditedNote
		) {
			level
			chosenQuoteSpans {
				questionKey
				start
				len
			}
			creditedNote
		}
	}
`;

/** 注册绑定（R27 寄出时刻一步注册；会话经 httpOnly cookie 交付） */
export const FLASHBACK_REGISTER_BIND: TypedDocumentNode<
	{ flashbackRegisterBind: FlashbackRegisterBindResult },
	{ token: string; phone: string; code: string }
> = gql`
	mutation FlashbackRegisterBind($token: String!, $phone: String!, $code: String!) {
		flashbackRegisterBind(token: $token, phone: $phone, code: $code) {
			bound
			maskedPhone
		}
	}
`;

/** 更新手机号（R17/KTD7 防劫持：新通道先验证；purpose=CHANGE_PHONE 发码） */
export const FLASHBACK_UPDATE_CONTACT: TypedDocumentNode<
	{ flashbackUpdateContact: FlashbackUpdateContactResult },
	{ token: string; phone: string; code: string }
> = gql`
	mutation FlashbackUpdateContact($token: String!, $phone: String!, $code: String!) {
		flashbackUpdateContact(token: $token, phone: $phone, code: $code) {
			maskedPhone
			updated
		}
	}
`;

/** 撤下（R30 免注册一键）：名册回到结构化卡 */
export const FLASHBACK_RETRACT: TypedDocumentNode<
	{ flashbackRetract: { retracted: boolean; sentToWallAt?: string | null } },
	{ token: string }
> = gql`
	mutation FlashbackRetract($token: String!) {
		flashbackRetract(token: $token) {
			retracted
			sentToWallAt
		}
	}
`;

/** 圆梦线 CTA 两态判定（U4）：匿名可读的指路数据 */
export const FLASHBACK_DREAM_TARGET: TypedDocumentNode<
	{ flashbackDreamTarget: FlashbackDreamTarget | null },
	{ city?: string | null }
> = gql`
	query FlashbackDreamTarget($city: String) {
		flashbackDreamTarget(city: $city) {
			eventSlug
			eventTitle
			startsAt
			initiativeSlug
		}
	}
`;

/** 时间胶囊读面（U5/R12/R13）：token 或登录态双入口；city（R34 城市钉）筛选 */
export const FLASHBACK_CAPSULE: TypedDocumentNode<
	{ flashbackCapsule: FlashbackCapsule | null },
	{ token?: string | null; city?: string | null }
> = gql`
	query FlashbackCapsule($token: String, $city: String) {
		flashbackCapsule(token: $token, city: $city) {
			me {
				id
				fullName
				surname
				city
				occupationThen
				participation
				appliedAt
				today {
					nowStatus
					want
					need
					say
					fogSpans
					sentToWallAt
				}
				quote
				quoteLevel
				quoteSpans {
					questionKey
					start
					len
				}
				quoteStats {
					likeCount
				}
				answers {
					questionKey
					text
				}
			}
			archives {
				key
				name
				city
				occurredOn
				appliedCount
				attendedCount
				label
				isMine
				roster {
					id
					surnameMasked
					fullName
					appliedAt
					city
					occupationThen
					sentToWallAt
					today {
						nowStatus
						want
						say
					}
					answers {
						questionKey
						segments {
							text
							fog
							len
						}
					}
				}
			}
			futureEvents {
				initiativeSlug
				initiativeName
				events {
					id
					slug
					title
					city
					startsAt
					capacity
					confirmedCount
					registrationDeadline
				}
			}
			publicWishes {
				id
				content
				city
				wisherMasked
				endorsementCount
				endorsedByMe
				mine
				comments {
					id
					content
					commenterMasked
					insertedAt
				}
				insertedAt
			}
			myPrivateWishes {
				id
				content
				city
				wisherMasked
				endorsementCount
				endorsedByMe
				insertedAt
			}
			cities
		}
	}
`;



export interface FogSegment {
	text: string;
	fog: boolean;
}

/**
 * 按 fog_spans 把原文切成渲染段（grapheme 偏移 → code point 近似：导入文本为
 * 中文 + ASCII，两者等价；emoji 组合字符的边缘差异不影响遮蔽语义）。
 * 区间非法（越界/负长）静默丢弃，渲染退化为全文——遮蔽失败不炸渲染。
 */
export function applyFogSpans(
	text: string,
	spans: FlashbackFogSpan[] | null | undefined,
): FogSegment[] {
	const chars = Array.from(text);
	const total = chars.length;
	const sorted = [...(spans ?? [])]
		.filter((s) => Number.isInteger(s.start) && Number.isInteger(s.len) && s.start >= 0 && s.len > 0)
		.sort((a, b) => a.start - b.start);

	const segments: FogSegment[] = [];
	let cursor = 0;

	for (const span of sorted) {
		if (span.start < cursor) continue; // 重叠区间丢弃（后端校验兜底）
		const end = Math.min(span.start + span.len, total);
		if (span.start >= total) break;
		if (span.start > cursor) {
			segments.push({ text: chars.slice(cursor, span.start).join(""), fog: false });
		}
		segments.push({ text: chars.slice(span.start, end).join(""), fog: true });
		cursor = end;
	}

	if (cursor < total) {
		segments.push({ text: chars.slice(cursor).join(""), fog: false });
	}

	return segments;
}

/** 姓氏隐名（R12）：全名 →「王**」（保留姓、隐去名；无姓可依时整体脱敏） */
export function surnameMasked(fullName: string, surname?: string | null): string {
	if (surname && fullName.startsWith(surname) && fullName.length > surname.length) {
		return `${surname}${"*".repeat(Math.max(fullName.length - surname.length, 1))}`;
	}
	// surname 缺失或不匹配（导入数据边缘）：首个字符作姓兜底
	const chars = Array.from(fullName);
	if (chars.length <= 1) return fullName;
	return `${chars[0]}${"*".repeat(chars.length - 1)}`;
}

/**
 * 相对年数（R3/AE1）：按本人 appliedAt 动态计算；不足一年返回 0，
 * 时间戳缺失由调用方回落「当年的你」文案。
 */
export function yearsAgo(appliedAt: string | null | undefined, now = new Date()): number {
	if (!appliedAt) return 0;
	const applied = new Date(appliedAt);
	if (Number.isNaN(applied.getTime())) return 0;
	let years = now.getFullYear() - applied.getFullYear();
	const beforeAnniversary =
		now.getMonth() < applied.getMonth() ||
		(now.getMonth() === applied.getMonth() && now.getDate() < applied.getDate());
	if (beforeAnniversary && years > 0) years -= 1;
	return Math.max(years, 0);
}

/** 报名时间戳展示（R3）：「12 年前的 13:06，你写下了这段话」的日期部分 */
export function appliedStamp(appliedAt: string | null | undefined): string | null {
	if (!appliedAt) return null;
	const applied = new Date(appliedAt);
	if (Number.isNaN(applied.getTime())) return null;
	return applied.toISOString().slice(0, 10).replace(/-/g, ".");
}

/**
 * 从答案切句（金句候选，R14/R31）：按中文句读与换行切段，供「选一句金句」
 * 列表与摘要卡取材；空段丢弃。金句候选只从**非雾面**句子取（U5 摘要卡纪律）。
 */
export function splitSentences(text: string): string[] {
	return text
		.split(/(?<=[。！？!?\n])/)
		.map((s) => s.trim())
		.filter((s) => s.length > 0);
}

/** 删除摘要（U10/R30 二次确认页数据源）：双入口（token 或登录态） */
export const FLASHBACK_DELETE_PREVIEW: TypedDocumentNode<
	{
		flashbackDeletePreview: {
			personId: string;
			fullName: string;
			sentToWallAt?: string | null;
			endorsementCount: number;
			alreadyDeleted: boolean;
		} | null;
	},
	{ token?: string | null }
> = gql`
	query FlashbackDeletePreview($token: String) {
		flashbackDeletePreview(token: $token) {
			personId
			fullName
			sentToWallAt
			endorsementCount
			alreadyDeleted
		}
	}
`;

/** 删除我的档案（U10/R30/ADR-0015）：不可逆；confirm 必须为 "DELETE" */
export const FLASHBACK_DELETE: TypedDocumentNode<
	{ flashbackDelete: { deleted: boolean; deletedAt: string } },
	{ token?: string | null; confirm: string }
> = gql`
	mutation FlashbackDelete($token: String, $confirm: String!) {
		flashbackDelete(token: $token, confirm: $confirm) {
			deleted
			deletedAt
		}
	}
`;

/** 公开统计层（U6/R32）：匿名可读的聚合数字 */
export const FLASHBACK_PUBLIC_STATS: TypedDocumentNode<
	{ flashbackPublicStats: FlashbackPublicStats },
	Record<string, never>
> = gql`
	query FlashbackPublicStats {
		flashbackPublicStats {
			archives {
				key
				name
				city
				occurredOn
				appliedCount
				attendedCount
				label
			}
			returnedCount
			sentCount
		}
	}
`;

/** 匿名金句墙（U6/R31/R32）：授权者的脱敏金句 */
export const FLASHBACK_PUBLIC_QUOTES: TypedDocumentNode<
	{ flashbackPublicQuotes: FlashbackPublicQuote[] },
	{ voterKey?: string | null }
> = gql`
	query FlashbackPublicQuotes($voterKey: String) {
		flashbackPublicQuotes(voterKey: $voterKey) {
			text
			attribution
			level
			publicSlug
			personId
			likeCount
			likedByViewer
		}
	}
`;

/** 点赞/取消（R36）：公开无登录，voterKey 去重 + IP 限频；返回实时计数 */
export const FLASHBACK_LIKE_QUOTE: TypedDocumentNode<
	{ flashbackLikeQuote: { likeCount: number } },
	{ personId: string; voterKey: string; liked: boolean }
> = gql`
	mutation FlashbackLikeQuote($personId: ID!, $voterKey: String!, $liked: Boolean!) {
		flashbackLikeQuote(personId: $personId, voterKey: $voterKey, liked: $liked) {
			likeCount
		}
	}
`;

/** 实名档案页（U6/R31 credited 档）：null = 未授权（404 态） */
export const FLASHBACK_PUBLIC_PROFILE: TypedDocumentNode<
	{ flashbackPublicProfile: FlashbackPublicProfile | null },
	{ slug: string }
> = gql`
	query FlashbackPublicProfile($slug: String!) {
		flashbackPublicProfile(slug: $slug) {
			fullName
			city
			eventName
			year
			creditedNote
			quote
		}
	}
`;

/** 自助找回·发起（U6/R21）：命中与未命中同形返回（不泄露存在性） */
export const FLASHBACK_RECOVER: TypedDocumentNode<
	{ flashbackRecover: { dispatched: boolean } },
	{ identifier: string }
> = gql`
	mutation FlashbackRecover($identifier: String!) {
		flashbackRecover(identifier: $identifier) {
			dispatched
		}
	}
`;

/** 自助找回·验证（U6/R21）：手机码通过 → 绑定全部匹配档案；多档案返回「你的 N 张卡」 */
export const FLASHBACK_RECOVER_VERIFY: TypedDocumentNode<
	{ flashbackRecoverVerify: { bound: boolean; cards: FlashbackRecoverCard[] } },
	{ identifier: string; code: string }
> = gql`
	mutation FlashbackRecoverVerify($identifier: String!, $code: String!) {
		flashbackRecoverVerify(identifier: $identifier, code: $code) {
			bound
			cards {
				personId
				surnameMasked
				eventName
				city
			}
		}
	}
`;

/* ---------------- 许愿（U4/R5-R14） ---------------- */

export const FLASHBACK_CREATE_WISH = gql`
	mutation FlashbackCreateWish($token: String, $content: String!, $visibility: String!) {
		flashbackCreateWish(token: $token, content: $content, visibility: $visibility) {
			endorsementCount
			endorsedByMe
		}
	}
`;

export const FLASHBACK_ENDORSE_WISH = gql`
	mutation FlashbackEndorseWish($token: String, $wishId: ID!) {
		flashbackEndorseWish(token: $token, wishId: $wishId) {
			endorsementCount
			endorsedByMe
		}
	}
`;

export const FLASHBACK_ADD_WISH_COMMENT = gql`
	mutation FlashbackAddWishComment($token: String, $wishId: ID!, $content: String!) {
		flashbackAddWishComment(token: $token, wishId: $wishId, content: $content) {
			endorsementCount
			endorsedByMe
		}
	}
`;

export const FLASHBACK_DELETE_WISH = gql`
	mutation FlashbackDeleteWish($token: String, $wishId: ID!) {
		flashbackDeleteWish(token: $token, wishId: $wishId)
	}
`;

export const FLASHBACK_DELETE_WISH_COMMENT = gql`
	mutation FlashbackDeleteWishComment($token: String, $commentId: ID!) {
		flashbackDeleteWishComment(token: $token, commentId: $commentId)
	}
`;
