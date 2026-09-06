import { render } from "@/test-utils";
import { fireEvent, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { MaterialRenderer } from "./material-renderer";

describe("MaterialRenderer", () => {
  it("escapes HTML while rendering the small markdown subset", () => {
    render(<MaterialRenderer material={{ kind: "markdown", body: "**重点** <script>alert(1)</script>" }} />);
    expect(screen.getByTestId("course-material-markdown").innerHTML).toContain("&lt;script&gt;");
    expect(screen.getByText("重点")).toBeInTheDocument();
    expect(screen.queryByRole("script")).not.toBeInTheDocument();
  });

  it("requires alt text and rejects unsafe image URLs", () => {
    render(<MaterialRenderer material={{ kind: "image", title: "图", url: "javascript:alert(1)" }} />);
    expect(screen.getByTestId("course-material-unavailable")).toHaveTextContent("图片材料缺少");
  });

  it("validates Bilibili IDs and falls back to an external link", () => {
    render(<MaterialRenderer material={{ kind: "video", title: "视频", provider: "unknown", external_id: "x", url: "https://example.com/video" }} />);
    expect(screen.getByTestId("course-material-link")).toHaveAttribute("href", "https://example.com/video");
  });

  it("shows a local image loading and failure state", () => {
    render(<MaterialRenderer material={{ kind: "image", title: "图", url: "https://example.com/a.png", alt_text: "图" }} />);
    expect(screen.getByTestId("course-material-image-loading")).toBeInTheDocument();
    fireEvent.error(screen.getByTestId("course-material-image").querySelector("img")!);
    expect(screen.getByTestId("course-material-image-error")).toBeInTheDocument();
  });
});
