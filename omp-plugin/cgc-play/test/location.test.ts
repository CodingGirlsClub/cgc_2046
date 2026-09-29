// location.test.ts — 地点定义 schema v0 校验
import { describe, expect, test } from "bun:test";
import { validateLocation } from "../src/location";
import c21 from "../fixtures/c21/location.json";

const minimal = () => ({
  version: 0,
  location: "x1",
  region: "r1",
  title: "测试地点",
  unlock_after: [],
  scene: { initial: "initial", states: { initial: "a.png", worse: "b.png" } },
  stages: [
    {
      checklist: "x1-1",
      mode: "hand",
      kind: "sequence",
      prompt: "排序",
      answer: ["甲", "乙"],
      distractors: [{ card: "丙", consequence: "worse", explain: "丙不对", anchor: "tb:ch1#p1" }],
    },
    { checklist: "x1-2", mode: "mouth", prompt: "为什么", judge_questions: ["是否说明了原因"] },
  ],
});

describe("validateLocation", () => {
  test("c21 fixture 通过校验", () => {
    const r = validateLocation(c21);
    expect(r.errors).toEqual([]);
    expect(r.ok).toBe(true);
  });

  test("最小合法定义通过", () => {
    expect(validateLocation(minimal()).ok).toBe(true);
  });

  test("缺字段时报出具体字段路径", () => {
    const loc = minimal() as any;
    delete loc.stages[1].judge_questions;
    const r = validateLocation(loc);
    expect(r.ok).toBe(false);
    expect(r.errors).toContain("stages[1].judge_questions: 必须是非空字符串数组");
  });

  test("干扰项的后果必须是已声明的情境状态", () => {
    const loc = minimal() as any;
    loc.stages[0].distractors[0].consequence = "dead";
    const r = validateLocation(loc);
    expect(r.errors).toContain("stages[0].distractors[0].consequence: 未声明的情境状态 dead");
  });

  test("scene.initial 必须在 states 里", () => {
    const loc = minimal() as any;
    loc.scene.initial = "nope";
    expect(validateLocation(loc).errors).toContain("scene.initial: 未声明的情境状态 nope");
  });

  test("hand 关卡的正确项与干扰项不能重名", () => {
    const loc = minimal() as any;
    loc.stages[0].distractors[0].card = "甲";
    expect(validateLocation(loc).errors).toContain("stages[0].distractors[0].card: 与正确项重名 甲");
  });

  test("未知 mode / kind 被拒", () => {
    const loc = minimal() as any;
    loc.stages[0].kind = "drag";
    loc.stages[1].mode = "voice";
    const errs = validateLocation(loc).errors;
    expect(errs).toContain("stages[0].kind: 必须是 sequence 或 select");
    expect(errs).toContain("stages[1].mode: 必须是 hand 或 mouth");
  });

  test("非对象输入不抛异常", () => {
    expect(validateLocation(null).ok).toBe(false);
    expect(validateLocation("x").ok).toBe(false);
  });
});
