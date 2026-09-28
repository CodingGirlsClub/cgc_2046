// location.ts — 地点定义 schema v0：一张卡 = 一个地点，关卡数 ≤ 该卡 checklist 条数。
// 数据由教研离线编译（v1 手工），游戏进程只读；这里是它进入进程的唯一校验关口。

export type Distractor = { card: string; consequence?: string; explain: string; anchor: string };

export type HandStage = {
  checklist: string;
  mode: "hand";
  kind: "sequence" | "select";
  prompt: string;
  answer: string[];
  distractors: Distractor[];
};

export type MouthStage = { checklist: string; mode: "mouth"; prompt: string; judge_questions: string[] };

export type Stage = HandStage | MouthStage;

export type Location = {
  version: 0;
  location: string;
  region: string;
  title: string;
  unlock_after: string[];
  intro?: string;
  scene: { initial: string; states: Record<string, string> };
  stages: Stage[];
};

const isStr = (v: unknown): v is string => typeof v === "string" && v.length > 0;
const isStrArr = (v: unknown, nonEmpty = true): v is string[] =>
  Array.isArray(v) && (!nonEmpty || v.length > 0) && v.every(isStr);

export function validateLocation(input: unknown): { ok: boolean; errors: string[] } {
  const errors: string[] = [];
  const err = (path: string, msg: string) => errors.push(`${path}: ${msg}`);
  if (typeof input !== "object" || input === null) return { ok: false, errors: ["(root): 必须是对象"] };
  const loc = input as Record<string, any>;

  if (loc.version !== 0) err("version", "必须是 0");
  for (const k of ["location", "region", "title"]) if (!isStr(loc[k])) err(k, "必须是非空字符串");
  if (!isStrArr(loc.unlock_after, false)) err("unlock_after", "必须是字符串数组");
  if (loc.intro !== undefined && !isStr(loc.intro)) err("intro", "必须是非空字符串");

  const states: Record<string, unknown> = loc.scene?.states ?? {};
  if (typeof loc.scene?.states !== "object" || loc.scene.states === null || Object.keys(states).length === 0) {
    err("scene.states", "必须是非空对象（状态名 → 图片文件）");
  } else {
    for (const [name, file] of Object.entries(states)) if (!isStr(file)) err(`scene.states.${name}`, "必须是图片文件名");
    if (!(loc.scene.initial in states)) err("scene.initial", `未声明的情境状态 ${loc.scene.initial}`);
  }

  if (!Array.isArray(loc.stages) || loc.stages.length === 0) {
    err("stages", "必须是非空数组");
    return { ok: errors.length === 0, errors };
  }
  loc.stages.forEach((st: Record<string, any>, i: number) => {
    const p = `stages[${i}]`;
    if (!isStr(st?.checklist)) err(`${p}.checklist`, "必须是非空字符串");
    if (!isStr(st?.prompt)) err(`${p}.prompt`, "必须是非空字符串");
    if (st?.mode === "mouth") {
      if (!isStrArr(st.judge_questions)) err(`${p}.judge_questions`, "必须是非空字符串数组");
    } else if (st?.mode === "hand") {
      if (st.kind !== "sequence" && st.kind !== "select") err(`${p}.kind`, "必须是 sequence 或 select");
      if (!isStrArr(st.answer)) err(`${p}.answer`, "必须是非空字符串数组");
      if (!Array.isArray(st.distractors)) {
        err(`${p}.distractors`, "必须是数组");
        return;
      }
      st.distractors.forEach((d: Record<string, any>, j: number) => {
        const dp = `${p}.distractors[${j}]`;
        if (!isStr(d?.card)) err(`${dp}.card`, "必须是非空字符串");
        else if (isStrArr(st.answer) && st.answer.includes(d.card)) err(`${dp}.card`, `与正确项重名 ${d.card}`);
        if (!isStr(d?.explain)) err(`${dp}.explain`, "必须是非空字符串");
        if (!isStr(d?.anchor)) err(`${dp}.anchor`, "必须是教材锚点");
        if (d?.consequence !== undefined && !(d.consequence in states)) {
          err(`${dp}.consequence`, `未声明的情境状态 ${d.consequence}`);
        }
      });
    } else {
      err(`${p}.mode`, "必须是 hand 或 mouth");
    }
  });
  return { ok: errors.length === 0, errors };
}
