import { ApolloClient, InMemoryCache, createHttpLink, ApolloLink, from } from "@apollo/client";

/**
 * Reads the auth token from the httpOnly cookie set at login time.
 * Returns undefined when no token is present (public/guest requests).
 */
export function getAuthToken(): string | undefined {
  if (typeof document === "undefined") return undefined;
  const match = document.cookie.match(/(?:^|;\s*)cgc_token=([^;]+)/);
  return match ? decodeURIComponent(match[1]) : undefined;
}

/**
 * Builds request headers for a GraphQL operation, attaching
 * `Authorization: Bearer <token>` when a token is available.
 */
export function buildAuthHeaders(
  token: string | undefined,
  headers: Record<string, string> = {},
): Record<string, string> {
  return {
    ...headers,
    ...(token ? { authorization: `Bearer ${token}` } : {}),
  };
}

/**
 * Apollo link middleware: attaches `Authorization: Bearer <token>` from the
 * httpOnly cookie to every request that has one.
 */
export const authLink = new ApolloLink((operation, forward) => {
  const token = getAuthToken();
  operation.setContext(({ headers = {} }) => ({
    headers: buildAuthHeaders(token, headers),
  }));
  return forward(operation);
});

const httpLink = createHttpLink({
  // Default: go through the Next.js rewrite proxy (no CORS).
  // Override with NEXT_PUBLIC_GRAPHQL_URL to talk to the backend directly.
  uri: process.env.NEXT_PUBLIC_GRAPHQL_URL ?? "/api/graphql",
});

export const client = new ApolloClient({
  link: from([authLink, httpLink]),
  cache: new InMemoryCache(),
});
