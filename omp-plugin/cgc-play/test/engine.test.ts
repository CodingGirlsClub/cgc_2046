// engine.test.ts — 关卡状态机：手关卡确定性判定、情境后果、嘴关卡交接
import { describe, expect, test } from "bun:test";
import { Session, type GameEvent } from "../src/engine";
import type { Location } from "../src/location";

const identity = <T>(xs: T[]) => xs;

const loc = (): Location => ({
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
      answer: ["甲", "乙", "丙"],
      distractors: [{ card: "丁", consequence: "worse", explain: "丁会让情况恶化", anchor: "tb:ch1#p1" }],
    },
    {
      checklist: "x1-2",
      mode: "hand",
      kind: "select",
      prompt: "选出禁用项",
      answer: ["戊"],
      distractors: [{ card: "己", explain: "己是安全的", anchor: "tb:ch1#p2" }],
    },
    { checklist: "x1-3", mode: "mouth", prompt: "为什么", judge_questions: ["是否说明了原因"] },
  ],
});

function started() {
  const events: GameEvent[] = [];
  const s = new Session(loc(), identity);
  s.onEvent((e) => events.push(e));
  s.start();
  return { s, events };
}

describe("sequence 手关卡", () => {
  test("按序选对：逐步推进并在完成时进入下一关", () => {
    const { s } = started();
    expect(s.pick("甲").kind).toBe("ok");
    expect(s.pick("乙").kind).toBe("ok");
    expect(s.view().stage.checklist).toBe("x1-1");
    expect(s.pick("丙").kind).toBe("stage_passed");
    expect(s.view().stage.checklist).toBe("x1-2");
  });

  test("正确项但顺序不对：不计入进度，给出反馈", () => {
    const { s } = started();
    const r = s.pick("乙");
    expect(r.kind).toBe("out_of_order");
    expect(s.view().progress).toEqual([]);
  });

  test("选中干扰项：切到后果情境并给出解释与锚点，不计入进度", () => {
    const { s } = started();
    const r = s.pick("丁");
    expect(r).toMatchObject({ kind: "distractor", explain: "丁会让情况恶化", anchor: "tb:ch1#p1" });
    expect(s.view().sceneState).toBe("worse");
    expect(s.view().progress).toEqual([]);
  });

  test("改正后情境恢复到初始", () => {
    const { s } = started();
    s.pick("丁");
    s.pick("甲");
    expect(s.view().sceneState).toBe("initial");
  });

  test("卡池包含全部正确项与干扰项（经洗牌函数）", () => {
    const { s } = started();
    expect(s.view().pool.map((p) => p.card).sort()).toEqual(["丁", "丙", "乙", "甲"].sort());
  });

  test("默认洗牌不会原样暴露正确顺序（多次抽样至少一次打乱）", () => {
    let shuffledOnce = false;
    for (let i = 0; i < 20 && !shuffledOnce; i++) {
      const s = new Session(loc());
      s.start();
      const order = s.view().pool.map((p) => p.card).filter((c) => ["甲", "乙", "丙"].includes(c));
      shuffledOnce = order.join() !== "甲,乙,丙";
    }
    expect(shuffledOnce).toBe(true);
  });
});

describe("select 手关卡", () => {
  function atSelect() {
    const t = started();
    ["甲", "乙", "丙"].forEach((c) => t.s.pick(c));
    return t;
  }

  test("选中全部正确项即过关", () => {
    const { s } = atSelect();
    expect(s.pick("戊").kind).toBe("stage_passed");
  });

  test("选中干扰项：给出解释，无后果时情境不变", () => {
    const { s } = atSelect();
    expect(s.pick("己")).toMatchObject({ kind: "distractor", explain: "己是安全的" });
    expect(s.view().sceneState).toBe("initial");
  });
});

describe("嘴关卡交接", () => {
  function atMouth() {
    const t = started();
    ["甲", "乙", "丙", "戊"].forEach((c) => t.s.pick(c));
    return t;
  }

  test("进入嘴关卡时发出 mouth_stage 事件并暂停手操作", () => {
    const { s, events } = atMouth();
    expect(events).toContainEqual({
      ev: "mouth_stage",
      location: "x1",
      checklist: "x1-3",
      prompt: "为什么",
      judge_questions: ["是否说明了原因"],
    });
    expect(s.view().awaitingMouth).toBe(true);
    expect(s.pick("甲").kind).toBe("not_hand");
  });

  test("回写 met=true：过关，最后一关完成则发出 location_complete", () => {
    const { s, events } = atMouth();
    expect(s.applyStageResult("x1-3", true)).toEqual({ ok: true });
    expect(s.view().completed).toBe(true);
    expect(events).toContainEqual({ ev: "location_complete", location: "x1" });
  });

  test("回写 met=false：停留在本关，继续等待", () => {
    const { s } = atMouth();
    expect(s.applyStageResult("x1-3", false)).toEqual({ ok: true });
    expect(s.view().awaitingMouth).toBe(true);
    expect(s.view().completed).toBe(false);
  });

  test("回写非当前关卡被拒", () => {
    const { s } = atMouth();
    expect(s.applyStageResult("x1-1", true)).toMatchObject({ ok: false });
  });

  test("不在嘴关卡时回写被拒", () => {
    const { s } = started();
    expect(s.applyStageResult("x1-1", true)).toMatchObject({ ok: false });
  });
});

describe("情境状态", () => {
  test("applyScene 只接受已声明的状态", () => {
    const { s } = started();
    expect(s.applyScene("worse")).toEqual({ ok: true });
    expect(s.view().sceneState).toBe("worse");
    expect(s.applyScene("dead")).toMatchObject({ ok: false });
    expect(s.view().sceneState).toBe("worse");
  });
});
