import { gql } from "@apollo/client";
import type { TypedDocumentNode } from "@apollo/client";
import { client } from "@/lib/apollo-client";

/** 公开页押金明细（#627）：金额缺失/非正 → amountCents 为 null，enabled 仍 true（#586 口径） */
export type InitiativeDeposit = {
	enabled: boolean;
	amountCents: number | null;
	refundableOnCheckIn: boolean | null;
};

/** 缴费槽三态（#586 单源：Offering.payment_mode/1）；free 与「押金未定」不可混 */
export type InitiativePaymentMode = "free" | "pricing" | "deposit";

export type InitiativeEvent = {
	id: string;
	slug: string;
	title: string;
	status: "open" | "closed" | "cancelled";
	visibility: "public" | "workspace";
	startsAt: string | null;
	endsAt: string | null;
	registrationDeadline: string | null;
	venue: string | null;
	confirmedCount: number;
	minParticipants: number | null;
	qualificationStatus: string | null;
	/** 后端派生成班徽章（与小程序同口径；archived = closed/cancelled 留档只读） */
	qualificationBadge: "cancelled" | "closed" | "confirmed" | "short_by" | "open";
	shortBy: number | null;
	archived: boolean;
	/** 参与条件（#627）：缴费槽三态，单槽互斥，不与成班徽章混算 */
	paymentMode: InitiativePaymentMode;
	deposit: InitiativeDeposit;
	/** 年龄门槛存在性（nil = 无门槛）；不投校验策略 */
	minAge: number | null;
	/** 收费态金额锚（可售档位最小值，分）；无金额锚 → null（不臆造金额） */
	priceRangeMinCents: number | null;
};

export type PublicInitiative = {
	id: string;
	name: string;
	slug: string;
	hashtag: string | null;
	description: string | null;
	status: string;
	/** 倡导窗口起止（ISO8601，可为 null）；列表卡片与详情 hero 共用 */
	windowStartsAt: string | null;
	windowEndsAt: string | null;
	cityCount: number;
	eventCount: number;
	confirmedCount: number;
	qualifiedEventCount: number;
	cities: Array<{ city: string; events: InitiativeEvent[] }>;
};

export type PublicInitiativeCard = Pick<
	PublicInitiative,
	| "id"
	| "name"
	| "slug"
	| "status"
	| "hashtag"
	| "description"
	| "windowStartsAt"
	| "windowEndsAt"
>;

/** #596 挂载前预览：单条规则的原始值（JSON 字符串，与 admin 面同口径）+ 锁态 */
export type InitiativeRulePreview = {
	key: string;
	valueJson: string;
	locked: boolean;
};

/**
 * #596 挂载前预览读面（Owner/Admin 专属，后端 `RulePreview`）：
 * 四项规则的原始值与锁态 + 未配齐的规则键。普通成员/非成员查询报 forbidden。
 */
export type InitiativeMountPreview = {
	initiativeId: string;
	name: string;
	slug: string;
	status: string;
	rules: InitiativeRulePreview[];
	missingRules: string[];
};

const PUBLIC_INITIATIVE: TypedDocumentNode<
	{ publicInitiative: PublicInitiative | null },
	{ slug: string }
> = gql`
	query PublicInitiative($slug: String!) {
		publicInitiative(slug: $slug) {
			id name slug hashtag description status windowStartsAt windowEndsAt cityCount eventCount confirmedCount qualifiedEventCount
			cities { city events { id slug title status visibility startsAt endsAt registrationDeadline venue confirmedCount minParticipants qualificationStatus qualificationBadge shortBy archived paymentMode deposit { enabled amountCents refundableOnCheckIn } minAge priceRangeMinCents } }
		}
	}
`;

const PUBLIC_INITIATIVES: TypedDocumentNode<
	{ publicInitiatives: PublicInitiativeCard[] },
	Record<string, never>
> = gql`
	query PublicInitiatives {
		publicInitiatives { id name slug hashtag description status windowStartsAt windowEndsAt }
	}
`;

/**
 * #596 挂载前预览（Owner/Admin）：rules 为四项规则的原始值 + 锁态。
 * workspaceId 只作权限判定（规则是平台级数据）；非本台 Owner/Admin → forbidden。
 */
export const INITIATIVE_MOUNT_PREVIEW: TypedDocumentNode<
	{ initiativeMountPreview: InitiativeMountPreview | null },
	{ workspaceId: string; initiativeId: string }
> = gql`
	query InitiativeMountPreview($workspaceId: ID!, $initiativeId: ID!) {
		initiativeMountPreview(workspaceId: $workspaceId, initiativeId: $initiativeId) {
			initiativeId name slug status missingRules
			rules { key valueJson locked }
		}
	}
`;

export async function fetchPublicInitiative(slug: string): Promise<PublicInitiative | null> {
	const { data } = await client.query({ query: PUBLIC_INITIATIVE, variables: { slug }, fetchPolicy: "network-only" });
	return data?.publicInitiative ?? null;
}

export async function fetchPublicInitiatives(): Promise<PublicInitiativeCard[]> {
	const { data } = await client.query({ query: PUBLIC_INITIATIVES, variables: {}, fetchPolicy: "network-only" });
	return data?.publicInitiatives ?? [];
}

/** #596 挂载前预览；无权/失败由调用方 catch 后降级（不阻塞编辑与保存） */
export async function fetchInitiativeMountPreview(
	workspaceId: string,
	initiativeId: string,
): Promise<InitiativeMountPreview | null> {
	const { data } = await client.query({
		query: INITIATIVE_MOUNT_PREVIEW,
		variables: { workspaceId, initiativeId },
		fetchPolicy: "network-only",
	});
	return data?.initiativeMountPreview ?? null;
}
