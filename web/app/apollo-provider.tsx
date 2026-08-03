"use client";

import { ApolloProvider } from "@apollo/client/react";
import { client } from "@/lib/apollo-client";
import { AuthProvider } from "@/lib/auth-provider";

export default function ApolloWrapper({ children }: { children: React.ReactNode }) {
	return (
		<ApolloProvider client={client}>
			<AuthProvider>{children}</AuthProvider>
		</ApolloProvider>
	);
}