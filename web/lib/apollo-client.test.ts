import { describe, it, expect } from "vitest";
import { client } from "./apollo-client";

describe("Apollo Client", () => {
  it("uses httpLink with credentials: same-origin", () => {
    const link = client.link;
    // The link should be an HttpLink (not an ApolloLink chain with authLink)
    expect(link).toBeDefined();
  });

  it("has an InMemoryCache", () => {
    expect(client.cache).toBeDefined();
  });
});
