// protocol.test.ts — socket 请求的合法性边界：只收 state / apply，apply 只收合法动作
import { describe, expect, test } from "bun:test";
import { Session } from "../src/engine";
import { handleLine } from "../src/protocol";
import type { Location } from "../src/location";

const loc = (): Location => ({
  version: 0,
  location: "x1",
  region: "r1",
  title: "测试地点",
  unlock_after: [],
  scene: { initial: "initial", states: { initial: "a.png", worse: "b.png" } },
  stages: [{ checklist: "x1-1", mode: "mouth", prompt: "为什么", judge_questions: ["是否说明了原因"] }],
});

function session() {
  const s = new Session(loc(), (xs) => xs);
  s.start();
  return s;
}

const call = (s: Session, req: unknown) => handleLine(s, typeof req === "string" ? req : JSON.stringify(req));

describe("handleLine", () => {
  test("state 返回当前视图", () => {
    const r = call(session(), { id: 1, op: "state" });
    expect(r).toMatchObject({ id: 1, ok: true, state: { location: "x1", sceneState: "initial", awaitingMouth: true } });
  });

  test("apply scene_state 合法状态", () => {
    const s = session();
    expect(call(s, { id: 2, op: "apply", scene_state: "worse" })).toEqual({ id: 2, ok: true });
    expect(s.view().sceneState).toBe("worse");
  });

  test("apply scene_state 非法状态被拒", () => {
    expect(call(session(), { id: 3, op: "apply", scene_state: "dead" })).toMatchObject({ id: 3, ok: false });
  });

  test("apply stage_result 回写当前嘴关卡", () => {
    const s = session();
    expect(call(s, { id: 4, op: "apply", stage_result: { stage: "x1-1", met: true } })).toEqual({ id: 4, ok: true });
    expect(s.view().completed).toBe(true);
  });

  test("apply 同时带两种动作被拒", () => {
    const r = call(session(), { id: 5, op: "apply", scene_state: "worse", stage_result: { stage: "x1-1", met: true } });
    expect(r).toMatchObject({ id: 5, ok: false });
  });

  test("apply 不带动作被拒", () => {
    expect(call(session(), { id: 6, op: "apply" })).toMatchObject({ id: 6, ok: false });
  });

  test("stage_result.met 不是布尔被拒", () => {
    const r = call(session(), { id: 7, op: "apply", stage_result: { stage: "x1-1", met: "yes" } });
    expect(r).toMatchObject({ id: 7, ok: false });
  });

  test("未知 op 被拒", () => {
    expect(call(session(), { id: 8, op: "teleport" })).toMatchObject({ id: 8, ok: false });
  });

  test("非 JSON 被拒且不抛异常", () => {
    expect(call(session(), "not json")).toMatchObject({ id: null, ok: false });
  });
});
