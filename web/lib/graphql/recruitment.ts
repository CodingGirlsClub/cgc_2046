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

// ── 管理侧（U8 审核面板；2046 台 Owner/Admin ∪ platform_admin）──────────────

/** 管理侧申请行（= 申请人侧同形 + userId：面板要显示与筛选「是谁」） */
export type AdminVolunteerApplication = VolunteerApplication & { userId: string };

export type VolunteerApplicationDetail = {
	application: AdminVolunteerApplication;
	/** 申请人简历档案（未建档 → null） */
	resumeProfile: ResumeProfile | null;
};

const ADMIN_APPLICATION_FIELDS = `id userId cohortId position city heardAboutUs hasInternalReferrer message status rejectionReason assignedAt assignmentNote`;

const DETAIL_RESUME_FIELDS = `id fullName contactEmail weeklyHours skills fileName fileContentType fileSize uploadedAt`;

const LIST_VOLUNTEER_APPLICATIONS: TypedDocumentNode<
	{ listVolunteerApplications: AdminVolunteerApplication[] },
	{
		workspaceId: string;
		cohortId?: string | null;
		position?: string | null;
		status?: string | null;
	}
> = gql`
	query ListVolunteerApplications($workspaceId: ID!, $cohortId: ID, $position: String, $status: String) {
		listVolunteerApplications(workspaceId: $workspaceId, cohortId: $cohortId, position: $position, status: $status) {
			${ADMIN_APPLICATION_FIELDS}
		}
	}
`;

const VOLUNTEER_APPLICATION_DETAIL: TypedDocumentNode<
	{ volunteerApplicationDetail: VolunteerApplicationDetail | null },
	{ workspaceId: string; id: string }
> = gql`
	query VolunteerApplicationDetail($workspaceId: ID!, $id: ID!) {
		volunteerApplicationDetail(workspaceId: $workspaceId, id: $id) {
			application { ${ADMIN_APPLICATION_FIELDS} }
			resumeProfile { ${DETAIL_RESUME_FIELDS} }
		}
	}
`;

const LIST_RECRUITMENT_COHORTS: TypedDocumentNode<
	{ listRecruitmentCohorts: RecruitmentCohort[] },
	{ workspaceId: string }
> = gql`
	query ListRecruitmentCohorts($workspaceId: ID!) {
		listRecruitmentCohorts(workspaceId: $workspaceId) { ${COHORT_FIELDS} }
	}
`;

/** 段位推进返回（与申请人侧 create 同通道：result + errors） */
const APPLICATION_MUTATION_RESULT = `
	result { ${ADMIN_APPLICATION_FIELDS} }
	errors { message code }
`;

const ADVANCE_TO_INTERVIEW: TypedDocumentNode<
	{ advanceVolunteerApplicationToInterview: MutationOutcome<AdminVolunteerApplication> },
	{ workspaceId: string; id: string }
> = gql`
	mutation AdvanceToInterview($workspaceId: ID!, $id: ID!) {
		advanceVolunteerApplicationToInterview(workspaceId: $workspaceId, id: $id) { ${APPLICATION_MUTATION_RESULT} }
	}
`;

const ADVANCE_TO_TRAINING: TypedDocumentNode<
	{ advanceVolunteerApplicationToTraining: MutationOutcome<AdminVolunteerApplication> },
	{ workspaceId: string; id: string }
> = gql`
	mutation AdvanceToTraining($workspaceId: ID!, $id: ID!) {
		advanceVolunteerApplicationToTraining(workspaceId: $workspaceId, id: $id) { ${APPLICATION_MUTATION_RESULT} }
	}
`;

const ASSIGN_APPLICATION: TypedDocumentNode<
	{ assignVolunteerApplication: MutationOutcome<AdminVolunteerApplication> },
	{ workspaceId: string; id: string; assignedEventId: string | null; assignmentNote: string | null }
> = gql`
	mutation AssignVolunteerApplication($workspaceId: ID!, $id: ID!, $assignedEventId: ID, $assignmentNote: String) {
		assignVolunteerApplication(workspaceId: $workspaceId, id: $id, assignedEventId: $assignedEventId, assignmentNote: $assignmentNote) { ${APPLICATION_MUTATION_RESULT} }
	}
`;

const REJECT_APPLICATION: TypedDocumentNode<
	{ rejectVolunteerApplication: MutationOutcome<AdminVolunteerApplication> },
	{ workspaceId: string; id: string; reason: string }
> = gql`
	mutation RejectVolunteerApplication($workspaceId: ID!, $id: ID!, $reason: String) {
		rejectVolunteerApplication(workspaceId: $workspaceId, id: $id, reason: $reason) { ${APPLICATION_MUTATION_RESULT} }
	}
`;

const CANCEL_APPLICATION: TypedDocumentNode<
	{ cancelVolunteerApplication: MutationOutcome<AdminVolunteerApplication> },
	{ workspaceId: string; id: string; reason: string | null }
> = gql`
	mutation CancelVolunteerApplication($workspaceId: ID!, $id: ID!, $reason: String) {
		cancelVolunteerApplication(workspaceId: $workspaceId, id: $id, reason: $reason) { ${APPLICATION_MUTATION_RESULT} }
	}
`;

const COHORT_MUTATION_RESULT = `
	result { ${COHORT_FIELDS} }
	errors { message code }
`;

const CREATE_RECRUITMENT_COHORT: TypedDocumentNode<
	{ createRecruitmentCohort: MutationOutcome<RecruitmentCohort> },
	{ workspaceId: string; input: { name: string; applyDeadlineAt: string; startsAt?: string | null; endsAt?: string | null } }
> = gql`
	mutation CreateRecruitmentCohort($workspaceId: ID!, $input: CreateRecruitmentCohortInput!) {
		createRecruitmentCohort(workspaceId: $workspaceId, input: $input) { ${COHORT_MUTATION_RESULT} }
	}
`;

const OPEN_RECRUITMENT_COHORT: TypedDocumentNode<
	{ openRecruitmentCohort: MutationOutcome<RecruitmentCohort> },
	{ workspaceId: string; id: string }
> = gql`
	mutation OpenRecruitmentCohort($workspaceId: ID!, $id: ID!) {
		openRecruitmentCohort(workspaceId: $workspaceId, id: $id) { ${COHORT_MUTATION_RESULT} }
	}
`;

const CLOSE_RECRUITMENT_COHORT: TypedDocumentNode<
	{ closeRecruitmentCohort: MutationOutcome<RecruitmentCohort> },
	{ workspaceId: string; id: string }
> = gql`
	mutation CloseRecruitmentCohort($workspaceId: ID!, $id: ID!) {
		closeRecruitmentCohort(workspaceId: $workspaceId, id: $id) { ${COHORT_MUTATION_RESULT} }
	}
`;

/** 管理侧申请列表（按批次/职位/状态过滤；非管理角色 → 服务端 forbidden 抛出） */
export async function fetchVolunteerApplications(
	workspaceId: string,
	filter: { cohortId?: string | null; position?: string | null; status?: string | null } = {},
): Promise<AdminVolunteerApplication[]> {
	const { data } = await client.query({
		query: LIST_VOLUNTEER_APPLICATIONS,
		variables: {
			workspaceId,
			cohortId: filter.cohortId ?? null,
			position: filter.position ?? null,
			status: filter.status ?? null,
		},
		fetchPolicy: "network-only",
	});
	return data?.listVolunteerApplications ?? [];
}

/** 申请详情（含申请人档案元数据；未建档 → resumeProfile null） */
export async function fetchVolunteerApplicationDetail(
	workspaceId: string,
	id: string,
): Promise<VolunteerApplicationDetail | null> {
	const { data } = await client.query({
		query: VOLUNTEER_APPLICATION_DETAIL,
		variables: { workspaceId, id },
		fetchPolicy: "network-only",
	});
	return data?.volunteerApplicationDetail ?? null;
}

/** 全部批次（管理侧；含 draft/closed，供过滤与批次管理） */
export async function fetchRecruitmentCohorts(workspaceId: string): Promise<RecruitmentCohort[]> {
	const { data } = await client.query({
		query: LIST_RECRUITMENT_COHORTS,
		variables: { workspaceId },
		fetchPolicy: "network-only",
	});
	return data?.listRecruitmentCohorts ?? [];
}

export async function advanceVolunteerApplication(
	workspaceId: string,
	id: string,
	stage: "interview" | "training",
): Promise<MutationOutcome<AdminVolunteerApplication>> {
	if (stage === "interview") {
		const { data } = await client.mutate({
			mutation: ADVANCE_TO_INTERVIEW,
			variables: { workspaceId, id },
		});
		const outcome = data?.advanceVolunteerApplicationToInterview ?? { result: null, errors: [] };
		return { result: outcome?.result ?? null, errors: outcome?.errors ?? [] };
	}

	const { data } = await client.mutate({
		mutation: ADVANCE_TO_TRAINING,
		variables: { workspaceId, id },
	});
	const outcome = data?.advanceVolunteerApplicationToTraining ?? { result: null, errors: [] };
	return { result: outcome?.result ?? null, errors: outcome?.errors ?? [] };
}

/** 项目分配（R15：分配副作用由后端同事务完成——入台 + 角色 + EventModerator） */
export async function assignVolunteerApplication(
	workspaceId: string,
	id: string,
	args: { assignedEventId?: string | null; assignmentNote?: string | null } = {},
): Promise<MutationOutcome<AdminVolunteerApplication>> {
	const { data } = await client.mutate({
		mutation: ASSIGN_APPLICATION,
		variables: {
			workspaceId,
			id,
			assignedEventId: args.assignedEventId ?? null,
			assignmentNote: args.assignmentNote ?? null,
		},
	});
	const outcome = data?.assignVolunteerApplication ?? { result: null, errors: [] };
	return { result: outcome?.result ?? null, errors: outcome?.errors ?? [] };
}

/** 拒绝（原因必填；空白/缺失 → 服务端 volunteer_application_rejection_reason_required） */
export async function rejectVolunteerApplication(
	workspaceId: string,
	id: string,
	reason: string,
): Promise<MutationOutcome<AdminVolunteerApplication>> {
	const { data } = await client.mutate({
		mutation: REJECT_APPLICATION,
		variables: { workspaceId, id, reason },
	});
	const outcome = data?.rejectVolunteerApplication ?? { result: null, errors: [] };
	return { result: outcome?.result ?? null, errors: outcome?.errors ?? [] };
}

/** 取消（备注选填；与拒绝不同，无必填约束） */
export async function cancelVolunteerApplication(
	workspaceId: string,
	id: string,
	reason?: string | null,
): Promise<MutationOutcome<AdminVolunteerApplication>> {
	const { data } = await client.mutate({
		mutation: CANCEL_APPLICATION,
		variables: { workspaceId, id, reason: reason ?? null },
	});
	const outcome = data?.cancelVolunteerApplication ?? { result: null, errors: [] };
	return { result: outcome?.result ?? null, errors: outcome?.errors ?? [] };
}

export async function createRecruitmentCohort(
	workspaceId: string,
	input: { name: string; applyDeadlineAt: string; startsAt?: string | null; endsAt?: string | null },
): Promise<MutationOutcome<RecruitmentCohort>> {
	const { data } = await client.mutate({
		mutation: CREATE_RECRUITMENT_COHORT,
		variables: { workspaceId, input },
	});
	const outcome = data?.createRecruitmentCohort ?? { result: null, errors: [] };
	return { result: outcome?.result ?? null, errors: outcome?.errors ?? [] };
}

/** 开放批次（同台已有 open → 服务端 recruitment_cohort_open_conflict） */
export async function openRecruitmentCohort(
	workspaceId: string,
	id: string,
): Promise<MutationOutcome<RecruitmentCohort>> {
	const { data } = await client.mutate({
		mutation: OPEN_RECRUITMENT_COHORT,
		variables: { workspaceId, id },
	});
	const outcome = data?.openRecruitmentCohort ?? { result: null, errors: [] };
	return { result: outcome?.result ?? null, errors: outcome?.errors ?? [] };
}

export async function closeRecruitmentCohort(
	workspaceId: string,
	id: string,
): Promise<MutationOutcome<RecruitmentCohort>> {
	const { data } = await client.mutate({
		mutation: CLOSE_RECRUITMENT_COHORT,
		variables: { workspaceId, id },
	});
	const outcome = data?.closeRecruitmentCohort ?? { result: null, errors: [] };
	return { result: outcome?.result ?? null, errors: outcome?.errors ?? [] };
}
