import { gql } from "@apollo/client";
import type { TypedDocumentNode } from "@apollo/client";
import { client } from "@/lib/apollo-client";
import { fetchMyWorkspaces } from "@/lib/workspaces";

/**
 * 志愿者招募域数据面（R10/R11；U5 的 GraphQL 面在 web 的消费层）。
 *
 * 招募活动全部落在 2046 台（KTD2/KTD8），入口一律走显式 `workspaceId` argument
 * （#104 惯例）。**公开端没有匿名反查工作台 id 的口子**（`getWorkspace(slug:)`
 * 需登录、批次查询也需显式 id），故 workspaceId 由当前用户的成员列表按
 * `CAMPAIGN_WORKSPACE_SLUG` 解析（注册流程自带 2046 入座，见
 * `MembershipContext.admit_to_default_workspace/1`）——申请页的批次/档案/申请
 * 读面因此都在登录态内（与小程序招募流「登录后批次/职位渲染」同口径）。
 *
 * 简历上传的调用顺序是**先建档再上传**（U2 契约）：未建档 → `resume_profile_not_found`。
 */

/** 招募活动工作台 slug（KTD8：所有倡导活动都在 2046 台；后端种子同值） */
export const CAMPAIGN_WORKSPACE_SLUG = "2046";

export type RecruitmentCohortStatus = "draft" | "open" | "closed";

/** 招募批次（只投影公开面需要的四项 + 状态） */
export type RecruitmentCohort = {
	id: string;
	name: string;
	/** 申请截止（ISO8601，展示走既有格式化路径） */
	applyDeadlineAt: string;
	startsAt: string | null;
	endsAt: string | null;
	status: RecruitmentCohortStatus;
};

/** 职位枚举（KTD4：代码枚举 + i18n 文案，不建职位表） */
export type VolunteerPosition = "event_moderator" | "tutor" | "coach";

/** 段位（R12 状态图；assigned 为终态，rejected/canceled 为审核段终止） */
export type VolunteerApplicationStatus =
	| "submitted"
	| "interview"
	| "training"
	| "assigned"
	| "rejected"
	| "canceled";

/** 审核中的四段（我的申请段位条用） */
export const VOLUNTEER_REVIEW_STAGES = [
	"submitted",
	"interview",
	"training",
	"assigned",
] as const;

/** 简历档案（文件内容列不出 GraphQL，只有元数据；U2 管道写入） */
export type ResumeProfile = {
	id: string;
	fullName: string;
	contactEmail: string;
	weeklyHours: number | null;
	skills: string[];
	fileName: string | null;
	fileContentType: string | null;
	fileSize: number | null;
	uploadedAt: string | null;
};

/** 志愿者申请（跨批次列表，后端按新→旧排序） */
export type VolunteerApplication = {
	id: string;
	cohortId: string;
	position: VolunteerPosition;
	city: string | null;
	heardAboutUs: string | null;
	hasInternalReferrer: boolean;
	message: string | null;
	status: VolunteerApplicationStatus;
	rejectionReason: string | null;
	assignedAt: string | null;
	assignmentNote: string | null;
};

/** mutation 业务错误（AshGraphql payload 通道；code 稳定，文案查 errors.<code>） */
export type MutationError = {
	message: string | null;
	code: string | null;
};

/** payload 通道返回（result 失败为 null；errors 为业务错误） */
export type MutationOutcome<T> = {
	result: T | null;
	errors: MutationError[];
};

export type UpsertResumeProfileInput = {
	fullName: string;
	contactEmail: string;
	weeklyHours?: number | null;
	skills?: string[];
};

export type UploadResumeFileInput = {
	fileName: string;
	contentType: string;
	/** 标准 base64（原始文件 ≤5MB，KTD3） */
	contentBase64: string;
};

export type CreateVolunteerApplicationInput = {
	cohortId: string;
	position: VolunteerPosition;
	city?: string | null;
	heardAboutUs?: string | null;
	hasInternalReferrer?: boolean;
	message?: string | null;
};

const COHORT_FIELDS = `id name applyDeadlineAt startsAt endsAt status`;

const CURRENT_RECRUITMENT_COHORT: TypedDocumentNode<
	{ currentRecruitmentCohort: RecruitmentCohort | null },
	{ workspaceId: string }
> = gql`
	query CurrentRecruitmentCohort($workspaceId: ID!) {
		currentRecruitmentCohort(workspaceId: $workspaceId) { ${COHORT_FIELDS} }
	}
`;

const MY_RESUME_PROFILE: TypedDocumentNode<
	{ myResumeProfile: ResumeProfile | null },
	{ workspaceId: string }
> = gql`
	query MyResumeProfile($workspaceId: ID!) {
		myResumeProfile(workspaceId: $workspaceId) {
			id fullName contactEmail weeklyHours skills fileName fileContentType fileSize uploadedAt
		}
	}
`;

const MY_VOLUNTEER_APPLICATIONS: TypedDocumentNode<
	{ myVolunteerApplications: VolunteerApplication[] },
	{ workspaceId: string }
> = gql`
	query MyVolunteerApplications($workspaceId: ID!) {
		myVolunteerApplications(workspaceId: $workspaceId) {
			id cohortId position city heardAboutUs hasInternalReferrer message status rejectionReason assignedAt assignmentNote
		}
	}
`;

const UPSERT_RESUME_PROFILE: TypedDocumentNode<
	{ upsertResumeProfile: MutationOutcome<ResumeProfile> },
	{ workspaceId: string; input: UpsertResumeProfileInput }
> = gql`
	mutation UpsertResumeProfile($workspaceId: ID!, $input: UpsertResumeProfileInput!) {
		upsertResumeProfile(workspaceId: $workspaceId, input: $input) {
			result { id fullName contactEmail weeklyHours skills fileName fileContentType fileSize uploadedAt }
			errors { message code }
		}
	}
`;

const UPLOAD_RESUME_FILE: TypedDocumentNode<
	{ uploadResumeFile: MutationOutcome<ResumeProfile> },
	{ workspaceId: string; input: UploadResumeFileInput }
> = gql`
	mutation UploadResumeFile($workspaceId: ID!, $input: UploadResumeFileInput!) {
		uploadResumeFile(workspaceId: $workspaceId, input: $input) {
			result { id fullName contactEmail weeklyHours skills fileName fileContentType fileSize uploadedAt }
			errors { message code }
		}
	}
`;

const CREATE_VOLUNTEER_APPLICATION: TypedDocumentNode<
	{ createVolunteerApplication: MutationOutcome<VolunteerApplication> },
	{ workspaceId: string; input: CreateVolunteerApplicationInput }
> = gql`
	mutation CreateVolunteerApplication($workspaceId: ID!, $input: CreateVolunteerApplicationInput!) {
		createVolunteerApplication(workspaceId: $workspaceId, input: $input) {
			result { id cohortId position city heardAboutUs hasInternalReferrer message status rejectionReason assignedAt assignmentNote }
			errors { message code }
		}
	}
`;

/** payload 未返回内容时的收口（与 admin.ts 的 `?? { result: null, errors: [] }` 同口径） */
type ResumeProfilePayload = { result: ResumeProfile | null; errors: MutationError[] };
type VolunteerApplicationPayload = {
	result: VolunteerApplication | null;
	errors: MutationError[];
};

/**
 * 解析招募活动工作台的 id（当前用户成员列表按 slug 命中）。
 *
 * 未命中抛错：调用方按「批次读取失败 + 重试」渲染（不是「无开放批次」空态——
 * 那是另一码事，两态混淆会让页面说谎）。
 */
export async function fetchCampaignWorkspaceId(): Promise<string> {
	const workspaces = await fetchMyWorkspaces();
	const campaign = workspaces.find((ws) => ws.slug === CAMPAIGN_WORKSPACE_SLUG);
	if (!campaign) {
		throw new Error(`campaign workspace not found: ${CAMPAIGN_WORKSPACE_SLUG}`);
	}
	return campaign.id;
}

/** 当前 open 批次（无 open 批次 → null；draft/closed 不因本查询露面） */
export async function fetchCurrentRecruitmentCohort(
	workspaceId: string,
): Promise<RecruitmentCohort | null> {
	const { data } = await client.query({
		query: CURRENT_RECRUITMENT_COHORT,
		variables: { workspaceId },
		fetchPolicy: "network-only",
	});
	return data?.currentRecruitmentCohort ?? null;
}

/** 本人简历档案（未建档 → null；跨批次复用） */
export async function fetchMyResumeProfile(
	workspaceId: string,
): Promise<ResumeProfile | null> {
	const { data } = await client.query({
		query: MY_RESUME_PROFILE,
		variables: { workspaceId },
		fetchPolicy: "network-only",
	});
	return data?.myResumeProfile ?? null;
}

/** 本人申请列表（跨批次、新→旧） */
export async function fetchMyVolunteerApplications(
	workspaceId: string,
): Promise<VolunteerApplication[]> {
	const { data } = await client.query({
		query: MY_VOLUNTEER_APPLICATIONS,
		variables: { workspaceId },
		fetchPolicy: "network-only",
	});
	return data?.myVolunteerApplications ?? [];
}

/** 完善 / 更新本人简历档案（一人一档，幂等；返回档案记录供回显） */
export async function upsertResumeProfile(
	workspaceId: string,
	input: UpsertResumeProfileInput,
): Promise<ResumeProfilePayload> {
	const { data } = await client.mutate<{ upsertResumeProfile: ResumeProfilePayload }>({
		mutation: UPSERT_RESUME_PROFILE,
		variables: { workspaceId, input },
	});
	return data?.upsertResumeProfile ?? { result: null, errors: [] };
}

/** 上传简历文件（U2 单入口；须先建档，否则 resume_profile_not_found） */
export async function uploadResumeFile(
	workspaceId: string,
	input: UploadResumeFileInput,
): Promise<ResumeProfilePayload> {
	const { data } = await client.mutate<{ uploadResumeFile: ResumeProfilePayload }>({
		mutation: UPLOAD_RESUME_FILE,
		variables: { workspaceId, input },
	});
	return data?.uploadResumeFile ?? { result: null, errors: [] };
}

/** 提交申请（同批一份；user_id 由后端按 actor 填充） */
export async function createVolunteerApplication(
	workspaceId: string,
	input: CreateVolunteerApplicationInput,
): Promise<VolunteerApplicationPayload> {
	const { data } = await client.mutate<{
		createVolunteerApplication: VolunteerApplicationPayload;
	}>({
		mutation: CREATE_VOLUNTEER_APPLICATION,
		variables: { workspaceId, input },
	});
	return data?.createVolunteerApplication ?? { result: null, errors: [] };
}
