// engine.ts — 关卡状态机。确定性代码拥有规则、顺序与情境状态；
// agent 只能经 protocol 的两个合法动作（换情境、回写嘴关卡结果）影响它。

import type { Distractor, HandStage, Location, Stage } from "./location";

export type GameEvent =
  | { ev: "mouth_stage"; location: string; checklist: string; prompt: string; judge_questions: string[] }
  | { ev: "location_complete"; location: string };

export type PickResult =
  | { kind: "ok" }
  | { kind: "stage_passed" }
  | { kind: "out_of_order" }
  | { kind: "already" }
  | { kind: "distractor"; explain: string; anchor: string }
  | { kind: "not_hand" };

type Result = { ok: true } | { ok: false; error: string };

function shuffle<T>(xs: T[]): T[] {
  const a = [...xs];
  for (let i = a.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a;
}

export class Session {
  private stageIndex = 0;
  private sceneState: string;
  private progress: string[] = [];
  private pool: string[] = [];
  private completed = false;
  private listeners: ((e: GameEvent) => void)[] = [];

  constructor(
    readonly loc: Location,
    private readonly order: (cards: string[]) => string[] = shuffle,
  ) {
    this.sceneState = loc.scene.initial;
  }

  onEvent(fn: (e: GameEvent) => void) {
    this.listeners.push(fn);
  }

  start() {
    this.enterStage(0);
  }

  view() {
    const stage = this.stage();
    return {
      location: this.loc.location,
      title: this.loc.title,
      stageIndex: this.stageIndex,
      stageCount: this.loc.stages.length,
      stage: { checklist: stage.checklist, mode: stage.mode, prompt: stage.prompt },
      sceneState: this.sceneState,
      pool: this.pool.map((card) => ({ card, picked: this.progress.includes(card) })),
      progress: [...this.progress],
      awaitingMouth: !this.completed && stage.mode === "mouth",
      completed: this.completed,
    };
  }

  pick(card: string): PickResult {
    const stage = this.stage();
    if (this.completed || stage.mode !== "hand") return { kind: "not_hand" };
    const miss = stage.distractors.find((d: Distractor) => d.card === card);
    if (miss) {
      if (miss.consequence) this.sceneState = miss.consequence;
      return { kind: "distractor", explain: miss.explain, anchor: miss.anchor };
    }
    if (!stage.answer.includes(card)) return { kind: "not_hand" };
    if (this.progress.includes(card)) return { kind: "already" };
    if (stage.kind === "sequence" && stage.answer[this.progress.length] !== card) return { kind: "out_of_order" };

    this.progress.push(card);
    this.sceneState = this.loc.scene.initial; // 改正即恢复：后果可挽回
    if (this.progress.length === stage.answer.length) {
      this.advance();
      return { kind: "stage_passed" };
    }
    return { kind: "ok" };
  }

  applyScene(state: string): Result {
    if (!(state in this.loc.scene.states)) return { ok: false, error: `未声明的情境状态 ${state}` };
    this.sceneState = state;
    return { ok: true };
  }

  applyStageResult(checklist: string, met: boolean): Result {
    const stage = this.stage();
    if (this.completed || stage.mode !== "mouth") return { ok: false, error: "当前不在嘴关卡" };
    if (stage.checklist !== checklist) return { ok: false, error: `当前关卡是 ${stage.checklist}，不是 ${checklist}` };
    if (met) this.advance();
    return { ok: true };
  }

  private stage(): Stage {
    return this.loc.stages[this.stageIndex];
  }

  private advance() {
    if (this.stageIndex + 1 < this.loc.stages.length) {
      this.enterStage(this.stageIndex + 1);
      return;
    }
    this.completed = true;
    this.emit({ ev: "location_complete", location: this.loc.location });
  }

  private enterStage(i: number) {
    this.stageIndex = i;
    this.progress = [];
    this.sceneState = this.loc.scene.initial;
    const stage = this.stage();
    if (stage.mode === "hand") {
      const h = stage as HandStage;
      this.pool = this.order([...h.answer, ...h.distractors.map((d) => d.card)]);
      return;
    }
    this.pool = [];
    this.emit({
      ev: "mouth_stage",
      location: this.loc.location,
      checklist: stage.checklist,
      prompt: stage.prompt,
      judge_questions: stage.judge_questions,
    });
  }

  private emit(e: GameEvent) {
    for (const fn of this.listeners) fn(e);
  }
}
