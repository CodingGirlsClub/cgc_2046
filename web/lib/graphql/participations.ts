import { gql } from "@apollo/client";
import type { TypedDocumentNode } from "@apollo/client";
import type { MutationResult } from "./shared";

export type EnrollmentStatus =
  "pending" | "payment_pending" | "confirmed" | "rejected" | "expired" | "cancelled";
export type SponsorshipStatus =
  "pending" | "active" | "rejected" | "expired" | "ended";
export type LearningRunStatus = "running" | "waiting" | "succeeded" | "failed";

export interface KeysetPage<T> {
  count: number | null;
  results: T[];
  startKeyset: string | null;
  endKeyset: string | null;
}

export interface ParticipationEnrollment {
  id: string;
  status: EnrollmentStatus;
  targetTitle: string | null;
  eventId: string | null;
  courseId: string | null;
  approvedAt: string | null;
  rejectionReason: string | null;
  approvalDeadline: string | null;
  expiredAt: string | null;
  cancelledAt: string | null;
  insertedAt: string;
}

export interface SponsorshipDelivery {
  benefit: string;
  dueDate: string | null;
  fulfilledAt: string | null;
}

export interface ParticipationSponsorship {
  id: string;
  level: "event" | "workspace";
  status: SponsorshipStatus;
  tierName: string | null;
  amount: number | null;
  targetTitle: string | null;
  approvedAt: string | null;
  rejectionReason: string | null;
  endedAt: string | null;
  deliveries: SponsorshipDelivery[];
}

// S8（ADR-0011）：objective 口径
export interface LearningProgressV2 {
  masteredRequired: number;
  totalRequired: number;
  complete: boolean;
}

export interface LearningNextAction {
  kind: "review" | "remediation" | "developing" | "next_required" | "elective";
  objectiveId: string;
  reason: string;
}

export interface MyLearningRun {
  runId: string;
  enrollmentId: string;
  targetTitle: string | null;
  status: LearningRunStatus;
  staleRevision: boolean;
  progress: LearningProgressV2;
  nextAction: LearningNextAction | null;
  courseId: string | null;
}

export type ParticipationPageVariables = {
  first?: number;
  after?: string;
};

export const MY_ENROLLMENTS: TypedDocumentNode<
  { myEnrollments: KeysetPage<ParticipationEnrollment> },
  ParticipationPageVariables
> = gql`
  query MyParticipationsEnrollments($first: Int, $after: String) {
    myEnrollments(first: $first, after: $after) {
      count
      results {
        id
        status
        targetTitle
        eventId
        courseId
        approvedAt
        rejectionReason
        approvalDeadline
        expiredAt
        cancelledAt
        insertedAt
      }
      startKeyset
      endKeyset
    }
  }
`;

export const MY_SPONSORSHIPS: TypedDocumentNode<
  { mySponsorships: KeysetPage<ParticipationSponsorship> },
  ParticipationPageVariables
> = gql`
  query MyParticipationsSponsorships($first: Int, $after: String) {
    mySponsorships(first: $first, after: $after) {
      count
      results {
        id
        level
        status
        tierName
        amount
        targetTitle
        approvedAt
        rejectionReason
        endedAt
        deliveries {
          benefit
          dueDate
          fulfilledAt
        }
      }
      startKeyset
      endKeyset
    }
  }
`;

export const MY_LEARNING_RUNS: TypedDocumentNode<
  { myLearningRuns: MyLearningRun[] },
  Record<string, never>
> = gql`
  query MyParticipationsLearningRuns {
    myLearningRuns {
      runId
      enrollmentId
      targetTitle
      status
      staleRevision
      progress {
        masteredRequired
        totalRequired
        complete
      }
      nextAction {
        kind
        objectiveId
        reason
      }
      courseId
    }
  }
`;

export const CANCEL_ENROLLMENT: TypedDocumentNode<
  {
    cancelEnrollment: MutationResult<
      Pick<ParticipationEnrollment, "id" | "status" | "cancelledAt">
    >;
  },
  { id: string }
> = gql`
  mutation CancelEnrollment($id: ID!) {
    cancelEnrollment(id: $id) {
      result {
        id
        status
        cancelledAt
      }
      errors {
        message
        code
      }
    }
  }
`;

export const ENROLLMENT_STATUS_LABEL: Record<EnrollmentStatus, string> = {
  pending: "labels.enrollmentStatus.pending",
  payment_pending: "labels.enrollmentStatus.payment_pending",
  confirmed: "labels.enrollmentStatus.confirmed",
  rejected: "labels.enrollmentStatus.rejected",
  expired: "labels.enrollmentStatus.expired",
  cancelled: "labels.enrollmentStatus.cancelled",
};

export const SPONSORSHIP_STATUS_LABEL: Record<SponsorshipStatus, string> = {
  pending: "labels.sponsorshipStatus.pending",
  active: "labels.sponsorshipStatus.active",
  rejected: "labels.sponsorshipStatus.rejected",
  expired: "labels.sponsorshipStatus.expired",
  ended: "labels.sponsorshipStatus.ended",
};

export const LEARNING_RUN_STATUS_LABEL: Record<LearningRunStatus, string> = {
  running: "labels.learningRunStatus.running",
  waiting: "labels.learningRunStatus.waiting",
  succeeded: "labels.learningRunStatus.succeeded",
  failed: "labels.learningRunStatus.failed",
};

/* ---------------- 课程学习详情(U8/R11:学习 tab 抽屉数据,恒本人视角) ---------------- */

// S8（ADR-0011）：objective 掌握地图（issue/checklist 学习语义删除）
export interface LearningRunSummary {
  id: string;
  status: string;
  revisionId: string | null;
  revisionNumber: number | null;
}

export interface LearningPrereqRef {
  id: string;
  title: string | null;
}

export type ObjectiveMastery =
  | "unassessed"
  | "developing"
  | "mastered"
  | "needs_review";

export interface LearningObjectiveState {
  id: string;
  title: string;
  required: boolean;
  issueId: string | null;
  prereqIds: string[];
  mastery: ObjectiveMastery;
  everMastered: boolean;
  locked: boolean;
  missingPrereqIds: LearningPrereqRef[];
  attemptCount: number;
  lastAttemptAt: string | null;
}

export interface CourseLearningDetail {
  courseId: string;
  title: string;
  slug: string | null;
  run: LearningRunSummary | null;
  revisionNumber: number | null;
  staleRevision: boolean;
  objectives: LearningObjectiveState[];
  nextAction: LearningNextAction | null;
  progress: LearningProgressV2;
}

export const COURSE_LEARNING_DETAIL: TypedDocumentNode<
  { courseLearningDetail: CourseLearningDetail | null },
  { courseId: string }
> = gql`
  query CourseLearningDetail($courseId: ID!) {
    courseLearningDetail(courseId: $courseId) {
      courseId
      title
      slug
      run {
        id
        status
        revisionId
        revisionNumber
      }
      revisionNumber
      staleRevision
      objectives {
        id
        title
        required
        issueId
        prereqIds
        mastery
        everMastered
        locked
        missingPrereqIds {
          id
          title
        }
        attemptCount
        lastAttemptAt
      }
      nextAction {
        kind
        objectiveId
        reason
      }
      progress {
        masteredRequired
        totalRequired
        complete
      }
    }
  }
`;
