import { gql } from "@apollo/client";
import type { TypedDocumentNode } from "@apollo/client";
import { client } from "@/lib/apollo-client";

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
};

export type PublicInitiative = {
	id: string;
	name: string;
	slug: string;
	hashtag: string | null;
	description: string | null;
	status: string;
	cityCount: number;
	eventCount: number;
	confirmedCount: number;
	qualifiedEventCount: number;
	cities: Array<{ city: string; events: InitiativeEvent[] }>;
};

export type PublicInitiativeCard = Pick<
	PublicInitiative,
	"id" | "name" | "slug" | "status" | "hashtag" | "description"
> & {
	windowStartsAt: string | null;
	windowEndsAt: string | null;
};

const PUBLIC_INITIATIVE: TypedDocumentNode<
	{ publicInitiative: PublicInitiative | null },
	{ slug: string }
> = gql`
	query PublicInitiative($slug: String!) {
		publicInitiative(slug: $slug) {
			id name slug hashtag description status cityCount eventCount confirmedCount qualifiedEventCount
			cities { city events { id slug title status visibility startsAt endsAt registrationDeadline venue confirmedCount minParticipants qualificationStatus qualificationBadge shortBy archived } }
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

export async function fetchPublicInitiative(slug: string): Promise<PublicInitiative | null> {
	const { data } = await client.query({ query: PUBLIC_INITIATIVE, variables: { slug }, fetchPolicy: "network-only" });
	return data?.publicInitiative ?? null;
}

export async function fetchPublicInitiatives(): Promise<PublicInitiativeCard[]> {
	const { data } = await client.query({ query: PUBLIC_INITIATIVES, variables: {}, fetchPolicy: "network-only" });
	return data?.publicInitiatives ?? [];
}
