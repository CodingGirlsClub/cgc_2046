import { describe, it, expect } from "vitest";
import { client, httpLinkOptions } from "./apollo-client";

describe("Apollo Client", () => {
	it("uses credentials: same-origin for httpOnly cookie auth", () => {
		expect(httpLinkOptions.credentials).toBe("same-origin");
	});

	it("has an InMemoryCache", () => {
		expect(client.cache).toBeDefined();
	});
});
