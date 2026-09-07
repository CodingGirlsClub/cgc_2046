import { describe, expect, it } from "vitest";
import { parseCourseContent } from "./course-content";

describe("parseCourseContent", () => {
  it("parses the shared chapter/material JSON shape", () => {
    const parsed = parseCourseContent(
      JSON.stringify({
        chapters: [{ id: "ch1", title: "第一章" }],
        issues: [{ id: "i1", chapter_id: "ch1", objectives: [{ id: "o1" }] }],
      }),
    );
    expect(parsed.chapters?.[0].id).toBe("ch1");
    expect(parsed.issues?.[0].chapter_id).toBe("ch1");
  });

  it("fails closed for invalid JSON", () => {
    expect(parseCourseContent("not-json")).toEqual({});
    expect(parseCourseContent(null)).toEqual({});
  });
});
