import { describe, it, expect } from "vitest";
import { render, screen } from "@testing-library/react";
import ApolloWrapper from "./apollo-provider";

describe("ApolloWrapper", () => {
  it("wraps children with the ApolloProvider", () => {
    render(
      <ApolloWrapper>
        <div>wired-child</div>
      </ApolloWrapper>,
    );

    expect(screen.getByText("wired-child")).toBeInTheDocument();
  });
});
